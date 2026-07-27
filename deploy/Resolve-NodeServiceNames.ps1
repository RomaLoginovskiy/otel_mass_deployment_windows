<#
.SYNOPSIS
  Enumerate the Node.js apps PM2 manages on the local host and resolve a distinct
  OpenTelemetry service name for each. The Node/PM2 analog of Resolve-IISServiceNames.ps1.

.DESCRIPTION
  Dot-source this file to expose the helpers used by the Node/PM2 instrumentation and
  uninstall scripts:

    Get-PM2ServiceMap        - pure enumeration + naming (no side effects). One record per
                               PM2-managed app.
    Get-NodeServiceLabelValue - comma-joined distinct service names for CX_NODE_SERVICES.
    Remove-NodeInstrumentation - uninstall inverse: clear NODE_OPTIONS/OTEL_* off each app.

  Naming convention:
    * OTEL_SERVICE_NAME = the PM2 app name (the .name field in `pm2 jlist`).
      In CLUSTER mode PM2 runs N workers under ONE app name / one PID each; they all share
      this single name so they roll up as one service in Coralogix, while the OTel process
      resource detector still separates the workers by process.pid. This matches the design
      intent: identical service name across workers, per-worker telemetry underneath.

  Overrides: a hashtable keyed by the auto-derived service name (the PM2 app name) whose value
  is the desired replacement name. Applied after auto-naming, mirroring Resolve-IISServiceNames.

.NOTES
  Requires the PM2 CLI on PATH (`pm2`). Run in the SAME user context that owns the PM2 daemon
  (PM2 is per-user on Windows). Windows PowerShell 5.1 compatible.
#>

function Get-PM2ProcessList {
    <#
      Internal: return one object per PM2 process as [pscustomobject]@{ Name; Pid; ExecMode; Status },
      or @() on any failure / no daemon. Cluster workers repeat the same Name.

      IMPORTANT: `pm2 jlist` emits JSON with DUPLICATE keys, and Windows PowerShell 5.1's
      ConvertFrom-Json throws `DuplicateKeysInJsonString` on it - so we do NOT use ConvertFrom-Json.
      Instead we split the array into per-process chunks (each top-level object starts with
      `{"pid":`) and pull the fields we need by regex. The top-level "name" is the one immediately
      after the pid, which is exactly the app name we want.
    #>
    [CmdletBinding()]
    param()
    # Force Continue locally: callers (Instrument-NodePM2.ps1) run under $ErrorActionPreference=Stop,
    # where redirecting pm2's stderr (`2>$null`) turns its chatter into a terminating
    # NativeCommandError in Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) { return @() }
    $raw = ''
    try { $raw = (& pm2 jlist 2>$null | Out-String).Trim() } catch {}
    if (-not $raw -or -not $raw.StartsWith('[')) { return @() }

    # Collect via foreach (plain array) - do NOT use System.Collections.Generic.List here: PS 5.1
    # throws "Argument types do not match" when that list is later wrapped with @(...).
    $out = foreach ($chunk in ($raw -split '\{"pid":')) {
        if ($chunk -notmatch '"name":"') { continue }   # skip the leading '[' fragment
        $name = if ($chunk -match '"name":"([^"]+)"')      { $matches[1] } else { $null }
        if (-not $name) { continue }
        $ppid = if ($chunk -match '^\s*(\d+)')             { [int]$matches[1] } else { $null }
        $mode = if ($chunk -match '"exec_mode":"([^"]+)"') { $matches[1] } else { '' }
        $stat = if ($chunk -match '"status":"([^"]+)"')    { $matches[1] } else { '' }
        [pscustomobject]@{ Name = $name; Pid = $ppid; ExecMode = $mode; Status = $stat }
    }
    return @($out)
}

function Get-PM2ServiceMap {
    <#
      One record per PM2-managed app (deduped by name, since cluster workers repeat the name):
        Name        - PM2 app name
        ServiceName - OTEL_SERVICE_NAME to assign (Name, unless overridden)
        ExecMode    - 'fork_mode' | 'cluster_mode'
        Instances   - worker count PM2 reports for the app
    #>
    [CmdletBinding()]
    param([hashtable] $Overrides = @{})

    $list = Get-PM2ProcessList
    $byName = [ordered]@{}
    foreach ($p in $list) {
        $name = [string]$p.Name
        if (-not $name) { continue }
        if ($byName.Contains($name)) {
            # Additional cluster worker of an app already seen: bump the instance tally.
            $byName[$name].Instances++
            continue
        }
        $mode = [string]$p.ExecMode
        $byName[$name] = [pscustomobject]@{
            Name        = $name
            ServiceName = $name
            ExecMode    = $mode
            Instances   = 1
        }
    }

    # Extract values by key (avoid @($orderedDict.Values), which can also trip the PS 5.1
    # "Argument types do not match" wrapping bug).
    $records = foreach ($k in $byName.Keys) { $byName[$k] }

    # Apply overrides keyed by the auto-derived service name (the PM2 app name).
    if ($Overrides -and $Overrides.Count -gt 0) {
        foreach ($r in $records) {
            if ($Overrides.ContainsKey($r.ServiceName)) { $r.ServiceName = [string]$Overrides[$r.ServiceName] }
        }
    }
    return $records
}

function Get-NodeServiceLabelValue {
    <#
    .SYNOPSIS
      Comma-joined distinct Node service name(s) for the CX_NODE_SERVICES machine env var.

    .DESCRIPTION
      The Node analog of Get-IISServiceLabelValue: feeds CX_NODE_SERVICES so the collector can
      stamp the host's Node service ownership onto infrastructure telemetry, aligned with the
      per-app OTEL_SERVICE_NAME. Pass the SAME $Map used to assign each app's OTEL_SERVICE_NAME
      to keep that alignment. When -Map is omitted it re-enumerates (standalone use); an
      explicitly-passed empty array is honored (returns '').

      Names are joined with ','; a name containing a comma would mis-split into multiple
      ownership items - avoid commas in PM2 app names and override values.
    #>
    [CmdletBinding()]
    param(
        [object[]]  $Map,
        [hashtable] $Overrides = @{}
    )
    if (-not $PSBoundParameters.ContainsKey('Map')) { $Map = Get-PM2ServiceMap -Overrides $Overrides }
    $names = @($Map | ForEach-Object { $_.ServiceName } | Where-Object { $_ } | Select-Object -Unique)
    return ($names -join ',')
}

function Remove-NodeInstrumentation {
    <#
      Inverse of Instrument-NodePM2.ps1 - used by Uninstall-Agent.ps1.

      For each PM2 app, disable the OTel bootstrap by clearing NODE_OPTIONS (and the OTEL_*
      vars) in the current process, then `pm2 restart <name> --update-env` so the app's runtime
      env is refreshed WITHOUT the --require hook. An empty NODE_OPTIONS reliably prevents the
      instrumentation from loading regardless of PM2's env-merge semantics. Finishes with
      `pm2 save` so the cleaned env persists across a daemon restart / resurrect.

      Best-effort: if PM2 is absent or has no apps, it is a no-op.
    #>
    [CmdletBinding()]
    param([object[]] $Map)

    # See Get-PM2ProcessList: keep pm2's stderr non-fatal under a caller's Stop preference.
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
        Write-Host "[node-uninstall] pm2 not found - nothing to revert."
        return
    }
    if (-not $PSBoundParameters.ContainsKey('Map')) { $Map = Get-PM2ServiceMap }
    if (-not $Map -or @($Map).Count -eq 0) {
        Write-Host "[node-uninstall] no PM2 apps - nothing to revert."
        return
    }

    # Clear the instrumentation env in THIS process so --update-env refreshes each app without it.
    $env:NODE_OPTIONS               = ''
    $env:OTEL_SERVICE_NAME          = ''
    $env:OTEL_EXPORTER_OTLP_ENDPOINT = ''
    $env:OTEL_EXPORTER_OTLP_PROTOCOL = ''
    $env:OTEL_TRACES_EXPORTER       = ''
    $env:OTEL_METRICS_EXPORTER      = ''
    $env:OTEL_LOGS_EXPORTER         = ''

    foreach ($r in $Map) {
        try {
            & pm2 restart $r.Name --update-env 2>$null | Out-Null
            Write-Host "[node-uninstall] $($r.Name): NODE_OPTIONS cleared (instrumentation off)"
        } catch { Write-Warning "[node-uninstall] pm2 restart $($r.Name) failed: $_" }
    }
    try { & pm2 save 2>$null | Out-Null } catch {}
}
