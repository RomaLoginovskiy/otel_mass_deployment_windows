<#
.SYNOPSIS
  Shared output helper for the Coralogix fleet deploy + diagnostic scripts.

.DESCRIPTION
  Dot-source this file to expose a small function library. It carries the
  DIAGNOSTIC FINDING model used by Test-Agent.ps1 and the standalone
  Test-*Instrumentation.ps1 validators:

     New-Finding          - build one finding record
     Write-FindingTable   - render findings to the console (BatchPatch-visible)
     Get-FindingCounts    - tally by severity
     Get-GradedExitCode   - map findings to the graded exit code 0 / 1 / 2

  ...plus one shared value normalizer used by the INSTRUMENTERS (Instrument-IIS.ps1,
  Instrument-NodePM2.ps1, scripts/deploy-app.ps1), which is here rather than in a
  fourth file because it is the only helper all three of them need:

     Resolve-CxOtlpEndpoint  - rewrite a `localhost` OTLP host to 127.0.0.1
     Update-CxServicesUnion  - republish machine CX_SERVICES from the per-runtime slices
     Restart-CxCollector     - restart the collector so it re-reads the machine environment

  Severity model (a finding carries exactly one):

     fail     something is broken and the agent cannot do its job  -> exit 1
     warn     the agent runs but is misconfigured                  -> exit 2
     pass     verified good                                        -> exit 0
     info     worth saying, never a verdict                        -> ignored
     skip     not applicable to this host (no IIS, no PM2, ...)    -> ignored
     unknown  could not determine - NOT the same as bad            -> ignored

  Only `fail` and `warn` move the exit code. `unknown` is deliberately inert:
  reporting "instrumentation missing" when we merely could not look would send
  an operator down the wrong path, which is the exact failure this tooling
  exists to prevent.

.NOTES
  Windows PowerShell 5.1.

  NON-NEGOTIABLE: no function in this file may throw, and none may write to the
  success stream. These are dot-sourced into scripts whose return value is
  meaningful (Detect-Workloads.ps1 returns $roles), and into a path that runs
  before the caller's try/catch. A stray pipeline object or an exception here
  would corrupt a caller or destroy its error handling.
#>

function Get-CxServicesUnionValue {
    <#
      The union itself, as a PURE function: three comma-joined slice values in, the ordered
      de-duplicated name array out. Separate from Update-CxServicesUnion so the rule can be tested
      without touching the machine environment - and because Test-Agent.ps1 asserts the same rule
      from the other side, so the two must not drift.

      Order is IIS, then Node, then .NET. De-duplication is case-INSENSITIVE and keeps the
      FIRST-SEEN spelling, so an IIS 'MyApp' and a Node 'myapp' collapse to one entry rather than
      claiming the same service twice under two spellings.
    #>
    [CmdletBinding()]
    param([string] $Iis, [string] $Node, [string] $DotNet)

    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $union = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Iis, $Node, $DotNet)) {
        if (-not $raw) { continue }
        foreach ($n in ($raw -split ',')) {
            $t = "$n".Trim()
            if ($t -and $seen.Add($t)) { [void]$union.Add($t) }
        }
    }
    # Plain return, NOT `,@(...)`: the comma-prefix form stops PowerShell unrolling a single-element
    # array, but it also turns an EMPTY array into a one-element array CONTAINING an empty array. A
    # caller doing @(...).Count then sees 1 on a host with nothing instrumented, takes the
    # "has services" branch, and reports "1 service(s) claimed" while writing an empty value. Every
    # caller wraps the result in @() anyway, which handles the single-element case correctly.
    return @($union.ToArray())
}

function Update-CxServicesUnion {
    <#
    .SYNOPSIS
      Republish the machine variable CX_SERVICES from the per-runtime slices. Returns the value
      written, or $null when there was nothing to claim.

    .DESCRIPTION
      CX_SERVICES is the ONLY one of these variables the collector reads for host Service
      ownership (transform/iis_service_labels in config.supervisor.yaml reads
      ${env:CX_SERVICES}, falling back to CX_IIS_SERVICES only for a host whose deploy predates
      it). CX_IIS_SERVICES / CX_NODE_SERVICES / CX_DOTNET_SERVICES are its INPUTS.

      This lives here, shared, because every writer of a slice has to republish the union or its
      work does not reach the host entity. Install-Agent.ps1 recomputes it at the end of a full
      install, which is why the gap only shows up when an instrumenter runs on its own: the slice
      gains a name, CX_SERVICES keeps the old value, and the new service has spans in APM while
      Infrastructure Explorer shows no ownership for it - with every variable looking correct.

      Ordering and de-duplication match what Test-Agent.ps1 asserts: IIS, then Node, then .NET,
      de-duplicated case-INSENSITIVELY keeping the first-seen spelling, so an IIS 'MyApp' and a
      Node 'myapp' collapse to one entry.

      The collector reads its environment at PROCESS START, so a changed value does nothing until
      it restarts - hence -RestartCollector. Never throws (see this file's NOTES).
    #>
    [CmdletBinding()]
    param(
        # Optional backup/manifest session, so an uninstall can put the prior value back.
        $Session,
        [switch] $RestartCollector,
        # Prefix for the one status line this writes, so it reads as coming from its caller.
        [string] $LogPrefix = '[agent]'
    )

    try {
        # CX_IISNODE_SERVICES is its own slice, and it has to be: iisnode names are written by
        # Instrument-IIS.ps1, but they are Node services, so they used to be folded into
        # CX_NODE_SERVICES - a variable a LATER instrumenter owns. MEASURED on cx-e2e-c1: with no
        # live PM2 apps, Instrument-NodePM2.ps1 took its clear-the-stale-value path, set
        # CX_NODE_SERVICES empty, and wiped both iisnode names; the two applications were
        # instrumented and reporting while the host claimed neither, every finding reading PASS.
        # One slice per writer is what makes that impossible: a writer may only clear its own.
        $nodeSlices = @(
            [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES',    'Machine')
            [Environment]::GetEnvironmentVariable('CX_IISNODE_SERVICES', 'Machine')
        ) | Where-Object { $_ }
        $union = @(Get-CxServicesUnionValue `
            -Iis    ([Environment]::GetEnvironmentVariable('CX_IIS_SERVICES',    'Machine')) `
            -Node   ($nodeSlices -join ',') `
            -DotNet ([Environment]::GetEnvironmentVariable('CX_DOTNET_SERVICES', 'Machine')))

        $prior = [Environment]::GetEnvironmentVariable('CX_SERVICES', 'Machine')
        if ($union.Count) {
            $value = ($union -join ',')
            if ($value -eq $prior) {
                Write-Host "$LogPrefix CX_SERVICES already current ($($union.Count) service(s))"
                if ($RestartCollector) { Restart-CxCollector -LogPrefix $LogPrefix | Out-Null }
                return $value
            }
            # Record BEFORE writing, so uninstall deletes a variable we created and restores one
            # that was already set.
            if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
                try { Record-EnvChange -Session $Session -Name 'CX_SERVICES' -PriorValue $prior } catch { }
            }
            [Environment]::SetEnvironmentVariable('CX_SERVICES', $value, 'Machine')
            $env:CX_SERVICES = $value
            Write-Host "$LogPrefix set machine CX_SERVICES=$value ($($union.Count) service(s) claimed for host ownership)" -ForegroundColor Green
            if ($RestartCollector) { Restart-CxCollector -LogPrefix $LogPrefix | Out-Null }
            return $value
        }
        elseif ($prior) {
            # Nothing instrumented, or everything was refused. Clear the stale value rather than
            # leaving the host claiming ownership of services that are gone.
            if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
                try { Record-EnvChange -Session $Session -Name 'CX_SERVICES' -PriorValue $prior } catch { }
            }
            [Environment]::SetEnvironmentVariable('CX_SERVICES', $null, 'Machine')
            $env:CX_SERVICES = $null
            Write-Host "$LogPrefix no instrumented services on this host; cleared stale CX_SERVICES"
            if ($RestartCollector) { Restart-CxCollector -LogPrefix $LogPrefix | Out-Null }
        }
        return $null
    } catch {
        Write-Warning "$LogPrefix could not republish CX_SERVICES: $($_.Exception.Message). Host Service ownership may be missing the services instrumented by this run."
        return $null
    }
}

function Restart-CxCollector {
    <#
      Restart the collector so it re-reads the MACHINE environment (it reads it at process start,
      so a changed CX_SERVICES / OTEL_RESOURCE_ATTRIBUTES does nothing until then).

      In supervisor mode there is no 'otelcol-contrib' service - the collector is a CHILD of
      'opampsupervisor', so restarting the supervisor is what relaunches it. Falls back to the
      collector service for local (non-supervisor) mode. Returns $true if something was restarted.
    #>
    [CmdletBinding()]
    param([string] $LogPrefix = '[agent]')

    try {
        $sup = Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue
        $col = Get-Service -Name 'otelcol-contrib' -ErrorAction SilentlyContinue
        if ($sup) {
            Write-Host "$LogPrefix restarting opampsupervisor so the collector re-reads the machine environment"
            Restart-Service -Name 'opampsupervisor' -Force -ErrorAction SilentlyContinue
            return $true
        } elseif ($col) {
            Write-Host "$LogPrefix restarting otelcol-contrib so it re-reads the machine environment"
            Restart-Service -Name 'otelcol-contrib' -Force -ErrorAction SilentlyContinue
            return $true
        }
        Write-Host "$LogPrefix no collector service found, so nothing was restarted - the new value applies when one starts"
        return $false
    } catch {
        Write-Warning "$LogPrefix could not restart the collector: $($_.Exception.Message). It keeps the OLD environment until it restarts, so the change has not taken effect yet."
        return $false
    }
}

function Resolve-CxOtlpEndpoint {
    <#
      Normalize an OTLP endpoint so its HOST is never `localhost`.

      The collector's OTLP receivers bind ${env:OTEL_LISTEN_INTERFACE:-127.0.0.1},
      i.e. IPv4 only. On a dual-stack Windows host `localhost` resolves to ::1
      first, nothing is listening there, and the export is dropped SILENTLY - the
      SDK reports no exporter error, so the app looks instrumented and no telemetry
      arrives. That is the single most expensive misconfiguration this tooling has
      had to diagnose, which is why it is normalized at the source instead of only
      being warned about downstream (Test-IISInstrumentation.ps1's
      OTLP_ENDPOINT_LOCALHOST).

      Returns the input unchanged when it is empty, when the host is not localhost,
      or when it will not parse as a URI. A malformed -OtlpEndpoint is the caller's
      to report; silently rewriting it here would hide the real problem.
    #>
    [CmdletBinding()]
    param([string] $Endpoint)

    if (-not $Endpoint) { return $Endpoint }

    try {
        if (([uri]$Endpoint).Host -ne 'localhost') { return $Endpoint }

        # Replace ONLY the host substring, keeping the caller's exact scheme, port
        # and path text. A [UriBuilder] round-trip would normalize the string and
        # append a trailing '/', which the doctor's literal endpoint comparison
        # (Test-IISInstrumentation.ps1) would then report as a mismatch.
        $i = $Endpoint.IndexOf('localhost', [System.StringComparison]::OrdinalIgnoreCase)
        if ($i -lt 0) { return $Endpoint }
        $fixed = $Endpoint.Remove($i, 'localhost'.Length).Insert($i, '127.0.0.1')
    } catch {
        return $Endpoint
    }

    Write-Warning "OTLP endpoint '$Endpoint' uses 'localhost', which resolves to ::1 first on a dual-stack host - the collector listens on IPv4 only and the export would be dropped silently. Using '$fixed' instead."
    return $fixed
}

# Severity ordering, worst first. Used for sorting and for the exit-code grade.
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
      Build one finding. `Code` is a stable SCREAMING_SNAKE token that operators
      and docs grep for (PROFILER_NOT_REGISTERED, CX_IIS_SERVICES_MISSING, ...);
      `Message` is the human sentence; `Data` carries the evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Check,
        [Parameter(Mandatory)][ValidateSet('pass','warn','fail','info','skip','unknown')]
        [string] $Severity,
        [string] $Code    = '',
        [string] $Message = '',
        [string] $Target  = '',      # the pool / app / service / path this is about
        $Data             = $null,
        # WHAT KIND OF EVIDENCE this finding rests on, which is not the same question as
        # whether it passed:
        #   config   the environment / registry / web.config says the right thing
        #   runtime  a running process was observed - a module scan, or telemetry seen
        #   none     neither applies (arguments, missing helpers, host-level facts)
        # A 'pass' backed only by 'config' means "correctly configured", NOT "data is
        # flowing", and the two were previously indistinguishable in the report. Node has
        # no in-process marker at all - its SDK loads no distinctive module - so for Node
        # 'config' is the best a host-side check can do, and saying so is the point.
        [ValidateSet('config','runtime','none')]
        [string] $Verified = 'none'
    )

    [pscustomobject]@{
        check    = $Check
        severity = $Severity
        code     = $Code
        target   = $Target
        message  = $Message
        data     = $Data
        verified = $Verified
    }
}

function Get-CxDotNetCoreVersionFromDeps {
    <#
      D-5: the .NET (Core) version an app targets, from its own metadata.

      The reference agent reads `*.deps.json` for exactly this - `DotNetVersionDetector::getDepsJsonPathByExtension`
      with `runtimeTarget` / `Microsoft.NETCore.App` (reference-agent study doc 11 s2.6). We currently look only for a
      `runtimeconfig.json` NEXT TO the exe, which a SINGLE-FILE publish does not have: those bundle their
      metadata into the executable, so the check misses them entirely (matrix row D8).

      Order: runtimeconfig.json (authoritative, has the exact framework version) -> deps.json
      (runtimeTarget name carries the TFM) -> $null. Regex rather than ConvertFrom-Json throughout: a
      deps.json is large, deeply nested, and can carry case-colliding keys which throw in PS 5.1 (the same
      trap as pm2 jlist).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $AppDir, [string] $AssemblyName)

    if (-not (Test-Path -LiteralPath $AppDir -ErrorAction SilentlyContinue)) { return $null }
    $mk = { param($ver, $src, $tfm) [pscustomobject]@{ Version = $ver; Source = $src; Tfm = $tfm } }

    $rc = @()
    if ($AssemblyName) { $rc += (Join-Path $AppDir "$AssemblyName.runtimeconfig.json") }
    try { $rc += @(Get-ChildItem -LiteralPath $AppDir -Filter '*.runtimeconfig.json' -File -ErrorAction Stop | ForEach-Object { $_.FullName }) } catch { }
    foreach ($f in @($rc | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) } | Select-Object -Unique)) {
        try {
            $txt = Get-Content -LiteralPath $f -Raw -ErrorAction Stop
            $tfm = if ($txt -match '"tfm"\s*:\s*"([^"]+)"') { $matches[1] } else { $null }
            if ($txt -match '"framework"\s*:\s*\{[^}]*?"version"\s*:\s*"(\d+)\.(\d+)\.(\d+)') {
                return & $mk ([version]"$($matches[1]).$($matches[2]).$($matches[3])") 'runtimeconfig.json' $tfm
            }
            if ($tfm -and $tfm -match '^net(\d+)\.(\d+)$') {
                return & $mk ([version]"$($matches[1]).$($matches[2]).0") 'runtimeconfig.json(tfm)' $tfm
            }
        } catch { }
    }

    foreach ($f in @(try { Get-ChildItem -LiteralPath $AppDir -Filter '*.deps.json' -File -ErrorAction Stop | ForEach-Object { $_.FullName } } catch { @() })) {
        try {
            $txt = Get-Content -LiteralPath $f -Raw -ErrorAction Stop
            if ($txt -match '"runtimeTarget"\s*:\s*\{[^}]*?"name"\s*:\s*"[^",]*?,Version=v(\d+)\.(\d+)') {
                return & $mk ([version]"$($matches[1]).$($matches[2]).0") 'deps.json(runtimeTarget)' "net$($matches[1]).$($matches[2])"
            }
            if ($txt -match '"Microsoft\.NETCore\.App[^"]*?/(\d+)\.(\d+)\.(\d+)') {
                return & $mk ([version]"$($matches[1]).$($matches[2]).$($matches[3])") 'deps.json(Microsoft.NETCore.App)' $null
            }
        } catch { }
    }
    return $null
}

function Get-CxFrameworkVersionFromRegistry {
    <#
      D-5: the installed .NET Framework 4.x version, from the NDP Release DWORD.

      The reference agent reads the same key (reference-agent study doc 10 s1.2). We need it because the CLR2 and 4.6.2 gates
      are currently decided by SHAPE (a v2.0 pool) rather than by version, so a host with only 4.5
      installed looks instrumentable and is not - the OTel .NET auto-instrumentation needs 4.6.2+.

      Release->version mapping per Microsoft's published table; the highest boundary at or below the value
      wins, so a future Release number reports the newest known version rather than nothing.
    #>
    [CmdletBinding()] param()
    $rel = $null
    try {
        $rel = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release
    } catch { return $null }
    if (-not $rel) { return $null }
    $map = @(
        @{ R = 533320; V = '4.8.1' }, @{ R = 528040; V = '4.8'   }, @{ R = 461808; V = '4.7.2' }
        @{ R = 461308; V = '4.7.1' }, @{ R = 460798; V = '4.7'   }, @{ R = 394802; V = '4.6.2' }
        @{ R = 394254; V = '4.6.1' }, @{ R = 393295; V = '4.6'   }, @{ R = 379893; V = '4.5.2' }
        @{ R = 378675; V = '4.5.1' }, @{ R = 378389; V = '4.5'   }
    )
    foreach ($m in $map) {
        if ([int]$rel -ge $m.R) {
            return [pscustomobject]@{ Release = [int]$rel; Version = [version]$m.V
                                      MeetsOtelMinimum = ([version]$m.V -ge [version]'4.6.2') }
        }
    }
    return [pscustomobject]@{ Release = [int]$rel; Version = $null; MeetsOtelMinimum = $false }
}

function Get-CxServiceAppIdentity {
    <#
      D-5: name a `dotnet.exe app.dll` service after the APP, not the host process.

      The reference agent needs its whole inproc store for this - dotnet.exe is a launcher whose command line is not
      the application's identity (reference-agent study doc 11 s2.5). We can read the command line directly, so the
      only thing needed is to prefer the managed dll over the exe.

      Returns the assembly name (no extension) and its directory, or $null when the command line does not
      name a dll - in which case the caller keeps using the service name, which is what it does today.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CommandLine)
    $m = [regex]::Match($CommandLine, '(?i)"?([A-Za-z]:\\[^"]*?\.dll)"?')
    if (-not $m.Success) { return $null }
    $dll = $m.Groups[1].Value
    return [pscustomobject]@{
        AssemblyName = [System.IO.Path]::GetFileNameWithoutExtension($dll)
        AppDir       = [System.IO.Path]::GetDirectoryName($dll)
        Dll          = $dll
    }
}

function Test-CxRuleMatch {
    <#
      X-2/X-3: one matcher for both the exclusion rules and the name/runtime overrides, because they are
      the same question - "does this rule apply to this target?" - and having two would let them drift.

      Modelled on the reference agent's decision layer, which is a rule engine rather than a flag:
      INJECTION_RULE_TYPE_{INCLUDE,EXCLUDE} x 10 INJECTION_RULE_MATCH_TYPE_* operators, evaluated per
      agent type and per process group (reference-agent study doc 12 s2.4). Ours needs the operators, not the
      distributed-config machinery.

      A rule is { field, op, value } where field is any property of the target object (site, pool,
      appPath, exePath, cmdline, serviceName, name, env:NAME) and op is one of:
        equals notEquals starts notStarts ends notEnds contains notContains all
      Comparison is case-insensitive: Windows paths and IIS names are.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] $Target
    )
    $op = [string]$Rule.op; if (-not $op) { $op = 'equals' }
    if ($op -eq 'all') { return $true }

    $field = [string]$Rule.field
    $actual = $null
    if ($field -like 'env:*') {
        $n = $field.Substring(4)
        if ($Target.PSObject.Properties['Env'] -and $Target.Env) {
            try { $actual = [string]$Target.Env[$n] } catch { }
        }
    } elseif ($field -and $Target.PSObject.Properties[$field]) {
        $actual = [string]$Target.$field
    }
    if ($null -eq $actual) { $actual = '' }
    $want = [string]$Rule.value

    switch ($op) {
        'equals'      { return ($actual -ieq $want) }
        'notEquals'   { return -not ($actual -ieq $want) }
        'starts'      { return $actual.ToLowerInvariant().StartsWith($want.ToLowerInvariant()) }
        'notStarts'   { return -not $actual.ToLowerInvariant().StartsWith($want.ToLowerInvariant()) }
        'ends'        { return $actual.ToLowerInvariant().EndsWith($want.ToLowerInvariant()) }
        'notEnds'     { return -not $actual.ToLowerInvariant().EndsWith($want.ToLowerInvariant()) }
        'contains'    { return $actual.ToLowerInvariant().Contains($want.ToLowerInvariant()) }
        'notContains' { return -not $actual.ToLowerInvariant().Contains($want.ToLowerInvariant()) }
        default {
            Write-Warning "[rules] unknown match operator '$op' - the rule is treated as NOT matching. Valid: equals notEquals starts notStarts ends notEnds contains notContains all"
            return $false
        }
    }
}

function Resolve-CxInstrumentDecision {
    <#
      X-3: should this target be instrumented, and under what name/runtime?

      Ordered rules, FIRST MATCH WINS, so an operator can write a broad exclude and then a narrow
      include above it. Each rule is:
        { type = 'exclude'|'include'|'set', field, op, value, serviceName, runtime, reason }

      'set' does not decide inclusion - it only supplies a serviceName and/or runtime (X-2, replacing the
      exact-key override hashtables whose two key spaces differ by one character for root apps and which
      had to be passed identically to the installer AND the doctor).

      Returns Instrument (bool), ServiceName, Runtime, MatchedRule, Reason. Default when nothing matches
      is Instrument=$true - the deployment's job is to instrument, and an empty rule set must behave
      exactly as today.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        $Rules = @(),
        [switch] $HostDisabled
    )
    $out = [pscustomobject]@{ Instrument = $true; ServiceName = $null; Runtime = $null
                              MatchedRule = $null; Reason = 'no rule matched; default is to instrument'
                              SetReason = $null }
    if ($HostDisabled) {
        $out.Instrument = $false
        $out.Reason = 'auto-injection is disabled for this whole host (the AutoInjectionDisabled equivalent), so nothing is instrumented regardless of rules'
        return $out
    }
    foreach ($r in @($Rules | Where-Object { $_ })) {
        if (-not (Test-CxRuleMatch -Rule $r -Target $Target)) { continue }
        $type = [string]$r.type; if (-not $type) { $type = 'exclude' }
        if ($type -eq 'set') {
            # Keep scanning: a 'set' supplies metadata, it does not settle inclusion. Its reason is still
            # recorded, because the caller prints it next to the rename - reporting the default
            # "no rule matched" there was actively misleading about why the name changed.
            if ($r.serviceName) { $out.ServiceName = [string]$r.serviceName }
            if ($r.runtime)     { $out.Runtime     = [string]$r.runtime }
            $out.SetReason = if ($r.reason) { [string]$r.reason } else { "rule {type=set; field=$($r.field); value=$($r.value)} matched" }
            continue
        }
        $out.Instrument  = ($type -eq 'include')
        $out.MatchedRule = $r
        $out.Reason      = if ($r.reason) { [string]$r.reason }
                           else { "rule {type=$type; field=$($r.field); op=$($r.op); value=$($r.value)} matched" }
        return $out
    }
    return $out
}

function Get-CxInstrumentRules {
    <#
      Load the rule list from JSON. Shape: { "hostDisabled": false, "rules": [ ... ] }

      Kept in a file rather than in parameters because the reference agent keeps the equivalent in configuration
      (a [blocklist] section in its process-agent config, plus a host-wide AutoInjectionDisabled
      switch) and because a rule set has
      to survive between the installer run and the doctor run without being retyped - which is the whole
      complaint about the current -ServiceNameOverrides / -RuntimeOverrides pair.
    #>
    [CmdletBinding()]
    param([string] $Path)
    if (-not $Path) {
        $here = if ($PSScriptRoot) { $PSScriptRoot } else { '.' }
        $Path = Join-Path $here 'cx-instrument-rules.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ HostDisabled = $false; Rules = @(); Source = $null }
    }
    try {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return [pscustomobject]@{ HostDisabled = [bool]$j.hostDisabled; Rules = @($j.rules); Source = $Path }
    } catch {
        # A malformed rule file must not silently mean "no rules" - that would instrument targets the
        # operator believed were excluded.
        throw "the instrumentation rule file '$Path' could not be parsed ($($_.Exception.Message)). Refusing to continue with an unknown rule set: fix the file, or move it aside to run with no rules."
    }
}

function Write-CxInstrumentationState {
    <#
      X-1: the installer's decisions, on disk, so the doctor can compare against what was DECIDED instead
      of re-deriving expectations from flags it must be handed identically.

      Today Instrument-IIS.ps1 tells the operator to pass the same -RuntimeOverrides to Test-Agent.ps1
      "or ... drift is reported forever". That is a design smell: the reference agent recomputes identity in-process
      and reconciles it against the host agent's value rather than asking anybody to repeat themselves.

      One file per host, overwritten each run, holding what was decided and why.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Records,
        [string] $Path = (Join-Path $env:ProgramData 'cx\instrumentation-state.json'),
        [string] $InstallerVersion = ''
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc = [pscustomobject]@{
        whenUtc          = ([datetime]::UtcNow.ToString('o'))
        host             = $env:COMPUTERNAME
        installerVersion = $InstallerVersion
        targets          = @($Records)
    }
    $doc | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $Path -Encoding utf8
    return $Path
}

function Get-CxInstrumentationState {
    [CmdletBinding()]
    param([string] $Path = (Join-Path $env:ProgramData 'cx\instrumentation-state.json'))
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { Write-Warning "[state] unreadable ($Path): $($_.Exception.Message)"; return $null }
}

function Compare-CxInstrumentationState {
    <#
      X-1: live state vs the recorded decision. Returns one row per disagreement.

      Drift is reported as a DIFFERENCE, never resolved: whichever side is wrong, silently preferring one
      is how a wrong answer becomes invisible.
    #>
    [CmdletBinding()]
    param(
        # NOT Mandatory, deliberately. Get-CxInstrumentationState returns $null when no state file exists,
        # which is the normal condition on every host until an installer has written one - and a doctor
        # that threw on that would crash exactly where it is most needed. No record means no expectations,
        # so no drift can be computed: return nothing and let the caller say so.
        $Expected,
        $Live = @()                           # array of { Target; ServiceName; Runtime }
    )
    if (-not $Expected -or -not $Expected.targets) { return @() }
    $liveByTarget = @{}
    foreach ($l in @($Live)) { if ($l.Target) { $liveByTarget[[string]$l.Target] = $l } }

    $drift = @()
    foreach ($e in @($Expected.targets)) {
        $t = [string]$e.target
        if (-not $liveByTarget.ContainsKey($t)) {
            $drift += [pscustomobject]@{ Target = $t; Field = 'presence'; Expected = 'instrumented'; Actual = 'not found'
                                         Reason = "the last install recorded this target, and it is not present now (renamed, removed, or a different site layout)" }
            continue
        }
        $l = $liveByTarget[$t]
        foreach ($f in @('ServiceName','Runtime')) {
            $exp = [string]$e.$($f.Substring(0,1).ToLowerInvariant() + $f.Substring(1))
            $act = [string]$l.$f
            if ($exp -and $act -and ($exp -ine $act)) {
                $drift += [pscustomobject]@{ Target = $t; Field = $f; Expected = $exp; Actual = $act
                                             Reason = "the install decided $f='$exp' for this target; the host now reports '$act'" }
            }
        }
    }
    return @($drift)
}

function Get-CxTelemetryPolicyVars {
    <#
      X-6: the sampler and per-instrumentation switches, as an explicit decision rather than by omission.

      Today we set neither, so every instrumented app runs `parentbased_always_on` with every bundled
      instrumentation enabled - not because that was chosen, but because nothing was written. The reference agent
      ships the opposite: a per-sensor enabled/capture gate and adaptive sampling on by default
      (reference-agent study doc 12 s4), and several of its noisiest sensors ship OFF.

      This returns the variables to write. Defaults keep today's behaviour (full sampling) so nothing
      changes silently for existing hosts - the value of the function is that the choice is now visible
      and overridable per deploy, and that a customer surprised by span volume has one knob.

        -SampleRatio 1.0   -> parentbased_always_on (the default; identical to writing nothing)
        -SampleRatio 0.25  -> parentbased_traceidratio with the ratio, which is the knob asked for first
        -DisableInstrumentations @('SqlClient','StackExchangeRedis')
                           -> per-library opt-out, spelled for whichever runtime is being written
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0.0, 1.0)][double] $SampleRatio = 1.0,
        [string[]] $DisableInstrumentations = @(),
        [ValidateSet('dotnet','node')][string] $Runtime = 'dotnet'
    )
    $v = [ordered]@{}
    if ($SampleRatio -ge 1.0) {
        $v['OTEL_TRACES_SAMPLER'] = 'parentbased_always_on'
    } else {
        $v['OTEL_TRACES_SAMPLER']     = 'parentbased_traceidratio'
        # Invariant culture: on a de-DE host "0.25" would otherwise be written as "0,25", which the SDK
        # cannot parse and which silently falls back to always_on - a sampling change that looks applied
        # and is not.
        $v['OTEL_TRACES_SAMPLER_ARG'] = $SampleRatio.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    $off = @($DisableInstrumentations | Where-Object { $_ })
    if (@($off).Count -gt 0) {
        if ($Runtime -eq 'dotnet') {
            # The .NET auto-instrumentation takes an explicit DISABLED list per signal.
            $v['OTEL_DOTNET_AUTO_TRACES_INSTRUMENTATION_DISABLED']  = ($off -join ',')
            $v['OTEL_DOTNET_AUTO_METRICS_INSTRUMENTATION_DISABLED'] = ($off -join ',')
        } else {
            # Node takes the inverse - a list of what to ENABLE - so a disable list cannot be expressed
            # directly. Refusing is better than writing a variable that does nothing.
            Write-Warning "[policy] Node instrumentation opt-out is expressed as OTEL_NODE_ENABLED_INSTRUMENTATIONS (an allow-list), so a disable list cannot be translated. Ignoring: $($off -join ', '). Pass the allow-list explicitly if you need this."
        }
    }
    return $v
}

function Get-CxClrFlavorFromModules {
    <#
      D-2: FullCLR or CoreCLR, decided from the modules a RUNNING process has mapped.

      The reference agent classifies this way rather than by parsing configuration, and reads the target's loaded
      modules from outside the process (reference-agent study doc 11 s2.6). Its measured table is
      \MSCOREE.DLL, \MSCORLIB.DLL, \MSCORWKS.DLL, \CLR.DLL, \CORECLR.DLL - plus \MSCORLIB.NI.DLL, the
      NGEN image, which docs 04/10 do not mention.

      Why this exists when we already parse web.config: the static parse cannot answer for an app whose
      configuration is ambiguous, and `Unknown` currently forces the operator to supply
      -RuntimeOverrides. A running process is authoritative - it has already loaded whichever CLR it
      loaded. Returns 'core' | 'framework' | $null (no CLR mapped, so no answer, which is NOT 'neither').
    #>
    [CmdletBinding()]
    param([string[]] $Modules)
    $m = @($Modules | Where-Object { $_ })
    if (@($m).Count -eq 0) { return $null }
    # CoreCLR first: a mixed process (an out-of-process ASP.NET Core child of a Framework w3wp) is
    # CoreCLR for our purposes, because that is the runtime the app code runs on.
    if ($m -contains 'coreclr.dll') { return 'core' }
    foreach ($fw in @('clr.dll','mscorwks.dll','mscoree.dll')) { if ($m -contains $fw) { return 'framework' } }
    # mscorlib without one of the above still means the desktop CLR is up.
    if (($m -contains 'mscorlib.dll') -or ($m -contains 'mscorlib.ni.dll')) { return 'framework' }
    return $null
}

function Get-CxForeignApmVendors {
    <#
      The signature table for OTHER APM agents, loaded from `cx-foreign-apm.json` next to this script.

      The list lives in DATA, not here, for three reasons: the vendor set changes on a different clock
      than the logic that uses it, an operator may need to add a vendor we have never seen, and the
      implementation stays free of product names. Every consumer - the pre-flight probe below and the
      doctor's in-process module scan - reads this one table, so the two cannot drift apart.

      A missing or unreadable file is reported, never silently treated as "no foreign agent": that would
      turn the whole guard off and every caller would read the empty result as an all-clear.
    #>
    [CmdletBinding()]
    param([string] $Path)

    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'cx-foreign-apm.json' }
    if ($script:CxForeignApmVendors -and $script:CxForeignApmVendorsPath -eq $Path) {
        return $script:CxForeignApmVendors
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Foreign-APM signature file not found at $Path - cannot check whether another APM agent already owns this host. Restore the file from the deployment package; do NOT read this as 'no other agent present'."
        return @()
    }

    $rows = @()
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($v in @($json.vendors)) {
            if (-not $v.name) { continue }
            $rows += [pscustomobject]@{
                Name    = [string] $v.name
                Path    = [string] $v.pathPattern
                Module  = [string] $v.modulePattern
                Svc     = [string] $v.servicePattern
                Dir     = if ($v.installDir) { [string] $v.installDir } else { $null }
            }
        }
    } catch {
        Write-Warning "Foreign-APM signature file $Path could not be parsed ($($_.Exception.Message)) - the foreign-agent check is NOT running. Fix the file; an empty result here is not an all-clear."
        return @()
    }

    $script:CxForeignApmVendors     = @($rows)
    $script:CxForeignApmVendorsPath = $Path
    return @($rows)
}

function Get-CxForeignApmModulePattern {
    <#
      One regex matching any listed vendor's in-process module name, for the doctor's module scan.
      Built from the same table as the pre-flight probe so a vendor added to the file is picked up by
      both without touching code.
    #>
    [CmdletBinding()]
    param([string] $Path)

    $pats = @(Get-CxForeignApmVendors -Path $Path | ForEach-Object { $_.Module } | Where-Object { $_ })
    if (@($pats).Count -eq 0) { return $null }
    return ($pats -join '|')
}

function Get-CxForeignApmVendorForModule {
    <#
      Reverse lookup: which vendor does this loaded module name belong to? Returns the vendor label, or
      $null when the module matched the combined pattern but no single row claims it (worth reporting as
      unattributed rather than guessing).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Module, [string] $Path)

    foreach ($v in @(Get-CxForeignApmVendors -Path $Path)) {
        if ($v.Module -and $Module -match $v.Module) { return $v.Name }
        if ($v.Path   -and $Module -match $v.Path)   { return $v.Name }
    }
    return $null
}

function Get-CxForeignApmSignature {
    <#
      D-4: is another APM agent established on this host, and which one?

      This has to be decided BEFORE we inject anything. We used to discover it only afterwards, from a
      module scan in the doctor, by which point the install had already claimed service names that would
      never report - only one ICorProfilerCallback can attach per .NET process, so if another agent holds
      that slot our profiler attaches to nothing.

      Two independent signals, because either alone has blind spots: a profiler DLL path/CLSID already
      registered in the machine or service environment, and a vendor agent's files/services present on
      disk. Returns one row per vendor found, with which signal found it.

      Node counts too: several third-party Node agents hook the same http module we do, and our Node path
      considered no foreign agent at all before this.
    #>
    [CmdletBinding()]
    param([string[]] $ExtraProfilerValues = @(), [string] $VendorFile)

    $vendors = @(Get-CxForeignApmVendors -Path $VendorFile)

    # Signal 1: profiler variables already set at machine scope, or handed in by the caller (e.g. the
    # W3SVC service Environment, which the IIS path reads anyway).
    $profilerValues = @($ExtraProfilerValues | Where-Object { $_ })
    foreach ($n in @('COR_PROFILER_PATH','COR_PROFILER_PATH_64','COR_PROFILER_PATH_32',
                     'CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_32')) {
        try { $v = [Environment]::GetEnvironmentVariable($n, 'Machine'); if ($v) { $profilerValues += $v } } catch { }
    }
    $joined = ($profilerValues -join ';')

    # Signal 2: services and install directories.
    $svcNames = @()
    try { $svcNames = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + ' ' + $_.DisplayName }) } catch { }

    $found = @()
    foreach ($v in $vendors) {
        $why = @()
        # An empty pattern must never be used: `-match ''` matches everything, which would report every
        # vendor in the file on every host.
        if ($v.Path -and $joined -and $joined -match $v.Path) { $why += 'a registered CLR profiler path' }
        if ($v.Svc -and @($svcNames | Where-Object { $_ -match $v.Svc }).Count -gt 0) { $why += 'an installed Windows service' }
        if ($v.Dir -and (Test-Path -LiteralPath $v.Dir -ErrorAction SilentlyContinue)) { $why += "files at $($v.Dir)" }
        if (@($why).Count -gt 0) {
            $found += [pscustomobject]@{ Vendor = $v.Name; Signals = @($why); Reason = "$($v.Name) detected by $($why -join ' and ')" }
        }
    }
    return @($found)
}

function Test-CxEndpointOverwriteAllowed {
    <#
      May we write our OTLP endpoint over the one this target already carries?

      A target already exporting to an endpoint that is NOT ours means another OpenTelemetry deployment
      owns that application - a customer's own SDK wiring, a second agent, a sidecar. Overwriting it
      silently redirects their telemetry to our collector, and that is the kind of change that gets
      noticed somewhere else entirely, by someone who cannot see this host. So it needs consent.

      This is the reference agent's DIFFERENT_TENANT gate, adapted: it refuses to inject where another tenant's
      agent is already established rather than fighting it.

      The rule:
        no existing value                  -> allowed (nothing to overwrite)
        existing is equivalent to ours     -> allowed (idempotent re-run; localhost/127.0.0.1 and a
                                              trailing slash are treated as the same endpoint)
        existing points at LOOPBACK        -> allowed, reported. A different port on this host is
                                              still a collector on this host - almost always an
                                              earlier install of ours - and refusing would block
                                              every legitimate re-deploy that changed the port.
        existing points ELSEWHERE          -> REFUSED unless -Force. A remote host is someone else's
                                              pipeline.

      Returns Allowed / Foreign / Reason so a caller can report the same facts it acts on.
    #>
    [CmdletBinding()]
    param(
        [string] $Existing,
        [string] $Ours,
        [switch] $Force
    )

    $mk = { param($allowed, $foreign, $reason)
            [pscustomobject]@{ Allowed = $allowed; Foreign = $foreign; Reason = $reason; Existing = $Existing; Ours = $Ours } }

    if ([string]::IsNullOrWhiteSpace($Existing)) { return & $mk $true $false 'no existing endpoint' }

    # Normalise for comparison only: a trailing slash and the localhost/127.0.0.1 spelling are the same
    # endpoint, and treating them as different would make every re-run look like a hijack.
    $norm = {
        param($u)
        $s = ([string]$u).Trim().TrimEnd('/')
        $s = $s -replace '(?i)^http://localhost([:/]|$)', 'http://127.0.0.1$1'
        $s = $s -replace '(?i)^http://\[::1\]([:/]|$)',   'http://127.0.0.1$1'
        return $s.ToLowerInvariant()
    }
    if ((& $norm $Existing) -eq (& $norm $Ours)) { return & $mk $true $false 'existing endpoint is already ours' }

    $hostPart = $null
    try { $hostPart = ([uri](& $norm $Existing)).Host } catch { }
    $isLoopback = $hostPart -and ($hostPart -in @('127.0.0.1','localhost','::1','[::1]'))
    if ($isLoopback) {
        return & $mk $true $false "existing endpoint '$Existing' is on this host (a collector of ours on a different port); it will be updated to '$Ours'"
    }

    if ($Force) {
        return & $mk $true $true "existing endpoint '$Existing' is NOT ours and points off-box, but -Force was given - OVERWRITING another deployment's endpoint"
    }
    return & $mk $false $true "existing endpoint '$Existing' points off-box and is not our collector, so another OpenTelemetry deployment owns this application. Overwriting it would silently redirect their telemetry to us. Nothing was written. Re-run with -Force if this host really should export to '$Ours' instead."
}

function Get-FindingCounts {
    <#
      Tally findings by severity. Always returns every key, so a caller can index
      .fail / .warn without a null check even when nothing was found.
    #>
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
      The graded rule, in one place so a standalone validator and the aggregating
      doctor cannot drift:

          1  any fail
          2  no fail, at least one warn
          0  otherwise

      info / skip / unknown never move the code.
    #>
    [CmdletBinding()]
    param([object[]] $Findings)

    $c = Get-FindingCounts -Findings $Findings
    if ($c.fail -gt 0) { return 1 }
    if ($c.warn -gt 0) { return 2 }
    return 0
}

function Write-FindingTable {
    <#
      Render findings to the console. This is the surface BatchPatch harvests, so
      it must be readable on its own with no JSON alongside it.

      -Quiet drops `pass` and `skip` rows (keeps fail/warn/unknown/info).
      -Title prints a section header first.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Findings,
        [string]   $Title,
        [switch]   $Quiet
    )

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
        # A rendering bug must never take down the caller. Fall back to raw output.
        try {
            Write-Host "  [WARN   ] finding-table render failed: $($_.Exception.Message)"
            foreach ($f in @($Findings)) {
                if ($f) { Write-Host ("  {0} {1} {2} {3}" -f $f.severity, $f.check, $f.code, $f.message) }
            }
        } catch { }
    }
}

function Write-FindingSummary {
    <#
      The terminator line. `Label` names the run (DOCTOR / IIS-INSTRUMENTATION /
      NODE-INSTRUMENTATION) so a combined transcript stays readable.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Findings,
        [string]   $Label = 'RESULT',
        [int]      $ExitCode = -1
    )

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

        # CONFIGURED IS NOT FLOWING. A pass whose only evidence is the environment means the host is
        # set up correctly; it does not mean telemetry arrives. Those two were indistinguishable in
        # this line, and the difference is exactly what the profiler-load check exists to expose:
        # registration is not attachment. Node has no in-process marker at all, so 'config' is the
        # ceiling there and the count says so rather than implying more.
        $runtimeVerified = @(@($Findings) | Where-Object { $_ -and $_.verified -eq 'runtime' })
        $configVerified  = @(@($Findings) | Where-Object { $_ -and $_.verified -eq 'config' })
        if (@($runtimeVerified).Count -gt 0 -or @($configVerified).Count -gt 0) {
            Write-Host ("  evidence: {0} runtime-verified (a running process was observed), {1} config-verified (environment only)" -f `
                @($runtimeVerified).Count, @($configVerified).Count)
            if (@($runtimeVerified).Count -eq 0) {
                Write-Host '  NOTE: nothing was runtime-verified - every check above rests on configuration alone. Confirm with a Coralogix query before calling this host healthy.' -ForegroundColor Yellow
            }
        }
        Write-Host ("=== {0} RESULT: {1}  exit={2} ===" -f $Label, $verdict, $ExitCode) -ForegroundColor $color
    } catch { }
}
