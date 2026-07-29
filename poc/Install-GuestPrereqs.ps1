<#
.SYNOPSIS
  Runs INSIDE a throwaway Windows Server guest: install everything the full-matrix E2E needs so
  every workload shape in the matrix can actually run and emit telemetry. Idempotent.

.DESCRIPTION
  Configure-Guest.ps1 gets a guest to the point where the agent can be deployed (IIS + ASP.NET +
  WinRM). This goes further, because the matrix needs the RUNTIMES the shapes are made of:

    IIS + ASP.NET 4.8 + .NET 3.5      the four CLR/framework combinations under test
    ASP.NET Core hosting bundles 8+6  side-by-side Core majors, in-process and out-of-process
    URL Rewrite + ARR                 the "IIS reverse-proxies to a Node app" shape, which is the
                                      real SGA architecture and reports on the Node side
    Node.js + pm2 + node-windows      PM2 per-user, PM2 as a service, and Node as a plain service
    otel-dotnet                       the .NET auto-instrumentation the deploy scripts register

  Everything that can be staged from the host is COPIED IN rather than downloaded, for reasons
  measured earlier in this project:

    * `npm install` on a Server SKU fails intermittently with an OpenSSL AES-GCM cipher fault, so
      node_modules (pm2, node-windows/winsw) is baked on the host and copied.
    * .NET's Invoke-WebRequest fails on some Server images with "The decryption operation failed",
      while curl.exe fetches the same URL fine - so anything that must be downloaded uses curl.exe.

  What is NOT installed here: the Coralogix agent. That is the thing under test and it arrives via
  deploy.bat, exactly as it would on a fleet host.

.PARAMETER Stage
  Directory in the guest holding the copied-in assets (node.zip, npm-global, otel-dotnet.zip,
  the app fixtures). Default C:\cx-stage.

.PARAMETER SkipDownloads
  Do not fetch anything from the internet. IIS/.NET 3.5 (Windows features) and anything already
  staged still get installed; the hosting bundles and ARR are reported as skipped so the matrix can
  mark the shapes that need them as unverified rather than silently passing.

.NOTES
  POC scaffolding for a DISPOSABLE guest. It enables Windows features, installs runtimes, creates
  local accounts and services. Never run it on a real host.
#>
[CmdletBinding()]
param(
    [string] $Stage = 'C:\cx-stage',
    [switch] $SkipDownloads
)

$ErrorActionPreference = 'Continue'
$report = [ordered]@{}

function Say { param([string] $M) Write-Host "[prereq] $M" }

function Get-File {
    <#
      curl.exe, not Invoke-WebRequest: on some Server images the .NET stack fails these downloads
      with "The decryption operation failed, see inner exception" while curl.exe succeeds against
      the same URL. curl.exe ships with Windows Server 2019+.
    #>
    param([string] $Url, [string] $OutFile)

    if (Test-Path -LiteralPath $OutFile) { return $true }
    if ($SkipDownloads) { return $false }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { return $false }
    & $curl -sSL --retry 3 --retry-delay 5 -o $OutFile $Url 2>&1 | Out-Null
    return (Test-Path -LiteralPath $OutFile)
}

function Install-Silent {
    param([string] $Path, [string[]] $Arguments)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

if (-not (Test-Path $Stage)) { New-Item -ItemType Directory -Path $Stage -Force | Out-Null }
$dl = Join-Path $Stage 'downloads'
if (-not (Test-Path $dl)) { New-Item -ItemType Directory -Path $dl -Force | Out-Null }

# ---- 1. IIS + ASP.NET 4.8 + .NET 3.5 + WinRM ----------------------------------
# Web-Asp-Net45 is the Framework 4.x pipeline (the 'legacy' and Framework-4.8 shapes).
# NET-Framework-Core is .NET 3.5, which is what makes a managedRuntimeVersion=v2.0 pool a real
# CLR-2 pool rather than a pool that simply fails to start - the matrix asserts a clean refusal
# there, and that is only meaningful if CLR 2 is actually present.
Say 'IIS + ASP.NET 4.8 + .NET 3.5 features'
$features = @('Web-Server','Web-Asp-Net45','Web-Net-Ext45','Web-Mgmt-Console','Web-Mgmt-Tools',
              'Web-Http-Logging','Web-Request-Monitor','Web-Windows-Auth','NET-Framework-45-ASPNET',
              'NET-Framework-Core','NET-Framework-Features')
$featResult = @{}
foreach ($f in $features) {
    try {
        $st = Get-WindowsFeature -Name $f -ErrorAction Stop
        if (-not $st) { $featResult[$f] = 'unknown'; continue }
        if ($st.Installed) { $featResult[$f] = 'present'; continue }
        $r = Install-WindowsFeature -Name $f -ErrorAction Stop
        $featResult[$f] = if ($r.Success) { 'installed' } else { 'failed' }
    } catch { $featResult[$f] = "error: $($_.Exception.Message)" }
}
$report['features'] = $featResult

# .NET 3.5 needs its payload; on an EVAL ISO-installed guest the feature may need the source or an
# online fetch. Report rather than fail: only the CLR-2 refusal shape depends on it.
try {
    $net35 = Get-WindowsFeature -Name 'NET-Framework-Core' -ErrorAction Stop
    if (-not $net35.Installed) {
        Say '.NET 3.5 not installed by feature call; trying DISM online'
        & dism.exe /online /enable-feature /featurename:NetFx3 /all /quiet /norestart 2>&1 | Out-Null
    }
    $report['net35'] = [bool](Get-WindowsFeature -Name 'NET-Framework-Core').Installed
} catch { $report['net35'] = "error: $($_.Exception.Message)" }

# Installing .NET 3.5 gives the box a CLR 2 runtime, but it does NOT map *.aspx to ASP.NET 2.0 in
# IIS. Without that mapping a v2.0 app pool serves an .aspx file as a static request that has no
# handler, and IIS answers 404 - which looks like a missing file rather than an unregistered
# framework. aspnet_regiis is what creates the handler mapping, and it only exists once 3.5 is in.
try {
    $regiis = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v2.0.50727\aspnet_regiis.exe'
    if (Test-Path $regiis) {
        Say 'registering ASP.NET 2.0 handler mappings (aspnet_regiis -i -enable)'
        & $regiis -i -enable 2>&1 | Out-Null
        $report['aspnet20'] = if ($LASTEXITCODE -eq 0) { 'registered' } else { "aspnet_regiis exit $LASTEXITCODE" }
    } else {
        $report['aspnet20'] = 'aspnet_regiis not present (no CLR 2 on this host)'
    }
} catch { $report['aspnet20'] = "error: $($_.Exception.Message)" }

# ---- 2. WinRM / firewall (so the loop can also use WinRM if guestcontrol misbehaves) ----
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management','File and Printer Sharing' -ErrorAction SilentlyContinue
    New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $report['winrm'] = 'configured'
} catch { $report['winrm'] = "error: $($_.Exception.Message)" }

# ---- 3. ASP.NET Core hosting bundles: 8 and 6 side by side ---------------------
# The hosting bundle installs the runtime AND the ASP.NET Core Module (ANCM) that IIS needs. Both
# majors are installed so the matrix can prove the profiler attaches across two Core versions on
# one host - a real fleet host rarely runs a single version.
$bundles = @(
    @{ Name = 'aspnetcore-8';  Url = 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.14/dotnet-hosting-8.0.14-win.exe' }
    @{ Name = 'aspnetcore-6';  Url = 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/6.0.36/dotnet-hosting-6.0.36-win.exe' }
)
$bundleResult = @{}
foreach ($b in $bundles) {
    $exe = Join-Path $dl "$($b.Name).exe"
    if (-not (Get-File -Url $b.Url -OutFile $exe)) { $bundleResult[$b.Name] = 'download-unavailable'; continue }
    Say "installing $($b.Name) hosting bundle"
    $code = Install-Silent -Path $exe -Arguments @('/quiet','/norestart','OPT_NO_RUNTIME=0','OPT_NO_SHAREDFX=0')
    # 0 = installed, 3010 = success + reboot required, 1638 = a newer version is already there.
    $bundleResult[$b.Name] = switch ($code) { 0 { 'installed' } 3010 { 'installed-reboot-pending' } 1638 { 'already-newer' } default { "exit $code" } }
}
$report['hostingBundles'] = $bundleResult

# ANCM has to be visible to IIS or every Core shape 500s with no telemetry, which would look like
# an instrumentation failure. Restart IIS after the bundles land and record the module list.
try {
    & iisreset.exe /restart 2>&1 | Out-Null
    $mods = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list module 2>&1
    $report['ancm'] = [bool](($mods -join ' ') -match 'AspNetCoreModuleV2')
} catch { $report['ancm'] = "error: $($_.Exception.Message)" }

try { $report['dotnetRuntimes'] = @(& dotnet --list-runtimes 2>&1 | ForEach-Object { "$_" }) } catch { $report['dotnetRuntimes'] = @() }

# ---- 4. URL Rewrite + ARR (the IIS -> Node proxy shape) ------------------------
# Order matters: ARR's installer requires URL Rewrite to be present first.
$arrParts = @(
    @{ Name = 'urlrewrite'; Url = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' }
    @{ Name = 'arr';        Url = 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi' }
)
$arrResult = @{}
foreach ($p in $arrParts) {
    $msi = Join-Path $dl "$($p.Name).msi"
    if (-not (Get-File -Url $p.Url -OutFile $msi)) { $arrResult[$p.Name] = 'download-unavailable'; continue }
    Say "installing $($p.Name)"
    $code = Install-Silent -Path (Join-Path $env:SystemRoot 'System32\msiexec.exe') -Arguments @('/i', "`"$msi`"", '/quiet', '/norestart')
    $arrResult[$p.Name] = if ($code -eq 0 -or $code -eq 3010) { 'installed' } else { "exit $code" }
}
$report['arr'] = $arrResult
try {
    $mods = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list module 2>&1
    $report['rewriteModule'] = [bool](($mods -join ' ') -match 'RewriteModule')
} catch { $report['rewriteModule'] = 'unknown' }

# ---- 5. Node.js + pm2 + node-windows (copied in, never npm-installed here) -----
$nodeDir = 'C:\nodejs'
$nodeZip = Join-Path $Stage 'node.zip'
if (-not (Test-Path (Join-Path $nodeDir 'node.exe'))) {
    if (Test-Path $nodeZip) {
        Say 'expanding node.zip'
        $tmp = Join-Path $Stage 'node-unzip'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -LiteralPath $nodeZip -DestinationPath $tmp -Force
        # The archive contains a single versioned top-level directory.
        $inner = @(Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1)
        if ($inner.Count) { Move-Item -LiteralPath $inner[0].FullName -Destination $nodeDir -Force }
        else { Move-Item -LiteralPath $tmp -Destination $nodeDir -Force }
    }
}
$report['node'] = if (Test-Path (Join-Path $nodeDir 'node.exe')) { (& (Join-Path $nodeDir 'node.exe') --version 2>&1 | Select-Object -First 1) } else { 'missing' }

# pm2 / node-windows come from the staged npm-global tree. A pm2 CLI SHIM is written rather than
# relying on the copied .cmd: CreateProcess cannot launch a .ps1, and a pm2.cmd that points at the
# host's paths would break - the deploy scripts resolve pm2 by looking for a runnable command.
$npmGlobal = 'C:\npm-global'
if ((Test-Path (Join-Path $Stage 'npm-global')) -and -not (Test-Path (Join-Path $npmGlobal 'node_modules\pm2'))) {
    Say 'copying npm-global (pm2, node-windows) into place'
    Copy-Item -LiteralPath (Join-Path $Stage 'npm-global') -Destination $npmGlobal -Recurse -Force
}
if ((Test-Path (Join-Path $npmGlobal 'node_modules\pm2\bin\pm2')) -and -not (Test-Path (Join-Path $npmGlobal 'pm2.cmd'))) {
    Set-Content -LiteralPath (Join-Path $npmGlobal 'pm2.cmd') -Encoding Ascii -Value @(
        '@ECHO OFF',
        'SETLOCAL',
        'SET "PATH=C:\nodejs;%PATH%"',
        '"C:\nodejs\node.exe" "C:\npm-global\node_modules\pm2\bin\pm2" %*'
    )
}
$report['pm2'] = if (Test-Path (Join-Path $npmGlobal 'pm2.cmd')) { 'present' } else { 'missing' }
$report['nodeWindows'] = if (Test-Path (Join-Path $npmGlobal 'node_modules\node-windows')) { 'present' } else { 'missing' }

# PATH for interactive/service use. Machine scope, because the services under test are not started
# from this session.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($p in @($nodeDir, $npmGlobal)) {
    if ($machinePath -notlike "*$p*") { $machinePath = "$machinePath;$p" }
}
[Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
$env:Path = "$env:Path;$nodeDir;$npmGlobal"

# ---- 6. otel-dotnet auto-instrumentation payload ------------------------------
# Staged, not downloaded: the deploy scripts install it from here, and a guest that cannot reach
# GitHub would otherwise fail the whole matrix for an unrelated reason.
$otelZip = Join-Path $Stage 'otel-dotnet.zip'
$report['otelDotnetZip'] = if (Test-Path $otelZip) { 'staged' } else { 'missing' }

# ---- 7. summary --------------------------------------------------------------
$report['iisRunning'] = [bool]((Get-Service W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running')
$report['stage'] = $Stage
[pscustomobject]$report | ConvertTo-Json -Depth 5 -Compress
