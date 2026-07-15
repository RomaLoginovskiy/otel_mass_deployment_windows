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
       OTEL_SERVICE_NAME is intentionally left per-app / auto-generated.
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

.NOTES
  Run elevated. The host-wide OTLP vars are set on <applicationPoolDefaults>, which
  only reaches pools that do not declare their own <environmentVariables> collection.
  Pools that need their own vars must list all of them (IIS inheritance rule).
#>
[CmdletBinding()]
param(
    [string] $Version      = 'v1.16.0-beta.1',
    [string] $OtlpEndpoint = 'http://localhost:4318',
    [switch] $NoReset
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

# ---- 1. Install the auto-instrumentation module (STRICT order) ----------------
$module_url    = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$Version/OpenTelemetry.DotNet.Auto.psm1"
$download_path = Join-Path $env:TEMP 'OpenTelemetry.DotNet.Auto.psm1'

Write-Host "[iis-instr] downloading auto-instrumentation module $Version ..."
Invoke-WebRequest -Uri $module_url -OutFile $download_path -UseBasicParsing

Import-Module $download_path -Force
Write-Host "[iis-instr] Install-OpenTelemetryCore ..."
Install-OpenTelemetryCore

Write-Host "[iis-instr] Register-OpenTelemetryForIIS ..."
if ($NoReset) { Register-OpenTelemetryForIIS -NoReset } else { Register-OpenTelemetryForIIS }

# ---- 2. Host-wide OTLP endpoint via applicationPoolDefaults -------------------
$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
if (-not (Test-Path $appcmd)) { throw "appcmd.exe not found - is the IIS management role installed?" }

function Set-PoolDefaultEnv {
    param([string] $Name, [string] $Value)
    # Idempotent: remove any existing entry, then add. Removal is best-effort.
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='applicationPoolDefaults'].environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    # applicationPoolDefaults is addressed without a [name=...] predicate on the parent.
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+applicationPoolDefaults.environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
    Write-Host "[iis-instr] applicationPoolDefaults env: $Name=$Value"
}

Set-PoolDefaultEnv -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value $OtlpEndpoint
Set-PoolDefaultEnv -Name 'OTEL_EXPORTER_OTLP_PROTOCOL' -Value 'http/protobuf'

Write-Host "[iis-instr] NOTE: OTEL_SERVICE_NAME is left per-app (web.config / appSettings) or auto-generated as SiteName\\VirtualDir."

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
