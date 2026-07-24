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

function Get-IISServiceLabelValue {
    <#
    .SYNOPSIS
      Comma-joined distinct IIS service name(s) for the CX_IIS_SERVICES machine env var.

    .DESCRIPTION
      Feeds the machine env var CX_IIS_SERVICES, which the collector's
      transform/iis_service_labels processor (delivered via the remote Fleet config; the repo
      collector YAMLs are the reference template) splits back into an array and stamps onto
      INFRASTRUCTURE telemetry so Coralogix resolves the host's Service ownership.

      ALIGNMENT GUARANTEE: pass the SAME $Map that the caller used to assign each app's
      OTEL_SERVICE_NAME (each record's .ServiceName). Because this formats that identical set,
      every Service-ownership item equals a per-app OTEL_SERVICE_NAME (the APM service name),
      so APM resource correlation can match a single service to the host. When -Map is omitted
      it re-enumerates via Get-IISServiceMap (standalone use), but callers in the deploy path
      MUST pass their pre-built map to keep the guarantee.

      Names are distinct (first-seen order kept) and joined with ','. The collector splits on
      the same comma, so a service name that itself contains a comma (or a double-quote, which
      would also break the OTTL string literal) is NOT supported and would mis-split into
      multiple ownership items - avoid commas/quotes in IIS site names, app paths, and override
      values. Returns '' when no IIS apps are found (the collector's guard then leaves the
      attributes unset).
    #>
    [CmdletBinding()]
    param(
        [object[]]  $Map,
        [hashtable] $Overrides = @{}
    )

    # Re-enumerate only when -Map was NOT supplied at all. An explicitly-passed empty array is
    # honored (returns '') so the caller's map stays authoritative - `-not @()` is $true in
    # PowerShell, which would otherwise silently re-scan and break the alignment guarantee.
    if (-not $PSBoundParameters.ContainsKey('Map')) { $Map = Get-IISServiceMap -Overrides $Overrides }
    $names = @($Map | ForEach-Object { $_.ServiceName } | Where-Object { $_ } | Select-Object -Unique)
    return ($names -join ',')
}

function Set-WebConfigServiceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PhysicalPath,
        [Parameter(Mandatory)][string] $ServiceName,
        # Optional backup/manifest session (from Backup-Config.ps1). When supplied,
        # the web.config is backed up and the edit recorded before it is mutated.
        $Session = $null
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

    # Capture prior state + back up BEFORE mutating, so uninstall removes only what
    # the installer adds (or restores a value that was already present here).
    $existingEnv  = $aspNetCore.SelectSingleNode('environmentVariables')
    $existingNode = if ($existingEnv) { $existingEnv.SelectSingleNode("environmentVariable[@name='OTEL_SERVICE_NAME']") } else { $null }
    $priorValue   = if ($existingNode) { [string]$existingNode.GetAttribute('value') } else { $null }
    if ($Session) {
        Backup-DeployFile    -Session $Session -Path $webConfig | Out-Null
        Record-WebConfigEdit -Session $Session -Path $webConfig -AddedNode (-not $existingNode) -PriorValue $priorValue -SetValue $ServiceName
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

function Remove-WebConfigServiceName {
    <#
      Inverse of Set-WebConfigServiceName - used by Uninstall-Agent.ps1.

      Removes the OTEL_SERVICE_NAME environmentVariable from an app's web.config,
      but ONLY the installer's own entry:
        * If -ExpectedValue is given and the current value does NOT match, the node
          is left untouched (it was hand-set by someone else -> not ours to remove).
        * If -PriorValue is a non-empty string, the node is RESTORED to that value
          instead of deleted (install overwrote a value that was already there).
        * Otherwise the node is deleted; a now-empty <environmentVariables> that we
          would have created is pruned too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PhysicalPath,
        [string] $ExpectedValue,
        [AllowNull()][string] $PriorValue
    )

    if (-not $PhysicalPath) { Write-Warning "  [webconfig] no physical path - skipping."; return $false }
    $webConfig = Join-Path $PhysicalPath 'web.config'
    if (-not (Test-Path $webConfig)) { Write-Warning "  [webconfig] no web.config at '$webConfig' - skipping."; return $false }

    [xml]$xml = Get-Content -LiteralPath $webConfig -Raw
    $aspNetCore = $xml.SelectSingleNode('//aspNetCore')
    if (-not $aspNetCore) { return $true }   # nothing we could have added
    $envVars = $aspNetCore.SelectSingleNode('environmentVariables')
    if (-not $envVars) { return $true }
    $node = $envVars.SelectSingleNode("environmentVariable[@name='OTEL_SERVICE_NAME']")
    if (-not $node) { return $true }

    $cur = [string]$node.GetAttribute('value')
    if ($PSBoundParameters.ContainsKey('ExpectedValue') -and $ExpectedValue -and $cur -ne $ExpectedValue) {
        Write-Warning "  [webconfig] '$webConfig' OTEL_SERVICE_NAME='$cur' != installer value '$ExpectedValue' - leaving (not installer-owned)."
        return $false
    }

    if (-not [string]::IsNullOrEmpty($PriorValue)) {
        [void]$node.SetAttribute('value', $PriorValue)
        Write-Host "  [webconfig] $webConfig -> restored OTEL_SERVICE_NAME=$PriorValue" -ForegroundColor Yellow
    } else {
        [void]$envVars.RemoveChild($node)
        # Prune an <environmentVariables> we created and left empty.
        if (-not $envVars.SelectSingleNode('environmentVariable')) { [void]$aspNetCore.RemoveChild($envVars) }
        Write-Host "  [webconfig] $webConfig -> removed OTEL_SERVICE_NAME" -ForegroundColor Yellow
    }
    $xml.Save($webConfig)
    return $true
}
