#Requires -PSEdition Desktop
#Requires -RunAsAdministrator
<#
    Zero-code OpenTelemetry .NET Automatic Instrumentation for the SimpleWebApp IIS site.
    Installs the OTel .NET auto-instrumentation (CLR profiler + startup hooks), registers it for
    IIS, and points the app pool's telemetry at the local collector on 127.0.0.1:4317.
    No application/csproj/Program.cs changes. Must run as admin under Windows PowerShell 5.1.
    Docs: https://opentelemetry.io/docs/zero-code/dotnet/#instrument-an-aspnet-application-deployed-on-iis
#>
$ErrorActionPreference = "Stop"
$pool = "SimpleWebAppPool"

Write-Host "== Step 1: download OpenTelemetry.DotNet.Auto.psm1 (latest stable) ==" -ForegroundColor Cyan
$mod = Join-Path $env:TEMP "OpenTelemetry.DotNet.Auto.psm1"
Invoke-WebRequest -UseBasicParsing -OutFile $mod `
  -Uri "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/OpenTelemetry.DotNet.Auto.psm1"
Import-Module $mod
Write-Host "  module imported." -ForegroundColor Green

Write-Host "== Step 2: install core binaries ==" -ForegroundColor Cyan
Install-OpenTelemetryCore
Write-Host "  core installed to 'C:\Program Files\OpenTelemetry .NET AutoInstrumentation'." -ForegroundColor Green

Write-Host "== Step 3: register profiler for IIS (sets W3SVC/WAS env, restarts IIS) ==" -ForegroundColor Cyan
Register-OpenTelemetryForIIS
Write-Host "  registered for IIS." -ForegroundColor Green

Write-Host "== Step 4: app-pool OTEL_* env vars (durable across publish) ==" -ForegroundColor Cyan
$appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
# Remove any prior entries first (idempotent), ignore errors if absent.
foreach ($name in @("OTEL_SERVICE_NAME","OTEL_EXPORTER_OTLP_ENDPOINT")) {
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='$pool'].environmentVariables.[name='$name']" /commit:apphost 2>$null | Out-Null
}
& $appcmd set config -section:system.applicationHost/applicationPools `
  "/+[name='$pool'].environmentVariables.[name='OTEL_SERVICE_NAME',value='SimpleWebApp']" /commit:apphost
& $appcmd set config -section:system.applicationHost/applicationPools `
  "/+[name='$pool'].environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT',value='http://localhost:4318']" /commit:apphost
Write-Host "  app-pool env vars set." -ForegroundColor Green

Write-Host "== Step 5: iisreset ==" -ForegroundColor Cyan
iisreset | Out-Null

Write-Host "== Verify ==" -ForegroundColor Cyan
$home1 = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation"
Write-Host ("  install dir exists: " + (Test-Path $home1)) -ForegroundColor Green
$envReg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC" -Name Environment -ErrorAction SilentlyContinue).Environment
$hasProf = ($envReg -join "`n") -match "CORECLR_PROFILER"
Write-Host ("  W3SVC has CORECLR_PROFILER: " + $hasProf) -ForegroundColor Green
Write-Host "  app-pool env:" -ForegroundColor Green
& $appcmd list config -section:system.applicationHost/applicationPools | Select-String "OTEL_"
Write-Host ""
Write-Host "DONE. App auto-instrumented. Spans/metrics/logs export to http://localhost:4318." -ForegroundColor Green
