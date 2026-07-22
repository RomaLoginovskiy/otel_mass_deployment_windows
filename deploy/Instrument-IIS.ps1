<#
.SYNOPSIS
  Configure zero-code (no-code) OpenTelemetry .NET auto-instrumentation for IIS,
  fleet-wide, and point every app pool at the local collector.

.DESCRIPTION
  Follows docs/iis-instrumentation.md Part 3/4. Runs only on hosts where IIS was
  detected (the orchestrator gates this). Steps:
    1. Download OpenTelemetry.DotNet.Auto.psm1, Import-Module, Install-OpenTelemetryCore,
       Register-OpenTelemetryForIIS  (STRICT order - the register step fails if run
       before core files are in place).
    2. Set the OTLP endpoint host-wide via applicationPoolDefaults environment
       variables (so all pools inherit it) - the fleet-friendly "set once" pattern.
    2b. Enumerate every IIS site + application and assign each a distinct
       OTEL_SERVICE_NAME derived from the site name + app path (see
       Resolve-IISServiceNames.ps1). Dedicated pools get the name on the pool; apps
       that share a pool get it in their own web.config.
    3. Recycle IIS so workers pick up the new environment.

  IMPORTANT: This requires Windows PowerShell 5.1 (NOT PowerShell 7) for the
  .NET auto-instrumentation module.

.PARAMETER Version
  Auto-instrumentation release tag. Default: v1.16.0-beta.1 (matches the runbook;
  bump to the current release from the project's releases page).

.PARAMETER OtlpEndpoint
  Local collector OTLP HTTP endpoint. Default: http://localhost:4318

.PARAMETER NoReset
  Pass -NoReset to Register-OpenTelemetryForIIS and skip the final iisreset (recycle
  manually later, e.g. during a maintenance window).

.PARAMETER ServiceNameOverrides
  Optional hashtable to rename specific apps, keyed by the auto-derived service name
  (e.g. @{ 'Wallet/api' = 'wallet-api' }). Merged over the JSON file if both are given.

.PARAMETER OverridesJson
  Optional path to a JSON file of the same { autoName = overrideName } shape.

.NOTES
  Run elevated. The host-wide OTLP vars are set on <applicationPoolDefaults>, which
  only reaches pools that do not declare their own <environmentVariables> collection.
  Pools that need their own vars must list all of them (IIS inheritance rule).
#>
[CmdletBinding()]
param(
    [string]    $Version              = 'v1.16.0-beta.1',
    [string]    $OtlpEndpoint          = 'http://localhost:4318',
    [switch]    $NoReset,
    [hashtable] $ServiceNameOverrides  = @{},
    [string]    $OverridesJson,
    # Optional backup/manifest session (from Backup-Config.ps1, created by the
    # orchestrator). When supplied, mutated configs are backed up and recorded so
    # Uninstall-Agent.ps1 can reverse only the installer's own changes.
    $Session = $null
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run elevated (Administrator)."
    }
}

Assert-Admin

if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Warning "The .NET auto-instrumentation module requires Windows PowerShell 5.1, not PowerShell $($PSVersionTable.PSVersion). Re-run under 'powershell.exe'."
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Optional backup/manifest recording (shared session from the orchestrator).
$backupHelper = Join-Path $PSScriptRoot 'Backup-Config.ps1'
if (Test-Path $backupHelper) { . $backupHelper }

# ---- 1. Install the auto-instrumentation module (STRICT order) ----------------
$module_url    = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$Version/OpenTelemetry.DotNet.Auto.psm1"
$download_path = Join-Path $env:TEMP 'OpenTelemetry.DotNet.Auto.psm1'

Write-Host "[iis-instr] downloading auto-instrumentation module $Version ..."
Invoke-WebRequest -Uri $module_url -OutFile $download_path -UseBasicParsing

Import-Module $download_path -Force
Write-Host "[iis-instr] Install-OpenTelemetryCore ..."
Install-OpenTelemetryCore

# Snapshot the CLR-profiler registry (REG_MULTI_SZ Environment) BEFORE the vendor
# register writes it, and mark the run as IIS-instrumented in the manifest.
if ($Session) {
    Backup-RegistryKey -Session $Session -Path 'HKLM\SYSTEM\CurrentControlSet\Services\W3SVC' | Out-Null
    Backup-RegistryKey -Session $Session -Path 'HKLM\SYSTEM\CurrentControlSet\Services\WAS'   | Out-Null
    $Session.Manifest.iisInstrumented   = $true
    $Session.Manifest.instrumentVersion = $Version
}

Write-Host "[iis-instr] Register-OpenTelemetryForIIS ..."
if ($NoReset) { Register-OpenTelemetryForIIS -NoReset } else { Register-OpenTelemetryForIIS }

# ---- 2. Host-wide OTLP endpoint via applicationPoolDefaults -------------------
$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
if (-not (Test-Path $appcmd)) { throw "appcmd.exe not found - is the IIS management role installed?" }
$appHostConfig = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'

function Test-PoolEnvPresent {
    # True if an environment variable is already declared on a pool (or, when
    # $Pool is empty, on applicationPoolDefaults). Used to flag entries that the
    # installer did NOT add, so uninstall leaves them alone.
    param([string] $Pool, [string] $Name)
    try {
        if (-not (Test-Path $appHostConfig)) { return $false }
        [xml]$c = Get-Content -LiteralPath $appHostConfig -Raw
        $base = if ($Pool) {
            "/configuration/system.applicationHost/applicationPools/add[@name='$Pool']"
        } else {
            "/configuration/system.applicationHost/applicationPools/applicationPoolDefaults"
        }
        return [bool]$c.SelectSingleNode("$base/environmentVariables/add[@name='$Name']")
    } catch { return $false }
}

function Set-PoolDefaultEnv {
    param([string] $Name, [string] $Value)
    # Back up applicationHost.config once + record whether this entry pre-existed,
    # BEFORE the remove/add, so uninstall removes only what we add.
    if ($Session) {
        Backup-DeployFile -Session $Session -Path $appHostConfig | Out-Null
        Record-PoolEnv    -Session $Session -Pool 'applicationPoolDefaults' -Name $Name -Value $Value -Preexisted (Test-PoolEnvPresent -Pool '' -Name $Name)
    }
    # Idempotent: remove any existing entry, then add. Removal is best-effort.
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='applicationPoolDefaults'].environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    # applicationPoolDefaults is addressed without a [name=...] predicate on the parent.
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+applicationPoolDefaults.environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
    Write-Host "[iis-instr] applicationPoolDefaults env: $Name=$Value"
}

function Set-PoolEnv {
    # Set an env var on a specific named pool (not the defaults template).
    param([string] $Pool, [string] $Name, [string] $Value)
    if ($Session) {
        Backup-DeployFile -Session $Session -Path $appHostConfig | Out-Null
        Record-PoolEnv    -Session $Session -Pool $Pool -Name $Name -Value $Value -Preexisted (Test-PoolEnvPresent -Pool $Pool -Name $Name)
    }
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='$Pool'].environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+[name='$Pool'].environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
}

Set-PoolDefaultEnv -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value $OtlpEndpoint
Set-PoolDefaultEnv -Name 'OTEL_EXPORTER_OTLP_PROTOCOL' -Value 'http/protobuf'

# ---- 2b. Per-app OTEL_SERVICE_NAME (auto-discovered) --------------------------
# Merge overrides: JSON file first, then the -ServiceNameOverrides hashtable on top.
if ($OverridesJson) {
    if (-not (Test-Path $OverridesJson)) { throw "Overrides JSON not found: $OverridesJson" }
    $fromFile = Get-Content -LiteralPath $OverridesJson -Raw | ConvertFrom-Json
    foreach ($p in $fromFile.PSObject.Properties) {
        if (-not $ServiceNameOverrides.ContainsKey($p.Name)) { $ServiceNameOverrides[$p.Name] = $p.Value }
    }
}

. (Join-Path $PSScriptRoot 'Resolve-IISServiceNames.ps1')
$svcMap = Get-IISServiceMap -Overrides $ServiceNameOverrides

if (-not $svcMap -or @($svcMap).Count -eq 0) {
    Write-Warning "[iis-instr] no IIS sites/applications found - no per-app service names set."
} else {
    Write-Host "[iis-instr] assigning per-app OTEL_SERVICE_NAME ($(@($svcMap).Count) app(s)):"
    foreach ($r in $svcMap) {
        Write-Host ("  {0,-20} {1,-10} pool={2,-20} -> {3} [{4}]" -f $r.Site, $r.AppPath, $r.Pool, $r.ServiceName, $r.Scope)
        if ($r.Scope -eq 'pool') {
            # A pool that declares its own <environmentVariables> stops inheriting the
            # applicationPoolDefaults entries (see .NOTES), so re-set the OTLP vars here.
            Set-PoolEnv -Pool $r.Pool -Name 'OTEL_SERVICE_NAME'           -Value $r.ServiceName
            Set-PoolEnv -Pool $r.Pool -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value $OtlpEndpoint
            Set-PoolEnv -Pool $r.Pool -Name 'OTEL_EXPORTER_OTLP_PROTOCOL' -Value 'http/protobuf'
        } else {
            # Shared pool: keep inheriting OTLP defaults, set only the per-app name in web.config.
            [void](Set-WebConfigServiceName -PhysicalPath $r.PhysicalPath -ServiceName $r.ServiceName -Session $Session)
        }
    }
}

# ---- 3. Recycle IIS -----------------------------------------------------------
if ($NoReset) {
    Write-Host "[iis-instr] -NoReset: skipping iisreset. Recycle pools during your maintenance window."
} else {
    Write-Host "[iis-instr] iisreset ..."
    & iisreset.exe | Out-String | Write-Host
}

# ---- Verify -------------------------------------------------------------------
Write-Host ""
Write-Host "[iis-instr] W3SVC status: $((Get-Service W3SVC -ErrorAction SilentlyContinue).Status)"
Write-Host "[iis-instr] done. ASP.NET Core pools must be set to 'No Managed Code' (managedRuntimeVersion='') or they emit no telemetry."
