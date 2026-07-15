<#
.SYNOPSIS
  Install the Coralogix OpenTelemetry Collector in SUPERVISOR mode (Fleet
  Management / remote-config ready) using a local base config.

.DESCRIPTION
  Downloads the vendor installer (coralogix-otel-collector.ps1) and runs it with
  -Supervisor. In this mode the OpAMP Supervisor process owns the OpAMP connection
  and Coralogix Fleet Management can push remote config that is merged on top of
  the local base config (which must NOT contain an opamp extension - see
  config.supervisor.yaml).

  Sets CORALOGIX_DOMAIN and CORALOGIX_PRIVATE_KEY (persisted as machine env vars so
  the service keeps them across restarts), stages the base config, and installs.

.PARAMETER Domain
  Coralogix domain. Default: eu1.coralogix.com

.PARAMETER PrivateKey
  Send-Your-Data API key. If omitted, read from -KeyFile.

.PARAMETER KeyFile
  File containing the Send-Your-Data key. Default: .\SendDataKey.txt (falls back to
  ..\SimpleWebApp\coralogix\SendDataKey.txt when present).

.PARAMETER BaseConfig
  Base collector config passed as -SupervisorCollectorBaseConfig.
  Default: .\config.supervisor.yaml

.PARAMETER StageDir
  Where the base config is staged on the host. Default: C:\otel

.PARAMETER Version
  Optional collector version to pin (passed to the vendor installer -Version).

.NOTES
  Run elevated (Administrator). The base config uses file_storage, so this script
  passes -EnableDynamicIISParsing to the vendor installer (otherwise the service
  can fail to start).
#>
[CmdletBinding()]
param(
    [string] $Domain     = 'eu1.coralogix.com',
    [string] $PrivateKey = $null,
    [string] $KeyFile    = (Join-Path $PSScriptRoot 'SendDataKey.txt'),
    [string] $BaseConfig = (Join-Path $PSScriptRoot 'config.supervisor.yaml'),
    [string] $StageDir   = 'C:\otel',
    [string] $Version    = $null
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

# TLS 1.2 for GitHub downloads on older Windows Server SKUs
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- Resolve the private key --------------------------------------------------
if (-not $PrivateKey) {
    $candidates = @($KeyFile, (Join-Path $PSScriptRoot '..\SimpleWebApp\coralogix\SendDataKey.txt'))
    $found = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $found) { throw "No private key: pass -PrivateKey or provide $KeyFile" }
    $PrivateKey = (Get-Content -Path $found -Raw).Trim()
    Write-Host "[supervisor] loaded key from $found"
}
if ([string]::IsNullOrWhiteSpace($PrivateKey) -or $PrivateKey -like '*<*your*key*>*') {
    throw "Private key is empty or a placeholder. Set a real Send-Your-Data key."
}

# ---- Stage the base config ----------------------------------------------------
if (-not (Test-Path $BaseConfig)) { throw "Base config not found: $BaseConfig" }
if (-not (Test-Path $StageDir)) { New-Item -ItemType Directory -Path $StageDir -Force | Out-Null }
$stagedConfig = Join-Path $StageDir 'config.supervisor.yaml'
Copy-Item -Path $BaseConfig -Destination $stagedConfig -Force
Write-Host "[supervisor] staged base config -> $stagedConfig"

# Guard: base config must NOT contain an opamp extension in Supervisor mode.
$cfgText = Get-Content -Path $stagedConfig -Raw
if ($cfgText -match '(?m)^\s{2}opamp\s*:') {
    throw "Base config contains an 'opamp' extension. Remove it - the Supervisor owns OpAMP."
}

# ---- Persist domain + key as machine env vars ---------------------------------
[Environment]::SetEnvironmentVariable('CORALOGIX_DOMAIN', $Domain, 'Machine')
[Environment]::SetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', $PrivateKey, 'Machine')
$env:CORALOGIX_DOMAIN      = $Domain
$env:CORALOGIX_PRIVATE_KEY = $PrivateKey
Write-Host "[supervisor] CORALOGIX_DOMAIN=$Domain (machine env set)"

# ---- Download vendor installer ------------------------------------------------
$u = 'https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f = Join-Path $env:TEMP 'coralogix-otel-collector.ps1'
Write-Host "[supervisor] downloading vendor installer..."
Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing

# ---- Install in Supervisor mode -----------------------------------------------
$installArgs = @{
    Supervisor                     = $true
    SupervisorCollectorBaseConfig  = $stagedConfig
    EnableDynamicIISParsing        = $true   # base config uses file_storage
}
if ($Version) { $installArgs['Version'] = $Version }

Write-Host "[supervisor] running installer: -Supervisor -SupervisorCollectorBaseConfig '$stagedConfig' -EnableDynamicIISParsing"
& $f @installArgs
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Vendor installer exited with code $LASTEXITCODE"
}

# ---- Verify -------------------------------------------------------------------
Start-Sleep -Seconds 6
Write-Host ""
Write-Host "[supervisor] services:"
Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'otel|coralogix|opamp|supervisor' } |
    Format-Table Name, Status, DisplayName -AutoSize | Out-String | Write-Host

$health = $false
try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 10
    if ($r.StatusCode -eq 200) { $health = $true }
} catch {}
Write-Host "[supervisor] health check 127.0.0.1:13133 -> $(if ($health) {'OK (200)'} else {'not responding yet'})"

if (-not $health) {
    Write-Warning "Collector health endpoint not responding. Check the Application event log (source otelcol-contrib) and confirm CORALOGIX_PRIVATE_KEY is set on the service."
}

Write-Host "[supervisor] done. Assign a remote config to this host in Coralogix Fleet Management."
