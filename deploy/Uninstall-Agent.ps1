<#
.SYNOPSIS
  Fleet agent UNINSTALL: reverse what Install-Agent.ps1 did on this host -
  remove the Coralogix collector/supervisor, undo the IIS zero-code
  instrumentation, and clear the machine env vars - using the backup manifest so
  only the installer's OWN changes are touched.

.DESCRIPTION
  The counterpart to Install-Agent.ps1, invoked by uninstall.bat. Reads the most
  recent backup manifest (written by the install run via Backup-Config.ps1) and
  reverses each recorded change surgically:

    1. IIS de-instrumentation (if the host was instrumented):
         - strip the OTEL_SERVICE_NAME the installer wrote into each app web.config
           (value-matched; a hand-set value is left alone; a pre-existing value is
           restored, not deleted);
         - remove the OTEL_* applicationHost.config pool env vars the installer
           added (entries that pre-existed are kept);
         - Unregister-OpenTelemetryForIIS + Uninstall-OpenTelemetryCore (vendor).
    2. Collector/supervisor: vendor installer -Uninstall, then a hard fallback that
         stops + `sc.exe delete`s opampsupervisor / otelcol-contrib if they remain.
    3. Machine env vars: delete the ones the installer created; restore any that had
         a prior value.
    4. -Purge (opt-in): also delete the staged/state dirs and vendor binaries.

  Scope: FLEET ARTIFACTS ONLY. It never removes a hosted application, the demo
  SimpleWebApp site/pool, or any IIS site/pool.

  If no manifest is found, it falls back to a conservative removal that only
  touches installer-owned names (OTEL_*, CORALOGIX_*, CX_ENVIRONMENT, CX_APPLICATION) and the
  known service names.

.PARAMETER Purge
  Also delete C:\otel, C:\ProgramData\OpenTelemetry\Collector,
  C:\ProgramData\opampsupervisor, and the OpenTelemetry Program Files dirs. Off by
  default so a re-install stays fast.

.PARAMETER RestoreConfigs
  Instead of surgical edits, restore applicationHost.config / each web.config /
  the supervisor config.yaml from the backup. The IIS profiler is still
  unregistered and services still removed.

.PARAMETER NoReset
  Skip the final iisreset (recycle manually during a maintenance window).

.PARAMETER InstrumentVersion
  Auto-instrumentation release tag for the vendor module used to Unregister. Falls
  back to the version recorded in the manifest, then this default.

.PARAMETER BackupRoot
  Where to look for the backup manifest. Default: C:\ProgramData\CoralogixDeploy\backups

.NOTES
  Run elevated. Exit code 0 = success (BatchPatch treats non-zero as failure).
#>
[CmdletBinding()]
param(
    [switch] $Purge,
    [switch] $RestoreConfigs,
    [switch] $NoReset,
    [string] $InstrumentVersion = 'v1.16.0-beta.1',
    [string] $BackupRoot        = $null
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$logDir = $here
$transcript = Join-Path $logDir 'uninstall-agent.log'
try { Start-Transcript -Path $transcript -Append | Out-Null } catch {}

. (Join-Path $here 'Backup-Config.ps1')
. (Join-Path $here 'Resolve-IISServiceNames.ps1')
if (Test-Path (Join-Path $here 'Resolve-NodeServiceNames.ps1')) { . (Join-Path $here 'Resolve-NodeServiceNames.ps1') }

# WOW64: %windir%\System32 is redirected to SysWOW64 for a 32-bit process, and
# SysWOW64\inetsrv has appcmd.exe but no applicationHost.config (its config\
# folder holds only Schema\ and Export\). Sysnative is the
# un-redirected view and exists only from WOW64. Same resolver as
# Instrument-IIS.ps1 - see the long comment there for the consequences.
$inetsrv = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    Join-Path $env:windir 'Sysnative\inetsrv'
} else {
    Join-Path $env:windir 'System32\inetsrv'
}
$appcmd        = Join-Path $inetsrv 'appcmd.exe'
$appHostConfig = Join-Path $inetsrv 'config\applicationHost.config'
$iisPresent    = Test-Path $appcmd

$status = [ordered]@{
    host              = $env:COMPUTERNAME
    started           = (Get-Date).ToString('s')
    manifestFound     = $false
    iisDeinstrumented = $false
    nodeDeinstrumented = $false
    servicesRemoved   = @()
    envVarsCleared    = @()
    serviceEnvCleared = @()
    restored          = $false
    purged            = $false
    result            = 'unknown'
    error             = $null
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Uninstall-Agent must run elevated (Administrator)."
    }
}

function Remove-PoolEnvEntry {
    # appcmd removal half of Set-PoolDefaultEnv / Set-PoolEnv.
    param([string] $Pool, [string] $Name)
    if (-not $iisPresent) { return }
    if ($Pool -eq 'applicationPoolDefaults') {
        # applicationPoolDefaults is a singleton element - address it WITHOUT a
        # [name=...] predicate, mirroring the installer's '/+applicationPoolDefaults...'
        # add (a predicate form silently no-ops and leaves the entry behind).
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/-applicationPoolDefaults.environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    } else {
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/-[name='$Pool'].environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    }
    Write-Host "[uninstall] removed pool env: $Pool / $Name"
}

function Get-PoolEnvValueRaw {
    # The current value of an env var on a pool (or on applicationPoolDefaults), or $null.
    param([string] $Pool, [string] $Name)
    if (-not $iisPresent -or -not (Test-Path $appHostConfig)) { return $null }
    try { [xml]$c = Get-Content -LiteralPath $appHostConfig -Raw } catch { return $null }
    $base = if ($Pool -eq 'applicationPoolDefaults') {
        "/configuration/system.applicationHost/applicationPools/applicationPoolDefaults"
    } else {
        "/configuration/system.applicationHost/applicationPools/add[@name='$Pool']"
    }
    $n = $c.SelectSingleNode("$base/environmentVariables/add[@name='$Name']")
    if (-not $n) { return $null }
    return [string]$n.GetAttribute('value')
}

function Set-PoolEnvEntry {
    # Write half of Remove-PoolEnvEntry. Only used to put an app's OWN NODE_OPTIONS flags back
    # after our bootstrap has been stripped out of the merged value.
    param([string] $Pool, [string] $Name, [string] $Value)
    if (-not $iisPresent) { return }
    if ($Pool -eq 'applicationPoolDefaults') {
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/-applicationPoolDefaults.environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/+applicationPoolDefaults.environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
    } else {
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/-[name='$Pool'].environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/+[name='$Pool'].environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
    }
    Write-Host "[uninstall] pool env kept, ours stripped: $Pool / $Name=$Value"
}

function Remove-PoolNodeBootstrap {
    <#
      Strip the iisnode bootstrap out of one pool's NODE_OPTIONS.

      NODE_OPTIONS cannot be handled like the other pool variables, and the difference is not
      cosmetic:

        * Its value is MERGED. Instrument-IIS.ps1 preserves the application's own flags
          (--max-old-space-size, --tls-*, --icu-data-dir) and appends our bootstrap, so deleting
          the entry would silently remove the app's heap ceiling during an uninstall. Nothing
          would report that, and it would surface later as an OOM nobody connects to this.
        * `preexisted` therefore does NOT mean "not ours". For every other variable, a
          pre-existing entry means someone else owns it and uninstall must keep its hands off.
          For NODE_OPTIONS it means the app had flags and we merged into them - skipping it is
          exactly what leaves the bootstrap behind forever, pointing at a register.js that this
          uninstall is about to delete.

      So: recompute the value without our tokens. Empty result -> remove the entry. Non-empty ->
      write the remainder back. Ownership is still enforced, one token at a time, by
      Remove-CxNodeOptionsBootstrap.
    #>
    param([string] $Pool, [string] $InstallPrefix)

    if (-not (Get-Command Remove-CxNodeOptionsBootstrap -ErrorAction SilentlyContinue)) {
        Write-Warning "[uninstall] Resolve-NodeServiceNames.ps1 is missing, so NODE_OPTIONS on pool '$Pool' was left as-is. Remove our --require/--experimental-loader tokens by hand, or the app preloads a bootstrap that is no longer installed."
        return $false
    }
    $current = Get-PoolEnvValueRaw -Pool $Pool -Name 'NODE_OPTIONS'
    if (-not $current) { return $false }

    # Exact targets when the package is still on disk - that covers a vendored or renamed copy
    # under a custom prefix, whose path carries none of the usual markers. When it is already gone
    # (or the prefix is unknown), the marker fallback inside the helper is what recognises it.
    $owned = @()
    if ($InstallPrefix -and (Get-Command Resolve-CxNodeBootstrap -ErrorAction SilentlyContinue)) {
        try {
            $b = Resolve-CxNodeBootstrap -InstallPrefix $InstallPrefix
            $owned = @($b.RegisterPath, $b.HookUrl) | Where-Object { $_ }
        } catch {}
    }
    $cleaned = Remove-CxNodeOptionsBootstrap -Existing $current -OwnedTargets $owned
    if ($cleaned -eq $current) { return $false }   # nothing of ours in there
    if ($cleaned) { Set-PoolEnvEntry  -Pool $Pool -Name 'NODE_OPTIONS' -Value $cleaned }
    else          { Remove-PoolEnvEntry -Pool $Pool -Name 'NODE_OPTIONS' }
    return $true
}

function Remove-InstallerOtlpFromAllPools {
    <#
      Value-matched sweep of the installer's OTLP endpoint/protocol env from
      applicationPoolDefaults AND every pool. IIS copies the applicationPoolDefaults
      <environmentVariables> into a pool the first time that pool gets any env var,
      so copies exist that the manifest never recorded (and get flagged 'preexisted'
      by mistake). Matching on the exact value the installer wrote clears those
      copies without touching a value someone else set.
    #>
    param([hashtable] $NameValue)
    if (-not $iisPresent -or -not (Test-Path $appHostConfig)) { return }
    if (-not $NameValue -or $NameValue.Count -eq 0) { return }
    try { [xml]$c = Get-Content -LiteralPath $appHostConfig -Raw } catch { return }
    $pools = @('applicationPoolDefaults')
    foreach ($add in $c.SelectNodes("/configuration/system.applicationHost/applicationPools/add")) { $pools += [string]$add.name }
    foreach ($pool in $pools) {
        $base = if ($pool -eq 'applicationPoolDefaults') {
            "/configuration/system.applicationHost/applicationPools/applicationPoolDefaults"
        } else {
            "/configuration/system.applicationHost/applicationPools/add[@name='$pool']"
        }
        foreach ($name in $NameValue.Keys) {
            $node = $c.SelectSingleNode("$base/environmentVariables/add[@name='$name']")
            if ($node -and ([string]$node.value -eq [string]$NameValue[$name])) {
                Remove-PoolEnvEntry -Pool $pool -Name $name
            }
        }
    }
}

function Remove-ServiceHard {
    param([string] $Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}
    & sc.exe delete $Name | Out-Null
    Write-Host "[uninstall] sc delete $Name (was $($svc.Status))"
    return $true
}

try {
    Assert-Admin
    Write-Host "=== Coralogix fleet agent UNINSTALL on $($env:COMPUTERNAME) ==="

    if (-not $BackupRoot) { $BackupRoot = Get-DefaultBackupRoot }
    $manifest = Get-LatestManifest -BackupRoot $BackupRoot
    $status.manifestFound = [bool]$manifest
    if ($manifest) { Write-Host "[uninstall] using manifest from $($manifest.dir)" }
    else { Write-Warning "[uninstall] no backup manifest under $BackupRoot - falling back to conservative removal of installer-owned names." }

    $version = $InstrumentVersion
    if ($manifest -and $manifest.instrumentVersion) { $version = $manifest.instrumentVersion }
    $wasInstrumented = if ($manifest) { [bool]$manifest.iisInstrumented } else { $iisPresent }

    # -- 1. IIS de-instrumentation ---------------------------------------------
    if ($RestoreConfigs -and $manifest -and $manifest.files) {
        Write-Host "[uninstall] -RestoreConfigs: restoring backed-up config files"
        foreach ($f in @($manifest.files)) {
            if (-not $f) { continue }
            Restore-DeployFile -Backup $f.backup -Original $f.original | Out-Null
        }
        $status.restored = $true
    }
    elseif ($iisPresent) {
        # Surgical: strip only installer-added web.config + pool env entries.
        if ($manifest -and $manifest.webConfig) {
            foreach ($w in @($manifest.webConfig)) {
                if (-not $w) { continue }
                $phys = Split-Path -Parent $w.path
                # kind says which element carries the name. Absent on manifests written before
                # per-app iisnode naming existed, and those only ever wrote <aspNetCore>.
                if ([string]$w.kind -eq 'appSettings') {
                    Remove-WebConfigAppSettingServiceName -PhysicalPath $phys -ExpectedValue $w.setValue -PriorValue $w.priorValue | Out-Null
                } else {
                    Remove-WebConfigServiceName -PhysicalPath $phys -ExpectedValue $w.setValue -PriorValue $w.priorValue | Out-Null
                }
            }
        }
        if ($manifest -and $manifest.poolEnv) {
            $nodePrefix = if ($manifest.nodeInstallPrefix) { [string]$manifest.nodeInstallPrefix } else { 'C:\cx\otel-node' }
            $nodeOptDone = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($pe in @($manifest.poolEnv)) {
                if (-not $pe) { continue }
                # NODE_OPTIONS first, and regardless of `preexisted` - see Remove-PoolNodeBootstrap
                # for why that flag means something different for a merged value. Once per pool:
                # the manifest carries one entry per write, and re-running the strip is wasted work.
                if ($pe.name -eq 'NODE_OPTIONS') {
                    if ($nodeOptDone.Add([string]$pe.pool)) {
                        Remove-PoolNodeBootstrap -Pool $pe.pool -InstallPrefix $nodePrefix | Out-Null
                    }
                    continue
                }
                if ($pe.preexisted) { Write-Host "[uninstall] keep pre-existing pool env: $($pe.pool) / $($pe.name)"; continue }
                Remove-PoolEnvEntry -Pool $pe.pool -Name $pe.name
            }
            # IIS propagates applicationPoolDefaults env into pools when they are first
            # materialized, so copies of the installer's OTLP endpoint/protocol exist
            # that the manifest never recorded. Sweep them by exact installer value.
            $otlp = @{}
            foreach ($pe in @($manifest.poolEnv)) {
                if ($pe -and ($pe.name -eq 'OTEL_EXPORTER_OTLP_ENDPOINT' -or $pe.name -eq 'OTEL_EXPORTER_OTLP_PROTOCOL')) { $otlp[$pe.name] = $pe.value }
            }
            Remove-InstallerOtlpFromAllPools -NameValue $otlp
        }
        if (-not $manifest) {
            # Fallback: remove installer-owned names from defaults + every pool, and
            # strip OTEL_SERVICE_NAME from each app web.config.
            Remove-PoolEnvEntry -Pool 'applicationPoolDefaults' -Name 'OTEL_EXPORTER_OTLP_ENDPOINT'
            Remove-PoolEnvEntry -Pool 'applicationPoolDefaults' -Name 'OTEL_EXPORTER_OTLP_PROTOCOL'
            $poolNames = @()
            try { $poolNames = & $appcmd list apppool /text:name 2>$null } catch {}
            foreach ($p in $poolNames) {
                if (-not $p) { continue }
                Remove-PoolEnvEntry -Pool $p -Name 'OTEL_SERVICE_NAME'
                Remove-PoolEnvEntry -Pool $p -Name 'OTEL_EXPORTER_OTLP_ENDPOINT'
                Remove-PoolEnvEntry -Pool $p -Name 'OTEL_EXPORTER_OTLP_PROTOCOL'
                # iisnode pools also carry the Node exporter trio and a merged NODE_OPTIONS. The
                # trio is ours outright; NODE_OPTIONS is token-stripped so the app keeps its own
                # flags.
                Remove-PoolEnvEntry -Pool $p -Name 'OTEL_TRACES_EXPORTER'
                Remove-PoolEnvEntry -Pool $p -Name 'OTEL_METRICS_EXPORTER'
                Remove-PoolEnvEntry -Pool $p -Name 'OTEL_LOGS_EXPORTER'
                Remove-PoolNodeBootstrap -Pool $p -InstallPrefix 'C:\cx\otel-node' | Out-Null
            }
            try {
                # -SkipRuntimeClassification on purpose. Uninstall must clean up names written
                # by ANY prior version of the installer, including ones it would no longer
                # write today (before runtime classification, every dedicated-pool app was
                # named - static sites included). Filtering here would strand exactly those.
                # Removal is already ownership-checked by value, so being broad is safe.
                $svcMap = Get-IISServiceMap -SkipRuntimeClassification
                foreach ($r in @($svcMap)) {
                    if ($r.Scope -eq 'webconfig' -and $r.PhysicalPath) {
                        Remove-WebConfigServiceName -PhysicalPath $r.PhysicalPath | Out-Null
                        # And the per-app iisnode name, which lives in <appSettings> instead. The
                        # map is built with -SkipRuntimeClassification here, so there is no
                        # NodeHosting to filter on - the remover is a no-op when the element or the
                        # entry is absent, which is the case for every non-iisnode app.
                        Remove-WebConfigAppSettingServiceName -PhysicalPath $r.PhysicalPath | Out-Null
                    }
                }
            } catch { Write-Warning "[uninstall] could not enumerate IIS apps for web.config cleanup: $_" }
        }
    }

    # Vendor Unregister + core uninstall (profiler registry + core files).
    if ($wasInstrumented) {
        try {
            $moduleUrl = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$version/OpenTelemetry.DotNet.Auto.psm1"
            $modulePath = Join-Path $env:TEMP 'OpenTelemetry.DotNet.Auto.psm1'
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
            Write-Host "[uninstall] downloading auto-instrumentation module $version ..."
            Invoke-WebRequest -Uri $moduleUrl -OutFile $modulePath -UseBasicParsing
            Import-Module $modulePath -Force
            if (Get-Command Unregister-OpenTelemetryForIIS -ErrorAction SilentlyContinue) {
                Write-Host "[uninstall] Unregister-OpenTelemetryForIIS ..."
                if ($NoReset) {
                    try { Unregister-OpenTelemetryForIIS -NoReset } catch { Unregister-OpenTelemetryForIIS }
                } else { Unregister-OpenTelemetryForIIS }
                # The profiler registry cleanup is the load-bearing step; mark done here
                # so an already-removed core (below) doesn't flip the flag back.
                $status.iisDeinstrumented = $true
            }
            if (Get-Command Uninstall-OpenTelemetryCore -ErrorAction SilentlyContinue) {
                Write-Host "[uninstall] Uninstall-OpenTelemetryCore ..."
                # Non-fatal: on a host where the core was already gone this throws
                # "OpenTelemetry Core is already removed" - that is success, not failure.
                try { Uninstall-OpenTelemetryCore } catch { Write-Warning "[uninstall] Uninstall-OpenTelemetryCore: $_" }
            }
        } catch {
            Write-Warning "[uninstall] IIS de-instrumentation (vendor) failed: $_"
        }
    }

    # -- 1b. Node.js / PM2 de-instrumentation ----------------------------------
    # Clear NODE_OPTIONS/OTEL_* off each PM2 app so its workers restart uninstrumented.
    # Guard: manifest flag when available, else best-effort.
    #
    # The best-effort probe deliberately does NOT rest on `Get-Command pm2`: where PM2 is hosted
    # as a Windows service the CLI lives in C:\ProgramData\npm and is routinely off the PATH of
    # the account running uninstall, so that test answers "no PM2 here" on precisely the hosts
    # that have the most of it. Ask the topology instead, and fall back to the PATH check only if
    # the helper is missing from this deploy directory.
    $nodeWasInstrumented = $false
    if ($manifest) {
        $nodeWasInstrumented = [bool]$manifest.nodeInstrumented
    } elseif (Get-Command Get-CxPm2Topology -ErrorAction SilentlyContinue) {
        try { $nodeWasInstrumented = ((Get-CxPm2Topology).Hosting -ne 'none') } catch { }
    } else {
        $nodeWasInstrumented = [bool](Get-Command pm2 -ErrorAction SilentlyContinue)
    }
    if ($nodeWasInstrumented -and (Get-Command Remove-NodeInstrumentation -ErrorAction SilentlyContinue)) {
        try {
            Write-Host "[uninstall] reverting Node.js/PM2 instrumentation ..."
            Remove-NodeInstrumentation
            $status.nodeDeinstrumented = $true
        } catch { Write-Warning "[uninstall] Node/PM2 de-instrumentation failed: $_" }
    }

    # -- 2. Collector / supervisor removal -------------------------------------
    try {
        $u = 'https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
        $f = Join-Path $env:TEMP 'coralogix-otel-collector.ps1'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        Write-Host "[uninstall] downloading + running vendor -Uninstall ..."
        Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing
        & $f -Uninstall
    } catch {
        Write-Warning "[uninstall] vendor -Uninstall failed (will try hard service removal): $_"
    }
    # Hard fallback: the vendor uninstaller does not always remove the supervisor
    # service (misc/uninstall only ever covered otelcol-contrib).
    foreach ($svcName in @('opampsupervisor','otelcol-contrib')) {
        if (Remove-ServiceHard -Name $svcName) { $status.servicesRemoved += $svcName }
    }

    # -- 3. Machine env vars ----------------------------------------------------
    $envNames = @('OTEL_RESOURCE_ATTRIBUTES','CORALOGIX_DOMAIN','CORALOGIX_PRIVATE_KEY','CX_ENVIRONMENT','CX_APPLICATION','CX_IIS_SERVICES','CX_NODE_SERVICES','CX_IISNODE_SERVICES','CX_DOTNET_SERVICES','CX_SERVICES')
    if ($manifest -and $manifest.envVars) {
        foreach ($e in @($manifest.envVars)) {
            if (-not $e) { continue }
            if ($e.added) {
                [Environment]::SetEnvironmentVariable($e.name, $null, 'Machine')
                Write-Host "[uninstall] deleted machine env $($e.name)"
            } else {
                [Environment]::SetEnvironmentVariable($e.name, $e.priorValue, 'Machine')
                Write-Host "[uninstall] restored machine env $($e.name) to prior value"
            }
            $status.envVarsCleared += $e.name
        }
        # Not every variable reaches the manifest: CX_SERVICES is written by Install-Agent.ps1 without a
        # -Session, and Instrument-DotNetService.ps1 has no Session parameter at all, so the manifest has
        # nothing to reverse for them. Worse, CX_DOTNET_SERVICES is written as a UNION with its previous
        # value, so a name left behind here outlives the uninstall and keeps accumulating across every
        # later reinstall - the host permanently claims ownership of software that is gone. Sweep
        # whatever the manifest did not cover.
        $covered = @(@($manifest.envVars) | Where-Object { $_ } | ForEach-Object { $_.name })
        foreach ($n in $envNames) {
            if ($covered -contains $n) { continue }
            if ([Environment]::GetEnvironmentVariable($n, 'Machine')) {
                [Environment]::SetEnvironmentVariable($n, $null, 'Machine')
                Write-Host "[uninstall] deleted machine env $n (not recorded in the manifest)"
                $status.envVarsCleared += $n
            }
        }
    } else {
        foreach ($n in $envNames) {
            if ([Environment]::GetEnvironmentVariable($n, 'Machine')) {
                [Environment]::SetEnvironmentVariable($n, $null, 'Machine')
                Write-Host "[uninstall] deleted machine env $n"
                $status.envVarsCleared += $n
            }
        }
    }

    # -- 4. Purge (opt-in) ------------------------------------------------------
    if ($Purge) {
        $dirs = @(
            'C:\otel',
            (Join-Path $env:ProgramData 'OpenTelemetry\Collector'),
            (Join-Path $env:ProgramData 'opampsupervisor'),
            (Join-Path ${env:ProgramFiles} 'OpenTelemetry OpAMP Supervisor'),
            (Join-Path ${env:ProgramFiles} 'OpenTelemetry Collector'),
            (Join-Path ${env:ProgramFiles} 'OpenTelemetry .NET AutoInstrumentation')
        )
        # BEFORE deleting anything: clear the per-service environment entries that POINT INTO these
        # directories. Instrument-DotNetService.ps1 and Instrument-NodeService.ps1 write CORECLR_* /
        # DOTNET_STARTUP_HOOKS / NODE_OPTIONS into the service's own Environment REG_MULTI_SZ under
        # HKLM\SYSTEM\CurrentControlSet\Services\<name>, and Unregister-OpenTelemetryForIIS only ever
        # covers W3SVC and WAS. Leaving them behind is not a telemetry problem: a missing profiler DLL
        # merely stops instrumentation, but a DOTNET_STARTUP_HOOKS pointing at a deleted assembly is
        # fatal at CLR bootstrap, so the service stops STARTING - a purge would brick every .NET service
        # this agent had instrumented.
        #
        # Ownership-checked: entries are removed only when a path-bearing value resolves under a
        # directory this purge is about to delete. A service instrumented by something else keeps its
        # own configuration.
        # Includes the bitness-specific PATH names the service instrumenter now writes: the CLR
        # prefers *_PATH_64, so one left behind pointing into a removed payload is not cosmetic.
        $ourSvcNames = @('CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH',
                         'CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_32',
                         'COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH',
                         'COR_PROFILER_PATH_64','COR_PROFILER_PATH_32',
                         'OTEL_DOTNET_AUTO_HOME','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE',
                         'DOTNET_STARTUP_HOOKS','OTEL_DOTNET_AUTO_PLUGINS','NODE_OPTIONS',
                         'OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_SERVICE_NAME')
        $ownedRoots = @(@($dirs) + @('C:\cx')) | Where-Object { $_ }
        foreach ($svcKey in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
            $lines = $null
            try { $lines = @((Get-ItemProperty -LiteralPath $svcKey.PSPath -Name 'Environment' -ErrorAction Stop).Environment) } catch { continue }
            if (-not $lines -or -not $lines.Count) { continue }

            $isOurs = $false
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $eq = $line.IndexOf('=')
                if ($eq -lt 1) { continue }
                if ($ourSvcNames -notcontains $line.Substring(0, $eq)) { continue }
                $val = $line.Substring($eq + 1)
                foreach ($root in $ownedRoots) {
                    if ($val -and $val.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isOurs = $true; break }
                }
                if ($isOurs) { break }
            }
            if (-not $isOurs) { continue }

            # Written as a unit, so removed as a unit - a half-cleared set is what leaves a service
            # with a profiler enabled and no DLL to load.
            $keep = @()
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $eq = $line.IndexOf('=')
                if ($eq -lt 1) { $keep += $line; continue }
                if ($ourSvcNames -notcontains $line.Substring(0, $eq)) { $keep += $line }
            }
            $svcName = Split-Path -Leaf $svcKey.Name
            try {
                if ($keep.Count) {
                    Set-ItemProperty -LiteralPath $svcKey.PSPath -Name 'Environment' -Value ([string[]]$keep) -Type MultiString -ErrorAction Stop
                } else {
                    Remove-ItemProperty -LiteralPath $svcKey.PSPath -Name 'Environment' -ErrorAction Stop
                }
                Write-Host "[uninstall] cleared OTel environment entries from service '$svcName' ($($lines.Count - $keep.Count) removed, $($keep.Count) kept)"
                $status.serviceEnvCleared += $svcName
            } catch {
                Write-Warning "[uninstall] could not clear OTel environment entries from service '$svcName' - it may fail to start once the purge deletes the profiler: $_"
            }
        }

        foreach ($d in $dirs) {
            if (Test-Path $d) {
                try { Remove-Item -LiteralPath $d -Recurse -Force; Write-Host "[uninstall] removed $d" }
                catch { Write-Warning "[uninstall] could not remove $d : $_" }
            }
        }
        $status.purged = $true
    } else {
        Write-Host "[uninstall] keeping staged config + binaries (pass -Purge to delete them)."
    }

    # -- Recycle IIS so workers drop the profiler / env changes -----------------
    if ($iisPresent -and -not $NoReset) {
        Write-Host "[uninstall] iisreset ..."
        try { & iisreset.exe | Out-String | Write-Host } catch { Write-Warning "[uninstall] iisreset failed: $_" }
        Write-Host "[uninstall] W3SVC status: $((Get-Service W3SVC -ErrorAction SilentlyContinue).Status)"
    }

    $status.result = 'success'
    Write-Host "=== uninstall done: iisDeinstrumented=$($status.iisDeinstrumented) nodeDeinstrumented=$($status.nodeDeinstrumented) services=[$($status.servicesRemoved -join ',')] purged=$($status.purged) restored=$($status.restored) ==="
}
catch {
    $status.result = 'error'
    $status.error  = $_.Exception.Message
    Write-Error $_
}
finally {
    $status.finished = (Get-Date).ToString('s')
    try { $status | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $logDir 'uninstall-agent-status.json') -Encoding utf8 } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

if ($status.result -eq 'error') { exit 1 } else { exit 0 }
