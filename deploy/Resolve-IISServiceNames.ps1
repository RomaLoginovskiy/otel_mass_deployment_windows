<#
.SYNOPSIS
  Enumerate every IIS site + application on the local host and resolve a distinct
  OpenTelemetry service name for each, deciding the scope at which the name must be set.

.DESCRIPTION
  Dot-source this file to expose two functions used by the instrumentation scripts:

    Get-IISServiceMap       - pure enumeration + naming (no side effects). Returns one
                              record per IIS application.
    Set-WebConfigServiceName - writes OTEL_SERVICE_NAME into an app's web.config
                              (ASP.NET Core in-process / ANCM mechanism).

  Naming convention (site + app path):
    * Root application of a site  -> the site name                      (e.g. "Wallet")
    * Nested application at /path -> "<SiteName><path>"                  (e.g. "Wallet/api")
  This mirrors the auto-instrumentation fallback "SiteName\VirtualDir" but uses a clean
  forward slash and is set explicitly per app.

  Scope decision (per app):
    * A pool serving exactly ONE application -> Scope = 'pool'
      The name is durable on the app pool's environment variables.
    * A pool serving MORE THAN ONE application -> Scope = 'webconfig'
      A single pool-level env var cannot distinguish co-hosted apps, so the name is
      written into each application's own web.config instead.

  Overrides: a hashtable keyed by the auto-derived service name ("Wallet", "Wallet/api")
  whose value is the desired replacement name. Applied after auto-naming, before the
  scope tally (so a rename never changes which pool an app belongs to).

.NOTES
  Requires the WebAdministration module (IIS management tools). Run elevated.
#>

function Get-IISServiceMap {
    [CmdletBinding()]
    param(
        [hashtable] $Overrides = @{}
    )

    Import-Module WebAdministration -ErrorAction Stop

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($site in Get-Website) {
        $siteName = $site.Name

        # Root application (virtual path '/') is the site itself; Get-WebApplication
        # below returns only the NON-root applications.
        $rootPhys = ''
        try { $rootPhys = [Environment]::ExpandEnvironmentVariables([string]$site.physicalPath) } catch {}
        $records.Add([pscustomobject]@{
            Site         = $siteName
            AppPath      = '/'
            Pool         = [string]$site.applicationPool
            ServiceName  = $siteName
            PhysicalPath = $rootPhys
            Scope        = $null   # filled in by the pool tally below
        })

        foreach ($app in (Get-WebApplication -Site $siteName)) {
            $appPath = [string]$app.path            # e.g. '/api'
            $phys    = [string]$app.PhysicalPath
            if (-not $phys) {
                # Fallback: physical path lives on the app's root virtual directory.
                $vdir = Get-WebVirtualDirectory -Site $siteName -Application $appPath.TrimStart('/') -Name '/' -ErrorAction SilentlyContinue
                if ($vdir) { $phys = [string]$vdir.PhysicalPath }
            }
            try { $phys = [Environment]::ExpandEnvironmentVariables($phys) } catch {}

            $records.Add([pscustomobject]@{
                Site         = $siteName
                AppPath      = $appPath
                Pool         = [string]$app.applicationPool
                ServiceName  = "$siteName$appPath"   # 'Wallet' + '/api' -> 'Wallet/api'
                PhysicalPath = $phys
                Scope        = $null
            })
        }
    }

    # Apply overrides keyed by the auto-derived service name.
    if ($Overrides -and $Overrides.Count -gt 0) {
        foreach ($r in $records) {
            if ($Overrides.ContainsKey($r.ServiceName)) {
                $r.ServiceName = [string]$Overrides[$r.ServiceName]
            }
        }
    }

    # Tally applications per pool, then stamp the scope on each record.
    $poolCounts = @{}
    foreach ($r in $records) {
        if ($poolCounts.ContainsKey($r.Pool)) { $poolCounts[$r.Pool]++ }
        else { $poolCounts[$r.Pool] = 1 }
    }
    foreach ($r in $records) {
        $r.Scope = if ($poolCounts[$r.Pool] -eq 1) { 'pool' } else { 'webconfig' }
    }

    return $records
}

function Set-WebConfigServiceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PhysicalPath,
        [Parameter(Mandatory)][string] $ServiceName
    )

    if (-not $PhysicalPath) {
        Write-Warning "  [webconfig] no physical path for '$ServiceName' - skipping."
        return $false
    }
    $webConfig = Join-Path $PhysicalPath 'web.config'
    if (-not (Test-Path $webConfig)) {
        Write-Warning "  [webconfig] no web.config at '$webConfig' - skipping '$ServiceName'."
        return $false
    }

    [xml]$xml = Get-Content -LiteralPath $webConfig -Raw

    # <aspNetCore> may sit directly under <system.webServer> or inside a <location>
    # element (the publish output wraps it in <location path="." ...>). Match anywhere.
    $aspNetCore = $xml.SelectSingleNode('//aspNetCore')
    if (-not $aspNetCore) {
        Write-Warning "  [webconfig] no <aspNetCore> in '$webConfig' (classic ASP.NET Framework?) - skipping. For Framework apps set OTEL_SERVICE_NAME via <appSettings> instead."
        return $false
    }

    $envVars = $aspNetCore.SelectSingleNode('environmentVariables')
    if (-not $envVars) {
        $envVars = $xml.CreateElement('environmentVariables')
        [void]$aspNetCore.AppendChild($envVars)
    }

    $node = $envVars.SelectSingleNode("environmentVariable[@name='OTEL_SERVICE_NAME']")
    if (-not $node) {
        $node = $xml.CreateElement('environmentVariable')
        [void]$node.SetAttribute('name', 'OTEL_SERVICE_NAME')
        [void]$envVars.AppendChild($node)
    }
    [void]$node.SetAttribute('value', $ServiceName)

    $xml.Save($webConfig)
    Write-Host "  [webconfig] $webConfig -> OTEL_SERVICE_NAME=$ServiceName" -ForegroundColor Green
    return $true
}
