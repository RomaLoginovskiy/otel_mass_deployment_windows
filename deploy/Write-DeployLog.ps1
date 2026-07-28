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

     Resolve-CxOtlpEndpoint - rewrite a `localhost` OTLP host to 127.0.0.1

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
