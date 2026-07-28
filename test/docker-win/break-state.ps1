<#
.SYNOPSIS
  Deliberately break (or inspect, or restore) one aspect of the container's IIS /
  instrumentation state, so Run-DoctorTest.ps1 can assert the doctor notices.

.DESCRIPTION
  Baked into the diagnostics test image and invoked via `docker exec`. Keeping the
  mutations here rather than as inline `docker exec powershell -Command "..."`
  strings makes the test harness readable, keeps the appcmd quoting in one place,
  and avoids shipping fragile escaped one-liners through two shells.

  DESTRUCTIVE BY DESIGN, and only ever safe because the container is disposable.
  Never run this anywhere else.

.PARAMETER Case
  inspect            dump the pool env model (defaults + each pool's own block)
  clearIisServices   remove the machine CX_IIS_SERVICES
  staleIisServices   set CX_IIS_SERVICES to a value matching no app
  restoreIisServices recompute CX_IIS_SERVICES from the live IIS layout
  poolManagedRuntime put an ASP.NET Core app's pool back on managed runtime v4.0
  restorePoolRuntime undo poolManagedRuntime
  poolEnvStale       change applicationPoolDefaults so pools' own copies go stale
  profilerMalformed  write an Environment REG_MULTI_SZ containing an empty entry
  profilerStalePath  register a profiler whose DLL path does not exist
  profilerClear      remove the W3SVC Environment value entirely
  logDirCustom       point a site's access logs at a non-default directory
  restoreLogDir      undo logDirCustom
  logFormatIis       switch a site from W3C to the IIS log format
  logDisabled        turn access logging off for a site
  logCentralW3C      switch the host to central W3C logging
  restoreLogCentral  undo logCentralW3C
  clearLogSlots      remove the machine CX_IIS_LOG_DIR_n slots
  webConfigRemove    delete a site's web.config entirely
  webConfigMalformed replace a site's web.config with XML that does not parse
  webConfigInherit   rewrite a site's web.config so <aspNetCore> is NOT wrapped in
                     <location inheritInChildApplications="false">, i.e. it flows
                     into child applications
  webConfigRestore   put back the location-wrapped ASP.NET Core web.config
  childNoWebConfig   add a child application under a site with NO web.config
  removeChildApp     undo childNoWebConfig (leave the site single-app again)

.PARAMETER Site
  Which site the log and web.config cases act on. Default: shop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('inspect','clearIisServices','staleIisServices','restoreIisServices',
                 'poolManagedRuntime','restorePoolRuntime','poolEnvStale',
                 'profilerMalformed','profilerStalePath','profilerClear',
                 'logDirCustom','restoreLogDir','logFormatIis','logDisabled',
                 'logCentralW3C','restoreLogCentral','clearLogSlots',
                 'webConfigRemove','webConfigMalformed','webConfigInherit',
                 'webConfigRestore','childNoWebConfig','removeChildApp')]
    [string] $Case,
    [string] $Pool = 'shop',
    [string] $Site = 'shop',
    [string] $LogDir = 'C:\iislogs\custom'
)
$ErrorActionPreference = 'Continue'

$appcmd  = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
$section = '-section:system.applicationHost/applicationPools'
$commit  = '/commit:apphost'
$appHost = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
$w3svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC'

function Set-DefaultEnv {
    param([string] $Name, [string] $Value)
    # Remove-then-add: appcmd has no "update" for a collection element.
    & $appcmd set config $section "/-applicationPoolDefaults.environmentVariables.[name='$Name']" $commit 2>$null | Out-Null
    & $appcmd set config $section "/+applicationPoolDefaults.environmentVariables.[name='$Name',value='$Value']" $commit | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  appcmd add exited $LASTEXITCODE" }
}

function Set-PoolEnvVar {
    param([string] $PoolName, [string] $Name, [string] $Value)
    & $appcmd set config $section "/-[name='$PoolName'].environmentVariables.[name='$Name']" $commit 2>$null | Out-Null
    & $appcmd set config $section "/+[name='$PoolName'].environmentVariables.[name='$Name',value='$Value']" $commit | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  appcmd add exited $LASTEXITCODE" }
}

switch ($Case) {

    'inspect' {
        [xml]$x = Get-Content -LiteralPath $appHost -Raw
        $r = $x.SelectSingleNode('/configuration/system.applicationHost/applicationPools')
        Write-Host 'DEFAULTS:'
        $d = $r.SelectSingleNode('applicationPoolDefaults')
        foreach ($e in @($d.SelectNodes('environmentVariables/add'))) {
            Write-Host ('   {0}={1}' -f $e.GetAttribute('name'), $e.GetAttribute('value'))
        }
        foreach ($p in @($r.SelectNodes('add'))) {
            $n = $p.GetAttribute('name')
            $b = $p.SelectSingleNode('environmentVariables')
            if ($b) {
                Write-Host ("POOL {0} (own block):" -f $n)
                foreach ($e in @($b.SelectNodes('add'))) {
                    Write-Host ('   {0}={1}' -f $e.GetAttribute('name'), $e.GetAttribute('value'))
                }
            } else {
                Write-Host ("POOL {0}: inherits defaults (no own block)" -f $n)
            }
        }
        Write-Host ("CX_IIS_SERVICES={0}" -f [Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine'))
    }

    'clearIisServices'   { [Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $null, 'Machine'); Write-Host 'cleared CX_IIS_SERVICES' }
    'staleIisServices'   { [Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', 'ghost-service', 'Machine'); Write-Host 'set CX_IIS_SERVICES=ghost-service' }

    'restoreIisServices' {
        . C:\cx\deploy\Resolve-IISServiceNames.ps1
        $m = Get-IISServiceMap
        $v = Get-IISServiceLabelValue -Map $m
        [Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $v, 'Machine')
        Write-Host "restored CX_IIS_SERVICES=$v"
    }

    'poolManagedRuntime' {
        Import-Module WebAdministration
        Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedRuntimeVersion -Value 'v4.0'
        Write-Host "pool '$Pool' managedRuntimeVersion=v4.0 (wrong for ASP.NET Core)"
    }
    'restorePoolRuntime' {
        Import-Module WebAdministration
        Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedRuntimeVersion -Value ''
        Write-Host "pool '$Pool' back to No Managed Code"
    }

    'poolEnvStale' {
        # A pool's own <environmentVariables> REPLACES applicationPoolDefaults, and
        # IIS materialises the defaults into that block the first time appcmd writes
        # any var to the pool. The copy never refreshes - so changing the default
        # afterwards leaves every already-instrumented pool on the old value.
        #
        # The value must DIFFER from what the installer wrote, or there is no drift to
        # find. This used to set 127.0.0.1 because the shipped default was
        # `localhost`; now the installer writes 127.0.0.1 itself, so that would be a
        # no-op and F5 would silently assert nothing. Use a different port instead -
        # nothing listens on 4319, which is also true to the failure being modelled.
        Set-DefaultEnv -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value 'http://127.0.0.1:4319'
        Write-Host 'applicationPoolDefaults endpoint -> http://127.0.0.1:4319 (pools keep their old snapshot)'
    }

    'profilerMalformed' {
        # An empty element in this REG_MULTI_SZ prevents IIS from starting.
        Set-ItemProperty -Path $w3svcKey -Name Environment -Type MultiString -Value @(
            'CORECLR_ENABLE_PROFILING=1'
            'CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}'
            ''
        )
        Write-Host 'W3SVC Environment now contains an empty element'
    }

    'profilerStalePath' {
        Set-ItemProperty -Path $w3svcKey -Name Environment -Type MultiString -Value @(
            'CORECLR_ENABLE_PROFILING=1'
            'CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}'
            'CORECLR_PROFILER_PATH_64=C:\nope\gone.dll'
            'OTEL_DOTNET_AUTO_HOME=C:\nope'
        )
        Write-Host 'W3SVC profiler points at a non-existent DLL'
    }

    'profilerClear' {
        Remove-ItemProperty -Path $w3svcKey -Name Environment -ErrorAction SilentlyContinue
        Write-Host 'W3SVC Environment removed'
    }

    # ---- IIS access-log placement ------------------------------------------
    # The collector ships ONE include glob (C:\inetpub\logs\LogFiles\W3SVC*\*.log).
    # These cases move the logs out from under it, which on a real host means the
    # site's access logs silently never reach Coralogix.

    'logDirCustom' {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        & $appcmd set site "/site.name:$Site" "/logFile.directory:$LogDir" $commit | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "  appcmd exited $LASTEXITCODE" }
        Write-Host "site '$Site' now logs to $LogDir"
    }

    'restoreLogDir' {
        & $appcmd set site "/site.name:$Site" '/logFile.directory:%SystemDrive%\inetpub\logs\LogFiles' $commit | Out-Null
        Write-Host "site '$Site' log directory restored to the IIS default"
    }

    'logFormatIis' {
        # The receiver's csv_parser keys off a W3C '#Fields:' header line. The IIS
        # format has no header at all, so the lines arrive unparsed.
        & $appcmd set site "/site.name:$Site" '/logFile.logFormat:IIS' $commit | Out-Null
        Write-Host "site '$Site' now logs in IIS format"
    }

    'logDisabled' {
        & $appcmd set site "/site.name:$Site" '/logFile.enabled:false' $commit | Out-Null
        Write-Host "access logging disabled for site '$Site'"
    }

    'logCentralW3C' {
        # One file for the whole host, written straight into the directory with no
        # per-site W3SVC<id> subfolder - so per-site attribution is gone.
        & $appcmd set config '-section:system.applicationHost/log' '/centralLogFileMode:CentralW3C' $commit | Out-Null
        & $appcmd set config '-section:system.applicationHost/log' '/centralW3CLogFile.directory:C:\iislogs\central' $commit | Out-Null
        Write-Host 'host switched to central W3C logging -> C:\iislogs\central'
    }

    'restoreLogCentral' {
        & $appcmd set config '-section:system.applicationHost/log' '/centralLogFileMode:Site' $commit | Out-Null
        Write-Host 'host restored to per-site logging'
    }

    'clearLogSlots' {
        foreach ($n in 1..3) {
            [Environment]::SetEnvironmentVariable("CX_IIS_LOG_DIR_$n", $null, 'Machine')
            Set-Item -Path "env:CX_IIS_LOG_DIR_$n" -Value '' -ErrorAction SilentlyContinue
        }
        [Environment]::SetEnvironmentVariable('CX_IIS_LOG_DIRS', $null, 'Machine')
        Write-Host 'cleared CX_IIS_LOG_DIR_1..3 and CX_IIS_LOG_DIRS'
    }

    # ---- web.config presence / shape ---------------------------------------
    # "no web.config" and "web.config cannot be read" are different answers and
    # must not collapse into one finding: the stock Default Web Site has no
    # web.config at all, so conflating them reported an ACL problem on every host.

    'webConfigRemove' {
        $p = "C:\inetpub\$Site\web.config"
        if (Test-Path -LiteralPath $p) { [IO.File]::Delete($p) }
        Write-Host "removed $p"
    }

    'webConfigMalformed' {
        # Unclosed tag: [xml] throws, which is the 'unreadable' branch. A real host
        # reaches this via a half-written deploy - and IIS itself 500.19s on it.
        Set-Content -LiteralPath "C:\inetpub\$Site\web.config" -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <aspNetCore processPath="dotnet"
'@
        Write-Host "site '$Site' web.config is now malformed XML"
    }

    'webConfigInherit' {
        # No <location> wrapper, so <system.webServer> flows into child applications.
        # `dotnet publish` emits inheritInChildApplications="false" to prevent exactly
        # this; a hand-written config often does not.
        Set-Content -LiteralPath "C:\inetpub\$Site\web.config" -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
  </system.webServer>
</configuration>
'@
        Write-Host "site '$Site' web.config now INHERITS <aspNetCore> into child apps"
    }

    'webConfigRestore' {
        Set-Content -LiteralPath "C:\inetpub\$Site\web.config" -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
    </system.webServer>
  </location>
</configuration>
'@
        Write-Host "site '$Site' web.config restored (location-wrapped, non-inheriting)"
    }

    'childNoWebConfig' {
        Import-Module WebAdministration
        $p = "C:\inetpub\$Site\child"
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        Set-Content -LiteralPath "$p\index.html" -Value '<h1>child</h1>' -Encoding utf8
        if (-not (Get-WebApplication -Site $Site -Name 'child' -ErrorAction SilentlyContinue)) {
            New-WebApplication -Site $Site -Name 'child' -PhysicalPath $p -ApplicationPool $Site | Out-Null
        }
        Write-Host "added application '$Site/child' with no web.config"
    }

    'removeChildApp' {
        # Must be undone: a second app on the pool flips Resolve-IISServiceNames
        # from pool scope to web.config scope, which would move later cases'
        # expected service names out from under them.
        Import-Module WebAdministration
        if (Get-WebApplication -Site $Site -Name 'child' -ErrorAction SilentlyContinue) {
            Remove-WebApplication -Site $Site -Name 'child'
        }
        Write-Host "removed application '$Site/child'"
    }
}
