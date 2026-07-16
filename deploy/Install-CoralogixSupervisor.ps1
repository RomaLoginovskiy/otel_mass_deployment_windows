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
    [string] $Version    = $null,
    # Comma-separated key=value selector attributes (cx.host.role, workload.*) to publish
    # in the OpAMP AgentDescription. Defaults to machine OTEL_RESOURCE_ATTRIBUTES (set by
    # Detect-Workloads.ps1) when omitted.
    [string] $ResourceAttributes = $null
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run elevated (Administrator)."
    }
}

function Set-SupervisorDescriptionAttributes {
    <#
      Inject the detected selector attributes (cx.host.role, workload.*) into the OpAMP
      Supervisor's config.yaml `agent.description.non_identifying_attributes`, so they show
      up in the Coralogix Fleet Management AgentDescription. The vendor installer writes
      only static service.name/cx.agent.type there. Best-effort: never fails the install.
    #>
    param([string] $ConfigPath, [string] $Attributes)

    if ([string]::IsNullOrWhiteSpace($Attributes)) {
        Write-Warning "[supervisor] no OTEL_RESOURCE_ATTRIBUTES to publish to AgentDescription; skipping"
        return
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "[supervisor] supervisor config not found at $ConfigPath; cannot publish selector attributes"
        return
    }

    # Parse "k1=v1,k2=v2" -> ordered pairs (split each token on the FIRST '=' only).
    $pairs = [ordered]@{}
    foreach ($tok in ($Attributes -split ',')) {
        $t = $tok.Trim(); if (-not $t) { continue }
        $eq = $t.IndexOf('='); if ($eq -lt 1) { continue }
        $pairs[$t.Substring(0, $eq).Trim()] = $t.Substring($eq + 1).Trim()
    }
    if ($pairs.Count -eq 0) { Write-Warning "[supervisor] no valid key=value pairs parsed; skipping"; return }

    $lines  = Get-Content -Path $ConfigPath
    $anchor = -1; $indent = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)non_identifying_attributes:\s*$') { $anchor = $i; $indent = $Matches[1]; break }
    }
    if ($anchor -lt 0) {
        Write-Warning "[supervisor] 'non_identifying_attributes:' not found in $ConfigPath (vendor template changed?); skipping selector publish"
        return
    }
    $itemIndent = $indent + '  '

    # Keys already present in the block (child lines indented under the anchor).
    $existing = @{}
    for ($j = $anchor + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*#') { continue }
        if ($lines[$j] -notmatch ("^" + [regex]::Escape($itemIndent) + "\S")) { break }
        if ($lines[$j] -match '^\s*([^:\s]+)\s*:') { $existing[$Matches[1]] = $true }
    }

    $insert = @(); $added = @()
    foreach ($k in $pairs.Keys) {
        if ($existing.ContainsKey($k)) { continue }
        $insert += ('{0}{1}: "{2}"' -f $itemIndent, $k, $pairs[$k]); $added += $k
    }
    if ($insert.Count -eq 0) { Write-Host "[supervisor] AgentDescription already carries the selector attributes"; return }

    $new = @($lines[0..$anchor]) + $insert
    if (($anchor + 1) -le ($lines.Count - 1)) { $new += $lines[($anchor + 1)..($lines.Count - 1)] }
    Set-Content -Path $ConfigPath -Value $new -Encoding utf8
    Write-Host "[supervisor] published selector attributes to AgentDescription ($($insert.Count) added): $($added -join ', ')"
}

Assert-Admin

# Default the selector attributes to what Detect-Workloads.ps1 persisted machine-wide.
if (-not $ResourceAttributes) {
    $ResourceAttributes = [Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES', 'Machine')
}

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

# ---- Publish selector attributes to the OpAMP AgentDescription ----------------
# The vendor installer writes only static service.name/cx.agent.type into the supervisor
# config's agent.description. Inject the detected cx.host.role/workload.* so Coralogix
# Fleet Management can group / assign config by them, then restart to apply.
$supervisorConfig = Join-Path ${env:ProgramFiles} 'OpenTelemetry OpAMP Supervisor\config.yaml'
Set-SupervisorDescriptionAttributes -ConfigPath $supervisorConfig -Attributes $ResourceAttributes
try {
    if (Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue) {
        # The vendor installer registers the service with StartType=Manual. After a reboot the
        # supervisor stays Stopped -> the agent silently drops off Fleet Management and no
        # telemetry ships until someone starts it by hand. Force Automatic so it survives reboots.
        Set-Service -Name 'opampsupervisor' -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Host "[supervisor] set opampsupervisor StartType=Automatic (survives reboot)"
        Restart-Service -Name 'opampsupervisor' -Force -ErrorAction SilentlyContinue
        Write-Host "[supervisor] restarted opampsupervisor to apply AgentDescription attributes"
    }
} catch { Write-Warning "[supervisor] could not configure/restart opampsupervisor: $_" }

# ---- Verify -------------------------------------------------------------------
Start-Sleep -Seconds 6
Write-Host ""
Write-Host "[supervisor] services:"
Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'otel|coralogix|opamp|supervisor' } |
    Format-Table Name, Status, StartType, DisplayName -AutoSize | Out-String | Write-Host

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
