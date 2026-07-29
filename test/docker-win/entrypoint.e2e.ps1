<#
.SYNOPSIS
  Provision a realistically-shaped IIS host, then wait. Nothing else.

.DESCRIPTION
  This entrypoint deliberately does LESS than the other harnesses'. It does not
  instrument anything, does not set CX_IIS_SERVICES, and does not start a
  collector - because all of that is what Run-E2ELoop.ps1 drives through
  deploy.bat, and a harness that pre-did the work would be testing itself.

  It builds nine IIS shapes. Each one exists because it is handled somewhere in
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
    9. brownfield         + /admin: two apps sharing a pool that ALREADY declares its
                          own <environmentVariables> before the agent is installed.
                          A pool's own block REPLACES applicationPoolDefaults, so this
                          pool never sees the OTLP endpoint set there and exports
                          nowhere while the defaults read as correct
                          (POOL_LOST_INHERITANCE). Instrument-IIS.ps1 must stamp the
                          OTLP vars directly onto it

  Shapes 10-14 exist for RUNTIME CLASSIFICATION. "No Managed Code" is a property of
  the app POOL, not of the application, so the pool setting on its own says nothing
  about whether .NET auto-instrumentation applies. Each of these is a case the
  installer used to get wrong or could plausibly get wrong:

   10. defaults-core      ASP.NET Core whose <application> omits applicationPool, so
                          the pool resolves from <sites><applicationDefaults> - i.e.
                          DefaultAppPool, whose managedRuntimeVersion attribute is
                          ABSENT and therefore defaults to v4.0. Pins two things at
                          once: the applicationDefaults resolution path (which shape 1
                          can no longer carry, now that it is correctly left
                          uninstrumented) and Core-on-a-managed-CLR-pool, which is
                          still named and still claimed, with a warning
   11. staticwc           a web.config that exists but declares only <staticContent>.
                          Kills the "web.config exists therefore .NET" heuristic
   12. arrproxy           a <rewrite> rule proxying to a backend on localhost:5000.
                          NOT instrumentable from IIS: the pool's environment never
                          reaches that separate process, so the backend has to be
                          instrumented where it runs
   13. oop-core           ASP.NET Core with hostingModel="outofprocess". Looks like 12
                          - IIS forwards to a dotnet process - but the ASP.NET Core
                          Module launches that process as a CHILD of w3wp, so it DOES
                          inherit the pool environment and IS instrumented normally.
                          The deliberate opposite verdict to 12
   14. binonly            managed assemblies in bin\ and no web.config. Ambiguous on
                          purpose: static sites carry stray bin folders and an
                          out-of-process publish puts DLLs in the app root, so this
                          must report RUNTIME_UNKNOWN_NEEDS_OVERRIDE rather than guess

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

# WebAdministration cannot edit an app pool's environmentVariables collection, so the
# one shape that needs a pre-existing entry (9, brownfield) uses appcmd - the same tool
# the deploy scripts use. 64-bit container, so System32 needs no Sysnative dance.
$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'

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

function New-OopCoreWebConfig {
    <#
      ASP.NET Core, out-of-process hosting: the module starts dotnet.exe as a CHILD of w3wp
      and reverse-proxies to it. Superficially the same picture as an ARR proxy (shape 12) and
      the opposite verdict, because a child process inherits the app pool's environment - so
      the profiler and OTEL_* variables reach it and it instruments normally.
    #>
    param([string] $Path)
    Set-Content -Path (Join-Path $Path 'web.config') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="outofprocess" />
  </system.webServer>
</configuration>
'@
}

function New-StaticWebConfig {
    <#
      A web.config with no runtime configuration at all - only static-content settings. Very
      common on asset/CDN-origin sites. The trap it exists to catch: "this app has a
      web.config, therefore it is a .NET app".
    #>
    param([string] $Path)
    Set-Content -Path (Join-Path $Path 'web.config') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <staticContent>
      <mimeMap fileExtension=".woff2" mimeType="font/woff2" />
    </staticContent>
    <defaultDocument>
      <files><add value="index.html" /></files>
    </defaultDocument>
  </system.webServer>
</configuration>
'@
}

function New-ArrProxyWebConfig {
    <#
      URL Rewrite reverse proxy to a backend process. NOTE: the URL Rewrite module is not
      installed in this container, so IIS itself would refuse to serve this site (500.19).
      That does not matter here - classification parses the FILE, and no phase requests this
      site. What is being pinned is the verdict, not the response.
    #>
    param([string] $Path)
    Set-Content -Path (Join-Path $Path 'web.config') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="proxy-to-backend" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://localhost:5000/{R:1}" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
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

# -- 9. brownfield + /admin: shared pool that ALREADY owns an env block --------
# The pool is given a non-OTEL environment variable HERE, i.e. before the agent is
# ever installed - the shape of a real host where someone set a connection string
# on the pool (exactly what misc\wire-db.ps1 does). That first write makes IIS
# materialise an <environmentVariables> block on the pool, and from then on the pool
# REPLACES applicationPoolDefaults instead of merging with it. The OTLP endpoint the
# installer later writes to the defaults therefore never reaches this pool: the
# defaults read as perfectly correct and the apps export nowhere.
#
# Two apps on purpose, so the pool is SHARED and takes the web.config naming path -
# the branch that used to skip pool env entirely. Run-E2ELoop.ps1 asserts the OTLP
# vars land on the pool anyway, and that they are written ONCE despite two apps.
New-CorePool 'BrownfieldPool'
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/+[name='BrownfieldPool'].environmentVariables.[name='CX_TEST_PREEXISTING',value='set-before-the-agent']" `
    /commit:apphost | Out-Null
New-Content "$wwwroot\brownfield" 'brownfield'
New-CoreWebConfig "$wwwroot\brownfield"
if (-not (Test-Path 'IIS:\Sites\brownfield')) {
    New-Website -Name 'brownfield' -Port 8085 -PhysicalPath "$wwwroot\brownfield" -ApplicationPool 'BrownfieldPool' | Out-Null
}
$bfAdmin = "$wwwroot\brownfield-admin"
New-Content $bfAdmin 'brownfield admin'
New-CoreWebConfig $bfAdmin
if (-not (Get-WebApplication -Site 'brownfield' -Name 'admin' -ErrorAction SilentlyContinue)) {
    New-WebApplication -Site 'brownfield' -Name 'admin' -PhysicalPath $bfAdmin -ApplicationPool 'BrownfieldPool' | Out-Null
}

# -- 11. staticwc: a web.config, but nothing .NET in it -----------------------
New-CorePool 'staticwc'          # No Managed Code pool, and still not instrumentable
New-Content "$wwwroot\staticwc" 'static assets'
New-StaticWebConfig "$wwwroot\staticwc"
if (-not (Test-Path 'IIS:\Sites\staticwc')) {
    New-Website -Name 'staticwc' -Port 8086 -PhysicalPath "$wwwroot\staticwc" -ApplicationPool 'staticwc' | Out-Null
}

# -- 12. arrproxy: IIS reverse-proxies to a backend process -------------------
# The pool's environment does NOT reach a process IIS merely forwards HTTP to, so
# instrumenting this pool would achieve nothing. Contrast with shape 13.
New-CorePool 'arrproxy'
New-Content "$wwwroot\arrproxy" 'arr proxy'
New-ArrProxyWebConfig "$wwwroot\arrproxy"
if (-not (Test-Path 'IIS:\Sites\arrproxy')) {
    New-Website -Name 'arrproxy' -Port 8087 -PhysicalPath "$wwwroot\arrproxy" -ApplicationPool 'arrproxy' | Out-Null
}

# -- 13. oop-core: ASP.NET Core, out-of-process hosting -----------------------
New-CorePool 'oop-core'
New-Content "$wwwroot\oop-core" 'oop core'
New-OopCoreWebConfig "$wwwroot\oop-core"
if (-not (Test-Path 'IIS:\Sites\oop-core')) {
    New-Website -Name 'oop-core' -Port 8088 -PhysicalPath "$wwwroot\oop-core" -ApplicationPool 'oop-core' | Out-Null
}

# -- 14. binonly: managed assemblies, no web.config ---------------------------
# Deliberately ambiguous. Promoting this to "Framework" would be a guess, and a wrong
# guess puts a name into CX_IIS_SERVICES that nothing ever reports under.
New-CorePool 'binonly'
New-Content "$wwwroot\binonly" 'bin only'
New-Item -ItemType Directory -Path "$wwwroot\binonly\bin" -Force | Out-Null
Set-Content -Path "$wwwroot\binonly\bin\App.dll" -Encoding utf8 -Value 'not a real assembly - presence is the signal'
if (-not (Test-Path 'IIS:\Sites\binonly')) {
    New-Website -Name 'binonly' -Port 8089 -PhysicalPath "$wwwroot\binonly" -ApplicationPool 'binonly' | Out-Null
}

# -- 10. defaults-core: Core app, pool resolved from <sites><applicationDefaults> --
# New-Website always writes an explicit applicationPool, so clear the attribute afterwards
# with appcmd. That reproduces the stock Default Web Site's shape - the one that is true on
# nearly every real host - but on an app that IS .NET, so the resolution path stays pinned
# by a positive assertion now that shape 1 is (correctly) left uninstrumented.
#
# DefaultAppPool's managedRuntimeVersion attribute is absent, which IIS reads as v4.0, so this
# app is also the Core-on-a-managed-CLR case: named, claimed, and warned about.
New-Content "$wwwroot\defaults-core" 'defaults core'
New-CoreWebConfig "$wwwroot\defaults-core"
if (-not (Test-Path 'IIS:\Sites\defaults-core')) {
    New-Website -Name 'defaults-core' -Port 8091 -PhysicalPath "$wwwroot\defaults-core" | Out-Null
}
& $appcmd set config -section:system.applicationHost/sites `
    "/[name='defaults-core'].[path='/'].applicationPool:" /commit:apphost | Out-Null

# -- 1. Default Web Site: left exactly as the base image made it --------------
# Untouched ON PURPOSE. It omits applicationPool and inherits it from
# <sites><applicationDefaults>, and it is static (wwwroot ships iisstart.htm and no
# web.config), which makes it the regression pin for the over-claim this matrix exists
# to catch: it must NOT be named and must NOT appear in CX_IIS_SERVICES.

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
