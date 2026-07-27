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
  touches installer-owned names (OTEL_*, CORALOGIX_*, CX_ENVIRONMENT) and the
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

$appcmd        = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
$appHostConfig = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
$iisPresent    = Test-Path $appcmd

$status = [ordered]@{
    host              = $env:COMPUTERNAME
    started           = (Get-Date).ToString('s')
    manifestFound     = $false
    iisDeinstrumented = $false
    nodeDeinstrumented = $false
    servicesRemoved   = @()
    envVarsCleared    = @()
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
                Remove-WebConfigServiceName -PhysicalPath $phys -ExpectedValue $w.setValue -PriorValue $w.priorValue | Out-Null
            }
        }
        if ($manifest -and $manifest.poolEnv) {
            foreach ($pe in @($manifest.poolEnv)) {
                if (-not $pe) { continue }
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
            }
            try {
                $svcMap = Get-IISServiceMap
                foreach ($r in @($svcMap)) {
                    if ($r.Scope -eq 'webconfig' -and $r.PhysicalPath) {
                        Remove-WebConfigServiceName -PhysicalPath $r.PhysicalPath | Out-Null
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
    # Guard: manifest flag when available, else best-effort if pm2 is on PATH.
    $nodeWasInstrumented = if ($manifest) { [bool]$manifest.nodeInstrumented } else { [bool](Get-Command pm2 -ErrorAction SilentlyContinue) }
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
    $envNames = @('OTEL_RESOURCE_ATTRIBUTES','CORALOGIX_DOMAIN','CORALOGIX_PRIVATE_KEY','CX_ENVIRONMENT','CX_IIS_SERVICES','CX_NODE_SERVICES')
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
