<#
.SYNOPSIS
  Backup + manifest helper for the Coralogix fleet deploy scripts.

.DESCRIPTION
  Dot-source this file to expose a small function library that the install
  scripts use to (a) snapshot every config they are about to mutate and
  (b) record exactly what they add, so Uninstall-Agent.ps1 can reverse ONLY
  the installer's own changes (surgical, "exclusively added" removal) and can
  restore a pre-existing value instead of deleting it.

  Everything lives under a single timestamped session directory:

     C:\ProgramData\CoralogixDeploy\backups\<yyyyMMddHHmmss>\
        manifest.json          - what was backed up + what was added
        applicationHost.config.bak / <mangled>-web.config.bak / ... - file copies
        W3SVC.reg / WAS.reg     - registry exports

  A stable pointer at ...\backups\latest.json (a copy of the newest manifest
  with a `dir` field) lets the uninstaller find the most recent run without
  guessing.

  Manifest schema:
    {
      timestamp, host, iisInstrumented, instrumentVersion,
      envVars:   [ { name, added, priorValue } ],
      poolEnv:   [ { pool, name, value, preexisted } ],
      webConfig: [ { path, addedNode, priorValue, setValue } ],
      files:     [ { original, backup } ],
      registry:  [ { key, export } ]
    }

.NOTES
  Windows PowerShell 5.1. Run elevated (reg export + ProgramData writes).
#>

function Get-DefaultBackupRoot {
    Join-Path $env:ProgramData 'CoralogixDeploy\backups'
}

function New-BackupSession {
    <#
      Create a timestamped backup session directory and return a session object
      that carries the manifest. Pass -Timestamp to reuse a caller-chosen stamp.
    #>
    [CmdletBinding()]
    param(
        [string] $BackupRoot = (Get-DefaultBackupRoot),
        [string] $Timestamp  = (Get-Date -Format 'yyyyMMddHHmmss')
    )

    $dir = Join-Path $BackupRoot $Timestamp
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $manifest = [ordered]@{
        timestamp         = $Timestamp
        host              = $env:COMPUTERNAME
        iisInstrumented   = $false
        instrumentVersion = $null
        envVars           = @()
        poolEnv           = @()
        webConfig         = @()
        files             = @()
        registry          = @()
    }

    [pscustomobject]@{
        Dir        = $dir
        BackupRoot = $BackupRoot
        Manifest   = $manifest
        # Track originals already snapshotted this session so a second call never
        # overwrites the pristine copy with an already-mutated file.
        Seen       = @{}
    }
}

function Backup-DeployFile {
    <#
      Copy a file into the session dir (once) and record it in manifest.files.
      Returns the backup path, or $null if the source did not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)][string] $Path
    )
    if (-not $Session) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "[backup] skip (missing): $Path"
        return $null
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ($Session.Seen.ContainsKey($full)) { return $Session.Seen[$full] }

    $mangled = ($full -replace '^[A-Za-z]:', '' -replace '[\\/:]', '_').TrimStart('_')
    $backup  = Join-Path $Session.Dir ($mangled + '.bak')
    Copy-Item -LiteralPath $full -Destination $backup -Force

    $Session.Manifest.files += [ordered]@{ original = $full; backup = $backup }
    $Session.Seen[$full] = $backup
    Write-Host "[backup] $full -> $backup"
    return $backup
}

function Backup-RegistryKey {
    <#
      Export a registry key to <session>\<leaf>.reg via reg.exe and record it.
      $Path uses the reg.exe form, e.g. HKLM\SYSTEM\CurrentControlSet\Services\W3SVC
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)][string] $Path
    )
    if (-not $Session) { return $null }
    $leaf   = ($Path -split '\\')[-1]
    $export = Join-Path $Session.Dir ($leaf + '.reg')
    # reg.exe returns non-zero if the key does not exist; treat as best-effort.
    & reg.exe export "$Path" "$export" /y 2>$null | Out-Null
    if (Test-Path $export) {
        $Session.Manifest.registry += [ordered]@{ key = $Path; export = $export }
        Write-Host "[backup] registry $Path -> $export"
        return $export
    }
    Write-Host "[backup] registry export skipped (key missing?): $Path"
    return $null
}

function Record-EnvChange {
    <#
      Record a machine env var the installer set. added=$true when it did not
      exist before (uninstall should DELETE it); otherwise uninstall RESTORES
      the prior value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][string] $PriorValue
    )
    if (-not $Session) { return }
    $added = [string]::IsNullOrEmpty($PriorValue)
    $Session.Manifest.envVars += [ordered]@{ name = $Name; added = $added; priorValue = $PriorValue }
}

function Record-PoolEnv {
    <#
      Record an app-pool (or applicationPoolDefaults) environment variable the
      installer set. preexisted=$true means an entry of the same name was already
      present -> uninstall must NOT remove it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)][string] $Pool,
        [Parameter(Mandatory)][string] $Name,
        [string] $Value,
        [bool]   $Preexisted = $false,
        # The value that was there BEFORE we wrote. Without it, `preexisted` says only "do not remove
        # this on uninstall" - it cannot restore what we replaced, so a post-write revert (X-5) could
        # not put an overwritten value back. Optional so existing callers keep working; a caller that
        # omits it gets an honest "cannot restore" from Restore-CxPoolEnvFromManifest instead of a
        # silently wrong restore.
        [string] $PriorValue = $null
    )
    if (-not $Session) { return }
    $Session.Manifest.poolEnv += [ordered]@{ pool = $Pool; name = $Name; value = $Value
                                             preexisted = $Preexisted; priorValue = $PriorValue }
}

function Record-WebConfigEdit {
    <#
      Record a web.config OTEL_SERVICE_NAME edit. addedNode=$true means the
      installer created the node (uninstall removes it); otherwise priorValue
      holds the value to restore.

      -Kind says WHICH element carries the name, because the two live in different
      places and reverse with different functions:
        aspNetCore   <aspNetCore><environmentVariables> - an ASP.NET Core app
        appSettings  <appSettings><add key=...>         - an iisnode app named per-app
      It defaults to aspNetCore so a manifest written before this field existed still
      replays correctly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)][string] $Path,
        [bool]   $AddedNode = $true,
        [AllowNull()][string] $PriorValue,
        [string] $SetValue,
        [ValidateSet('aspNetCore','appSettings')][string] $Kind = 'aspNetCore'
    )
    if (-not $Session) { return }
    $Session.Manifest.webConfig += [ordered]@{ path = $Path; addedNode = $AddedNode; priorValue = $PriorValue; setValue = $SetValue; kind = $Kind }
}

function Save-Manifest {
    <#
      Write manifest.json into the session dir and refresh the stable latest.json
      pointer (manifest content + a `dir` field). Best-effort.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session)
    if (-not $Session) { return }
    try {
        $manifestPath = Join-Path $Session.Dir 'manifest.json'
        $json = $Session.Manifest | ConvertTo-Json -Depth 8
        Set-Content -Path $manifestPath -Value $json -Encoding utf8

        $latest = [ordered]@{ dir = $Session.Dir }
        foreach ($k in $Session.Manifest.Keys) { $latest[$k] = $Session.Manifest[$k] }
        $latestPath = Join-Path $Session.BackupRoot 'latest.json'
        Set-Content -Path $latestPath -Value ($latest | ConvertTo-Json -Depth 8) -Encoding utf8
        Write-Host "[backup] manifest saved -> $manifestPath (latest.json refreshed)"
    } catch {
        Write-Warning "[backup] could not save manifest: $_"
    }
}

function Get-LatestManifest {
    <#
      Read ...\backups\latest.json and return it as an object (with a `dir`
      field), or $null if none exists. Used by Uninstall-Agent.ps1.
    #>
    [CmdletBinding()]
    param([string] $BackupRoot = (Get-DefaultBackupRoot))
    $latestPath = Join-Path $BackupRoot 'latest.json'
    if (-not (Test-Path $latestPath)) { return $null }
    try { return (Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json) }
    catch { Write-Warning "[backup] could not read $latestPath : $_"; return $null }
}

# =============================================================================
# X-5 - post-write sanity check, revert, and the disablement latch.
#
# We had the opposite failure mode from the reference agent: if an environment write left an app pool unable to
# start or a service crash-looping, nothing backed it out. The operator found it, usually later, usually
# somewhere else. The reference agent verifies after installing and can switch its own injection OFF
# (GLOBAL_HOOKING_STATUS_DISABLED_SANITYCHECK / _RECOVERY), then refuses to re-enable silently:
# "Cannot enable auto-injection as it was disabled during installation, please contact support".
#
# The latch is the part that is easy to leave out and pointless to omit: a safety valve that the NEXT
# deploy quietly reopens is not a safety valve. So a revert records WHY, and the next run refuses to
# re-apply to that target until the reason is cleared explicitly.
# =============================================================================

function Get-CxLatchPath {
    [CmdletBinding()] param()
    return (Join-Path $env:ProgramData 'cx\instrumentation-disabled.json')
}

function Get-CxInstrumentationLatch {
    <#
      The current latch, or $null. Shape: { disabled: [ { target, kind, reason, detail, whenUtc } ] }
    #>
    [CmdletBinding()] param([string] $Path = (Get-CxLatchPath))
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { Write-Warning "[latch] unreadable ($Path): $($_.Exception.Message)"; return $null }
}

function Test-CxTargetLatched {
    <#
      Is this specific target latched off? Returns the latch entry, or $null.

      Per-target rather than host-wide on purpose: one pool that could not start must not stop a fleet
      deploy from instrumenting the other forty applications on the box.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Target, [string] $Path = (Get-CxLatchPath))
    $l = Get-CxInstrumentationLatch -Path $Path
    if (-not $l -or -not $l.disabled) { return $null }
    return (@($l.disabled | Where-Object { $_.target -eq $Target }) | Select-Object -First 1)
}

function Set-CxTargetLatched {
    <#
      Latch a target OFF with a reason, mirroring the reference agent's four disablement reasons.
      Idempotent: re-latching the same target replaces its entry rather than appending.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][ValidateSet('installation','manual','sanitycheck','recovery')][string] $Reason,
        [string] $Kind   = '',
        [string] $Detail = '',
        [string] $Path   = (Get-CxLatchPath)
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $l = Get-CxInstrumentationLatch -Path $Path
    $entries = @()
    if ($l -and $l.disabled) { $entries = @($l.disabled | Where-Object { $_.target -ne $Target }) }
    $entries += [pscustomobject]@{
        target  = $Target
        kind    = $Kind
        reason  = $Reason
        detail  = $Detail
        whenUtc = ([datetime]::UtcNow.ToString('o'))
    }
    [pscustomobject]@{ disabled = @($entries) } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8
    Write-Warning "[latch] $Target is now DISABLED (reason=$Reason). It will NOT be instrumented again until the latch is cleared: Clear-CxTargetLatch -Target '$Target'. Detail: $Detail"
    return $Path
}

function Clear-CxTargetLatch {
    <#
      Explicit, per-target un-latch. There is deliberately no "clear everything" convenience: the
      point of the latch is that re-enabling is a decision somebody makes about a named target.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Target, [string] $Path = (Get-CxLatchPath))
    $l = Get-CxInstrumentationLatch -Path $Path
    if (-not $l -or -not $l.disabled) { return $false }
    $before = @($l.disabled).Count
    $entries = @($l.disabled | Where-Object { $_.target -ne $Target })
    if (@($entries).Count -eq $before) { return $false }
    [pscustomobject]@{ disabled = @($entries) } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8
    Write-Host "[latch] cleared for $Target"
    return $true
}

function Test-CxIisPoolHealthy {
    <#
      Did this app pool survive what we just wrote to it, and can it still serve?

      Two separate questions, because a pool can be 'Started' and still fail every request - which is
      exactly what a bad profiler path or a malformed environment produces. So: the pool must be
      Started, AND a request to one of its URLs must not return a 5xx that the same request did not
      return before the change.

      -Url is optional; with none supplied only the pool state is checked and the caller is told that
      is all that was verified. Never reports healthy on evidence it did not gather.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Pool,
        [string] $Url,
        [int]    $TimeoutSec  = 20,
        [int]    $SettleSec   = 3
    )
    Start-Sleep -Seconds $SettleSec
    $state = $null
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $state = (Get-Item "IIS:\AppPools\$Pool" -ErrorAction Stop).State
    } catch {
        return [pscustomobject]@{ Healthy = $false; Checked = 'none'; Reason = "could not read the state of pool '$Pool': $($_.Exception.Message)" }
    }
    if ("$state" -ne 'Started') {
        return [pscustomobject]@{ Healthy = $false; Checked = 'poolState'; Reason = "pool '$Pool' is '$state', not Started, after the write" }
    }
    if (-not $Url) {
        return [pscustomobject]@{ Healthy = $true; Checked = 'poolState'; Reason = "pool '$Pool' is Started (no URL supplied, so serving was NOT verified)" }
    }
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [pscustomobject]@{ Healthy = $true; Checked = 'poolState+request'; Reason = "pool '$Pool' is Started and $Url returned $($resp.StatusCode)" }
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        # A 4xx is the application's business (auth, no route) and not evidence that we broke it. A 5xx
        # or a dead socket after an environment write is.
        if ($code -and $code -lt 500) {
            return [pscustomobject]@{ Healthy = $true; Checked = 'poolState+request'; Reason = "pool '$Pool' is Started and $Url returned $code (a 4xx is the application's own answer, not a failure we caused)" }
        }
        return [pscustomobject]@{ Healthy = $false; Checked = 'poolState+request'
                                  Reason = "pool '$Pool' is Started but $Url failed after the write: $(if ($code) { "HTTP $code" } else { $_.Exception.Message })" }
    }
}

function Restore-CxPoolEnvFromManifest {
    <#
      Undo the environment WE wrote to one app pool, using what Record-PoolEnv captured before the
      change: entries we ADDED are removed, entries we OVERWROTE go back to their prior value.

      Only this pool, and only our own names - a revert that reached further than the change would be
      its own incident.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)][string] $Pool,
        [Parameter(Mandatory)][scriptblock] $SetVar,      # param($pool,$name,$value)
        [Parameter(Mandatory)][scriptblock] $RemoveVar    # param($pool,$name)
    )
    if (-not $Session -or -not $Session.Manifest -or -not $Session.Manifest.poolEnv) {
        Write-Warning "[revert] no recorded pool-env changes for '$Pool' - nothing to undo (was the write recorded?)"
        return 0
    }
    $n = 0; $stuck = @()
    foreach ($e in @($Session.Manifest.poolEnv | Where-Object { $_.pool -eq $Pool })) {
        try {
            if (-not $e.preexisted) {
                # We created this entry, so removing it restores the original state exactly.
                & $RemoveVar $Pool $e.name; $n++
            }
            elseif (-not [string]::IsNullOrEmpty([string]$e.priorValue)) {
                & $SetVar $Pool $e.name ([string]$e.priorValue); $n++
            }
            else {
                # It pre-existed and its prior value was not recorded, so putting it back is not
                # possible. Say so rather than leaving our value in place and calling it a revert.
                $stuck += $e.name
            }
        } catch {
            Write-Warning "[revert] could not undo $($e.name) on '$Pool': $($_.Exception.Message)"
        }
    }
    Write-Host "[revert] undid $n environment change(s) on pool '$Pool'"
    if (@($stuck).Count -gt 0) {
        Write-Warning "[revert] $(@($stuck).Count) pre-existing value(s) on '$Pool' could NOT be restored because no prior value was recorded: $($stuck -join ', '). They still hold OUR value - set them back by hand."
    }
    return $n
}

function Restore-DeployFile {
    <#
      Copy a backed-up file back over its original location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Backup,
        [Parameter(Mandatory)][string] $Original
    )
    if (-not (Test-Path -LiteralPath $Backup)) {
        Write-Warning "[restore] backup missing: $Backup"
        return $false
    }
    Copy-Item -LiteralPath $Backup -Destination $Original -Force
    Write-Host "[restore] $Backup -> $Original"
    return $true
}
