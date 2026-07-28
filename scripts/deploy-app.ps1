#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
<#
    Build, deploy, and OTEL-instrument SimpleWebApp on IIS in a single elevated pass.

    Does, in order:
      1. dotnet publish the app (Release) from ..\SimpleWebApp.
      2. Ensure the ASP.NET Core 8 Hosting Bundle (ASP.NET Core 8 runtime + ANCM v2).
      3. Stop IIS once (releases any auto-instrumentation DLL locks before copy/instrument).
      4. Create a "No Managed Code" app pool + site on port 8080 and copy the publish output.
      5. Install OpenTelemetry .NET Automatic Instrumentation and register the CLR profiler for IIS.
      6. Set the app pool's OTEL_* env vars, including the requested resource attributes
         OTEL_RESOURCE_ATTRIBUTES=tags.CX_SERVICE_NAME=<name>,tags.service=<name>.
      7. iisreset + start the site.
      8. Drive a load burst (/, /health, /db) to emit HTTP + DB spans.
      9. Verify the site, the profiler registration, and the resolved pool env vars.

    The app itself carries no OTEL code; all instrumentation is external (profiler + app-pool env).
    A running Coralogix OTel collector on 127.0.0.1:4318 is assumed (install separately).
    Re-runnable: the pool/site are recreated and env vars are set idempotently.
    Must run as Administrator under Windows PowerShell 5.1 (Desktop edition).
    Docs: https://opentelemetry.io/docs/zero-code/dotnet/#instrument-an-aspnet-application-deployed-on-iis
#>
param(
    [string]$SourceDir     = "$PSScriptRoot\..\SimpleWebApp",   # repo-root app (sibling of misc\)
    [string]$PublishDir    = "$PSScriptRoot\publish",           # dotnet publish output
    [string]$SitePath      = "C:\inetpub\SimpleWebApp",
    [string]$SiteName      = "SimpleWebApp",
    [string]$AppPool       = "SimpleWebAppPool",
    [int]   $Port          = 8080,
    [string]$ServiceName   = "SimpleWebApp",                    # feeds OTEL_SERVICE_NAME + both tags
    # IPv4 literal on purpose: the collector binds 127.0.0.1 only, and `localhost`
    # resolves to ::1 first on a dual-stack host, which drops the export silently.
    # A `localhost` value passed here is rewritten, not honored (see below).
    [string]$OtlpEndpoint  = "http://127.0.0.1:4318",          # collector HTTP (http/protobuf default)
    [string]$Configuration = "Release",
    [int]   $LoadSweeps    = 40,
    [string]$Environment   = "",                               # deployment env (production/staging/dev); stamps cx_environment/cx_env + semconv, splits telemetry per env in Coralogix
    [switch]$InstrumentAllApps                                 # also name every OTHER IIS app on this host (site + app path)
)

$ErrorActionPreference = "Stop"
$ancm   = "C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
# Sysnative, not System32, when this runs 32-bit: WOW64 redirects System32 to
# SysWOW64, whose inetsrv has appcmd.exe but no config\applicationHost.config.
# appcmd would still work (bitness-agnostic COM API) while any direct config read
# silently missed. Same resolver as deploy/Instrument-IIS.ps1.
$inetsrv = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    Join-Path $env:windir 'Sysnative\inetsrv'
} else {
    Join-Path $env:windir 'System32\inetsrv'
}
$appcmd = Join-Path $inetsrv "appcmd.exe"
$csproj = Join-Path $SourceDir "SimpleWebApp.csproj"

# Normalize a `localhost` endpoint to the IPv4 literal before it is written to any pool.
$logHelper = Join-Path $PSScriptRoot "..\deploy\Write-DeployLog.ps1"
if (Test-Path $logHelper) { . $logHelper }
if (Get-Command Resolve-CxOtlpEndpoint -ErrorAction SilentlyContinue) {
    $OtlpEndpoint = Resolve-CxOtlpEndpoint -Endpoint $OtlpEndpoint
}

# The requested OTEL resource attributes (literal Coralogix-visible tag keys).
$resourceAttrs = "tags.CX_SERVICE_NAME=$ServiceName,tags.service=$ServiceName"
# Environment label: set machine CX_ENVIRONMENT (read by the single-host collector's
# resource/environment processor for host/infra signals) and append the env keys to
# the app-pool attrs so app spans carry it immediately, no collector restart needed.
if ($Environment) {
    [Environment]::SetEnvironmentVariable('CX_ENVIRONMENT', $Environment, 'Machine')
    $resourceAttrs += ",tags.cx_environment=$Environment,tags.cx_env=$Environment,deployment.environment.name=$Environment"
}

Write-Host "== Step 1: dotnet publish ==" -ForegroundColor Cyan
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found on PATH. Install the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0"
}
if (-not (Test-Path $csproj)) { throw "Project not found at $csproj" }
dotnet publish $csproj -c $Configuration -o $PublishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)." }
if (-not (Test-Path "$PublishDir\SimpleWebApp.dll")) { throw "Publish output missing SimpleWebApp.dll at $PublishDir" }
Write-Host "  published to $PublishDir" -ForegroundColor Green

Write-Host "== Step 2: ASP.NET Core 8 Hosting Bundle ==" -ForegroundColor Cyan
$aspnet8 = Get-ChildItem "C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App" -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "8.*" }
if ((Test-Path $ancm) -and $aspnet8) {
    Write-Host "  Hosting Bundle already present (ANCM + ASP.NET Core 8 runtime). Skipping." -ForegroundColor Green
} else {
    Write-Host "  Installing via winget (Microsoft.DotNet.HostingBundle.8)..."
    winget install --id Microsoft.DotNet.HostingBundle.8 --accept-source-agreements --accept-package-agreements --silent
    if (-not (Test-Path $ancm)) {
        throw "ANCM still missing after install. Download manually: https://dotnet.microsoft.com/download/dotnet/8.0 -> ASP.NET Core Runtime -> Hosting Bundle, then re-run."
    }
    Write-Host "  Hosting Bundle installed." -ForegroundColor Green
}

Write-Host "== Step 3: stop IIS (release instrumentation DLL locks) ==" -ForegroundColor Cyan
# A running w3wp holds the auto-instrumentation DLLs open, so Install-OpenTelemetryCore's clean
# reinstall would fail with "Access denied". Stop IIS up front; Step 7 restarts it.
iisreset /stop | Out-Null
Start-Sleep -Seconds 2
Write-Host "  IIS stopped." -ForegroundColor Green

Write-Host "== Step 4: IIS app pool + site + content ==" -ForegroundColor Cyan
Import-Module WebAdministration
New-Item -ItemType Directory -Force -Path $SitePath | Out-Null
Copy-Item "$PublishDir\*" $SitePath -Recurse -Force

if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName }
if (Test-Path "IIS:\AppPools\$AppPool") { Remove-WebAppPool -Name $AppPool }

New-WebAppPool -Name $AppPool | Out-Null
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name managedRuntimeVersion -Value ""   # No Managed Code
New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $AppPool -Port $Port | Out-Null

# App-pool identity needs read/execute on the content folder.
icacls $SitePath /grant "IIS AppPool\${AppPool}:(OI)(CI)RX" /T | Out-Null
Write-Host "  Site '$SiteName' on port $Port, pool '$AppPool' (No Managed Code)." -ForegroundColor Green

Write-Host "== Step 5: OpenTelemetry .NET auto-instrumentation ==" -ForegroundColor Cyan
$mod = Join-Path $env:TEMP "OpenTelemetry.DotNet.Auto.psm1"
Invoke-WebRequest -UseBasicParsing -OutFile $mod `
  -Uri "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/OpenTelemetry.DotNet.Auto.psm1"
Import-Module $mod
Install-OpenTelemetryCore
Register-OpenTelemetryForIIS
Write-Host "  core installed + profiler registered for IIS." -ForegroundColor Green

Write-Host "== Step 6: app-pool OTEL_* env vars (durable across publish) ==" -ForegroundColor Cyan
$otelVars = [ordered]@{
    "OTEL_SERVICE_NAME"           = $ServiceName
    "OTEL_EXPORTER_OTLP_ENDPOINT" = $OtlpEndpoint
    "OTEL_RESOURCE_ATTRIBUTES"    = $resourceAttrs
}
foreach ($name in $otelVars.Keys) {
    # Remove any prior entry first (idempotent), ignore errors if absent.
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='$AppPool'].environmentVariables.[name='$name']" /commit:apphost 2>$null | Out-Null
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+[name='$AppPool'].environmentVariables.[name='$name',value='$($otelVars[$name])']" /commit:apphost | Out-Null
}
Write-Host "  set OTEL_SERVICE_NAME=$ServiceName" -ForegroundColor Green
Write-Host "  set OTEL_EXPORTER_OTLP_ENDPOINT=$OtlpEndpoint" -ForegroundColor Green
Write-Host "  set OTEL_RESOURCE_ATTRIBUTES=$resourceAttrs" -ForegroundColor Green

if ($InstrumentAllApps) {
    Write-Host "== Step 6b: name every IIS app on this host (site + app path) ==" -ForegroundColor Cyan
    # Reuse the fleet resolver so the demo host and the fleet path name apps identically.
    . (Join-Path $PSScriptRoot "..\deploy\Resolve-IISServiceNames.ps1")
    $svcMap = Get-IISServiceMap
    foreach ($r in $svcMap) {
        $attrs = "tags.CX_SERVICE_NAME=$($r.ServiceName),tags.service=$($r.ServiceName)"
        if ($Environment) { $attrs += ",tags.cx_environment=$Environment,tags.cx_env=$Environment,deployment.environment.name=$Environment" }
        Write-Host ("  {0,-18} {1,-10} pool={2,-18} -> {3} [{4}]" -f $r.Site, $r.AppPath, $r.Pool, $r.ServiceName, $r.Scope) -ForegroundColor Green
        if ($r.Scope -eq 'pool') {
            # Dedicated pool: set the name, endpoint, and per-app tags on the pool.
            $poolVars = [ordered]@{
                "OTEL_SERVICE_NAME"           = $r.ServiceName
                "OTEL_EXPORTER_OTLP_ENDPOINT" = $OtlpEndpoint
                "OTEL_RESOURCE_ATTRIBUTES"    = $attrs
            }
            foreach ($n in $poolVars.Keys) {
                & $appcmd set config -section:system.applicationHost/applicationPools `
                    "/-[name='$($r.Pool)'].environmentVariables.[name='$n']" /commit:apphost 2>$null | Out-Null
                & $appcmd set config -section:system.applicationHost/applicationPools `
                    "/+[name='$($r.Pool)'].environmentVariables.[name='$n',value='$($poolVars[$n])']" /commit:apphost | Out-Null
            }
        } else {
            # Shared pool: only the per-app service name is distinguishable; endpoint/tags
            # are inherited from the pool. Set the name in the app's web.config.
            [void](Set-WebConfigServiceName -PhysicalPath $r.PhysicalPath -ServiceName $r.ServiceName)
        }
    }
}

Write-Host "== Step 6c: CX_IIS_SERVICES (infra service label) ==" -ForegroundColor Cyan
# Machine env var read (from the remote Fleet config) by the collector's
# transform/iis_service_labels processor to stamp the IIS service name(s) onto INFRASTRUCTURE
# telemetry so Coralogix resolves the host's Service ownership. Built from the SAME names
# assigned as each app's OTEL_SERVICE_NAME, so ownership items == per-app service names:
#   -InstrumentAllApps -> the distinct set from $svcMap (via Get-IISServiceLabelValue);
#   otherwise the single $ServiceName (which is exactly this pool's OTEL_SERVICE_NAME).
if ($InstrumentAllApps -and $svcMap) {
    $iisServices = Get-IISServiceLabelValue -Map $svcMap
} else {
    $iisServices = $ServiceName
}
[Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $iisServices, 'Machine')
$env:CX_IIS_SERVICES = $iisServices
Write-Host "  set machine CX_IIS_SERVICES=$iisServices" -ForegroundColor Green
# The collector reads ${env:CX_IIS_SERVICES} only at process start, and iisreset below only
# restarts IIS (not the collector). Restart the collector so THIS single-host run actually
# stamps the label. (The fleet path restarts the supervisor in Install-Agent.ps1.) Best-effort
# across supervisor / local-mode service names.
foreach ($svc in 'opampsupervisor','otelcol-contrib') {
    if (Get-Service $svc -ErrorAction SilentlyContinue) {
        try { Restart-Service $svc -Force -ErrorAction Stop; Write-Host "  restarted $svc (picks up CX_IIS_SERVICES)" -ForegroundColor Green }
        catch { Write-Warning "  could not restart ${svc}: $_" }
    }
}

Write-Host "== Step 7: iisreset + start ==" -ForegroundColor Cyan
iisreset | Out-Null
Start-Website -Name $SiteName
Start-Sleep -Seconds 2
Write-Host "  IIS restarted, site started." -ForegroundColor Green

Write-Host "== Step 8: generate load ==" -ForegroundColor Cyan
$base = "http://localhost:$Port"
1..$LoadSweeps | ForEach-Object {
    foreach ($u in @("/", "/health", "/db")) {
        try { Invoke-WebRequest "$base$u" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {}
    }
    Start-Sleep -Milliseconds 200
}
Write-Host "  sent ~$([int]($LoadSweeps * 3)) requests ($LoadSweeps x /, /health, /db)." -ForegroundColor Green

Write-Host "== Verify ==" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest "$base/" -UseBasicParsing -TimeoutSec 15
    Write-Host ("  GET /       -> HTTP $($r.StatusCode)") -ForegroundColor Green
    if ($r.Content -match "IIS Instrumentation Test") { Write-Host "  landing heading found. OK." -ForegroundColor Green }
    $h = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 15
    Write-Host ("  GET /health -> $($h.Content)") -ForegroundColor Green
} catch {
    Write-Warning "Request failed: $($_.Exception.Message)"
    Write-Warning "502.5 => runtime/bundle issue; 500.19 => web.config/module. Check C:\inetpub\logs."
}
$envReg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC" -Name Environment -ErrorAction SilentlyContinue).Environment
$hasProf = ($envReg -join "`n") -match "CORECLR_PROFILER"
Write-Host ("  W3SVC has CORECLR_PROFILER: " + $hasProf) -ForegroundColor Green
Write-Host "  app-pool OTEL env:" -ForegroundColor Green
& $appcmd list config -section:system.applicationHost/applicationPools | Select-String "OTEL_"

Write-Host ""
Write-Host "DONE. App built, deployed, and instrumented on $base" -ForegroundColor Green
Write-Host "Resource attributes tags.CX_SERVICE_NAME + tags.service = '$ServiceName' are set on pool '$AppPool'." -ForegroundColor Green
Write-Host "With the collector running, data arrives in Coralogix (app 'iis-instrumentation-test', subsystem '$ServiceName')." -ForegroundColor Green
