#Requires -RunAsAdministrator
<#
    Deploys the SimpleWebApp Razor Pages app to IIS.
    Steps:
      1. Ensure .NET 8 ASP.NET Core Hosting Bundle is installed (ASP.NET Core 8 runtime + ANCM v2).
      2. Copy publish output to C:\inetpub\SimpleWebApp.
      3. Create a "No Managed Code" app pool + website bound to port 8080.
      4. iisreset so the ANCM module loads, then start the site.
    Re-runnable: existing pool/site are removed and recreated.
#>
param(
    [string]$PublishSource = "$PSScriptRoot\publish",
    [string]$SitePath      = "C:\inetpub\SimpleWebApp",
    [string]$SiteName      = "SimpleWebApp",
    [string]$AppPool       = "SimpleWebAppPool",
    [int]   $Port          = 8080
)

$ErrorActionPreference = "Stop"
$ancm = "C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"

Write-Host "== Step 1: ASP.NET Core 8 Hosting Bundle ==" -ForegroundColor Cyan
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

Write-Host "== Step 2: Copy publish output ==" -ForegroundColor Cyan
if (-not (Test-Path "$PublishSource\SimpleWebApp.dll")) { throw "Publish output not found at $PublishSource. Run 'dotnet publish' first." }
New-Item -ItemType Directory -Force -Path $SitePath | Out-Null
Copy-Item "$PublishSource\*" $SitePath -Recurse -Force
Write-Host "  Copied to $SitePath" -ForegroundColor Green

Write-Host "== Step 3: IIS app pool + site ==" -ForegroundColor Cyan
Import-Module WebAdministration

if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName }
if (Test-Path "IIS:\AppPools\$AppPool") { Remove-WebAppPool -Name $AppPool }

New-WebAppPool -Name $AppPool | Out-Null
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name managedRuntimeVersion -Value ""   # No Managed Code
New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $AppPool -Port $Port | Out-Null

# App-pool identity needs read/execute on the content folder.
icacls $SitePath /grant "IIS AppPool\${AppPool}:(OI)(CI)RX" /T | Out-Null
Write-Host "  Site '$SiteName' on port $Port, pool '$AppPool' (No Managed Code)." -ForegroundColor Green

Write-Host "== Step 4: iisreset + start ==" -ForegroundColor Cyan
iisreset | Out-Null
Start-Website -Name $SiteName
Start-Sleep -Seconds 2

Write-Host "== Verify ==" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 15
    Write-Host "  GET / -> HTTP $($r.StatusCode)" -ForegroundColor Green
    if ($r.Content -match "IIS Instrumentation Test") { Write-Host "  Heading found in response. OK." -ForegroundColor Green }
    $h = Invoke-WebRequest "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 15
    Write-Host "  GET /health -> $($h.Content)" -ForegroundColor Green
    Write-Host ""
    Write-Host "SUCCESS. Open http://localhost:$Port/ in a browser." -ForegroundColor Green
} catch {
    Write-Warning "Request failed: $($_.Exception.Message)"
    Write-Warning "502.5 => runtime/bundle issue; 500.19 => web.config/module. Check C:\inetpub\logs."
    throw
}
