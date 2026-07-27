#Requires -RunAsAdministrator
<#
    Installs the Coralogix OpenTelemetry Collector as a Windows service, configured to:
      - receive the app's OTLP on 127.0.0.1:4317/4318
      - scrape host metrics + IIS/ASP.NET perf counters
      - tail IIS access logs + Windows event logs
      - derive RED span-metrics
      - ship everything directly to Coralogix (eu1.coralogix.com)
    IIS log field parsing is done in config.yaml (filelog header + csv_parser + transform/iis),
    so the installer's -EnableDynamicIISParsing is intentionally NOT used (would double-parse).
    Docs: https://coralogix.com/docs/external/telemetry-shippers/otel-installer/windows/
#>
$ErrorActionPreference = "Stop"
$cxDir = Join-Path $PSScriptRoot "SimpleWebApp\coralogix"

Write-Host "== Step 1: stage config to C:\otel\config.yaml ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path C:\otel | Out-Null
Copy-Item (Join-Path $cxDir "config.yaml") C:\otel\config.yaml -Force
Write-Host "  staged." -ForegroundColor Green

Write-Host "== Step 2: load Send-Your-Data key into env (not printed) ==" -ForegroundColor Cyan
$keyPath = Join-Path $cxDir "SendDataKey.txt"
if (-not (Test-Path $keyPath)) { throw "SendDataKey.txt not found at $keyPath" }
$env:CORALOGIX_PRIVATE_KEY = (Get-Content $keyPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($env:CORALOGIX_PRIVATE_KEY)) { throw "SendDataKey.txt is empty" }
Write-Host ("  key loaded (length " + $env:CORALOGIX_PRIVATE_KEY.Length + ").") -ForegroundColor Green

Write-Host "== Step 3: download + run Coralogix installer ==" -ForegroundColor Cyan
$u = 'https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f = Join-Path $env:TEMP "coralogix-otel-collector.ps1"
Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing
& $f -Config 'C:\otel\config.yaml'

Write-Host "== Verify ==" -ForegroundColor Cyan
Start-Sleep -Seconds 3
Get-Service | Where-Object { $_.Name -match "otel|coralogix" } |
    Select-Object Name, Status, DisplayName | Format-Table -AutoSize
try {
    $h = Invoke-WebRequest "http://127.0.0.1:13133" -UseBasicParsing -TimeoutSec 10
    Write-Host ("  health_check -> HTTP " + $h.StatusCode) -ForegroundColor Green
} catch {
    Write-Warning ("health_check probe failed: " + $_.Exception.Message + " (collector may still be starting)")
}
Write-Host ""
Write-Host "DONE. Collector shipping to eu1.coralogix.com. Hit http://localhost:8080/ to generate telemetry." -ForegroundColor Green
