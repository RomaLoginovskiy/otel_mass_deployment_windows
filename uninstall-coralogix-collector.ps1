#Requires -RunAsAdministrator
<#
    Removes the Coralogix OpenTelemetry Collector Windows service installed by
    install-coralogix-collector.ps1, using the vendor uninstaller (-Uninstall).

    The vendor script stops + deletes the `otelcol-contrib` service; no manual
    `sc delete` needed. Does NOT touch the app/IIS or the otel-mssql docker
    container - collector only.

    -RemoveConfig (off by default): also delete the staged config dirs
    (C:\otel and C:\ProgramData\OpenTelemetry\Collector). Leave off if you plan
    to re-install, so the staged config survives.

    Run elevated. From a non-admin shell:
      Start-Process powershell -Verb RunAs -Wait -ArgumentList "-File `"$PWD\uninstall-coralogix-collector.ps1`""
#>
param(
    [switch]$RemoveConfig
)
$ErrorActionPreference = "Stop"

Write-Host "== Before: collector services ==" -ForegroundColor Cyan
Get-Service | Where-Object { $_.Name -match "otel|coralogix" } |
    Select-Object Name, Status, DisplayName | Format-Table -AutoSize

Write-Host "== Step 1: download + run Coralogix uninstaller ==" -ForegroundColor Cyan
$u = 'https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f = Join-Path $env:TEMP "coralogix-otel-collector.ps1"
Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing
& $f -Uninstall

if ($RemoveConfig) {
    Write-Host "== Step 2: remove staged config dirs ==" -ForegroundColor Cyan
    foreach ($d in @("C:\otel", "C:\ProgramData\OpenTelemetry\Collector")) {
        if (Test-Path $d) {
            Remove-Item -Recurse -Force $d
            Write-Host "  removed $d" -ForegroundColor Green
        }
    }
}

Write-Host "== Verify ==" -ForegroundColor Cyan
Start-Sleep -Seconds 2
$remaining = Get-Service | Where-Object { $_.Name -match "otel|coralogix" }
if ($remaining) {
    Write-Warning "Collector service(s) still present:"
    $remaining | Select-Object Name, Status, DisplayName | Format-Table -AutoSize
} else {
    Write-Host "DONE. No otel/coralogix services remain." -ForegroundColor Green
}
