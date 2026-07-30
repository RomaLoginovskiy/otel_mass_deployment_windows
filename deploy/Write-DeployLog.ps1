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
        $union = @(Get-CxServicesUnionValue `
            -Iis    ([Environment]::GetEnvironmentVariable('CX_IIS_SERVICES',    'Machine')) `
            -Node   ([Environment]::GetEnvironmentVariable('CX_NODE_SERVICES',   'Machine')) `
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
        Write-Host ("=== {0} RESULT: {1}  exit={2} ===" -f $Label, $verdict, $ExitCode) -ForegroundColor $color
    } catch { }
}
