<#
.SYNOPSIS
  Self-contained, read-only validator: is auto-instrumentation configured on this
  host, and is every receiver in the collector config actually producing data?

.DESCRIPTION
  ONE FILE, NO DEPENDENCIES. Copy it to any Windows host and run it. It does not
  dot-source anything, does not need the rest of the repo, and does not need a
  PowerShell module (in particular NOT powershell-yaml or WebAdministration).

  Eight checks:

    collector       collector process / service / health 13133 / OTLP ports
    config          locate + parse the collector YAML actually in effect
    receiverWiring  every configured receiver is wired into a pipeline
    receiverFlow    every wired receiver is PRODUCING DATA right now, measured
                    as a delta on the collector's own :8888 counters
    endpoints       (-ProbeEndpoints) what each receiver POINTS AT is reachable
    exporterFlow    data is leaving for Coralogix, and is not failing or queuing
    iis             the .NET CLR profiler is attached and the pools carry OTLP
    node            PM2 apps carry NODE_OPTIONS=--require <register> + OTEL_*

  The receiverFlow check is the reason this script exists. Everything else in the
  repo answers "is it configured?"; nothing answered "is it working?". A dead
  rabbitmq broker, a filelog glob that matches no files, or a windowseventlog
  channel we cannot read are all invisible to a config-only check.

  READ-ONLY by default. Reads the registry, applicationHost.config, web.config,
  the collector YAML, `pm2 jlist`, and two HTTP GETs against loopback. Writes
  nothing, starts nothing, restarts nothing. The single exception is opt-in:
  -SendTestSpan posts one synthetic span to the local OTLP receiver.

  Exit codes are GRADED, so BatchPatch can triage a fleet run:
    0 = pass       everything checked is good (or legitimately N/A here)
    1 = hard fail  the collector is down, or something is definitively broken
    2 = degraded   it runs, but something is misconfigured or not flowing

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-CxInstrumentation.ps1

.EXAMPLE
  # Just the data-flow question, fast, for a fleet sweep:
  .\Test-CxInstrumentation.ps1 -Only collector,receiverFlow -Fast

.EXAMPLE
  # Parse a config file without touching this host at all:
  .\Test-CxInstrumentation.ps1 -Only config,receiverWiring -CollectorConfig .\config.supervisor.yaml

.NOTES
  Windows PowerShell 5.1.

  ELEVATION. applicationHost.config and the service Environment registry values
  are readable by Administrators only, so on a host that HAS IIS the `iis` check
  hard-fails when not elevated rather than reporting every app as unconfigured.
  Every other check runs fine unelevated, so the config/wiring/flow checks can be
  used non-elevated, and `-Only config,receiverWiring -CollectorConfig <file>`
  parses a config file on any machine without touching the host at all.
#>
# PositionalBinding=$false is deliberate. Under `powershell -File`, an array
# parameter binds only the NEXT token, so `-Only config receiverFlow` would bind
# 'config' to -Only and then silently bind 'receiverFlow' to the first positional
# parameter - a wrong run with no error. With positional binding off that mistake
# is rejected outright and the user is told to use the comma form.
[CmdletBinding(PositionalBinding = $false)]
param(
    # Run only these checks. Anything omitted reports SKIP and does not affect the
    # exit code. Accepts both forms, because both occur in practice:
    #     -Only config,receiverFlow    (ONE string under `powershell -File`)
    #     -Only config receiverFlow    (rejected - see PositionalBinding above)
    #
    # Deliberately NO [ValidateSet]: under -File a comma-joined list arrives as a
    # single string and ValidateSet rejects it outright, and a typo would fail
    # parameter binding before any output exists - a red BatchPatch row with zero
    # diagnostics. Normalised and validated below with a readable error instead.
    [string[]] $Only,

    # --- collector / config ----------------------------------------------------
    # Override the config to parse. When omitted the script finds the one actually
    # in effect (see Get-CxCollectorConfig).
    [string]   $CollectorConfig,
    [string]   $MetricsUrl,                       # default: derived from the config + socket
    [string]   $HealthUrl        = 'http://127.0.0.1:13133',
    [int]      $OtlpHttpPort     = 4318,
    [int]      $OtlpGrpcPort     = 4317,

    # --- receiverFlow tuning ---------------------------------------------------
    # Two scrapes this far apart. 35s covers the slowest default scrape interval
    # in the shipped config (iis and the prometheus self-scrape are both 30s) plus
    # jitter margin. Raised automatically if the config has a slower receiver.
    [int]      $SampleSeconds    = 35,
    [switch]   $Fast,                             # one scrape, absolute-only

    # --- opt-in probes ---------------------------------------------------------
    [switch]   $ProbeEndpoints,                   # reach out to what receivers point at
    [switch]   $SendTestSpan,                     # NOT read-only: injects one span

    # --- instrumentation checks ------------------------------------------------
    # 127.0.0.1, not localhost: on a dual-stack host `localhost` resolves to ::1
    # first and OTLP export is silently dropped.
    [string]   $ExpectedOtlpEndpoint = 'http://127.0.0.1:4318',
    [string]   $AppHostConfig        = (Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'),
    [string]   $InstallPrefix        = 'C:\cx\otel-node',
    [string]   $Package              = '@opentelemetry/auto-instrumentations-node',

    # --- output ----------------------------------------------------------------
    [string]   $JsonPath,
    [switch]   $NoFileOutput,
    [switch]   $Quiet,
    [switch]   $PassThru,
    [int]      $TimeoutSec       = 10
)

# Native probes (netstat, pm2) write to stderr; under 'Stop' that becomes a
# terminating NativeCommandError in PS 5.1.
$ErrorActionPreference = 'Continue'

# $PSScriptRoot is empty under `powershell -File <relative>`.
$script:CxHere = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# Hard ceiling on the whole run so a fleet sweep can never hang on one host.
$script:CxDeadline = (Get-Date).AddSeconds(300)
function Test-CxOutOfTime { (Get-Date) -gt $script:CxDeadline }

# ===========================================================================
# SECTION 1 - finding model
#
# Embedded copy of deploy\Write-DeployLog.ps1 so this file stands alone. Keep the
# row format and the severity ranks identical to that file: fleet output must
# stay greppable across both.
#
# NON-NEGOTIABLE: no function here may throw, and none may write to the success
# stream. Callers' return values are meaningful.
# ===========================================================================

$script:CxSeverityRank = @{
    fail    = 0
    warn    = 1
    unknown = 2
    info    = 3
    skip    = 4
    pass    = 5
}

function New-Finding {
    <#
      One finding. `Code` is a stable SCREAMING_SNAKE token operators grep for;
      `Message` is the human sentence; `Data` carries the evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Check,
        [Parameter(Mandatory)][ValidateSet('pass','warn','fail','info','skip','unknown')]
        [string] $Severity,
        [string] $Code    = '',
        [string] $Message = '',
        [string] $Target  = '',
        $Data             = $null
    )
    [pscustomobject]@{
        check    = $Check
        severity = $Severity
        code     = $Code
        target   = $Target
        message  = $Message
        data     = $Data
    }
}

function Get-FindingCounts {
    [CmdletBinding()]
    param([object[]] $Findings)
    $counts = [ordered]@{ pass = 0; warn = 0; fail = 0; info = 0; skip = 0; unknown = 0 }
    foreach ($f in @($Findings)) {
        if (-not $f) { continue }
        $s = [string]$f.severity
        if ($counts.Contains($s)) { $counts[$s]++ }
    }
    $counts
}

function Get-GradedExitCode {
    <#
      1 = any fail, 2 = no fail but at least one warn, 0 = otherwise.
      info / skip / unknown never move the code: reporting "broken" when we merely
      could not look would send an operator down the wrong path, which is the
      exact failure this tooling exists to prevent.
    #>
    [CmdletBinding()]
    param([object[]] $Findings)
    $c = Get-FindingCounts -Findings $Findings
    if ($c.fail -gt 0) { return 1 }
    if ($c.warn -gt 0) { return 2 }
    return 0
}

function Write-FindingTable {
    [CmdletBinding()]
    param([object[]] $Findings, [string] $Title, [switch] $Quiet)
    try {
        if ($Title) {
            Write-Host ''
            Write-Host ("== {0} " -f $Title).PadRight(78, '=')
        }
        $rows = @($Findings) | Where-Object { $_ }
        if ($Quiet) {
            $rows = @($rows | Where-Object { $_.severity -ne 'pass' -and $_.severity -ne 'skip' })
        }
        if (-not $rows -or $rows.Count -eq 0) {
            Write-Host '  (nothing to report)'
            return
        }
        # Worst first, then by check, so the actionable lines are at the top of a
        # long BatchPatch output pane.
        $rows = @($rows | Sort-Object `
            @{ Expression = { $script:CxSeverityRank[[string]$_.severity] } }, `
            @{ Expression = { [string]$_.check } })

        foreach ($f in $rows) {
            $sev = ([string]$f.severity).ToUpperInvariant()
            $color = switch ([string]$f.severity) {
                'fail'    { 'Red' }
                'warn'    { 'Yellow' }
                'pass'    { 'Green' }
                'unknown' { 'Magenta' }
                'skip'    { 'DarkGray' }
                default   { 'Gray' }
            }
            $label = if ($f.target) { "{0}[{1}]" -f $f.check, $f.target } else { [string]$f.check }
            $line  = "  [{0,-7}] {1,-34} {2}" -f $sev, $label, $f.message
            if ($f.code) { $line = "{0}  ({1})" -f $line, $f.code }
            Write-Host $line -ForegroundColor $color
        }
    } catch {
        try {
            Write-Host "  [WARN   ] finding-table render failed: $($_.Exception.Message)"
            foreach ($f in @($Findings)) {
                if ($f) { Write-Host ("  {0} {1} {2} {3}" -f $f.severity, $f.check, $f.code, $f.message) }
            }
        } catch { }
    }
}

function Write-FindingSummary {
    [CmdletBinding()]
    param([object[]] $Findings, [string] $Label = 'RESULT', [int] $ExitCode = -1)
    try {
        $c = Get-FindingCounts -Findings $Findings
        if ($ExitCode -lt 0) { $ExitCode = Get-GradedExitCode -Findings $Findings }
        $verdict = switch ($ExitCode) {
            0       { 'PASS' }
            1       { 'HARD FAIL' }
            2       { 'DEGRADED' }
            default { "exit $ExitCode" }
        }
        $color = switch ($ExitCode) { 0 { 'Green' } 1 { 'Red' } 2 { 'Yellow' } default { 'Gray' } }
        Write-Host ''
        Write-Host ("  {0} pass, {1} warn, {2} fail, {3} unknown, {4} skipped" -f `
            $c.pass, $c.warn, $c.fail, $c.unknown, $c.skip)
        Write-Host ("=== {0} RESULT: {1}  exit={2} ===" -f $Label, $verdict, $ExitCode) -ForegroundColor $color
    } catch { }
}

# ===========================================================================
# SECTION 2 - generic helpers: elevation, HTTP, sockets, Prometheus text
# ===========================================================================

function Test-CxElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-CxRawGet {
    <#
      HTTP GET with the proxy explicitly disabled for THIS request.

      Why not Invoke-WebRequest: it honours the WinINET/system proxy and
      $env:HTTP_PROXY, so on a corporate fleet host the request for
      http://127.0.0.1:8888/metrics is sent TO THE PROXY and fails. `-NoProxy`
      does not exist in PowerShell 5.1, and mutating
      [Net.WebRequest]::DefaultWebProxy would be a process-global side effect.
      HttpWebRequest with $req.Proxy = $null is the only clean 5.1 route.

      Never throws. Returns @{ ok; status; body; error }.
    #>
    [CmdletBinding()]
    param([string] $Url, [int] $TimeoutSec = 10)

    $res = [pscustomobject]@{ ok = $false; status = 0; body = ''; error = $null }
    if (-not $Url) { $res.error = 'no url'; return $res }
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method           = 'GET'
        $req.Proxy            = $null
        $req.Timeout          = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.KeepAlive        = $false
        $req.UserAgent        = 'Test-CxInstrumentation'
        $resp = $req.GetResponse()
        try {
            $res.status = [int]$resp.StatusCode
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { $res.body = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $res.ok = ($res.status -ge 200 -and $res.status -lt 300)
        } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        $res.error = $_.Exception.Message
        # A 401/403 still proves the endpoint is reachable - the caller needs the
        # status to tell "auth required" apart from "nothing is listening".
        try {
            if ($_.Exception.Response) {
                $res.status = [int]$_.Exception.Response.StatusCode
                $sr2 = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                try { $res.body = $sr2.ReadToEnd() } catch { } finally { $sr2.Dispose() }
            }
        } catch { }
    } catch {
        $res.error = $_.Exception.Message
    }
    return $res
}

function Invoke-CxRawPost {
    <#
      POST with an explicit content type, same no-proxy handling as the GET.
      Used only by -SendTestSpan.
    #>
    [CmdletBinding()]
    param([string] $Url, [string] $Body, [string] $ContentType = 'application/json', [int] $TimeoutSec = 10)

    $res = [pscustomobject]@{ ok = $false; status = 0; body = ''; error = $null }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method           = 'POST'
        $req.Proxy            = $null
        $req.Timeout          = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.KeepAlive        = $false
        $req.ContentType      = $ContentType
        $req.ContentLength    = $bytes.Length
        $req.UserAgent        = 'Test-CxInstrumentation'
        $st = $req.GetRequestStream()
        try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Dispose() }
        $resp = $req.GetResponse()
        try {
            $res.status = [int]$resp.StatusCode
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { $res.body = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $res.ok = ($res.status -ge 200 -and $res.status -lt 300)
        } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        $res.error = $_.Exception.Message
        try { if ($_.Exception.Response) { $res.status = [int]$_.Exception.Response.StatusCode } } catch { }
    } catch {
        $res.error = $_.Exception.Message
    }
    return $res
}

function Test-CxTcpPort {
    <#
      Can we open a TCP connection? Used for the OTLP listen ports and for
      endpoints where an HTTP GET would need credentials. Never throws.
    #>
    [CmdletBinding()]
    param([string] $ComputerName = '127.0.0.1', [int] $Port, [int] $TimeoutMs = 2000)

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Get-CxListeners {
    <#
      Sockets listening on a port, as @{ LocalAddress; OwningProcess }.

      Get-NetTCPConnection is absent on old/minimal images, so fall back to
      netstat -ano, and if both fail return $null so the caller can SKIP the rung
      rather than conclude "nothing is listening".
    #>
    [CmdletBinding()]
    param([int] $Port)

    try {
        $c = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
        return @($c | ForEach-Object {
            [pscustomobject]@{ LocalAddress = [string]$_.LocalAddress; OwningProcess = [int]$_.OwningProcess }
        })
    } catch { }

    try {
        $out = & netstat.exe -ano 2>$null | Out-String
        if (-not $out) { return $null }
        $rows = @()
        foreach ($line in ($out -split "`r?`n")) {
            if ($line -notmatch 'LISTENING') { continue }
            # proto  local  foreign  state  pid
            $m = [regex]::Match($line, '^\s*TCP\s+(?<la>\S+)\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$')
            if (-not $m.Success) { continue }
            $la = $m.Groups['la'].Value
            # Split host:port from the right - IPv6 literals contain colons.
            $idx = $la.LastIndexOf(':')
            if ($idx -lt 0) { continue }
            $p = 0
            if (-not [int]::TryParse($la.Substring($idx + 1), [ref]$p)) { continue }
            if ($p -ne $Port) { continue }
            $addr = $la.Substring(0, $idx).Trim('[', ']')
            $rows += [pscustomobject]@{ LocalAddress = $addr; OwningProcess = [int]$m.Groups['pid'].Value }
        }
        return @($rows)
    } catch { }

    return $null
}

function ConvertFrom-CxPromText {
    <#
      Parse a Prometheus exposition body ONCE into @{ name -> @( @{labels; value} ) }.

      Parsed once and indexed because /metrics here runs 2000-6000 lines (the
      hostmetrics `process` scraper plus otel_scope_* labels on every series);
      running Select-String per receiver would be O(n*m) and cost seconds of CPU.

      Culture: [double]::TryParse MUST be given InvariantCulture. The 2-argument
      overload is current-culture and parses "1.5" as 15 on a de-DE host - a live
      latent bug in deploy\Test-Agent.ps1 that is deliberately not copied here.
    #>
    [CmdletBinding()]
    param([string] $Text)

    $idx = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $idx }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $rxLine  = [regex] '^(?<n>[A-Za-z_:][A-Za-z0-9_:]*)(?:\{(?<lab>.*)\})?[ \t]+(?<v>\S+)(?:[ \t]+\d+)?[ \t]*$'
    $rxLabel = [regex] '(?<k>[A-Za-z_][A-Za-z0-9_]*)="(?<v>(?:[^"\\]|\\.)*)"'

    foreach ($l in ($Text -split "`r?`n")) {
        if ($l.Length -eq 0) { continue }
        if ($l[0] -eq '#') { continue }          # # HELP / # TYPE
        $m = $rxLine.Match($l)
        if (-not $m.Success) { continue }
        $vs = $m.Groups['v'].Value
        if ($vs -eq 'NaN' -or $vs -like '*Inf') { continue }
        $v = 0.0
        if (-not [double]::TryParse($vs, [Globalization.NumberStyles]::Float, $inv, [ref] $v)) { continue }

        $lab = @{}
        foreach ($k in $rxLabel.Matches($m.Groups['lab'].Value)) {
            $lv = $k.Groups['v'].Value -replace '\\"', '"' -replace '\\n', "`n" -replace '\\\\', '\'
            $lab[$k.Groups['k'].Value] = $lv
        }
        $n = $m.Groups['n'].Value
        if (-not $idx.ContainsKey($n)) { $idx[$n] = New-Object System.Collections.ArrayList }
        [void] $idx[$n].Add([pscustomobject]@{ labels = $lab; value = $v })
    }
    return $idx
}

function Get-CxMetricSum {
    <#
      Sum every series whose name matches $Base (with the suffixes the OTel-Go
      Prometheus exporter may append) and whose labels CONTAIN all of $Where.

      Suffix tolerance is required, not cosmetic. This collector runs with
      without_type_suffix:false and without_units:false, so monotonic sums carry
      _total and mapped UCUM units add _seconds/_bytes BEFORE it. Annotation units
      like {spans} add nothing. The queue gauges are queue_size on some builds and
      queue_size_ratio on others. Hardcoding a full name silently matches nothing.

      Label CONTAINMENT, never a whole-{...} match: without_scope_info:false puts
      otel_scope_name/otel_scope_version on every series.

      Returns @{ found; count; value }. `found` distinguishes "the series exists
      and is zero" from "there is no such series" - the difference between a
      receiver that is idle and one that is not reporting at all.
    #>
    [CmdletBinding()]
    param([hashtable] $Idx, [string] $Base, [hashtable] $Where = @{})

    $rx  = '^' + [regex]::Escape($Base) + '(?:_ratio|_seconds|_bytes)?(?:_total)?$'
    $sum = 0.0
    $n   = 0
    if (-not $Idx) { return [pscustomobject]@{ found = $false; count = 0; value = 0.0 } }

    foreach ($k in @($Idx.Keys)) {
        if ($k -notmatch $rx) { continue }
        foreach ($s in $Idx[$k]) {
            $ok = $true
            foreach ($wk in @($Where.Keys)) {
                # -cne: component ids are case-sensitive.
                if ([string]$s.labels[$wk] -cne [string]$Where[$wk]) { $ok = $false; break }
            }
            if ($ok) { $sum += $s.value; $n++ }
        }
    }
    [pscustomobject]@{ found = ($n -gt 0); count = $n; value = $sum }
}

function Get-CxMetricLabelValues {
    <#
      Distinct values of one label across every series matching $Base. Used to
      discover exporter names from the scrape rather than from the config: an
      exporter present in config but never instantiated has no series, which is
      itself signal.
    #>
    [CmdletBinding()]
    param([hashtable] $Idx, [string] $BasePattern, [string] $Label)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if (-not $Idx) { return @() }
    foreach ($k in @($Idx.Keys)) {
        if ($k -notmatch $BasePattern) { continue }
        foreach ($s in $Idx[$k]) {
            $v = [string]$s.labels[$Label]
            if ($v) { [void] $seen.Add($v) }
        }
    }
    return @($seen)
}

# ===========================================================================
# SECTION 3 - mini-YAML scanner
#
# No YAML module is available (powershell-yaml is not installed on fleet hosts
# and this file must stand alone), so this is an indent-relative line scanner.
#
# It is NOT a general YAML parser and does not try to be. It resolves exactly the
# handful of paths below and builds no document tree:
#
#     receivers / connectors / exporters      (top-level map keys)
#     service.pipelines.<p>.receivers         (per-pipeline lists)
#     service.telemetry.metrics -> prometheus host/port
#     extensions.health_check*.endpoint
#     receivers.<r>.<various>                 (endpoints, intervals, globs)
#
# Misparsing at a depth we never query is harmless, which is what makes this safe
# against an 848-line config full of OTTL statements containing : # - [ and {.
# ===========================================================================

function Remove-CxYamlComment {
    <#
      Strip a trailing comment, quote-aware.

      A naive `-replace '#.*$'` destroys real config in this very file:
          regex: ^#Fields:\s+(?P<csv_header>.+)$
          pattern: ^#.*$
      Only an unquoted '#' preceded by whitespace (or at column 0) starts a
      comment. $prev is seeded to a space so a '#' in column 0 qualifies.
    #>
    [CmdletBinding()]
    param([string] $Line)

    if ([string]::IsNullOrEmpty($Line)) { return $Line }
    $q = [char]0
    $prev = ' '
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($q -ne [char]0) {
            if ($c -eq $q) { $q = [char]0 }
        } elseif ($c -eq "'" -or $c -eq '"') {
            $q = $c
        } elseif ($c -eq '#' -and ($prev -eq ' ' -or $prev -eq "`t")) {
            return $Line.Substring(0, $i)
        }
        $prev = $c
    }
    return $Line
}

function ConvertTo-CxYamlRecords {
    <#
      Tokenise the document into flat records:
          @{ indent; key; value; isItem; itemValue }

      Block scalars (| and >) have their bodies skipped wholesale by indent - the
      OTTL/regex payloads inside them must never be mistaken for keys.

      The key charset [A-Za-z0-9_.\-/]+ is deliberately tight. It matches every
      real component id (filelog/iis, windowseventlog/application,
      coralogix/resource_catalog, spanmetrics/db_compact) while rejecting OTTL
      statement bodies such as
          set(datapoint.attributes["status.code"], "X")
      which a looser pattern would happily read as a key.
    #>
    [CmdletBinding()]
    param([string] $Text)

    $recs = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($Text)) { return @() }

    $blockScalarIndent = -1
    foreach ($raw0 in ($Text -split "`r?`n")) {
        $raw = $raw0 -replace "`t", '  '
        if ($raw -match '^\s*$') { continue }

        $indent = $raw.Length - $raw.TrimStart(' ').Length

        if ($blockScalarIndent -ge 0) {
            if ($indent -gt $blockScalarIndent) { continue }
            $blockScalarIndent = -1
        }

        $line = Remove-CxYamlComment $raw
        if ($line -match '^\s*$') { continue }
        $t = $line.TrimEnd()
        if ($t.Length -le $indent) { continue }
        $body = $t.Substring($indent)
        if ($body -eq '---' -or $body -eq '...') { continue }

        $isItem = $false
        $key = $null
        $val = ''
        $itemValue = ''

        if ($body -match '^-(?:\s+(?<rest>.*))?$') {
            $isItem = $true
            $rest = $Matches['rest']
            if ($null -eq $rest) { $rest = '' }
            $itemValue = $rest.Trim()
            # A list item may itself open a map: "- job_name: opentelemetry-collector"
            if ($itemValue -match '^(?<k>"[^"]*"|''[^'']*''|[A-Za-z0-9_.\-/]+)\s*:\s*(?<v>.*)$') {
                $key = $Matches['k'].Trim('"', "'")
                $val = $Matches['v'].Trim()
            }
        }
        elseif ($body -match '^(?<k>"[^"]*"|''[^'']*''|[A-Za-z0-9_.\-/]+)\s*:(?:\s+(?<v>.*))?$') {
            $key = $Matches['k'].Trim('"', "'")
            $v = $Matches['v']
            $val = if ($null -eq $v) { '' } else { $v.Trim() }
        }
        else {
            continue
        }

        if ($val -match '^[|>][-+]?\d*\s*$') { $blockScalarIndent = $indent }

        [void] $recs.Add([pscustomobject]@{
            indent    = $indent
            key       = $key
            value     = $val
            isItem    = $isItem
            itemValue = $itemValue
        })
    }
    return @($recs)
}

function Get-CxYamlKeyIndex {
    <#
      Index of the record for $Key at the IMMEDIATE child level of [$Lo..$Hi].
      -ceq because YAML keys are case-sensitive.
    #>
    [CmdletBinding()]
    param([object[]] $Recs, [int] $Lo, [int] $Hi, [int] $ParentIndent, [string] $Key)

    $childIndent = -1
    for ($i = $Lo; $i -le $Hi; $i++) {
        $r = $Recs[$i]
        if ($r.indent -le $ParentIndent) { continue }
        if ($r.isItem) { continue }                       # items never define the map level
        if ($childIndent -lt 0) { $childIndent = $r.indent }
        if ($r.indent -ne $childIndent) { continue }
        if ($r.key -ceq $Key) { return $i }
    }
    return -1
}

function Get-CxYamlExtent {
    <#
      [start, end] of the body owned by the key record at $At.

      THE LOAD-BEARING RULE: a sequence item at the SAME indent as its parent key
      still belongs to that key. Two writers produce these files with different
      styles, and both occur on real hosts:

          # yq / repo template - sequence at the parent's indent
          receivers:
          - otlp

          # gopkg.in/yaml.v3 - what the supervisor writes to effective.yaml
          receivers:
              - otlp

      Treating indentation as "always 2 spaces" or requiring a deeper indent for
      items breaks one of these silently.
    #>
    [CmdletBinding()]
    param([object[]] $Recs, [int] $At, [int] $Hi)

    $ind = $Recs[$At].indent
    $start = $At + 1
    $end = $Hi
    for ($j = $start; $j -le $Hi; $j++) {
        $r = $Recs[$j]
        if ($r.indent -lt $ind -or ($r.indent -eq $ind -and -not $r.isItem)) { $end = $j - 1; break }
    }
    , @($start, $end)
}

function Get-CxYamlBlock {
    [CmdletBinding()]
    param([object[]] $Recs, [string[]] $Path)

    if (-not $Recs -or @($Recs).Count -eq 0) { return @() }
    $lo = 0
    $hi = @($Recs).Count - 1
    $parent = -1
    foreach ($seg in $Path) {
        if ($lo -gt $hi) { return @() }
        $at = Get-CxYamlKeyIndex -Recs $Recs -Lo $lo -Hi $hi -ParentIndent $parent -Key $seg
        if ($at -lt 0) { return @() }
        $ext = Get-CxYamlExtent -Recs $Recs -At $at -Hi $hi
        $parent = $Recs[$at].indent
        $lo = $ext[0]
        $hi = $ext[1]
    }
    if ($lo -gt $hi) { return @() }
    @($Recs[$lo..$hi])
}

function Get-CxYamlMapKeys {
    <#
      The immediate child keys of a map. `forward/compact: {}` still yields the
      key (empty extent, inline flow value) - a connector declared with an empty
      map must still be counted.
    #>
    [CmdletBinding()]
    param([object[]] $Recs, [string[]] $Path)

    $blk = Get-CxYamlBlock -Recs $Recs -Path $Path
    if (@($blk).Count -eq 0) { return @() }
    $first = @($blk | Where-Object { -not $_.isItem -and $_.key }) | Select-Object -First 1
    if (-not $first) { return @() }
    $lvl = $first.indent
    @($blk | Where-Object { -not $_.isItem -and $_.key -and $_.indent -eq $lvl } | ForEach-Object { $_.key })
}

function Get-CxYamlDescendantBlock {
    <#
      First descendant block named $Key anywhere inside $Block. Needed because
      service.telemetry.metrics.readers is a LIST of maps, so the path walker
      cannot step through it by key.
    #>
    [CmdletBinding()]
    param([object[]] $Block, [string] $Key)

    $arr = @($Block)
    for ($i = 0; $i -lt $arr.Count; $i++) {
        if ($arr[$i].key -ceq $Key) {
            $ext = Get-CxYamlExtent -Recs $arr -At $i -Hi ($arr.Count - 1)
            if ($ext[0] -gt $ext[1]) { return @() }
            return @($arr[$ext[0]..$ext[1]])
        }
    }
    return @()
}

function Get-CxYamlScalarIn {
    [CmdletBinding()]
    param([object[]] $Block, [string] $Key)
    foreach ($r in @($Block)) {
        if ($r.key -ceq $Key -and $r.value -ne '') { return $r.value }
    }
    return $null
}

function Get-CxYamlList {
    <#
      A sequence, in either flow style ([a, b, c]) or block style (- a).

      A multi-line flow sequence returns the sentinel <UNPARSED_FLOW> so the
      caller can report CONFIG_PARSE_DEGRADED / unknown, rather than concluding
      the pipeline has no receivers and emitting a wall of false
      RECEIVER_ORPHANED findings.
    #>
    [CmdletBinding()]
    param([object[]] $Recs, [string[]] $Path)

    if (-not $Recs -or @($Recs).Count -eq 0) { return @() }
    $lo = 0
    $hi = @($Recs).Count - 1
    $parent = -1
    $at = -1
    foreach ($seg in $Path) {
        if ($lo -gt $hi) { return @() }
        $at = Get-CxYamlKeyIndex -Recs $Recs -Lo $lo -Hi $hi -ParentIndent $parent -Key $seg
        if ($at -lt 0) { return @() }
        $ext = Get-CxYamlExtent -Recs $Recs -At $at -Hi $hi
        $parent = $Recs[$at].indent
        $lo = $ext[0]
        $hi = $ext[1]
    }

    $inline = $Recs[$at].value
    if ($inline -match '^\[(?<b>.*)\]\s*$') {
        return @($Matches['b'] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }
    if ($inline -match '^\[') { return @('<UNPARSED_FLOW>') }

    if ($lo -gt $hi) { return @() }
    $items = @($Recs[$lo..$hi] | Where-Object { $_.isItem })
    if ($items.Count -eq 0) { return @() }
    $lvl = $items[0].indent
    @($items | Where-Object { $_.indent -eq $lvl } |
        ForEach-Object { (($_.itemValue -split '\s+')[0]).Trim().Trim('"', "'", ',') } |
        Where-Object { $_ })
}

function Expand-CxEnvPlaceholder {
    <#
      Resolve ${env:VAR:-default} / ${VAR}.

      MACHINE scope is checked FIRST. The collector runs as a service and reads
      the machine environment; this validator's own process env is not what the
      service saw, so preferring Process would give a plausible wrong answer.

      The result is a HINT only. Where it matters (the telemetry endpoint) the
      real listening socket is authoritative and overrides this.
    #>
    [CmdletBinding()]
    param([string] $Value)

    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $v = $Value.Trim().Trim('"', "'")
    $rx = [regex] '\$\{\s*(?:env:)?(?<n>[A-Za-z_][A-Za-z0-9_]*)\s*(?::-(?<d>[^}]*))?\}'
    try {
        return $rx.Replace($v, [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $n = $m.Groups['n'].Value
            $r = $null
            foreach ($s in 'Machine', 'Process', 'User') {
                try { $r = [Environment]::GetEnvironmentVariable($n, $s) } catch { }
                if (-not [string]::IsNullOrEmpty($r)) { break }
            }
            if ([string]::IsNullOrEmpty($r)) { $r = $m.Groups['d'].Value }
            $r
        })
    } catch { return $v }
}

function ConvertFrom-CxDuration {
    <#
      "30s" / "1m" / "500ms" -> seconds. $null when unparseable.
      InvariantCulture again: "1.5" must not become 15 on a de-DE host.
    #>
    [CmdletBinding()]
    param([string] $Value)

    if ([string]::IsNullOrEmpty($Value)) { return $null }
    $v = $Value.Trim().Trim('"', "'")
    $m = [regex]::Match($v, '^(?<n>[0-9.]+)\s*(?<u>ms|s|m|h)?$')
    if (-not $m.Success) { return $null }
    $n = 0.0
    if (-not [double]::TryParse($m.Groups['n'].Value, [Globalization.NumberStyles]::Float,
                                [Globalization.CultureInfo]::InvariantCulture, [ref] $n)) { return $null }
    switch ($m.Groups['u'].Value) {
        'ms'    { return $n / 1000.0 }
        'm'     { return $n * 60.0 }
        'h'     { return $n * 3600.0 }
        default { return $n }
    }
}

function Read-CxSharedText {
    <#
      Read a file that another process holds open.

      FileShare::ReadWrite is mandatory: the supervisor keeps effective.yaml open
      and Get-Content -Raw (which requests FileShare::Read) throws "being used by
      another process". StreamReader(..., $true) strips a BOM if a human edited it.

      Returns $null on any failure - the caller classifies it.
    #>
    [CmdletBinding()]
    param([string] $Path)

    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read,
                                     [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return $null
    }
}

function Get-CxCollectorProcesses {
    <#
      Running collector processes WITH their command lines.

      Win32_Process, not Get-Process, because we need CommandLine to recover the
      --config path. That is the only way to find the config in the test
      containers, which run the collector as a bare child process with an
      explicit --config rather than installing it as a service.
    #>
    [CmdletBinding()]
    param()

    $rows = @()
    foreach ($name in @('otelcol-contrib.exe', 'otelcol.exe', 'otelcol-windows.exe')) {
        try {
            $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='$name'" -ErrorAction Stop)
            foreach ($p in $procs) {
                $rows += [pscustomobject]@{
                    Name        = [string]$p.Name
                    ProcessId   = [int]$p.ProcessId
                    CommandLine = [string]$p.CommandLine
                }
            }
        } catch { }
    }
    # Fallback for hosts where CIM is unavailable: at least prove it is running.
    if (@($rows).Count -eq 0) {
        try {
            foreach ($p in @(Get-Process -Name 'otelcol-contrib', 'otelcol' -ErrorAction SilentlyContinue)) {
                $rows += [pscustomobject]@{ Name = "$($p.ProcessName).exe"; ProcessId = [int]$p.Id; CommandLine = '' }
            }
        } catch { }
    }
    return @($rows)
}

function Get-CxArgValue {
    <#
      Pull --flag <value> or --flag=value out of a command line, honouring quotes.
    #>
    [CmdletBinding()]
    param([string] $CommandLine, [string] $Flag)

    if (-not $CommandLine) { return $null }
    $rx = [regex] ('(?:^|\s)' + [regex]::Escape($Flag) + '(?:=|\s+)(?:"(?<q>[^"]+)"|(?<u>\S+))')
    $m = $rx.Match($CommandLine)
    if (-not $m.Success) { return $null }
    if ($m.Groups['q'].Success) { return $m.Groups['q'].Value }
    return $m.Groups['u'].Value
}

# ===========================================================================
# SECTION 4 - locate and parse the collector config
# ===========================================================================

function Get-CxCollectorConfig {
    <#
      Find the config ACTUALLY IN EFFECT, parse it, and return a model.

      Precedence:
        0. --config on the running collector's command line. Authoritative when
           present: it is what the process actually loaded. Also the only way to
           find the config in the test containers.
        1. C:\ProgramData\opampsupervisor\state\effective.yaml - the supervisor's
           merged base + Fleet remote config.
        2. The supervisor's base collector.yaml.
        3. Staged / legacy paths.

      Returns a model with Ok/Error and, when Ok, the extracted component sets.
    #>
    [CmdletBinding()]
    param([string] $Override, [object[]] $Processes)

    $model = [pscustomobject]@{
        Ok             = $false
        Error          = $null
        Denied         = $false
        SawFile        = $false      # a candidate existed on disk, even if unusable
        Path           = $null
        Source         = $null
        LastWriteTime  = $null
        FeatureGates   = $null
        Records        = @()
        Receivers      = @()
        Connectors     = @()
        Exporters      = @()
        Extensions     = @()
        Pipelines      = [ordered]@{}    # name -> receiver name[]
        Degraded       = @()             # pipeline names whose list could not be parsed
        TelemetryHost  = $null
        TelemetryPort  = $null
        TelemetryFound = $false
        HealthEndpoint = $null
    }

    $candidates = New-Object System.Collections.ArrayList
    if ($Override) {
        [void] $candidates.Add(@{ p = $Override; src = 'override' })
    } else {
        foreach ($proc in @($Processes)) {
            $cfg = Get-CxArgValue -CommandLine $proc.CommandLine -Flag '--config'
            if ($cfg) {
                # A --config may be prefixed with a provider scheme (file:...).
                $cfg = $cfg -replace '^file:', ''
                [void] $candidates.Add(@{ p = $cfg; src = "process(pid $($proc.ProcessId))" })
            }
        }
        [void] $candidates.Add(@{ p = 'C:\ProgramData\opampsupervisor\state\effective.yaml';            src = 'effective' })
        [void] $candidates.Add(@{ p = 'C:\Program Files\OpenTelemetry OpAMP Supervisor\collector.yaml'; src = 'base' })
        [void] $candidates.Add(@{ p = 'C:\otel\config.supervisor.yaml';                                 src = 'staged' })
        [void] $candidates.Add(@{ p = 'C:\otel\config.yaml';                                            src = 'legacy' })
    }

    # Feature gates are worth reporting: the IIS filelog header parse needs one.
    foreach ($proc in @($Processes)) {
        $fg = Get-CxArgValue -CommandLine $proc.CommandLine -Flag '--feature-gates'
        if ($fg) { $model.FeatureGates = $fg; break }
    }

    $anySeen = $false
    foreach ($c in $candidates) {
        $path = [string]$c.p
        if (-not $path) { continue }
        if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        $anySeen = $true
        $model.SawFile = $true

        $txt = Read-CxSharedText -Path $path
        if ($null -eq $txt) {
            # Exists but unreadable. Usually the ProgramData state dir being ACL'd
            # to SYSTEM/Administrators on a non-elevated run.
            $model.Error  = "cannot read $path (ACL? run elevated)"
            $model.Denied = $true
            continue
        }

        $recs = ConvertTo-CxYamlRecords -Text $txt
        $recv = @(Get-CxYamlMapKeys -Recs $recs -Path @('receivers'))

        # The supervisor rewrites effective.yaml on every remote-config push, so a
        # read can land mid-write. Retry once before giving up on this candidate.
        if (@($recv).Count -eq 0) {
            Start-Sleep -Seconds 1
            $txt = Read-CxSharedText -Path $path
            if ($null -ne $txt) {
                $recs = ConvertTo-CxYamlRecords -Text $txt
                $recv = @(Get-CxYamlMapKeys -Recs $recs -Path @('receivers'))
            }
        }
        if (@($recv).Count -eq 0) {
            $model.Error = "no receivers found in $path"
            continue
        }

        $model.Path    = $path
        $model.Source  = [string]$c.src
        $model.Records = $recs
        try { $model.LastWriteTime = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime } catch { }

        $model.Receivers  = $recv
        $model.Connectors = @(Get-CxYamlMapKeys -Recs $recs -Path @('connectors'))
        $model.Exporters  = @(Get-CxYamlMapKeys -Recs $recs -Path @('exporters'))
        $model.Extensions = @(Get-CxYamlMapKeys -Recs $recs -Path @('extensions'))

        foreach ($p in @(Get-CxYamlMapKeys -Recs $recs -Path @('service', 'pipelines'))) {
            $list = @(Get-CxYamlList -Recs $recs -Path @('service', 'pipelines', $p, 'receivers'))
            if ($list -contains '<UNPARSED_FLOW>') {
                $model.Degraded += $p
                $model.Pipelines[$p] = @()
            } else {
                $model.Pipelines[$p] = $list
            }
        }

        # Self-telemetry prometheus reader. readers is a LIST of maps, so descend.
        $mBlk = Get-CxYamlBlock -Recs $recs -Path @('service', 'telemetry', 'metrics')
        $promBlk = Get-CxYamlDescendantBlock -Block $mBlk -Key 'prometheus'
        if (@($mBlk).Count -gt 0 -and @($promBlk).Count -gt 0) {
            $model.TelemetryFound = $true
            $h = Expand-CxEnvPlaceholder (Get-CxYamlScalarIn -Block $promBlk -Key 'host')
            $pt = Expand-CxEnvPlaceholder (Get-CxYamlScalarIn -Block $promBlk -Key 'port')
            $model.TelemetryHost = if ($h) { $h } else { '127.0.0.1' }
            $model.TelemetryPort = if ($pt) { $pt } else { '8888' }
        }

        # health_check may be aliased (health_check/1) - match by prefix.
        $hcKey = @($model.Extensions | Where-Object { $_ -match '^health_check(/.*)?$' }) | Select-Object -First 1
        if ($hcKey) {
            $model.HealthEndpoint = Expand-CxEnvPlaceholder (
                Get-CxYamlScalarIn -Block (Get-CxYamlBlock -Recs $recs -Path @('extensions', $hcKey)) -Key 'endpoint')
        }

        $model.Ok = $true
        $model.Error = $null
        break
    }

    if (-not $model.Ok -and -not $anySeen) {
        $model.Error = 'no collector config found in any known location'
    }
    return $model
}

function Get-CxReceiverInterval {
    <#
      A receiver's scrape cadence in seconds, so the sampling window can be sized
      to guarantee at least one tick. Checks collection_interval, then
      scrape_interval (the prometheus receiver keeps its cadence down in
      config.scrape_configs[].scrape_interval).
    #>
    [CmdletBinding()]
    param([object[]] $Recs, [string] $Name)

    $blk = Get-CxYamlBlock -Recs $Recs -Path @('receivers', $Name)
    if (@($blk).Count -eq 0) { return $null }
    foreach ($k in @('collection_interval', 'scrape_interval')) {
        $v = Get-CxYamlScalarIn -Block $blk -Key $k
        if ($v) {
            $s = ConvertFrom-CxDuration (Expand-CxEnvPlaceholder $v)
            if ($s) { return $s }
        }
    }
    return $null
}

function Test-CxConfig {
    <#
      Report which config won and whether it parsed. Never fails the run on its
      own: a config we cannot read is `unknown`, not `fail`.
    #>
    [CmdletBinding()]
    param($Model)

    $out = New-Object System.Collections.ArrayList

    if (-not $Model.Ok) {
        # Three distinct failures, three distinct codes: nothing on disk, present
        # but unreadable (ACL - usually a non-elevated run against the ProgramData
        # state dir), and present and readable but with no receivers: block.
        $code = if ($Model.Denied) { 'COLLECTOR_CONFIG_UNREADABLE' }
                elseif ($Model.SawFile) { 'CONFIG_NO_RECEIVERS' }
                else { 'COLLECTOR_CONFIG_NOT_FOUND' }
        $sev  = if ($Model.Denied) { 'unknown' } else { 'warn' }
        [void] $out.Add((New-Finding -Check 'config' -Severity $sev -Code $code `
            -Message ([string]$Model.Error)))
        return , @($out.ToArray())
    }

    [void] $out.Add((New-Finding -Check 'config' -Severity 'info' -Code 'COLLECTOR_CONFIG_SOURCE' -Target $Model.Source `
        -Message ("using {0} (modified {1})" -f $Model.Path, $(if ($Model.LastWriteTime) { $Model.LastWriteTime.ToString('s') } else { 'unknown' })) `
        -Data @{ path = $Model.Path; source = $Model.Source }))

    if ($Model.Source -eq 'base' -or $Model.Source -eq 'staged') {
        # The supervisor merges a Fleet remote config on top of the base and writes
        # the result to effective.yaml. Reading the base instead means what we
        # graded may not be what the collector is running.
        [void] $out.Add((New-Finding -Check 'config' -Severity 'info' -Code 'COLLECTOR_CONFIG_FALLBACK' `
            -Message 'effective.yaml is absent, so the BASE config was parsed. If Fleet Management has assigned a remote config, the running config differs from this one.'))
    }

    if ($Model.FeatureGates) {
        [void] $out.Add((New-Finding -Check 'config' -Severity 'info' `
            -Message "collector started with --feature-gates=$($Model.FeatureGates)" `
            -Data @{ featureGates = $Model.FeatureGates }))
    }

    foreach ($p in @($Model.Degraded)) {
        [void] $out.Add((New-Finding -Check 'config' -Severity 'unknown' -Code 'CONFIG_PARSE_DEGRADED' -Target $p `
            -Message 'this pipeline uses a multi-line flow sequence for receivers, which this parser does not read - its receivers were NOT graded'))
    }

    if (@($Model.Pipelines.Keys).Count -eq 0) {
        [void] $out.Add((New-Finding -Check 'config' -Severity 'warn' -Code 'CONFIG_NO_PIPELINES' `
            -Message 'no service.pipelines found - the collector would export nothing'))
    } else {
        [void] $out.Add((New-Finding -Check 'config' -Severity 'pass' `
            -Message ("parsed {0} receiver(s), {1} connector(s), {2} exporter(s), {3} pipeline(s)" -f `
                @($Model.Receivers).Count, @($Model.Connectors).Count, @($Model.Exporters).Count, @($Model.Pipelines.Keys).Count) `
            -Data @{ receivers = $Model.Receivers; pipelines = @($Model.Pipelines.Keys) }))
    }

    return , @($out.ToArray())
}

# ===========================================================================
# SECTION 5 - receiver wiring
# ===========================================================================

function New-CxOrdinalSet {
    # PowerShell hashtables are case-INSENSITIVE; YAML component ids are not.
    New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
}

function Test-CxReceiverWiring {
    <#
      Classify every receiver against the pipelines, and return both the findings
      and the wired set (which drives the data-flow check).

      CONNECTORS MUST BE EXCLUDED. forward/* and spanmetrics* legitimately appear
      in pipeline `receivers:` lists but are connectors, not receivers: they emit
      no receiver counters at all. On the shipped config that is 7 of them, so
      treating them as receivers would produce 7 permanent false failures.
    #>
    [CmdletBinding()]
    param($Model, [bool] $CollectorRunning)

    $out = New-Object System.Collections.ArrayList

    $defined = New-CxOrdinalSet
    foreach ($r in @($Model.Receivers)) { [void] $defined.Add($r) }
    $connectors = New-CxOrdinalSet
    foreach ($c in @($Model.Connectors)) { [void] $connectors.Add($c) }

    $used = New-CxOrdinalSet
    $signals = @{}                 # receiver -> ordinal set of signal kinds
    foreach ($p in @($Model.Pipelines.Keys)) {
        $sig = ($p -split '/')[0]
        $list = @($Model.Pipelines[$p])
        foreach ($r in $list) {
            [void] $used.Add($r)
            if (-not $signals.ContainsKey($r)) { $signals[$r] = New-CxOrdinalSet }
            [void] $signals[$r].Add($sig)
        }
        if ($list.Count -eq 0 -and @($Model.Degraded) -notcontains $p) {
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'warn' -Code 'PIPELINE_NO_RECEIVERS' -Target $p `
                -Message 'pipeline declares no receivers - it can never produce data'))
            continue
        }
        $nonConn = @($list | Where-Object { -not $connectors.Contains($_) })
        if ($list.Count -gt 0 -and $nonConn.Count -eq 0) {
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'info' -Code 'PIPELINE_CONNECTOR_ONLY' -Target $p `
                -Message 'fed entirely by connectors - expected for the spanmetrics/forward fan-out pipelines'))
        }
    }

    $wired = @()
    foreach ($r in @($Model.Receivers)) {
        if ($used.Contains($r)) {
            $wired += $r
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'pass' -Target $r `
                -Message ("wired into: {0}" -f (@($Model.Pipelines.Keys | Where-Object { @($Model.Pipelines[$_]) -contains $r }) -join ', ')) `
                -Data @{ signals = @($signals[$r]) }))
        } else {
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'warn' -Code 'RECEIVER_ORPHANED' -Target $r `
                -Message 'configured but not referenced by any pipeline - it is instantiated by nothing and collects nothing'))
        }
    }

    foreach ($u in @($used)) {
        if ($defined.Contains($u)) { continue }
        if ($connectors.Contains($u)) {
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'info' -Code 'CONNECTOR_AS_RECEIVER' -Target $u `
                -Message 'a connector used as a pipeline receiver - expected; excluded from the data-flow check because connectors report no receiver counters'))
            continue
        }
        if ($CollectorRunning) {
            # The collector refuses to start with an undefined receiver, so if it
            # IS running the likeliest explanation is that this parser missed a
            # key - say so rather than accusing a working config.
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'warn' -Code 'RECEIVER_UNDEFINED' -Target $u `
                -Message "referenced by a pipeline but not declared under receivers:. The collector IS running, which it could not do with a genuinely undefined receiver - so either this validator mis-parsed the config, or it is not the config in force. Check receivers: in $($Model.Path)."))
        } else {
            [void] $out.Add((New-Finding -Check 'receiverWiring' -Severity 'fail' -Code 'RECEIVER_UNDEFINED' -Target $u `
                -Message 'referenced by a pipeline but not declared under receivers:. The collector is NOT running, and this is exactly the config error that prevents startup.'))
        }
    }

    return [pscustomobject]@{
        Findings = @($out.ToArray())
        Wired    = @($wired)
        Signals  = $signals
    }
}

# ===========================================================================
# SECTION 6 - the collector probe ladder
#
# Each rung, on failure, emits ONE finding and marks everything downstream
# skip/unknown. This ladder is what tells "the receiver produced nothing" apart
# from "the collector is down" and from ":8888 is unreachable".
# ===========================================================================

function Test-CxCollector {
    <#
      Returns findings plus a Probe object the data-flow checks consume.

      PROCESS-FIRST, NOT SERVICE-FIRST. Three legitimate modes exist and only one
      has a collector service:

        supervisor    service opampsupervisor + CHILD otelcol-contrib.exe
        legacy        service otelcol-contrib
        process-only  no service at all, collector run directly with --config

      The test containers use process-only (the vendor supervisor MSI cannot be
      downloaded inside minimal Server Core), so a service-first ladder would
      report COLLECTOR_SERVICE_MISSING/fail and exit 1 on every container run.
    #>
    [CmdletBinding()]
    param($Model, [object[]] $Processes, [string] $MetricsUrlOverride, [string] $HealthUrl,
          [int] $OtlpHttpPort, [int] $OtlpGrpcPort, [int] $TimeoutSec)

    $out = New-Object System.Collections.ArrayList
    $probe = [pscustomobject]@{
        Running     = $false
        MetricsUrl  = $null
        Reachable   = $false
        Body        = $null
        Pids        = @()
    }

    # -- rung 1: the process ------------------------------------------------
    $procs = @($Processes)
    $probe.Pids = @($procs | ForEach-Object { $_.ProcessId })

    $svc = $null
    $svcName = $null
    foreach ($n in @('opampsupervisor', 'otelcol-contrib')) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $svc = $s; $svcName = $n; break }
    }

    if ($procs.Count -eq 0) {
        if ($svc -and $svc.Status -ne 'Running') {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'fail' -Code 'COLLECTOR_SERVICE_STOPPED' -Target $svcName `
                -Message "service '$svcName' is $($svc.Status) and no collector process is running - this host is sending nothing"))
        } elseif ($svc) {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'fail' -Code 'COLLECTOR_PROCESS_MISSING' -Target $svcName `
                -Message "service '$svcName' reports Running but no otelcol process exists - the supervisor is up and its child collector is not"))
        } else {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'fail' -Code 'COLLECTOR_SERVICE_MISSING' `
                -Message 'no collector service and no collector process on this host - nothing is collecting telemetry'))
        }
        return [pscustomobject]@{ Findings = @($out.ToArray()); Probe = $probe }
    }

    $probe.Running = $true
    [void] $out.Add((New-Finding -Check 'collector' -Severity 'pass' -Target 'process' `
        -Message ("collector running (pid {0})" -f (($probe.Pids) -join ', ')) `
        -Data @{ pids = $probe.Pids }))

    # -- rung 2: the service, as CONTEXT rather than a gate -----------------
    if (-not $svc) {
        [void] $out.Add((New-Finding -Check 'collector' -Severity 'info' -Code 'COLLECTOR_MODE_PROCESS_ONLY' `
            -Message 'the collector is running as a bare process with no Windows service. Valid for a container or a hand-started collector; on a fleet host it means the supervisor is not installed and nothing will restart it after a reboot.'))
    } elseif ($svcName -eq 'otelcol-contrib') {
        [void] $out.Add((New-Finding -Check 'collector' -Severity 'info' -Code 'COLLECTOR_MODE_LEGACY' -Target $svcName `
            -Message 'legacy local-collector mode (no OpAMP supervisor) - Fleet Management cannot push config to this host'))
    }
    if ($svc) {
        if ($svc.Status -ne 'Running') {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'info' -Code 'COLLECTOR_MODE_PROCESS_ONLY' -Target $svcName `
                -Message "service '$svcName' is $($svc.Status) but a collector process IS running - it was started outside the service"))
        } else {
            try {
                $st = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction Stop).StartMode
                if ($st -and $st -ne 'Auto') {
                    [void] $out.Add((New-Finding -Check 'collector' -Severity 'warn' -Code 'STARTTYPE_NOT_AUTOMATIC' -Target $svcName `
                        -Message "service start type is '$st' - it will not come back after a reboot"))
                }
            } catch { }
        }
    }

    # -- health + OTLP ports ------------------------------------------------
    $hUrl = if ($Model.Ok -and $Model.HealthEndpoint) {
        $ep = $Model.HealthEndpoint
        if ($ep -match '^https?://') { $ep } else { "http://$ep" }
    } else { $HealthUrl }

    if ($hUrl) {
        $okHealth = $false
        # 3 tries with the first immediate: this restarts nothing, so a long wait
        # only slows a fleet sweep, but a host mid-relaunch still gets some grace.
        for ($i = 0; $i -lt 3; $i++) {
            if ($i -gt 0) { Start-Sleep -Seconds 5 }
            $r = Invoke-CxRawGet -Url $hUrl -TimeoutSec $TimeoutSec
            if ($r.ok) { $okHealth = $true; break }
        }
        if ($okHealth) {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'pass' -Target 'health' -Message "health endpoint 200 at $hUrl"))
        } else {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'warn' -Code 'HEALTH_UNREACHABLE' -Target 'health' `
                -Message "health endpoint did not answer 200 at $hUrl - the process is up but may not have finished starting its pipelines"))
        }
    } else {
        [void] $out.Add((New-Finding -Check 'collector' -Severity 'info' -Code 'HEALTH_ENDPOINT_MISSING' `
            -Message 'no health_check extension in the effective config'))
    }

    foreach ($pp in @(@{ n = 'otlp/http'; p = $OtlpHttpPort }, @{ n = 'otlp/grpc'; p = $OtlpGrpcPort })) {
        if (Test-CxTcpPort -Port ([int]$pp.p)) {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'pass' -Target ([string]$pp.n) -Message "listening on $($pp.p)"))
        } else {
            [void] $out.Add((New-Finding -Check 'collector' -Severity 'warn' -Code 'OTLP_PORT_NOT_LISTENING' -Target ([string]$pp.n) `
                -Message "nothing accepting TCP on $($pp.p) - instrumented apps on this host cannot deliver telemetry"))
        }
    }

    # -- rung 3: is self-telemetry even configured? -------------------------
    if ($Model.Ok -and -not $Model.TelemetryFound -and -not $MetricsUrlOverride) {
        [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_METRICS_DISABLED' `
            -Message 'the effective config declares no service.telemetry.metrics prometheus reader, so the collector publishes no internal counters and per-receiver data flow cannot be measured on this host'))
        return [pscustomobject]@{ Findings = @($out.ToArray()); Probe = $probe }
    }

    $telHost = if ($Model.Ok -and $Model.TelemetryHost) { $Model.TelemetryHost } else { '127.0.0.1' }
    $telPort = if ($Model.Ok -and $Model.TelemetryPort) { $Model.TelemetryPort } else { '8888' }

    # -- rung 4: socket reality check (authoritative over the parsed host) --
    $cands = New-Object System.Collections.ArrayList
    if ($MetricsUrlOverride) {
        [void] $cands.Add($MetricsUrlOverride)
    } else {
        $portNum = 0
        [void] [int]::TryParse([string]$telPort, [ref] $portNum)
        $lis = if ($portNum -gt 0) { Get-CxListeners -Port $portNum } else { $null }

        if ($null -eq $lis) {
            # Could not enumerate sockets at all - skip the rung, do not conclude.
            [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'info' `
                -Message 'could not enumerate listening sockets on this host; probing the configured address directly'))
        } elseif (@($lis).Count -eq 0) {
            [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_PORT_NOT_LISTENING' -Target $telPort `
                -Message "nothing is listening on port $telPort - the collector's internal telemetry endpoint is not up, so per-receiver flow cannot be measured"))
        } else {
            $mine = @($lis | Where-Object { $probe.Pids -contains $_.OwningProcess })
            if (@($mine).Count -eq 0) {
                [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_PORT_CONFLICT' -Target $telPort `
                    -Message "port $telPort is held by a process that is not this collector (pid $(@($lis | ForEach-Object { $_.OwningProcess }) -join ', ')) - any counters scraped from it would describe something else"))
            }
            foreach ($a in @($mine | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique)) {
                if ($a -eq '0.0.0.0' -or $a -eq '::') { [void] $cands.Add("http://127.0.0.1:$telPort/metrics") }
                elseif ($a -match ':') { [void] $cands.Add("http://[$a]:$telPort/metrics") }
                else { [void] $cands.Add("http://${a}:$telPort/metrics") }
            }
            # rung 5: flag a config that moved the endpoint off loopback.
            if ($telHost -and $telHost -ne '127.0.0.1' -and $telHost -ne 'localhost' -and
                @($mine | Where-Object { $_.LocalAddress -eq $telHost }).Count -eq 0) {
                [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'info' -Code 'TELEMETRY_ENDPOINT_NOT_LOOPBACK' -Target $telHost `
                    -Message "the config binds internal telemetry to $telHost (OTEL_LISTEN_INTERFACE), which does not match any socket this collector owns"))
            }
        }
        [void] $cands.Add("http://${telHost}:$telPort/metrics")
        [void] $cands.Add("http://127.0.0.1:$telPort/metrics")
    }

    # Proxy interference is the #1 real-world false negative. Our own probe is
    # immune (Invoke-CxRawGet nulls the proxy), but the collector's EXPORTER reads
    # the same env and is not.
    $hp = $env:HTTP_PROXY; if (-not $hp) { $hp = $env:http_proxy }
    $hsp = $env:HTTPS_PROXY; if (-not $hsp) { $hsp = $env:https_proxy }
    if ($hp -or $hsp) {
        $np = $env:NO_PROXY; if (-not $np) { $np = $env:no_proxy }
        if (-not $np -or ($np -notmatch '127\.0\.0\.1' -and $np -notmatch 'localhost')) {
            [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_PROXY_INTERFERENCE' `
                -Message "HTTP(S)_PROXY is set and NO_PROXY does not exempt loopback. This probe bypasses the proxy explicitly, but the collector's own exporter does not - suspect the proxy if exports are failing." `
                -Data @{ httpProxy = $hp; httpsProxy = $hsp; noProxy = $np }))
        }
    }

    # -- rung 6: scrape, and confirm the body is actually a collector's -----
    $body = $null
    $usedUrl = $null
    foreach ($u in @($cands | Where-Object { $_ } | Select-Object -Unique)) {
        $r = Invoke-CxRawGet -Url $u -TimeoutSec $TimeoutSec
        if ($r.ok) { $body = $r.body; $usedUrl = $u; break }
    }

    if ($null -eq $body) {
        [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_UNREACHABLE' `
            -Message ("could not scrape the collector's internal metrics at any of: {0}" -f (@($cands | Select-Object -Unique) -join ', ')) `
            -Data @{ tried = @($cands | Select-Object -Unique) }))
        return [pscustomobject]@{ Findings = @($out.ToArray()); Probe = $probe }
    }
    if ([string]::IsNullOrWhiteSpace($body)) {
        [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_SCRAPE_EMPTY' -Target $usedUrl `
            -Message 'the telemetry endpoint answered 200 with an empty body'))
        return [pscustomobject]@{ Findings = @($out.ToArray()); Probe = $probe }
    }
    if ($body -notmatch 'otelcol_') {
        [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'warn' -Code 'TELEMETRY_FOREIGN_ENDPOINT' -Target $usedUrl `
            -Message 'the endpoint answered but exposes no otelcol_* series - something other than the collector owns this port'))
        return [pscustomobject]@{ Findings = @($out.ToArray()); Probe = $probe }
    }

    $probe.MetricsUrl = $usedUrl
    $probe.Reachable  = $true
    $probe.Body       = $body
    [void] $out.Add((New-Finding -Check 'telemetry' -Severity 'pass' -Code 'TELEMETRY_OK' -Target $usedUrl `
        -Message 'internal telemetry scraped'))

    return [pscustomobject]@{ Findings = @($out.ToArray()); Probe = $probe }
}

# ===========================================================================
# SECTION 7 - receiver + exporter data flow
#
# WHICH RECEIVER KIND REPORTS WHAT - the single most important detail here:
#
#   scraperhelper  hostmetrics, iis, rabbitmq
#                  -> otelcol_scraper_scraped_metric_points_total{receiver,scraper}
#                  -> emits NO otelcol_receiver_accepted_* AT ALL
#   stanza adapter filelog/*, windowseventlog/*
#                  -> otelcol_receiver_accepted_log_records_total{receiver}
#   obsreport      otlp, prometheus
#                  -> otelcol_receiver_accepted_{spans,metric_points,log_records}_total
#                  -> prometheus emits NO otelcol_scraper_* despite scraping
#   connectors     forward/*, spanmetrics*  -> nothing usable (excluded earlier)
#
# A check that looks only at otelcol_receiver_accepted_* reports a FALSE ZERO for
# hostmetrics, iis and rabbitmq. That is why misc\apply-config.ps1's working
# `receiver="iis"` assertion matches the SCRAPER series, not an accepted one.
#
# Kind is therefore detected from EVIDENCE (which series exist), not a hardcoded
# list, so a receiver added later by a Fleet config is graded honestly instead of
# failed. The list above only informs the warm-up window and the message text.
# ===========================================================================

function Get-CxReceiverEvidence {
    <#
      What one receiver reports in a single scrape. `hasCounters` false means no
      series exist for it at all -> the caller reports unknown, never fail.
    #>
    [CmdletBinding()]
    param([hashtable] $Idx, [string] $Name)

    $sc = Get-CxMetricSum -Idx $Idx -Base 'otelcol_scraper_scraped_metric_points' -Where @{ receiver = $Name }
    $se = Get-CxMetricSum -Idx $Idx -Base 'otelcol_scraper_errored_metric_points' -Where @{ receiver = $Name }

    $acc = 0.0; $ref = 0.0; $accFound = $false
    foreach ($sig in @('spans', 'metric_points', 'log_records')) {
        $a = Get-CxMetricSum -Idx $Idx -Base "otelcol_receiver_accepted_$sig" -Where @{ receiver = $Name }
        $r = Get-CxMetricSum -Idx $Idx -Base "otelcol_receiver_refused_$sig"  -Where @{ receiver = $Name }
        if ($a.found) { $accFound = $true; $acc += $a.value }
        if ($r.found) { $ref += $r.value }
    }

    $kind = if ($sc.found) { 'scraper' } elseif ($accFound) { 'obsreport' } else { 'none' }
    [pscustomobject]@{
        kind        = $kind
        produced    = $(if ($sc.found) { $sc.value } else { $acc })
        errored     = $(if ($sc.found) { $se.value } else { $ref })
        hasCounters = ($sc.found -or $accFound)
    }
}

function Test-CxReceiverFlow {
    <#
      Two scrapes, graded on the DELTA with the absolute value as a qualifier.

      Absolute-only is unsafe (false PASS): filelog/iis with start_at:beginning
      emits a large burst on first start and then nothing, so a counter frozen at
      40000 for six hours reads as healthy. A dead rabbitmq broker likewise keeps
      a flat non-zero `scraped`.

      Delta-only is unsafe (false FAIL): iis ticks every 30s and the prometheus
      self-scrape every 30s, so a 10s window catches neither.
    #>
    [CmdletBinding()]
    param($Model, $Probe, [string[]] $Wired, $Signals, [int] $SampleSeconds, [bool] $Fast, [int] $TimeoutSec)

    $out = New-Object System.Collections.ArrayList
    $result = [pscustomobject]@{ Findings = @(); Idx2 = $null; Idx1 = $null; AnyReceiverDelta = $false; Restarted = $false }

    if (-not $Probe.Reachable) {
        foreach ($r in @($Wired)) {
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_CHECK_UNAVAILABLE' -Target $r `
                -Message 'the collector internal telemetry endpoint could not be scraped, so data flow is unknown (see the telemetry finding above)'))
        }
        $result.Findings = @($out.ToArray())
        return $result
    }

    # Size the window so the slowest wired receiver ticks at least once. Floor 30
    # covers iis and the prometheus self-scrape in the shipped config.
    $maxInterval = 30.0
    if ($Model.Ok) {
        foreach ($r in @($Wired)) {
            $i = Get-CxReceiverInterval -Recs $Model.Records -Name $r
            if ($i -and $i -gt $maxInterval) { $maxInterval = $i }
        }
    }
    $window = [Math]::Max($SampleSeconds, [int]($maxInterval + 5))

    $idx1 = ConvertFrom-CxPromText -Text $Probe.Body
    $up1 = Get-CxMetricSum -Idx $idx1 -Base 'otelcol_process_uptime'
    $warmup = [Math]::Max(90.0, 3.0 * $maxInterval)

    $idx2 = $null
    if (-not $Fast) {
        if (Test-CxOutOfTime) {
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_CHECK_UNAVAILABLE' `
                -Message 'ran out of time budget before the second sample could be taken'))
        } else {
            Write-Host ("  ... sampling collector counters for {0}s (use -Fast to skip)" -f $window) -ForegroundColor DarkGray
            Start-Sleep -Seconds $window
            $r2 = Invoke-CxRawGet -Url $Probe.MetricsUrl -TimeoutSec $TimeoutSec
            if ($r2.ok -and $r2.body) { $idx2 = ConvertFrom-CxPromText -Text $r2.body }
        }
    }

    if ($null -eq $idx2) {
        if (-not $Fast) {
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_STALL_UNKNOWN' `
                -Message 'the second sample could not be taken; grading on absolute counters only, so a stalled receiver cannot be distinguished from a working one'))
        }
        $idx2 = $idx1
        $Fast = $true
    }

    # Counter-reset guard: a restart mid-window makes every delta meaningless.
    $up2 = Get-CxMetricSum -Idx $idx2 -Base 'otelcol_process_uptime'
    if ($up1.found -and $up2.found -and $up2.value -lt $up1.value) {
        $result.Restarted = $true
        $Fast = $true
        [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'COLLECTOR_RESTARTED_DURING_CHECK' `
            -Message 'the collector restarted between the two samples, so all deltas were discarded; grading on absolute counters only. Re-run for a clean measurement.'))
    }

    $uptime = if ($up2.found) { $up2.value } else { $null }
    if ($null -eq $uptime) {
        # Fall back to the process start time.
        try {
            $p = @(Get-Process -Id $Probe.Pids -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($p) { $uptime = ((Get-Date) - $p.StartTime).TotalSeconds }
        } catch { }
    }
    $warm = ($null -eq $uptime) -or ($uptime -ge $warmup)

    foreach ($r in @($Wired)) {
        $e1 = Get-CxReceiverEvidence -Idx $idx1 -Name $r
        $e2 = Get-CxReceiverEvidence -Idx $idx2 -Name $r

        if (-not $e2.hasCounters) {
            # The collector creates a counter series lazily, on the first record.
            # So "no series" usually means this receiver has never produced
            # anything - but it is reported as unknown, not warn, because it is
            # indistinguishable from a receiver kind that publishes no counters at
            # all, and calling a working receiver broken is the worse error.
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_NO_COUNTERS' -Target $r `
                -Message 'the collector publishes no counter series for this receiver. Most likely it has never produced a single record (a series appears on first use); it may also be a receiver kind that reports nothing. Run with -ProbeEndpoints to test whether its source (log glob, event channel, endpoint) is there at all.' `
                -Data @{ signals = $(if ($Signals -and $Signals.ContainsKey($r)) { (@($Signals[$r]) -join '/') } else { '' }) }))
            continue
        }

        $dProd = $e2.produced - $e1.produced
        $dErr  = $e2.errored  - $e1.errored
        if ($dProd -lt 0 -or $dErr -lt 0) { $dProd = 0; $dErr = 0 }   # reset guard
        $abs = $e2.produced
        $sigList = if ($Signals -and $Signals.ContainsKey($r)) { (@($Signals[$r]) -join '/') } else { '' }
        $data = @{ kind = $e2.kind; produced = $abs; deltaProduced = $dProd; deltaErrored = $dErr; signals = $sigList }

        if ($dProd -gt 0) { $result.AnyReceiverDelta = $true }

        # Errors first: they outrank a healthy-looking absolute count.
        if ($dErr -gt 0 -and $dProd -le 0) {
            $code = if ($e2.kind -eq 'scraper') { 'RECEIVER_SCRAPE_FAILING' } else { 'RECEIVER_ALL_REFUSED' }
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'fail' -Code $code -Target $r `
                -Message ("every attempt failed during the sample window ({0} errored, 0 produced) - this receiver is delivering nothing" -f $dErr) -Data $data))
            continue
        }
        if ($dErr -gt 0) {
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'warn' -Code 'RECEIVER_ERRORS' -Target $r `
                -Message ("producing data but also erroring ({0} produced, {1} errored in the window) - partial data loss" -f $dProd, $dErr) -Data $data))
            continue
        }

        if ($dProd -gt 0) {
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'pass' -Code 'RECEIVER_FLOWING' -Target $r `
                -Message ("+{0} {1} in {2}s" -f $dProd, $(if ($e2.kind -eq 'scraper') { 'points' } else { 'records' }), $window) -Data $data))
            continue
        }

        if ($Fast) {
            if ($abs -gt 0) {
                [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_STALL_UNKNOWN' -Target $r `
                    -Message ("has produced {0} since start, but with a single sample it cannot be told whether it is still producing. Re-run without -Fast." -f $abs) -Data $data))
            } elseif (-not $warm) {
                [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_NO_DATA_YET' -Target $r `
                    -Message ("nothing yet, but the collector has only been up {0:N0}s - re-run in {1:N0}s" -f $uptime, ($warmup - $uptime)) -Data $data))
            } else {
                [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'warn' -Code 'RECEIVER_NO_DATA' -Target $r `
                    -Message 'has produced nothing at all since the collector started' -Data $data))
            }
            continue
        }

        if ($abs -gt 0) {
            if ($e2.kind -eq 'scraper') {
                # A 10-30s scraper that produced nothing across the window is stalled.
                [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'warn' -Code 'RECEIVER_STALLED' -Target $r `
                    -Message ("produced nothing in {0}s despite {1} total since start - the scraper has stopped ticking" -f $window, $abs) -Data $data))
            } else {
                # A quiet host legitimately has no new HTTP traffic / no new events.
                [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'pass' -Code 'RECEIVER_IDLE' -Target $r `
                    -Message ("idle in this window but has produced {0} since start - normal for an event-driven receiver on a quiet host" -f $abs) -Data $data))
            }
            continue
        }

        if (-not $warm) {
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_NO_DATA_YET' -Target $r `
                -Message ("nothing yet, but the collector has only been up {0:N0}s - re-run in {1:N0}s" -f $uptime, ($warmup - $uptime)) -Data $data))
        } else {
            # This is where a scraper whose SOURCE is down lands. It does not reach
            # RECEIVER_SCRAPE_FAILING: a connection-level failure returns zero data
            # points, so otelcol_scraper_errored_metric_points stays 0 (measured
            # against a rabbitmq receiver with no broker - the error appears only in
            # the collector log). The counters therefore cannot say WHY, and
            # -ProbeEndpoints is what turns this into a diagnosis.
            [void] $out.Add((New-Finding -Check 'receiverFlow' -Severity 'warn' -Code 'RECEIVER_NO_DATA' -Target $r `
                -Message 'has produced nothing since the collector started, and nothing during the sample window. Run with -ProbeEndpoints to test whether its source is reachable - a scraper whose target is down reports exactly this, with no error counter to show for it.' -Data $data))
        }
    }

    $result.Findings = @($out.ToArray())
    $result.Idx1 = $idx1
    $result.Idx2 = $idx2
    return $result
}

function Test-CxExporterFlow {
    <#
      Is anything actually LEAVING for Coralogix?

      Exporter names come from the scrape's exporter= labels, not from the config:
      an exporter declared in config but never instantiated has no series, and
      that absence is itself the signal.
    #>
    [CmdletBinding()]
    param($Flow, [bool] $Fast)

    $out = New-Object System.Collections.ArrayList
    if (-not $Flow.Idx2) { return , @() }

    $names = @(Get-CxMetricLabelValues -Idx $Flow.Idx2 -BasePattern '^otelcol_exporter_' -Label 'exporter')
    if (@($names).Count -eq 0) {
        [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'unknown' -Code 'EXPORTER_NO_COUNTERS' `
            -Message 'the collector publishes no otelcol_exporter_* series, so whether data is reaching Coralogix cannot be measured from here'))
        return , @($out.ToArray())
    }

    foreach ($e in $names) {
        $sent1 = 0.0; $sent2 = 0.0; $fail1 = 0.0; $fail2 = 0.0; $enq1 = 0.0; $enq2 = 0.0
        foreach ($sig in @('spans', 'metric_points', 'log_records')) {
            $sent1 += (Get-CxMetricSum -Idx $Flow.Idx1 -Base "otelcol_exporter_sent_$sig"          -Where @{ exporter = $e }).value
            $sent2 += (Get-CxMetricSum -Idx $Flow.Idx2 -Base "otelcol_exporter_sent_$sig"          -Where @{ exporter = $e }).value
            $fail1 += (Get-CxMetricSum -Idx $Flow.Idx1 -Base "otelcol_exporter_send_failed_$sig"   -Where @{ exporter = $e }).value
            $fail2 += (Get-CxMetricSum -Idx $Flow.Idx2 -Base "otelcol_exporter_send_failed_$sig"   -Where @{ exporter = $e }).value
            $enq1  += (Get-CxMetricSum -Idx $Flow.Idx1 -Base "otelcol_exporter_enqueue_failed_$sig" -Where @{ exporter = $e }).value
            $enq2  += (Get-CxMetricSum -Idx $Flow.Idx2 -Base "otelcol_exporter_enqueue_failed_$sig" -Where @{ exporter = $e }).value
        }
        $dSent = [Math]::Max(0.0, $sent2 - $sent1)
        $dFail = [Math]::Max(0.0, $fail2 - $fail1)
        $dEnq  = [Math]::Max(0.0, $enq2 - $enq1)

        $q1 = Get-CxMetricSum -Idx $Flow.Idx1 -Base 'otelcol_exporter_queue_size'     -Where @{ exporter = $e }
        $q2 = Get-CxMetricSum -Idx $Flow.Idx2 -Base 'otelcol_exporter_queue_size'     -Where @{ exporter = $e }
        $qc = Get-CxMetricSum -Idx $Flow.Idx2 -Base 'otelcol_exporter_queue_capacity' -Where @{ exporter = $e }

        $data = @{ sent = $sent2; deltaSent = $dSent; deltaFailed = $dFail; deltaEnqueueFailed = $dEnq
                   queue = $q2.value; queueCapacity = $qc.value }

        if ($dFail -gt 0 -and $dSent -le 0) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'fail' -Code 'EXPORTER_ALL_SENDS_FAILING' -Target $e `
                -Message ("every send failed during the window ({0} failed, 0 sent) - check CORALOGIX_PRIVATE_KEY, CORALOGIX_DOMAIN, proxy and TLS interception" -f $dFail) -Data $data))
        } elseif ($dFail -gt 0) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'warn' -Code 'EXPORTER_SEND_FAILURES' -Target $e `
                -Message ("{0} sent but {1} failed during the window - intermittent delivery loss" -f $dSent, $dFail) -Data $data))
        } elseif ($dSent -gt 0) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'pass' -Code 'EXPORTER_FLOWING' -Target $e `
                -Message ("+{0} item(s) sent, 0 failed" -f $dSent) -Data $data))
        } elseif ($e -eq 'debug') {
            # The debug exporter sits in an unused stanza; silence is expected.
        } elseif ($Fast) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'unknown' -Target $e `
                -Message ("{0} sent since start; a single sample cannot show whether it is still sending" -f $sent2) -Data $data))
        } elseif ($Flow.AnyReceiverDelta -and $sent2 -le 0) {
            # Data went IN and nothing has EVER come OUT. Isolates a processor-stage
            # drop (memory_limiter, filter/*, groupbytrace) that neither side's
            # counters flag alone.
            #
            # The "sent nothing EVER" qualifier is load-bearing. Gating only on a
            # zero delta produces a false positive on every periodic exporter:
            # coralogix/resource_catalog emits entity events on a slow cadence, so
            # its 35s delta is legitimately 0 almost always. Screaming "data is
            # being dropped" at a healthy pipeline is worse than staying quiet.
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'warn' -Code 'PIPELINE_DROP_SUSPECTED' -Target $e `
                -Message 'receivers produced data but this exporter has never sent anything and reports no failures - data is being dropped in the processor stage (memory_limiter / filter / groupbytrace)' -Data $data))
        } elseif ($sent2 -gt 0) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'info' -Target $e `
                -Message ("nothing sent during the window, but {0} item(s) since start - consistent with a periodic exporter such as the entity/resource-catalog feed" -f $sent2) -Data $data))
        } else {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'info' -Target $e `
                -Message ("nothing sent in the window; no receiver produced anything either, so this is consistent with an idle host ({0} sent since start)" -f $sent2) -Data $data))
        }

        if ($dEnq -gt 0) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'warn' -Code 'EXPORTER_ENQUEUE_FAILED' -Target $e `
                -Message ("{0} item(s) could not even be queued - they were dropped before the wire" -f $dEnq) -Data $data))
        }
        if ($qc.found -and $qc.value -gt 0 -and $q2.value -ge $qc.value) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'fail' -Code 'EXPORTER_QUEUE_FULL' -Target $e `
                -Message ("the send queue is full ({0}/{1}) - new telemetry is being dropped" -f $q2.value, $qc.value) -Data $data))
        } elseif ($qc.found -and $qc.value -gt 0 -and $q2.value -gt $q1.value -and $q2.value -gt (0.5 * $qc.value)) {
            [void] $out.Add((New-Finding -Check 'exporterFlow' -Severity 'warn' -Code 'EXPORTER_QUEUE_GROWING' -Target $e `
                -Message ("the send queue grew from {0} to {1} of {2} - export is slower than ingest (backpressure)" -f $q1.value, $q2.value, $qc.value) -Data $data))
        }
    }
    return , @($out.ToArray())
}

# ===========================================================================
# SECTION 8 - endpoint probes (-ProbeEndpoints)
#
# Probe what each receiver POINTS AT, so "this receiver produced nothing" can be
# attributed to a dead upstream instead of a broken collector. Targets are read
# out of the parsed config, generically - nothing here is a hardcoded host list.
# ===========================================================================

function Test-CxEndpoints {
    [CmdletBinding()]
    param($Model, [string[]] $Wired, [int] $TimeoutSec)

    $out = New-Object System.Collections.ArrayList
    if (-not $Model.Ok) { return , @() }

    foreach ($r in @($Wired)) {
        $blk = Get-CxYamlBlock -Recs $Model.Records -Path @('receivers', $r)
        if (@($blk).Count -eq 0) { continue }
        $kind = ($r -split '/')[0]

        switch -Regex ($kind) {

            '^otlp$' {
                foreach ($proto in @('grpc', 'http')) {
                    $pb = Get-CxYamlBlock -Recs $Model.Records -Path @('receivers', $r, 'protocols', $proto)
                    $ep = Expand-CxEnvPlaceholder (Get-CxYamlScalarIn -Block $pb -Key 'endpoint')
                    if (-not $ep) { continue }
                    $hp = $ep -replace '^https?://', ''
                    $idx = $hp.LastIndexOf(':')
                    if ($idx -lt 0) { continue }
                    $h = $hp.Substring(0, $idx).Trim('[', ']')
                    if ($h -eq '0.0.0.0' -or $h -eq '::' -or -not $h) { $h = '127.0.0.1' }
                    $pn = 0
                    if (-not [int]::TryParse($hp.Substring($idx + 1), [ref] $pn)) { continue }
                    if (Test-CxTcpPort -ComputerName $h -Port $pn) {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Code 'ENDPOINT_REACHABLE' -Target "$r/$proto" `
                            -Message "accepting connections on ${h}:$pn"))
                    } else {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'ENDPOINT_UNREACHABLE' -Target "$r/$proto" `
                            -Message "not accepting connections on ${h}:$pn - instrumented apps cannot deliver telemetry here"))
                    }
                }
            }

            '^prometheus$' {
                # scrape_configs[].static_configs[].targets - a list of host:port
                # nested two list levels down, so collect every `targets` list in
                # the receiver's block rather than walking a fixed path.
                $targets = @()
                $arr = @($blk)
                for ($i = 0; $i -lt $arr.Count; $i++) {
                    if ($arr[$i].key -cne 'targets') { continue }
                    $inline = $arr[$i].value
                    if ($inline -match '^\[(?<b>.*)\]\s*$') {
                        $targets += @($Matches['b'] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                    } else {
                        $ext = Get-CxYamlExtent -Recs $arr -At $i -Hi ($arr.Count - 1)
                        if ($ext[0] -le $ext[1]) {
                            $targets += @($arr[$ext[0]..$ext[1]] | Where-Object { $_.isItem } |
                                ForEach-Object { $_.itemValue.Trim().Trim('"', "'") } | Where-Object { $_ })
                        }
                    }
                }
                foreach ($t in @($targets | Select-Object -Unique)) {
                    $tt = Expand-CxEnvPlaceholder $t
                    $url = "http://$tt/metrics"
                    $resp = Invoke-CxRawGet -Url $url -TimeoutSec $TimeoutSec
                    if ($resp.ok -and $resp.body) {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Code 'ENDPOINT_REACHABLE' -Target "$r/$tt" `
                            -Message "scrape target answered 200 ($(@($resp.body -split "`r?`n").Count) lines)"))
                    } else {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'ENDPOINT_UNREACHABLE' -Target "$r/$tt" `
                            -Message "scrape target did not answer at $url - this receiver produces nothing while that is true"))
                    }
                }
            }

            '^filelog$' {
                $inc = @()
                $arr = @($blk)
                for ($i = 0; $i -lt $arr.Count; $i++) {
                    if ($arr[$i].key -cne 'include') { continue }
                    $inline = $arr[$i].value
                    if ($inline -match '^\[(?<b>.*)\]\s*$') {
                        $inc += @($Matches['b'] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                    } else {
                        $ext = Get-CxYamlExtent -Recs $arr -At $i -Hi ($arr.Count - 1)
                        if ($ext[0] -le $ext[1]) {
                            $inc += @($arr[$ext[0]..$ext[1]] | Where-Object { $_.isItem } |
                                ForEach-Object { $_.itemValue.Trim().Trim('"', "'") } | Where-Object { $_ })
                        }
                    }
                }
                foreach ($g in @($inc | Select-Object -Unique)) {
                    $gg = Expand-CxEnvPlaceholder $g
                    $files = @()
                    try { $files = @(Get-ChildItem -Path $gg -File -ErrorAction SilentlyContinue) } catch { }
                    if (@($files).Count -eq 0) {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'FILELOG_GLOB_NO_MATCH' -Target "$r" `
                            -Message "the include glob matches no files, so this receiver reads nothing: $gg" -Data @{ glob = $gg }))
                    } else {
                        $newest = @($files | Sort-Object LastWriteTime -Descending)[0]
                        $ageMin = ((Get-Date) - $newest.LastWriteTime).TotalMinutes
                        if ($ageMin -gt 60) {
                            [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'info' -Code 'FILELOG_GLOB_STALE' -Target "$r" `
                                -Message ("{0} file(s) match but the newest was written {1:N0} min ago - the source may have stopped logging" -f @($files).Count, $ageMin) `
                                -Data @{ glob = $gg; newest = $newest.FullName }))
                        } else {
                            [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Code 'ENDPOINT_REACHABLE' -Target "$r" `
                                -Message ("{0} file(s) match, newest written {1:N0} min ago" -f @($files).Count, $ageMin) `
                                -Data @{ glob = $gg }))
                        }
                    }
                }
            }

            '^windowseventlog$' {
                $ch = Expand-CxEnvPlaceholder (Get-CxYamlScalarIn -Block $blk -Key 'channel')
                if (-not $ch) { continue }
                try {
                    $log = Get-WinEvent -ListLog $ch -ErrorAction Stop
                    [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Code 'ENDPOINT_REACHABLE' -Target "$r" `
                        -Message ("channel '{0}' readable, {1} record(s)" -f $ch, $log.RecordCount) `
                        -Data @{ channel = $ch; records = $log.RecordCount }))
                } catch {
                    $msg = $_.Exception.Message
                    if ($msg -match 'access|denied|privilege') {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'WINEVENTLOG_CHANNEL_UNREADABLE' -Target "$r" `
                            -Message "channel '$ch' cannot be read by this account (the Security channel needs elevation) - the collector service may still be able to"))
                    } else {
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'WINEVENTLOG_CHANNEL_MISSING' -Target "$r" `
                            -Message "channel '$ch' does not exist on this host: $msg"))
                    }
                }
            }

            default {
                # Generic: any receiver with a plain `endpoint` scalar (rabbitmq,
                # redis, postgresql, elasticsearch, ...).
                $ep = Expand-CxEnvPlaceholder (Get-CxYamlScalarIn -Block $blk -Key 'endpoint')
                if (-not $ep) { continue }
                $hp = $ep -replace '^[a-z]+://', ''
                $hp = ($hp -split '/')[0]
                $idx = $hp.LastIndexOf(':')
                if ($idx -lt 0) { continue }
                $h = $hp.Substring(0, $idx).Trim('[', ']')
                $pn = 0
                if (-not [int]::TryParse($hp.Substring($idx + 1), [ref] $pn)) { continue }
                if (-not (Test-CxTcpPort -ComputerName $h -Port $pn)) {
                    [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'ENDPOINT_UNREACHABLE' -Target $r `
                        -Message "nothing accepting TCP at ${h}:$pn - this receiver cannot collect while that is true" -Data @{ endpoint = $ep }))
                    continue
                }
                if ($ep -match '^https?://') {
                    $resp = Invoke-CxRawGet -Url $ep -TimeoutSec $TimeoutSec
                    if ($resp.status -eq 401 -or $resp.status -eq 403) {
                        # Reachable is what we are testing; the collector has creds.
                        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'info' -Code 'ENDPOINT_AUTH_REQUIRED' -Target $r `
                            -Message "reachable at $ep and requires auth (HTTP $($resp.status)) - expected; the collector supplies credentials" -Data @{ endpoint = $ep }))
                        continue
                    }
                }
                [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Code 'ENDPOINT_REACHABLE' -Target $r `
                    -Message "reachable at ${h}:$pn" -Data @{ endpoint = $ep }))
            }
        }
    }

    # Extensions worth a look when the config declares them.
    foreach ($x in @($Model.Extensions)) {
        $port = switch -Regex ($x) {
            '^zpages'  { 55679; break }
            '^pprof'   { 1777;  break }
            default    { 0 }
        }
        if ($port -eq 0) { continue }
        if (Test-CxTcpPort -Port $port) {
            [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Target $x -Message "extension listening on $port"))
        } else {
            [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'info' -Code 'EXTENSION_UNREACHABLE' -Target $x `
                -Message "declared in the config but nothing is listening on the default port $port"))
        }
    }

    return , @($out.ToArray())
}

function Test-CxOtlpRoundTrip {
    <#
      -SendTestSpan: post one synthetic OTLP/JSON span to the local receiver and
      confirm the otlp accepted-spans counter moves.

      This is the ONLY non-read-only path in the script. It answers the question
      the counters cannot when a host is idle: "is the OTLP receiver actually
      ingesting, or is it just that nothing is sending?"
    #>
    [CmdletBinding()]
    param($Probe, [int] $OtlpHttpPort, [int] $TimeoutSec)

    $out = New-Object System.Collections.ArrayList
    if (-not $Probe.Reachable) {
        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'unknown' -Code 'OTLP_ROUNDTRIP_FAILED' `
            -Message 'cannot verify the round trip without the collector internal telemetry endpoint'))
        return , @($out.ToArray())
    }

    $before = (Get-CxMetricSum -Idx (ConvertFrom-CxPromText -Text (Invoke-CxRawGet -Url $Probe.MetricsUrl -TimeoutSec $TimeoutSec).body) `
        -Base 'otelcol_receiver_accepted_spans' -Where @{ receiver = 'otlp' }).value

    # 16-byte trace id / 8-byte span id as lowercase hex, per the OTLP/JSON spec.
    $rand = New-Object System.Random
    $tid = -join (1..32 | ForEach-Object { '{0:x}' -f $rand.Next(0, 16) })
    $sid = -join (1..16 | ForEach-Object { '{0:x}' -f $rand.Next(0, 16) })
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000
    $body = @"
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"cx-instrumentation-selftest"}}]},"scopeSpans":[{"scope":{"name":"Test-CxInstrumentation"},"spans":[{"traceId":"$tid","spanId":"$sid","name":"selftest","kind":1,"startTimeUnixNano":"$now","endTimeUnixNano":"$now"}]}]}]}
"@

    $post = Invoke-CxRawPost -Url ("http://127.0.0.1:{0}/v1/traces" -f $OtlpHttpPort) -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSec
    if (-not $post.ok) {
        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'OTLP_ROUNDTRIP_FAILED' -Target 'otlp' `
            -Message ("the OTLP receiver rejected a synthetic span (HTTP {0}) {1}" -f $post.status, $post.error)))
        return , @($out.ToArray())
    }

    Start-Sleep -Seconds 3
    $after = (Get-CxMetricSum -Idx (ConvertFrom-CxPromText -Text (Invoke-CxRawGet -Url $Probe.MetricsUrl -TimeoutSec $TimeoutSec).body) `
        -Base 'otelcol_receiver_accepted_spans' -Where @{ receiver = 'otlp' }).value

    if ($after -gt $before) {
        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'pass' -Code 'OTLP_ROUNDTRIP_OK' -Target 'otlp' `
            -Message ("synthetic span accepted (counter {0} -> {1}) - the OTLP ingest path works" -f $before, $after)))
    } else {
        [void] $out.Add((New-Finding -Check 'endpoints' -Severity 'warn' -Code 'OTLP_ROUNDTRIP_FAILED' -Target 'otlp' `
            -Message ("the span was accepted over HTTP but the accepted-spans counter did not move ({0}) - the receiver may be dropping it" -f $after)))
    }
    return , @($out.ToArray())
}

# ===========================================================================
# SECTION 9 - IIS / .NET instrumentation
#
# Ported from deploy\Test-IISInstrumentation.ps1. Deliberately does NOT use the
# WebAdministration module: everything needed is in applicationHost.config, so
# this still works on a host where the IIS management tools are missing - itself
# one of the failure modes the fleet has hit.
# ===========================================================================

function Test-CxIisPresent {
    (Test-Path -LiteralPath (Join-Path $env:windir 'System32\inetsrv\appcmd.exe')) -or
    [bool](Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue)
}

function Get-CxServiceEnvironment {
    <#
      A service's Environment value (REG_MULTI_SZ) as string[]. $null when absent,
      which is NOT an error: a host that was never instrumented has no such value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ServiceName)
    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        if (-not (Test-Path -LiteralPath $key -ErrorAction SilentlyContinue)) { return $null }
        $p = Get-ItemProperty -LiteralPath $key -Name 'Environment' -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        return @($p.Environment)
    } catch { return $null }
}

function Get-CxEnvEntry {
    # NAME=value out of a REG_MULTI_SZ list; case-insensitive like Windows env.
    [CmdletBinding()]
    param([string[]] $Entries, [Parameter(Mandatory)][string] $Name)
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $i = $e.IndexOf('=')
        if ($i -lt 1) { continue }
        if ($e.Substring(0, $i).Trim() -ieq $Name) { return $e.Substring($i + 1) }
    }
    return $null
}

function Get-CxAppHostModel {
    <#
      Parse applicationHost.config ONCE into Pools / Defaults / Apps.

      Node selection is done in PowerShell rather than by interpolating names into
      an XPath literal, so a pool named  Bob's Pool  cannot break the query.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $model = [pscustomobject]@{ Ok = $false; Error = $null; Denied = $false; Pools = @{}; Defaults = @{}; Apps = @() }

    # Read first and classify the failure rather than pre-checking with Test-Path:
    # on a permission-denied path Test-Path emits a NON-TERMINATING error (which
    # escapes try/catch under 'Continue') and returns $false, so a pre-check
    # reports "not found" for a file that exists but is unreadable. That exact
    # misdiagnosis is what this script exists to prevent.
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        $model.Error = "access denied reading applicationHost.config (run elevated): $Path"
        $model.Denied = $true
        return $model
    } catch {
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.Exception -is [System.IO.FileNotFoundException] -or
            $_.Exception -is [System.IO.DirectoryNotFoundException]) {
            $model.Error = "applicationHost.config not found at $Path"
        } elseif ($_.Exception.GetType().Name -match 'UnauthorizedAccess') {
            $model.Error = "access denied reading applicationHost.config (run elevated): $Path"
            $model.Denied = $true
        } else {
            $model.Error = "could not read/parse applicationHost.config: $($_.Exception.Message)"
        }
        return $model
    }

    function ConvertTo-CxEnvMap($node) {
        $map = @{}
        if (-not $node) { return $map }
        $block = $node.SelectSingleNode('environmentVariables')
        if (-not $block) { return $map }
        foreach ($a in @($block.SelectNodes('add'))) {
            $n = [string]$a.GetAttribute('name')
            if ($n) { $map[$n] = [string]$a.GetAttribute('value') }
        }
        return $map
    }

    try {
        $poolsRoot = $xml.SelectSingleNode('/configuration/system.applicationHost/applicationPools')
        if ($poolsRoot) {
            $model.Defaults = ConvertTo-CxEnvMap $poolsRoot.SelectSingleNode('applicationPoolDefaults')
            foreach ($p in @($poolsRoot.SelectNodes('add'))) {
                $name = [string]$p.GetAttribute('name')
                if (-not $name) { continue }
                $model.Pools[$name] = [pscustomobject]@{
                    Name = $name
                    # An ABSENT attribute means "inherit the default", which is v4.0 -
                    # NOT "No Managed Code". Only an explicitly empty string is No
                    # Managed Code, so absent and empty must stay distinguishable.
                    ManagedRuntimeVersion = if ($p.HasAttribute('managedRuntimeVersion')) { [string]$p.GetAttribute('managedRuntimeVersion') } else { $null }
                    HasOwnEnvBlock        = [bool]$p.SelectSingleNode('environmentVariables')
                    Env                   = (ConvertTo-CxEnvMap $p)
                }
            }
        }

        $sitesRoot = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
        if ($sitesRoot) {
            # An <application> may OMIT applicationPool, in which case IIS resolves
            # it from <sites><applicationDefaults applicationPool="...">. The stock
            # "Default Web Site" does exactly this on a fresh IIS, so skipping the
            # fallback makes the pool look empty and every check keyed on it report
            # a FALSE "not configured" - on essentially every host in the fleet.
            $poolDefault = ''
            $defNode = $sitesRoot.SelectSingleNode('applicationDefaults')
            if ($defNode) { $poolDefault = [string]$defNode.GetAttribute('applicationPool') }

            foreach ($site in @($sitesRoot.SelectNodes('site'))) {
                $siteName = [string]$site.GetAttribute('name')
                foreach ($app in @($site.SelectNodes('application'))) {
                    $appPath = [string]$app.GetAttribute('path')
                    if (-not $appPath) { $appPath = '/' }

                    $pool = [string]$app.GetAttribute('applicationPool')
                    if (-not $pool) {
                        $siteDef = $site.SelectSingleNode('applicationDefaults')
                        if ($siteDef) { $pool = [string]$siteDef.GetAttribute('applicationPool') }
                    }
                    if (-not $pool) { $pool = $poolDefault }

                    $phys = ''
                    foreach ($vd in @($app.SelectNodes('virtualDirectory'))) {
                        if (([string]$vd.GetAttribute('path')) -eq '/') { $phys = [string]$vd.GetAttribute('physicalPath'); break }
                    }
                    if ($phys) { try { $phys = [Environment]::ExpandEnvironmentVariables($phys) } catch { } }

                    $model.Apps += [pscustomobject]@{ Site = $siteName; AppPath = $appPath; Pool = $pool; PhysicalPath = $phys }
                }
            }
        }
        $model.Ok = $true
    } catch {
        $model.Error = "unexpected shape in applicationHost.config: $($_.Exception.Message)"
    }
    return $model
}

function Get-CxWebConfigCoreState {
    <#
      Does this app's own web.config declare <aspNetCore> - i.e. is it an ASP.NET
      Core app, which REQUIRES a "No Managed Code" pool?

      A state, not a tri-state boolean, because "there is no web.config" and
      "web.config could not be read" are DIFFERENT ANSWERS and reporting them as
      one produced a wrong diagnosis on essentially every host: stock IIS ships
      C:\inetpub\wwwroot with iisstart.htm and no web.config, so "Default Web
      Site/" always came back as unreadable and read like a permissions problem.

        nopath      no physicalPath in applicationHost.config
        absent      no web.config there (DirMissing = the folder is gone too).
                    ANCM is wired BY web.config, so barring inheritance from a
                    parent application this is NOT an ASP.NET Core app
        unreadable  exists but could not be opened or parsed - Error carries the
                    reason, the only way to tell an ACL from malformed XML
        ok          parsed; IsCore is authoritative

      Matched with //aspNetCore because publish output commonly wraps the node in
      <location path="."> rather than putting it directly under <system.webServer>.
      Inheritable reports whether that <location> lets the setting flow into child
      applications; `dotnet publish` emits inheritInChildApplications="false"
      precisely to stop it.

      Reads through [System.IO.File] rather than Test-Path/Get-Content on purpose:
      the .NET exceptions distinguish not-found from access-denied, where a
      Test-Path under SilentlyContinue returns $false for both.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)

    # $Reason, not $Error: a parameter named Error would shadow the automatic
    # $Error collection inside this function.
    function New-State {
        param($State, $IsCore, $Inheritable = $false, $DirMissing = $false, $Reason = $null)
        [pscustomobject]@{
            State = $State; IsCore = $IsCore; Inheritable = $Inheritable
            DirMissing = $DirMissing; Error = $Reason
        }
    }

    if (-not $PhysicalPath) {
        return (New-State 'nopath' $null -Reason 'the application has no physicalPath in applicationHost.config, so its web.config cannot be located')
    }

    $wc = Join-Path $PhysicalPath 'web.config'
    $raw = $null
    try {
        $raw = [System.IO.File]::ReadAllText($wc)
    } catch [System.IO.DirectoryNotFoundException] {
        return (New-State 'absent' $false -DirMissing $true)
    } catch [System.IO.FileNotFoundException] {
        return (New-State 'absent' $false)
    } catch {
        return (New-State 'unreadable' $null -Reason $_.Exception.Message)
    }

    try {
        [xml]$x = $raw
    } catch {
        return (New-State 'unreadable' $null -Reason "web.config is not well-formed XML: $($_.Exception.Message)")
    }

    $core = $x.SelectSingleNode('//aspNetCore')
    $inheritable = $true
    if ($core) {
        foreach ($loc in @($core.SelectNodes('ancestor::location'))) {
            $v = [string]$loc.GetAttribute('inheritInChildApplications')
            if ($v -match '^\s*(false|0)\s*$') { $inheritable = $false; break }
        }
    }
    return (New-State 'ok' ([bool]$core) -Inheritable $inheritable)
}

function Get-CxAncestorApps {
    <#
      Applications on the same site ABOVE this one in the URL hierarchy, nearest
      first. IIS config inheritance follows the URL path, not the physical one, so
      this - not a walk up the filesystem - is how a child app finds the web.config
      it may be inheriting from.
    #>
    [CmdletBinding()]
    param($Model, $App)

    $self = ([string]$App.AppPath).TrimEnd('/')      # '/' -> '',  '/api' -> '/api'
    $out = @($Model.Apps | Where-Object {
        $_.Site -eq $App.Site -and $_.AppPath -ne $App.AppPath -and
        ($_.AppPath -eq '/' -or $self.StartsWith((([string]$_.AppPath).TrimEnd('/') + '/'), [StringComparison]::OrdinalIgnoreCase))
    })
    return ,@($out | Sort-Object { ([string]$_.AppPath).Length } -Descending)
}

function Test-CxAspNetCoreApp {
    <#
      Back-compat wrapper: $true / $false / $null-when-unknowable. Prefer
      Get-CxWebConfigCoreState, which says WHY the answer is unknown.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)
    $s = Get-CxWebConfigCoreState -PhysicalPath $PhysicalPath
    if ($s.State -eq 'ok' -or $s.State -eq 'absent') { return [bool]$s.IsCore }
    return $null
}

function Get-CxEffectivePoolEnv {
    <#
      A pool's own <environmentVariables> block REPLACES applicationPoolDefaults;
      it is not merged. Checking the defaults alone therefore reports a false pass
      for any pool that has its own block.

      The block is a snapshot of the defaults as they were at its FIRST write, and a
      pool can acquire one before the agent is ever installed (any earlier appcmd
      write of any env var - a connection string, say). Such a pool predates the OTLP
      defaults and never sees them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pool, [hashtable] $Defaults)
    if ($Pool.HasOwnEnvBlock) { return $Pool.Env }
    return $Defaults
}

function Get-CxPoolEnvDrift {
    <#
      Names in BOTH the defaults and the pool's own block whose values disagree.
      Each is a stale snapshot: the pool's block was copied when it was first
      written and never picks up a later change to the defaults. This is the
      failure behind "I fixed the OTLP endpoint centrally and half the fleet still
      exports nowhere".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pool, [hashtable] $Defaults)
    $drift = @()
    if (-not $Pool.HasOwnEnvBlock) { return $drift }
    foreach ($k in @($Defaults.Keys)) {
        if ($Pool.Env.ContainsKey($k) -and ([string]$Pool.Env[$k]) -ne ([string]$Defaults[$k])) {
            $drift += [pscustomobject]@{ Name = $k; Pool = [string]$Pool.Env[$k]; Default = [string]$Defaults[$k] }
        }
    }
    return $drift
}

function Test-CxIis {
    [CmdletBinding()]
    param([string] $ExpectedOtlpEndpoint, [string] $AppHostConfig)

    $findings = New-Object System.Collections.ArrayList
    function Add-F { param($f) [void]$findings.Add($f) }

    if (-not (Test-CxIisPresent)) {
        Add-F (New-Finding -Check 'iis' -Severity 'skip' -Code 'IIS_ABSENT' -Message 'no IIS on this host - nothing to instrument')
        return , @($findings.ToArray())
    }

    # Elevation is a hard fail HERE (and only here): applicationHost.config and
    # the service registry are Administrators-only, so a non-elevated run would
    # report every app as unconfigured. Refuse rather than lie.
    if (-not (Test-CxElevated)) {
        Add-F (New-Finding -Check 'iis' -Severity 'fail' -Code 'NOT_ELEVATED' `
            -Message 'IIS is present but this is not an elevated run - applicationHost.config and the service registry are unreadable, so every IIS result would be a false negative')
        return , @($findings.ToArray())
    }

    $model = Get-CxAppHostModel -Path $AppHostConfig
    if (-not $model.Ok) {
        $code = if ($model.Denied) { 'APPHOST_ACCESS_DENIED' } else { 'APPHOST_UNREADABLE' }
        Add-F (New-Finding -Check 'iis' -Severity 'unknown' -Code $code -Message $model.Error -Target $AppHostConfig)
    }

    $appCount = @($model.Apps).Count
    # A golden image with the role baked in and no sites yet is a legitimate
    # steady state; claiming the profiler is missing would be noise.
    if ($model.Ok -and $appCount -eq 0) {
        Add-F (New-Finding -Check 'iis' -Severity 'skip' -Code 'IIS_NO_APPS' `
            -Message 'IIS is installed but hosts no applications - instrumentation is not expected' -Data @{ appCount = 0 })
        return , @($findings.ToArray())
    }

    foreach ($svc in @('W3SVC', 'WAS')) {
        $entries = Get-CxServiceEnvironment -ServiceName $svc
        if ($null -eq $entries) {
            Add-F (New-Finding -Check 'profiler' -Severity 'warn' -Code 'PROFILER_NOT_REGISTERED' -Target $svc `
                -Message "$svc has no Environment value - Register-OpenTelemetryForIIS never ran (or was undone). No .NET app on this host is instrumented.")
            continue
        }

        # Malformed FIRST: an empty element in this REG_MULTI_SZ PREVENTS IIS FROM
        # STARTING ("cannot contain empty strings"), so it outranks everything else.
        $emptyCount = @($entries | Where-Object { [string]::IsNullOrEmpty($_) }).Count
        if ($emptyCount -gt 0) {
            Add-F (New-Finding -Check 'profilerReg' -Severity 'fail' -Code 'PROFILER_REGISTRY_MALFORMED' -Target $svc `
                -Message "$svc Environment REG_MULTI_SZ contains $emptyCount empty element(s) - this PREVENTS IIS FROM STARTING. Restore $svc.reg from the deploy backup dir (reg import) or remove the blank entry." `
                -Data @{ entryCount = @($entries).Count; emptyCount = $emptyCount })
        } else {
            Add-F (New-Finding -Check 'profilerReg' -Severity 'pass' -Target $svc `
                -Message "$svc Environment is well-formed ($(@($entries).Count) entries)")
        }

        # CORECLR_* is .NET Core/5+; COR_* is .NET Framework.
        $clrGuid   = Get-CxEnvEntry -Entries $entries -Name 'CORECLR_PROFILER'
        $clrEnable = Get-CxEnvEntry -Entries $entries -Name 'CORECLR_ENABLE_PROFILING'
        $fwGuid    = Get-CxEnvEntry -Entries $entries -Name 'COR_PROFILER'
        $fwEnable  = Get-CxEnvEntry -Entries $entries -Name 'COR_ENABLE_PROFILING'

        if (-not $clrGuid -and -not $fwGuid) {
            Add-F (New-Finding -Check 'profiler' -Severity 'warn' -Code 'PROFILER_NOT_REGISTERED' -Target $svc `
                -Message "$svc Environment has no CORECLR_PROFILER or COR_PROFILER - the CLR profiler is not attached, so no spans are produced regardless of collector health")
        } elseif ($clrGuid -and $clrEnable -ne '1') {
            Add-F (New-Finding -Check 'profiler' -Severity 'warn' -Code 'PROFILER_NOT_ENABLED' -Target $svc `
                -Message "$svc has CORECLR_PROFILER but CORECLR_ENABLE_PROFILING='$clrEnable' (expected '1') - the profiler is registered but switched off" `
                -Data @{ profiler = $clrGuid; enable = $clrEnable })
        } else {
            Add-F (New-Finding -Check 'profiler' -Severity 'pass' -Target $svc `
                -Message "profiler registered (coreclr=$([bool]$clrGuid) framework=$([bool]$fwGuid), enabled)" `
                -Data @{ coreclrProfiler = $clrGuid; corProfiler = $fwGuid })
        }

        # A stale DLL path lets IIS start and emit nothing - invisible otherwise.
        $pathNames = @('CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH',
                       'COR_PROFILER_PATH_64','COR_PROFILER_PATH_32','COR_PROFILER_PATH')
        $checked = 0
        foreach ($pn in $pathNames) {
            $dll = Get-CxEnvEntry -Entries $entries -Name $pn
            if (-not $dll) { continue }
            $checked++
            if (Test-Path -LiteralPath $dll -ErrorAction SilentlyContinue) {
                Add-F (New-Finding -Check 'profilerPath' -Severity 'pass' -Target "$svc/$pn" -Message 'profiler DLL present' -Data @{ path = $dll })
            } else {
                Add-F (New-Finding -Check 'profilerPath' -Severity 'warn' -Code 'PROFILER_PATH_MISSING' -Target "$svc/$pn" `
                    -Message "$pn points at a file that does not exist - IIS starts but emits no telemetry: $dll" -Data @{ path = $dll })
            }
        }
        if ($checked -eq 0 -and ($clrGuid -or $fwGuid)) {
            Add-F (New-Finding -Check 'profilerPath' -Severity 'warn' -Code 'PROFILER_PATH_MISSING' -Target $svc `
                -Message "$svc declares a profiler GUID but no *_PROFILER_PATH* entry - the CLR cannot load the profiler")
        }
    }

    $w3 = Get-CxServiceEnvironment -ServiceName 'W3SVC'
    $autoHome = Get-CxEnvEntry -Entries $w3 -Name 'OTEL_DOTNET_AUTO_HOME'
    if (-not $autoHome) {
        if ($w3) {
            Add-F (New-Finding -Check 'autoHome' -Severity 'warn' -Code 'AUTO_HOME_MISSING' `
                -Message 'OTEL_DOTNET_AUTO_HOME is not set on W3SVC - Install-OpenTelemetryCore did not complete')
        }
    } elseif (-not (Test-Path -LiteralPath $autoHome -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'autoHome' -Severity 'warn' -Code 'AUTO_HOME_MISSING' `
            -Message "OTEL_DOTNET_AUTO_HOME points at a missing directory: $autoHome" -Data @{ path = $autoHome })
    } else {
        Add-F (New-Finding -Check 'autoHome' -Severity 'pass' -Message 'auto-instrumentation home present' -Data @{ path = $autoHome })
    }

    # Version is best-effort. Read the deploy manifest directly rather than
    # dot-sourcing Backup-Config.ps1, so this file stays standalone.
    $manifestVersion = $null
    try {
        $latest = Join-Path $env:ProgramData 'CoralogixDeploy\backups\latest.json'
        if (Test-Path -LiteralPath $latest -ErrorAction SilentlyContinue) {
            $j = Get-Content -LiteralPath $latest -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($j.instrumentVersion) { $manifestVersion = [string]$j.instrumentVersion }
            elseif ($j.manifest -and $j.manifest.instrumentVersion) { $manifestVersion = [string]$j.manifest.instrumentVersion }
        }
    } catch { }

    if ($manifestVersion) {
        Add-F (New-Finding -Check 'autoHome' -Severity 'info' -Message "deploy manifest records instrumentation version $manifestVersion" `
            -Data @{ instrumentVersion = $manifestVersion })
    } elseif ($autoHome) {
        Add-F (New-Finding -Check 'autoHome' -Severity 'info' -Code 'INSTRUMENTATION_VERSION_UNKNOWN' `
            -Message 'no deploy manifest found, so the installed instrumentation version cannot be confirmed')
    }

    if (-not $model.Ok) { return , @($findings.ToArray()) }

    # Only pools that actually host an application matter.
    $usedPools = @($model.Apps | ForEach-Object { $_.Pool } | Where-Object { $_ } | Select-Object -Unique)
    $defEndpoint = $model.Defaults['OTEL_EXPORTER_OTLP_ENDPOINT']
    if (-not $defEndpoint) {
        Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'IIS_OTLP_DEFAULTS_MISSING' -Target 'applicationPoolDefaults' `
            -Message 'OTEL_EXPORTER_OTLP_ENDPOINT is not set on applicationPoolDefaults - pools that do not set it themselves have no exporter target')
    }

    foreach ($poolName in $usedPools) {
        $pool = $model.Pools[$poolName]
        if (-not $pool) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'unknown' -Code 'POOL_NOT_FOUND' -Target $poolName `
                -Message 'an application references a pool that is not declared in applicationHost.config')
            continue
        }

        $eff = Get-CxEffectivePoolEnv -Pool $pool -Defaults $model.Defaults
        $endpoint = $eff['OTEL_EXPORTER_OTLP_ENDPOINT']

        if (-not $endpoint) {
            if ($pool.HasOwnEnvBlock -and $defEndpoint) {
                Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'POOL_LOST_INHERITANCE' -Target $poolName `
                    -Message 'pool declares its own <environmentVariables>, which REPLACES applicationPoolDefaults - it has no OTEL_EXPORTER_OTLP_ENDPOINT even though the defaults do. Usually a pool that owned a block before the agent was installed. Re-run Instrument-IIS.ps1 and recycle the pool: it writes the OTLP vars straight onto pools that own a block.' `
                    -Data @{ defaultsEndpoint = $defEndpoint; poolEnvKeys = @($pool.Env.Keys) })
            } else {
                Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'IIS_OTLP_DEFAULTS_MISSING' -Target $poolName `
                    -Message 'no effective OTEL_EXPORTER_OTLP_ENDPOINT for this pool')
            }
            continue
        }

        if ($endpoint -match 'localhost') {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'OTLP_ENDPOINT_LOCALHOST' -Target $poolName `
                -Message "endpoint uses 'localhost' ($endpoint). On a dual-stack host that resolves to ::1 first and OTLP export is silently dropped. Use $ExpectedOtlpEndpoint." `
                -Data @{ endpoint = $endpoint; expected = $ExpectedOtlpEndpoint })
        } elseif ($endpoint -ne $ExpectedOtlpEndpoint) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'info' -Target $poolName `
                -Message "endpoint '$endpoint' differs from the expected '$ExpectedOtlpEndpoint' (intentional if this host exports elsewhere)" `
                -Data @{ endpoint = $endpoint; expected = $ExpectedOtlpEndpoint })
        } else {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'pass' -Target $poolName -Message "endpoint $endpoint" `
                -Data @{ endpoint = $endpoint; inherited = (-not $pool.HasOwnEnvBlock) })
        }

        if (-not $eff['OTEL_EXPORTER_OTLP_PROTOCOL']) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'info' -Target $poolName `
                -Message 'OTEL_EXPORTER_OTLP_PROTOCOL is not set; the SDK default applies')
        }

        foreach ($d in (Get-CxPoolEnvDrift -Pool $pool -Defaults $model.Defaults)) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'POOL_ENV_STALE' -Target "$poolName/$($d.Name)" `
                -Message "pool has '$($d.Pool)' but applicationPoolDefaults now says '$($d.Default)'. A pool's own <environmentVariables> block replaces the defaults and is only a snapshot taken when the pool was first written, so this pool never picked up the change. Re-run Instrument-IIS.ps1 and recycle the pool." `
                -Data @{ name = $d.Name; pool = $d.Pool; default = $d.Default })
        }
    }

    # Wrong runtime here means NO telemetry at all, regardless of everything above.
    foreach ($app in $model.Apps) {
        $label = "$($app.Site)$($app.AppPath)"
        $wc    = Get-CxWebConfigCoreState -PhysicalPath $app.PhysicalPath

        # A read FAILURE is genuinely unknown. A web.config that is simply not
        # there is not, and reporting both as "cannot read web.config" made the
        # stock Default Web Site - wwwroot ships iisstart.htm and no web.config -
        # look like an ACL problem on every host in the fleet.
        if ($wc.State -eq 'unreadable' -or $wc.State -eq 'nopath') {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'WEBCONFIG_UNREADABLE' -Target $label `
                -Message "$($wc.Error) - so it is unknown whether this is an ASP.NET Core app needing 'No Managed Code'" `
                -Data @{ physicalPath = $app.PhysicalPath; error = $wc.Error })
            continue
        }

        $isCore        = [bool]$wc.IsCore
        $inheritedFrom = $null

        if ($wc.State -eq 'absent') {
            # No web.config of its own. ANCM is wired per-application BY web.config,
            # so that normally settles it - except <system.webServer> inherits into
            # child applications unless a parent wraps it in
            # <location inheritInChildApplications="false">. The nearest ancestor
            # that HAS a web.config decides; anything above it is already shadowed.
            foreach ($anc in (Get-CxAncestorApps -Model $model -App $app)) {
                $awc = Get-CxWebConfigCoreState -PhysicalPath $anc.PhysicalPath
                if ($awc.State -ne 'ok') { continue }
                if ($awc.IsCore -and $awc.Inheritable) {
                    $isCore = $true
                    $inheritedFrom = "$($anc.Site)$($anc.AppPath)"
                }
                break
            }

            if (-not $isCore) {
                $msg = if ($wc.DirMissing) {
                    "physical path '$($app.PhysicalPath)' does not exist, so there is no web.config - IIS cannot serve this app at all, and it is certainly not ASP.NET Core"
                } else {
                    "no web.config at '$($app.PhysicalPath)' - ASP.NET Core in IIS is wired by <aspNetCore> in web.config, so this is a static or ASP.NET Framework app and needs no 'No Managed Code' pool. Normal for the stock Default Web Site."
                }
                Add-F (New-Finding -Check 'poolRuntime' -Severity 'info' -Code 'WEBCONFIG_ABSENT' -Target $label `
                    -Message $msg -Data @{ physicalPath = $app.PhysicalPath; dirMissing = [bool]$wc.DirMissing })
                continue
            }
        }

        if (-not $isCore) { continue }   # Framework app: a managed runtime is correct

        $via = if ($inheritedFrom) { " (<aspNetCore> inherited from '$inheritedFrom'; it has no web.config of its own)" } else { '' }

        $pool = $model.Pools[$app.Pool]
        if (-not $pool) {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'POOL_NOT_FOUND' -Target $label `
                -Message "pool '$($app.Pool)' is not declared in applicationHost.config")
            continue
        }

        $mrv = $pool.ManagedRuntimeVersion
        if ($mrv -eq '') {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'pass' -Target $label `
                -Message "ASP.NET Core app on pool '$($app.Pool)' is No Managed Code$via")
        } else {
            $shown = if ($null -eq $mrv) { '<inherited default>' } else { $mrv }
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'warn' -Code 'POOL_NOT_NO_MANAGED_CODE' -Target $label `
                -Message "ASP.NET Core app but pool '$($app.Pool)' has managedRuntimeVersion=$shown - it must be '' (No Managed Code) or the app emits NO telemetry at all$via" `
                -Data @{ pool = $app.Pool; managedRuntimeVersion = $mrv; inheritedFrom = $inheritedFrom })
        }
    }

    return , @($findings.ToArray())
}

# ===========================================================================
# SECTION 10 - Node.js / PM2 instrumentation
#
# Ported from deploy\Test-NodeInstrumentation.ps1, including two traps already
# paid for in this repo:
#
#  1. NEVER ConvertFrom-Json the output of `pm2 jlist`. PM2 copies the whole
#     process environment into pm2_env, and PS 5.1 deserialises JSON into a
#     CASE-INSENSITIVE dictionary, so two env keys differing only in case
#     (Path/PATH, Temp/TEMP - routine on Windows) collide and it throws
#     DuplicateKeysInJsonString. Exact-case duplicates are merely last-wins and
#     do NOT throw, so the failure is intermittent across hosts, which is worse
#     than a hard one. Parse the blob with regex instead.
#
#  2. PM2 IS PER-USER ON WINDOWS. The daemon this script can see belongs to the
#     account running it, which when elevated is often NOT the account owning the
#     production apps. When PM2 looks installed but reports no apps this returns
#     `unknown`, never `fail`.
# ===========================================================================

function Get-CxJsonString {
    # A JSON string value by key, honouring backslash escapes. Order matters on
    # the unescape: doing \\ first would double-process.
    [CmdletBinding()]
    param([string] $Json, [Parameter(Mandatory)][string] $Key)
    if (-not $Json) { return $null }
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"((?:[^"\\]|\\.)*)"'
    $m = [regex]::Match($Json, $pattern)
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    $v = $v -replace '\\u0026', '&'
    $v = $v.Replace('\/', '/').Replace('\"', '"').Replace('\n', "`n").Replace('\r', "`r").Replace('\t', "`t")
    $v = $v.Replace('\\', '\')
    return $v
}

function Test-CxPm2Available { [bool](Get-Command pm2 -ErrorAction SilentlyContinue) }

function Test-CxNodeWorkloadPresent {
    # Is there Node/PM2 activity at all, regardless of whether THIS account's
    # daemon can see it? Tells "no Node here" (skip) from "wrong daemon" (unknown).
    $procs = @(Get-Process -Name 'node', 'pm2', 'PM2' -ErrorAction SilentlyContinue)
    return ($procs.Count -gt 0)
}

function Get-CxPm2Apps {
    <#
      $null      - pm2 could not be queried at all
      @()        - pm2 answered and manages no apps
      @(records) - one per app

      Where a key appears both at pm2_env level and inside pm2_env.env, the first
      match wins, which is the pm2_env value - the one the running process
      actually inherited.

      No `2>&1` on pm2: it writes to stderr, and under 'Stop' a merge becomes a
      terminating NativeCommandError in PS 5.1.
    #>
    [CmdletBinding()]
    param()

    $raw = $null
    try { $raw = (& pm2 jlist 2>$null | Out-String) } catch { return $null }
    if ($null -eq $raw) { return $null }
    $raw = $raw.Trim()
    if (-not $raw) { return $null }

    # PM2 sometimes prefixes the JSON with daemon chatter; start at the array.
    $start = $raw.IndexOf('[')
    if ($start -lt 0) { return $null }
    $raw = $raw.Substring($start)
    if ($raw -eq '[]') { return @() }

    $chunks = [regex]::Split($raw, '(?=\{"pid")') | Where-Object { $_ -match '"pid"' }
    if (-not $chunks -or @($chunks).Count -eq 0) {
        if ($raw -match '"name"') { return $null }   # unrecognised shape - do not guess
        return @()
    }

    $apps = @()
    foreach ($c in $chunks) {
        $apps += [pscustomobject]@{
            Name         = (Get-CxJsonString -Json $c -Key 'name')
            Status       = (Get-CxJsonString -Json $c -Key 'status')
            ExecMode     = (Get-CxJsonString -Json $c -Key 'exec_mode')
            NodeOptions  = (Get-CxJsonString -Json $c -Key 'NODE_OPTIONS')
            ServiceName  = (Get-CxJsonString -Json $c -Key 'OTEL_SERVICE_NAME')
            OtlpEndpoint = (Get-CxJsonString -Json $c -Key 'OTEL_EXPORTER_OTLP_ENDPOINT')
        }
    }
    return @($apps | Where-Object { $_.Name })
}

function Get-CxRegisterPathFromNodeOptions {
    [CmdletBinding()]
    param([string] $NodeOptions)
    if (-not $NodeOptions) { return $null }
    $m = [regex]::Match($NodeOptions, '--require(?:=|\s+)(?:"([^"]+)"|(\S+))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

function Test-CxNode {
    [CmdletBinding()]
    param([string] $InstallPrefix, [string] $Package, [string] $ExpectedOtlpEndpoint, $ConfigModel)

    $findings = New-Object System.Collections.ArrayList
    function Add-F { param($f) [void]$findings.Add($f) }

    $cxNodeServices = $null
    try { $cxNodeServices = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine') } catch { }

    if (-not (Test-CxPm2Available)) {
        if (Test-CxNodeWorkloadPresent) {
            Add-F (New-Finding -Check 'node' -Severity 'unknown' -Code 'NODE_PM2_NOT_ON_PATH' `
                -Message 'node processes are running but pm2 is not on this account PATH - cannot determine whether they are instrumented')
        } else {
            Add-F (New-Finding -Check 'node' -Severity 'skip' -Code 'NO_PM2' -Message 'PM2 is not installed on this host - nothing to instrument')
        }
        if ($cxNodeServices) {
            Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_DRIFT' `
                -Message "CX_NODE_SERVICES is set to '$cxNodeServices' but PM2 is not present - this is a stale value from a prior deploy" `
                -Data @{ cxNodeServices = $cxNodeServices })
        }
        return , @($findings.ToArray())
    }

    $apps = Get-CxPm2Apps

    if ($null -eq $apps) {
        Add-F (New-Finding -Check 'node' -Severity 'unknown' -Code 'NODE_PM2_DAEMON_NOT_VISIBLE' `
            -Message 'pm2 is installed but its app list could not be read. PM2 is per-user on Windows: an elevated run often sees a DIFFERENT daemon than the one owning the apps. Re-run as the account that owns them.')
        return , @($findings.ToArray())
    }

    if (@($apps).Count -eq 0) {
        if (Test-CxNodeWorkloadPresent) {
            Add-F (New-Finding -Check 'node' -Severity 'unknown' -Code 'NODE_PM2_DAEMON_NOT_VISIBLE' `
                -Message 'this account''s pm2 daemon manages no apps, yet node processes are running - they are almost certainly owned by another user''s daemon. Re-run as that account.')
        } else {
            Add-F (New-Finding -Check 'node' -Severity 'skip' -Code 'NO_PM2_APPS' -Message 'PM2 is installed but manages no apps - nothing to instrument')
        }
        if ($cxNodeServices) {
            Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_DRIFT' `
                -Message "CX_NODE_SERVICES is set to '$cxNodeServices' but PM2 manages no apps - stale value from a prior deploy" `
                -Data @{ cxNodeServices = $cxNodeServices })
        }
        return , @($findings.ToArray())
    }

    $nodeModules = Join-Path $InstallPrefix 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModules -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'nodePackage' -Severity 'warn' -Code 'NODE_PACKAGE_MISSING' -Target $InstallPrefix `
            -Message 'no node_modules under the install prefix - the OTel Node package was never staged here' -Data @{ installPrefix = $InstallPrefix })
    } else {
        $pkgDir = Join-Path $nodeModules ($Package -replace '/', '\')
        if (Test-Path -LiteralPath $pkgDir -ErrorAction SilentlyContinue) {
            Add-F (New-Finding -Check 'nodePackage' -Severity 'pass' -Target $InstallPrefix -Message 'OTel Node package staged' `
                -Data @{ package = $Package; path = $pkgDir })
        } else {
            Add-F (New-Finding -Check 'nodePackage' -Severity 'warn' -Code 'NODE_PACKAGE_MISSING' -Target $InstallPrefix `
                -Message "node_modules exists but '$Package' is not in it" -Data @{ installPrefix = $InstallPrefix; expected = $pkgDir })
        }
    }

    $seenServiceNames = @()
    foreach ($app in $apps) {
        $label = $app.Name

        if ($app.Status -and $app.Status -ne 'online') {
            Add-F (New-Finding -Check 'node' -Severity 'info' -Target $label `
                -Message "app status is '$($app.Status)' - its env may not reflect the last instrument run" -Data @{ status = $app.Status })
        }

        $reg = Get-CxRegisterPathFromNodeOptions -NodeOptions $app.NodeOptions
        if (-not $app.NodeOptions -or -not $reg) {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'warn' -Code 'NODE_OPTIONS_MISSING' -Target $label `
                -Message "no NODE_OPTIONS=--require <register> on this app - it is NOT instrumented. A plain 'pm2 restart' without --update-env drops it." `
                -Data @{ nodeOptions = $app.NodeOptions })
        } elseif (-not (Test-Path -LiteralPath $reg -ErrorAction SilentlyContinue)) {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'warn' -Code 'NODE_REGISTER_PATH_STALE' -Target $label `
                -Message "NODE_OPTIONS points at a register bootstrap that no longer exists: $reg" -Data @{ register = $reg })
        } else {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'pass' -Target $label -Message "--require $reg" -Data @{ register = $reg })
        }

        if (-not $app.ServiceName) {
            Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_MISSING' -Target $label `
                -Message 'no OTEL_SERVICE_NAME on this app - its spans land under a default service name')
        } else {
            $seenServiceNames += $app.ServiceName
            Add-F (New-Finding -Check 'nodeService' -Severity 'pass' -Target $label -Message "OTEL_SERVICE_NAME=$($app.ServiceName)" `
                -Data @{ serviceName = $app.ServiceName })
        }

        if ($app.OtlpEndpoint -and $app.OtlpEndpoint -match 'localhost') {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'warn' -Code 'OTLP_ENDPOINT_LOCALHOST' -Target $label `
                -Message "endpoint uses 'localhost' ($($app.OtlpEndpoint)); that resolves to ::1 first and OTLP export is silently dropped. Use $ExpectedOtlpEndpoint." `
                -Data @{ endpoint = $app.OtlpEndpoint })
        }
    }

    # Set comparison, not string: app add/remove reorders the join and would
    # otherwise look like drift.
    $expected = @($seenServiceNames | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    $actual = @()
    if ($cxNodeServices) {
        $actual = @($cxNodeServices -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    }

    if ($expected.Count -eq 0) {
        # already reported per app
    } elseif ($actual.Count -eq 0) {
        Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_MISSING' -Target 'CX_NODE_SERVICES' `
            -Message "machine CX_NODE_SERVICES is not set, but $($expected.Count) PM2 app(s) carry a service name - host Service-ownership will be blank" `
            -Data @{ expected = $expected })
    } elseif (Compare-Object $expected $actual) {
        Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_DRIFT' -Target 'CX_NODE_SERVICES' `
            -Message "CX_NODE_SERVICES does not match the running apps. var=[$($actual -join ', ')] apps=[$($expected -join ', ')] - re-run Instrument-NodePM2.ps1" `
            -Data @{ cxNodeServices = $actual; appServiceNames = $expected })
    } else {
        Add-F (New-Finding -Check 'nodeService' -Severity 'pass' -Target 'CX_NODE_SERVICES' `
            -Message "matches the running apps: $($actual -join ', ')" -Data @{ cxNodeServices = $actual })
    }

    # Does anything actually CONSUME CX_NODE_SERVICES? Determined by looking, not
    # asserted from memory: if a Fleet config later adds a processor reading it,
    # this finding disappears on its own.
    if ($cxNodeServices -and $ConfigModel -and $ConfigModel.Ok) {
        $consumed = $false
        try {
            $txt = Read-CxSharedText -Path $ConfigModel.Path
            if ($txt) {
                # Ignore comment lines so a mention in a comment is not a match.
                $live = ($txt -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                if ($live -match 'CX_NODE_SERVICES') { $consumed = $true }
            }
        } catch { }
        if ($consumed) {
            Add-F (New-Finding -Check 'nodeOwnership' -Severity 'pass' -Message 'the collector config on this host consumes CX_NODE_SERVICES')
        } else {
            Add-F (New-Finding -Check 'nodeOwnership' -Severity 'info' -Code 'NODE_SERVICES_NOT_CONSUMED' `
                -Message 'CX_NODE_SERVICES is set, but the collector config on this host does not read ${env:CX_NODE_SERVICES} - unlike CX_IIS_SERVICES there is no transform consuming it, so Node host Service-ownership will stay blank. The env var is not the problem; the missing processor is.' `
                -Data @{ checked = $ConfigModel.Path })
        }
    }

    return , @($findings.ToArray())
}

# ===========================================================================
# SECTION 11 - main
# ===========================================================================

# Dot-sourcing sets $MyInvocation.InvocationName to '.', so everything below runs
# ONLY on direct execution. Same guard as the deploy\Test-*.ps1 validators: it
# lets the functions above be loaded and called individually, which is how the
# parser and metric matching get unit-tested without a collector present.
#     . .\Test-CxInstrumentation.ps1 ; ConvertTo-CxYamlRecords -Text $yaml
if ($MyInvocation.InvocationName -eq '.') { return }

$AllChecks = @('collector', 'config', 'receiverWiring', 'receiverFlow', 'endpoints', 'exporterFlow', 'iis', 'node')

# Normalise -Only: accept a comma-joined single string (what `powershell -File`
# delivers) as well as a real array.
$selected = $AllChecks
if ($Only) {
    $req = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $bad = @($req | Where-Object { $AllChecks -notcontains $_ })
    if ($bad.Count -gt 0) {
        Write-Host ''
        Write-Host ("ERROR: unknown check name(s): {0}" -f ($bad -join ', ')) -ForegroundColor Red
        Write-Host ("       valid: {0}" -f ($AllChecks -join ', ')) -ForegroundColor Red
        Write-Host  '       use the comma form with no spaces, e.g. -Only collector,receiverFlow' -ForegroundColor Red
        exit 1
    }
    $selected = $req
}
function Test-CxSelected { param([string] $Name) return ($selected -contains $Name) }

Write-Host ''
Write-Host "Coralogix instrumentation check on $env:COMPUTERNAME  ($(Get-Date -Format 's'))"
if ($Only) { Write-Host ("  checks: {0}" -f ($selected -join ', ')) -ForegroundColor DarkGray }
if ($SendTestSpan) {
    Write-Host '  -SendTestSpan: one synthetic span WILL be sent to the local collector and on to Coralogix.' -ForegroundColor Yellow
}

$all = New-Object System.Collections.ArrayList
function Add-All { param($f) foreach ($x in @($f)) { if ($x) { [void]$all.Add($x) } } }

# Which stages actually need to run. Prerequisites are computed silently for a
# selected dependent check, but only the SELECTED checks emit findings.
$needConfig    = @('config', 'receiverWiring', 'receiverFlow', 'endpoints', 'node') | Where-Object { Test-CxSelected $_ }
$needCollector = @('collector', 'receiverFlow', 'exporterFlow', 'endpoints')        | Where-Object { Test-CxSelected $_ }

$procs = @()
if (@($needCollector).Count -gt 0 -or (-not $CollectorConfig -and @($needConfig).Count -gt 0)) {
    $procs = Get-CxCollectorProcesses
}

$cfg = $null
if (@($needConfig).Count -gt 0) {
    $cfg = Get-CxCollectorConfig -Override $CollectorConfig -Processes $procs
    if (Test-CxSelected 'config') { Add-All (Test-CxConfig -Model $cfg) }
} elseif (Test-CxSelected 'config') {
    Add-All (New-Finding -Check 'config' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

$wiring = $null
if ((Test-CxSelected 'receiverWiring') -or (Test-CxSelected 'receiverFlow') -or (Test-CxSelected 'endpoints')) {
    if ($cfg -and $cfg.Ok) {
        $wiring = Test-CxReceiverWiring -Model $cfg -CollectorRunning ([bool](@($procs).Count -gt 0))
        if (Test-CxSelected 'receiverWiring') { Add-All $wiring.Findings }
    } elseif (Test-CxSelected 'receiverWiring') {
        Add-All (New-Finding -Check 'receiverWiring' -Severity 'unknown' -Code 'RECEIVER_CHECK_UNAVAILABLE' `
            -Message 'the collector config could not be parsed, so receiver wiring is unknown')
    }
}

$probeRes = $null
if (@($needCollector).Count -gt 0) {
    $probeRes = Test-CxCollector -Model $(if ($cfg) { $cfg } else { [pscustomobject]@{ Ok = $false } }) `
        -Processes $procs -MetricsUrlOverride $MetricsUrl -HealthUrl $HealthUrl `
        -OtlpHttpPort $OtlpHttpPort -OtlpGrpcPort $OtlpGrpcPort -TimeoutSec $TimeoutSec
    if (Test-CxSelected 'collector') { Add-All $probeRes.Findings }
    elseif (@($probeRes.Findings | Where-Object { $_.severity -eq 'fail' }).Count -gt 0) {
        # The collector being down invalidates the checks the caller DID select;
        # surface that reason even when 'collector' itself was not requested.
        Add-All @($probeRes.Findings | Where-Object { $_.severity -eq 'fail' })
    }
}

$flow = $null
if (Test-CxSelected 'receiverFlow') {
    if ($probeRes -and $wiring) {
        $flow = Test-CxReceiverFlow -Model $cfg -Probe $probeRes.Probe -Wired $wiring.Wired -Signals $wiring.Signals `
            -SampleSeconds $SampleSeconds -Fast:$Fast -TimeoutSec $TimeoutSec
        Add-All $flow.Findings
    } else {
        Add-All (New-Finding -Check 'receiverFlow' -Severity 'unknown' -Code 'RECEIVER_CHECK_UNAVAILABLE' `
            -Message 'the collector or its config could not be read, so per-receiver data flow is unknown')
    }
}

if (Test-CxSelected 'exporterFlow') {
    if ($flow -and $flow.Idx2) {
        Add-All (Test-CxExporterFlow -Flow $flow -Fast:$Fast)
    } elseif ($probeRes -and $probeRes.Probe.Reachable) {
        # exporterFlow without receiverFlow: one scrape, absolute-only.
        $one = [pscustomobject]@{
            Idx1 = (ConvertFrom-CxPromText -Text $probeRes.Probe.Body)
            Idx2 = (ConvertFrom-CxPromText -Text $probeRes.Probe.Body)
            AnyReceiverDelta = $false
        }
        Add-All (Test-CxExporterFlow -Flow $one -Fast:$true)
    } else {
        Add-All (New-Finding -Check 'exporterFlow' -Severity 'unknown' -Code 'EXPORTER_NO_COUNTERS' `
            -Message 'the collector internal telemetry endpoint could not be scraped, so export status is unknown')
    }
}

if (Test-CxSelected 'endpoints') {
    if ($ProbeEndpoints -and $cfg -and $cfg.Ok -and $wiring) {
        Add-All (Test-CxEndpoints -Model $cfg -Wired $wiring.Wired -TimeoutSec $TimeoutSec)
    } elseif (-not $ProbeEndpoints) {
        Add-All (New-Finding -Check 'endpoints' -Severity 'skip' -Code 'NOT_SELECTED' `
            -Message 'endpoint probing is opt-in - pass -ProbeEndpoints to reach out to what each receiver points at')
    } else {
        Add-All (New-Finding -Check 'endpoints' -Severity 'unknown' `
            -Message 'the collector config could not be parsed, so receiver endpoints are unknown')
    }
    if ($SendTestSpan -and $probeRes) {
        Add-All (Test-CxOtlpRoundTrip -Probe $probeRes.Probe -OtlpHttpPort $OtlpHttpPort -TimeoutSec $TimeoutSec)
    }
}

if (Test-CxSelected 'iis') {
    Add-All (Test-CxIis -ExpectedOtlpEndpoint $ExpectedOtlpEndpoint -AppHostConfig $AppHostConfig)
}

if (Test-CxSelected 'node') {
    Add-All (Test-CxNode -InstallPrefix $InstallPrefix -Package $Package `
        -ExpectedOtlpEndpoint $ExpectedOtlpEndpoint -ConfigModel $cfg)
}

foreach ($c in $AllChecks) {
    if (-not (Test-CxSelected $c)) {
        Add-All (New-Finding -Check $c -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
    }
}

$result = @($all.ToArray())
$code = Get-GradedExitCode -Findings $result

Write-FindingTable   -Findings $result -Title 'Coralogix instrumentation' -Quiet:$Quiet
Write-FindingSummary -Findings $result -Label 'CX-INSTRUMENTATION' -ExitCode $code

if (-not $NoFileOutput) {
    try {
        $jp = if ($JsonPath) { $JsonPath } else { Join-Path $script:CxHere 'cx-instrumentation.json' }
        $payload = [pscustomobject]@{
            host      = $env:COMPUTERNAME
            timestamp = (Get-Date -Format 's')
            exitCode  = $code
            checks    = $selected
            counts    = (Get-FindingCounts -Findings $result)
            findings  = $result
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jp -Encoding UTF8 -ErrorAction Stop
        Write-Host "  report: $jp" -ForegroundColor DarkGray
    } catch {
        Write-Host "  (could not write the JSON report: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

if ($PassThru) { $result }
exit $code
