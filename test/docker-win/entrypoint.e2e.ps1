<#
.SYNOPSIS
  Provision a realistically-shaped IIS host, then wait. Nothing else.

.DESCRIPTION
  This entrypoint deliberately does LESS than the other harnesses'. It does not
  instrument anything, does not set CX_IIS_SERVICES, and does not start a
  collector - because all of that is what Run-E2ELoop.ps1 drives through
  deploy.bat, and a harness that pre-did the work would be testing itself.

  It builds eight IIS shapes. Each one exists because it is handled somewhere in
  the deploy code and has never been exercised end to end:

    1. Default Web Site   stock; omits applicationPool, so the pool resolves from
                          <sites><applicationDefaults> - true on nearly every real
                          host and the single worst thing to get wrong
    2. shop               dedicated pool, ASP.NET Core, plain <aspNetCore>
                          -> name goes on the POOL
    3. shop/api           nested application with its OWN pool
                          -> name is "shop/api", not "shop"
    4. shared + /api      two applications sharing ONE pool: the pool cannot carry
       + /admin           two different names, so each name must land in web.config
    5. legacy             ASP.NET FRAMEWORK pool (managedRuntimeVersion=v4.0).
                          Set-WebConfigServiceName refuses these (no <aspNetCore>),
                          so this app is expected to end up UNNAMED - the point is
                          that the run degrades with a reason instead of failing
    6. wrapped            <aspNetCore> nested inside <location path="."> - the shape
                          `dotnet publish` actually emits, which is why the code
                          matches //aspNetCore rather than a direct child path
    7. nocfg              shared pool AND no web.config: nowhere to put a name at
                          all. Must degrade cleanly, not crash the run
    8. shop/assets        a virtual DIRECTORY, not an application. Must NOT get its
                          own service name

  Logging variants are left at the IIS default here; Run-E2ELoop.ps1 mutates them
  through break-state.ps1 so each case is attributable to one change.

.NOTES
  Runs as ContainerAdministrator, so the elevation-gated paths execute without an
  interactive UAC prompt.
#>
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration -ErrorAction Stop

$wwwroot = 'C:\sites'
New-Item -ItemType Directory -Path $wwwroot -Force | Out-Null

function New-CoreWebConfig {
    <# The plain shape: <aspNetCore> directly under <system.webServer>. #>
    param([string] $Path)
    Set-Content -Path (Join-Path $Path 'web.config') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
  </system.webServer>
</configuration>
'@
}

function New-WrappedWebConfig {
    <#
      What `dotnet publish` emits: the whole system.webServer block wrapped in
      <location path="." inheritInChildApplications="false">. A reader that looks
      for /configuration/system.webServer/aspNetCore finds nothing here.
    #>
    param([string] $Path)
    Set-Content -Path (Join-Path $Path 'web.config') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
      </handlers>
      <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
    </system.webServer>
  </location>
</configuration>
'@
}

function New-FrameworkWebConfig {
    <# Classic ASP.NET: no <aspNetCore> node anywhere. #>
    param([string] $Path)
    Set-Content -Path (Join-Path $Path 'web.config') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.web>
    <compilation targetFramework="4.8" />
  </system.web>
</configuration>
'@
}

function New-Content {
    param([string] $Path, [string] $Title)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -Path (Join-Path $Path 'index.html') -Encoding utf8 -Value "<html><body><h1>$Title</h1></body></html>"
}

function New-CorePool {
    param([string] $Name)
    if (-not (Test-Path "IIS:\AppPools\$Name")) { New-WebAppPool -Name $Name | Out-Null }
    # '' is "No Managed Code", which ASP.NET Core REQUIRES. An absent attribute
    # means "inherit v4.0", which is not the same thing.
    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion -Value ''
}

Write-Host '[e2e] provisioning IIS shapes...'

# -- 2. shop: dedicated pool, Core -------------------------------------------
New-CorePool 'shop'
New-Content "$wwwroot\shop" 'shop'
New-CoreWebConfig "$wwwroot\shop"
if (-not (Test-Path 'IIS:\Sites\shop')) {
    New-Website -Name 'shop' -Port 8081 -PhysicalPath "$wwwroot\shop" -ApplicationPool 'shop' | Out-Null
}

# -- 3. shop/api: nested application, its own pool ---------------------------
New-CorePool 'shop-api'
New-Content "$wwwroot\shop-api" 'shop api'
New-CoreWebConfig "$wwwroot\shop-api"
if (-not (Get-WebApplication -Site 'shop' -Name 'api' -ErrorAction SilentlyContinue)) {
    New-WebApplication -Site 'shop' -Name 'api' -PhysicalPath "$wwwroot\shop-api" -ApplicationPool 'shop-api' | Out-Null
}

# -- 8. shop/assets: a virtual DIRECTORY, not an application -----------------
# Must not be named as an app: it has no pool of its own and shares the parent's
# process, so giving it a service name would invent an app that does not exist.
New-Content "$wwwroot\shop-assets" 'shop assets'
if (-not (Get-WebVirtualDirectory -Site 'shop' -Name 'assets' -ErrorAction SilentlyContinue)) {
    New-WebVirtualDirectory -Site 'shop' -Name 'assets' -PhysicalPath "$wwwroot\shop-assets" | Out-Null
}

# -- 4. shared + /api + /admin on ONE pool ------------------------------------
New-CorePool 'SharedPool'
New-Content "$wwwroot\shared" 'shared'
New-CoreWebConfig "$wwwroot\shared"
if (-not (Test-Path 'IIS:\Sites\shared')) {
    New-Website -Name 'shared' -Port 8082 -PhysicalPath "$wwwroot\shared" -ApplicationPool 'SharedPool' | Out-Null
}
foreach ($sub in 'api', 'admin') {
    $p = "$wwwroot\shared-$sub"
    New-Content $p "shared $sub"
    New-CoreWebConfig $p
    if (-not (Get-WebApplication -Site 'shared' -Name $sub -ErrorAction SilentlyContinue)) {
        New-WebApplication -Site 'shared' -Name $sub -PhysicalPath $p -ApplicationPool 'SharedPool' | Out-Null
    }
}

# -- 5. legacy: ASP.NET Framework pool ----------------------------------------
if (-not (Test-Path 'IIS:\AppPools\legacy')) { New-WebAppPool -Name 'legacy' | Out-Null }
Set-ItemProperty 'IIS:\AppPools\legacy' -Name managedRuntimeVersion -Value 'v4.0'
New-Content "$wwwroot\legacy" 'legacy'
New-FrameworkWebConfig "$wwwroot\legacy"
if (-not (Test-Path 'IIS:\Sites\legacy')) {
    New-Website -Name 'legacy' -Port 8083 -PhysicalPath "$wwwroot\legacy" -ApplicationPool 'legacy' | Out-Null
}

# -- 6. wrapped: <aspNetCore> inside <location path="."> ----------------------
New-CorePool 'wrapped'
New-Content "$wwwroot\wrapped" 'wrapped'
New-WrappedWebConfig "$wwwroot\wrapped"
if (-not (Test-Path 'IIS:\Sites\wrapped')) {
    New-Website -Name 'wrapped' -Port 8084 -PhysicalPath "$wwwroot\wrapped" -ApplicationPool 'wrapped' | Out-Null
}

# -- 7. nocfg: shared pool, NO web.config -------------------------------------
# Deliberately no web.config: on a shared pool there is then nowhere at all to put
# a per-app name. The run must degrade with a reason, not throw.
New-Content "$wwwroot\nocfg" 'nocfg'
if (-not (Get-WebApplication -Site 'shared' -Name 'nocfg' -ErrorAction SilentlyContinue)) {
    New-WebApplication -Site 'shared' -Name 'nocfg' -PhysicalPath "$wwwroot\nocfg" -ApplicationPool 'SharedPool' | Out-Null
}

# -- 1. Default Web Site: left exactly as the base image made it --------------
# Untouched ON PURPOSE. It omits applicationPool and inherits it from
# <sites><applicationDefaults>, which is the case that broke the doctor once and
# would break it silently on nearly every real host.

Write-Host '[e2e] sites:'
Get-Website | Select-Object Name, ID, State, PhysicalPath | Format-Table -AutoSize | Out-String | Write-Host
Write-Host '[e2e] applications:'
Get-WebApplication | Select-Object Path, ApplicationPool, PhysicalPath | Format-Table -AutoSize | Out-String | Write-Host

# Deliberately NOT done here: instrumentation, CX_IIS_SERVICES, collector install.
# Run-E2ELoop.ps1 does all of it through deploy.bat.
Write-Host '[e2e] IIS provisioned. NOT instrumented, no collector - that is deploy.bat''s job.'
Write-Host '[alive]'

# Hold the container open. W3SVC keeps running; the loop drives everything else
# from outside via docker exec.
while ($true) { Start-Sleep -Seconds 3600 }
