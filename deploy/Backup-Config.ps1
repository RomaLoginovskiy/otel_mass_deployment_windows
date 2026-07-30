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
        [bool]   $Preexisted = $false
    )
    if (-not $Session) { return }
    $Session.Manifest.poolEnv += [ordered]@{ pool = $Pool; name = $Name; value = $Value; preexisted = $Preexisted }
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
