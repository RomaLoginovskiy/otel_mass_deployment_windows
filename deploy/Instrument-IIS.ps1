<#
.SYNOPSIS
  Configure zero-code (no-code) OpenTelemetry .NET auto-instrumentation for IIS,
  fleet-wide, and point every app pool at the local collector.

.DESCRIPTION
  Follows docs/iis-instrumentation.md Part 3/4. Runs only on hosts where IIS was
  detected (the orchestrator gates this). Steps:
    1. Download OpenTelemetry.DotNet.Auto.psm1, Import-Module, Install-OpenTelemetryCore,
       Register-OpenTelemetryForIIS  (STRICT order - the register step fails if run
       before core files are in place).
    2. Set the OTLP endpoint host-wide via applicationPoolDefaults environment
       variables (so all pools inherit it) - the fleet-friendly "set once" pattern.
       Pools that declare their own <environmentVariables> do NOT inherit and are
       written explicitly in step 2b (see .NOTES).
    2b. Enumerate every IIS site + application and assign each a distinct
       OTEL_SERVICE_NAME derived from the site name + app path (see
       Resolve-IISServiceNames.ps1). Dedicated pools get the name on the pool; apps
       that share a pool get it in their own web.config.
    3. Recycle IIS so workers pick up the new environment.

  IMPORTANT: This requires Windows PowerShell 5.1 (NOT PowerShell 7) for the
  .NET auto-instrumentation module.

.PARAMETER Version
  Auto-instrumentation release tag. Default: v1.16.0-beta.1 (matches the runbook;
  bump to the current release from the project's releases page).

.PARAMETER OtlpEndpoint
  Local collector OTLP HTTP endpoint. Default: http://127.0.0.1:4318

  Deliberately the IPv4 literal, not `localhost`. The collector's receivers bind
  ${env:OTEL_LISTEN_INTERFACE:-127.0.0.1}, and on a dual-stack host `localhost`
  resolves to ::1 first - nothing listens there and the export is dropped with no
  exporter error to show for it. A `localhost` value passed here is rewritten (see
  Resolve-CxOtlpEndpoint in Write-DeployLog.ps1) rather than honored.

.PARAMETER NoReset
  Pass -NoReset to Register-OpenTelemetryForIIS and skip the final iisreset (recycle
  manually later, e.g. during a maintenance window).

.PARAMETER ServiceNameOverrides
  Optional hashtable to rename specific apps, keyed by the auto-derived service name
  (e.g. @{ 'Wallet/api' = 'wallet-api' }). Merged over the JSON file if both are given.

.PARAMETER OverridesJson
  Optional path to a JSON file of the same { autoName = overrideName } shape.

.NOTES
  Run elevated. The host-wide OTLP vars are set on <applicationPoolDefaults>, which
  only reaches pools that do not declare their own <environmentVariables> collection -
  a pool's own block REPLACES the defaults, it does not merge with them. Every pool
  that has (or gets) its own block is therefore written explicitly:

    * dedicated pool  - gets a block the moment OTEL_SERVICE_NAME is written to it
    * shared pool     - gets the OTLP vars only if it ALREADY had a block (e.g. a
                        connection string added before install). Writing to a clean
                        shared pool would create a block and break its inheritance,
                        so those are deliberately left inheriting.
#>
[CmdletBinding()]
param(
    [string]    $Version              = 'v1.16.0-beta.1',
    [string]    $OtlpEndpoint          = 'http://127.0.0.1:4318',
    [switch]    $NoReset,
    # Pre-staged copies, for hosts that cannot reach GitHub: an outbound proxy, an
    # air-gapped network, or a TLS stack that cannot complete the download (Windows
    # Server Core containers fail the archive fetch with "The decryption operation
    # failed" while curl.exe on the same box succeeds).
    #
    # Both also read an env var, so a fleet can stage the files once and set the
    # variables machine-wide instead of threading flags through deploy.bat.
    #   -LocalArchive / CX_OTEL_DOTNET_ARCHIVE  the *-windows.zip release archive,
    #                                           passed to Install-OpenTelemetryCore
    #                                           -LocalPath
    #   -LocalModule  / CX_OTEL_DOTNET_MODULE   OpenTelemetry.DotNet.Auto.psm1
    [string]    $LocalArchive          = $env:CX_OTEL_DOTNET_ARCHIVE,
    [string]    $LocalModule           = $env:CX_OTEL_DOTNET_MODULE,
    [hashtable] $ServiceNameOverrides  = @{},
    [string]    $OverridesJson,
    # Optional backup/manifest session (from Backup-Config.ps1, created by the
    # orchestrator). When supplied, mutated configs are backed up and recorded so
    # Uninstall-Agent.ps1 can reverse only the installer's own changes.
    $Session = $null
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run elevated (Administrator)."
    }
}

Assert-Admin

if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Warning "The .NET auto-instrumentation module requires Windows PowerShell 5.1, not PowerShell $($PSVersionTable.PSVersion). Re-run under 'powershell.exe'."
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Optional backup/manifest recording (shared session from the orchestrator).
$backupHelper = Join-Path $PSScriptRoot 'Backup-Config.ps1'
if (Test-Path $backupHelper) { . $backupHelper }

# Normalize a `localhost` endpoint to the IPv4 literal before it is written anywhere.
# Guarded because the helper is optional in a hand-assembled deploy directory; the
# param default is already correct, so a missing helper only loses the rewrite for an
# operator who passed `localhost` explicitly (the doctor still warns in that case).
$logHelper = Join-Path $PSScriptRoot 'Write-DeployLog.ps1'
if (Test-Path $logHelper) { . $logHelper }
if (Get-Command Resolve-CxOtlpEndpoint -ErrorAction SilentlyContinue) {
    $OtlpEndpoint = Resolve-CxOtlpEndpoint -Endpoint $OtlpEndpoint
}

# ---- 1. Install the auto-instrumentation module (STRICT order) ----------------
$module_url    = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$Version/OpenTelemetry.DotNet.Auto.psm1"
$download_path = Join-Path $env:TEMP 'OpenTelemetry.DotNet.Auto.psm1'

if ($LocalModule -and (Test-Path -LiteralPath $LocalModule)) {
    $download_path = $LocalModule
    Write-Host "[iis-instr] using pre-staged module: $LocalModule"
} else {
    # A leftover, still-locked temp file from an interrupted earlier run makes this
    # fail with "the process cannot access the file", which reads like a permissions
    # problem and is not. Clear it first.
    if (Test-Path -LiteralPath $download_path) {
        Remove-Item -LiteralPath $download_path -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[iis-instr] downloading auto-instrumentation module $Version ..."
    Invoke-WebRequest -Uri $module_url -OutFile $download_path -UseBasicParsing
}

Import-Module $download_path -Force
Write-Host "[iis-instr] Install-OpenTelemetryCore ..."
if ($LocalArchive) {
    # -LocalPath makes the vendor module install from a pre-staged archive instead
    # of downloading it. Fail loudly on a bad path rather than silently falling
    # back to the download an air-gapped host cannot do.
    if (-not (Test-Path -LiteralPath $LocalArchive)) {
        throw "LocalArchive not found: $LocalArchive (from -LocalArchive or CX_OTEL_DOTNET_ARCHIVE)"
    }
    Write-Host "[iis-instr] installing from pre-staged archive: $LocalArchive"
    Install-OpenTelemetryCore -LocalPath $LocalArchive
} else {
    Install-OpenTelemetryCore
}

# Snapshot the CLR-profiler registry (REG_MULTI_SZ Environment) BEFORE the vendor
# register writes it, and mark the run as IIS-instrumented in the manifest.
if ($Session) {
    Backup-RegistryKey -Session $Session -Path 'HKLM\SYSTEM\CurrentControlSet\Services\W3SVC' | Out-Null
    Backup-RegistryKey -Session $Session -Path 'HKLM\SYSTEM\CurrentControlSet\Services\WAS'   | Out-Null
    $Session.Manifest.iisInstrumented   = $true
    $Session.Manifest.instrumentVersion = $Version
}

Write-Host "[iis-instr] Register-OpenTelemetryForIIS ..."
if ($NoReset) { Register-OpenTelemetryForIIS -NoReset } else { Register-OpenTelemetryForIIS }

# ---- 2. Host-wide OTLP endpoint via applicationPoolDefaults -------------------
# WOW64. In a 32-bit process on 64-bit Windows the file system redirector
# rewrites %windir%\System32 to %windir%\SysWOW64. SysWOW64\inetsrv exists and
# holds appcmd.exe; its config\ folder holds only Schema\ and Export\, never
# applicationHost.config. Hardcoding System32 here
# is therefore silently dangerous rather than merely wrong: appcmd keeps working
# (it goes through the bitness-agnostic ahadmin COM API and mutates the real
# config), while $appHostConfig points at a file that does not exist - so
# Backup-DeployFile below snapshots nothing and Test-PoolEnvPresent returns
# $false for every variable, making the uninstaller believe it added entries
# that were really the customer's. Writes without a backup, in other words.
#
# %windir%\Sysnative is the un-redirected view of the real System32 and exists
# ONLY from a 32-bit process. Branch on process bitness, not on Test-Path:
# Test-Path returns $false on an access-denied path.
$inetsrv = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    Join-Path $env:windir 'Sysnative\inetsrv'
} else {
    Join-Path $env:windir 'System32\inetsrv'
}
$appcmd = Join-Path $inetsrv 'appcmd.exe'
if (-not (Test-Path $appcmd)) { throw "appcmd.exe not found - is the IIS management role installed?" }
$appHostConfig = Join-Path $inetsrv 'config\applicationHost.config'

function Test-PoolEnvPresent {
    # True if an environment variable is already declared on a pool (or, when
    # $Pool is empty, on applicationPoolDefaults). Used to flag entries that the
    # installer did NOT add, so uninstall leaves them alone.
    param([string] $Pool, [string] $Name)
    try {
        if (-not (Test-Path $appHostConfig)) { return $false }
        [xml]$c = Get-Content -LiteralPath $appHostConfig -Raw
        $base = if ($Pool) {
            "/configuration/system.applicationHost/applicationPools/add[@name='$Pool']"
        } else {
            "/configuration/system.applicationHost/applicationPools/applicationPoolDefaults"
        }
        return [bool]$c.SelectSingleNode("$base/environmentVariables/add[@name='$Name']")
    } catch { return $false }
}

function Test-PoolHasOwnEnvBlock {
    <#
      True if a pool declares its OWN <environmentVariables> collection - which
      REPLACES applicationPoolDefaults rather than merging with it. Such a pool does
      not see the OTLP vars set on the defaults above, no matter how correct they are.

      This is the instrumenter-side twin of the doctor's HasOwnEnvBlock
      (Test-IISInstrumentation.ps1), and it exists because a pool can acquire a block
      WITHOUT this installer: any prior `appcmd set config .../+[name=...]
      .environmentVariables...` creates one. A brownfield shared pool carrying, say, a
      connection string (exactly what misc\wire-db.ps1 writes) is the common case. Its
      block was materialised from whatever the defaults held at that time - i.e. no
      OTLP entries - so it silently exports nowhere. The doctor reports this as
      POOL_LOST_INHERITANCE; the caller below repairs it.

      Note the XPath deliberately has no trailing add[@name=...] predicate: we are
      asking whether the COLLECTION exists, not whether one entry does.
    #>
    param([string] $Pool)
    try {
        if (-not $Pool) { return $false }
        if (-not (Test-Path $appHostConfig)) { return $false }
        [xml]$c = Get-Content -LiteralPath $appHostConfig -Raw
        return [bool]$c.SelectSingleNode(
            "/configuration/system.applicationHost/applicationPools/add[@name='$Pool']/environmentVariables")
    } catch { return $false }
}

function Set-PoolDefaultEnv {
    param([string] $Name, [string] $Value)
    # Back up applicationHost.config once + record whether this entry pre-existed,
    # BEFORE the remove/add, so uninstall removes only what we add.
    if ($Session) {
        Backup-DeployFile -Session $Session -Path $appHostConfig | Out-Null
        Record-PoolEnv    -Session $Session -Pool 'applicationPoolDefaults' -Name $Name -Value $Value -Preexisted (Test-PoolEnvPresent -Pool '' -Name $Name)
    }
    # Idempotent: remove any existing entry, then add.
    #
    # BOTH lines address applicationPoolDefaults WITHOUT a [name=...] predicate on
    # the parent - that predicate selects an element of the `add` collection (a named
    # pool), and applicationPoolDefaults is not one. The remove used to carry
    # "/-[name='applicationPoolDefaults']...", which silently matched nothing; the
    # following add then hit an existing element and left the OLD value in place.
    # Net effect: this function could only ever write a value ONCE. Changing
    # -OtlpEndpoint and re-running did nothing to the defaults, so the documented
    # remediation for POOL_ENV_STALE ("re-run Instrument-IIS.ps1") did not work.
    # Found by the E2E loop, which measured defaults and pools disagreeing after a
    # re-run. Removal is still best-effort: a first run has nothing to remove.
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-applicationPoolDefaults.environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+applicationPoolDefaults.environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
    Write-Host "[iis-instr] applicationPoolDefaults env: $Name=$Value"
}

function Set-PoolEnv {
    # Set an env var on a specific named pool (not the defaults template).
    param([string] $Pool, [string] $Name, [string] $Value)
    if ($Session) {
        Backup-DeployFile -Session $Session -Path $appHostConfig | Out-Null
        Record-PoolEnv    -Session $Session -Pool $Pool -Name $Name -Value $Value -Preexisted (Test-PoolEnvPresent -Pool $Pool -Name $Name)
    }
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='$Pool'].environmentVariables.[name='$Name']" /commit:apphost 2>$null | Out-Null
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+[name='$Pool'].environmentVariables.[name='$Name',value='$Value']" /commit:apphost | Out-Null
}

Set-PoolDefaultEnv -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value $OtlpEndpoint
Set-PoolDefaultEnv -Name 'OTEL_EXPORTER_OTLP_PROTOCOL' -Value 'http/protobuf'

# ---- 2b. Per-app OTEL_SERVICE_NAME (auto-discovered) --------------------------
# Merge overrides: JSON file first, then the -ServiceNameOverrides hashtable on top.
if ($OverridesJson) {
    if (-not (Test-Path $OverridesJson)) { throw "Overrides JSON not found: $OverridesJson" }
    $fromFile = Get-Content -LiteralPath $OverridesJson -Raw | ConvertFrom-Json
    foreach ($p in $fromFile.PSObject.Properties) {
        if (-not $ServiceNameOverrides.ContainsKey($p.Name)) { $ServiceNameOverrides[$p.Name] = $p.Value }
    }
}

. (Join-Path $PSScriptRoot 'Resolve-IISServiceNames.ps1')
$svcMap = Get-IISServiceMap -Overrides $ServiceNameOverrides

if (-not $svcMap -or @($svcMap).Count -eq 0) {
    Write-Warning "[iis-instr] no IIS sites/applications found - no per-app service names set."
    # Clear any stale CX_IIS_SERVICES left by a prior run (site decommissioned) so the collector
    # stops stamping a now-removed service onto this host's infra/ownership telemetry.
    $staleIisSvc = [Environment]::GetEnvironmentVariable('CX_IIS_SERVICES', 'Machine')
    if ($staleIisSvc) {
        if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
            Record-EnvChange -Session $Session -Name 'CX_IIS_SERVICES' -PriorValue $staleIisSvc
        }
        [Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $null, 'Machine')
        $env:CX_IIS_SERVICES = $null
        Write-Host "[iis-instr] cleared stale CX_IIS_SERVICES (no IIS apps present)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[iis-instr] assigning per-app OTEL_SERVICE_NAME ($(@($svcMap).Count) app(s)):"
    # Only apps whose name assignment actually SUCCEEDED. CX_IIS_SERVICES is built
    # from this, not from $svcMap - see the comment at the label value below.
    $namedApps = New-Object System.Collections.ArrayList
    # Shared pools already repaired this run. $svcMap iterates per APPLICATION, so a
    # 3-app shared pool would otherwise be written three times: harmless on disk
    # (Set-PoolEnv is idempotent) but it triples the Record-PoolEnv manifest entries
    # and the console output, and Run-E2ELoop.ps1 asserts zero duplicate pool/varname
    # entries. Ordinal-ignore-case because IIS pool names are case-insensitive.
    $otlpPatchedPools = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $svcMap) {
        Write-Host ("  {0,-20} {1,-10} pool={2,-20} -> {3} [{4}]" -f $r.Site, $r.AppPath, $r.Pool, $r.ServiceName, $r.Scope)
        if ($r.Scope -eq 'pool') {
            # A pool that declares its own <environmentVariables> stops inheriting the
            # applicationPoolDefaults entries (see .NOTES), so re-set the OTLP vars here.
            Set-PoolEnv -Pool $r.Pool -Name 'OTEL_SERVICE_NAME'           -Value $r.ServiceName
            Set-PoolEnv -Pool $r.Pool -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value $OtlpEndpoint
            Set-PoolEnv -Pool $r.Pool -Name 'OTEL_EXPORTER_OTLP_PROTOCOL' -Value 'http/protobuf'
            [void]$namedApps.Add($r)
        } else {
            # Shared pool: the per-app NAME can only go in web.config (one pool, many
            # apps, one env block). The OTLP vars are a different matter.
            #
            # A shared pool normally inherits them from applicationPoolDefaults - but
            # only while it has no <environmentVariables> block of its own, because a
            # pool's own block REPLACES the defaults instead of merging. A pool that
            # already had a block before this installer ran (a connection string, an
            # app setting) therefore never receives the endpoint and exports nowhere,
            # while the defaults read as perfectly correct. Stamp the OTLP vars
            # explicitly on exactly those pools.
            #
            # Scoped to pools that already own a block on purpose: writing to a clean
            # shared pool would CREATE one (IIS materialises the current defaults into
            # it on first write), turning an inheriting pool into a snapshot that a
            # later central endpoint change would never reach.
            if (-not $otlpPatchedPools.Contains($r.Pool) -and (Test-PoolHasOwnEnvBlock -Pool $r.Pool)) {
                Write-Host "  [pool] $($r.Pool) declares its own <environmentVariables> (defaults do not reach it) - setting OTLP vars on the pool" -ForegroundColor Yellow
                Set-PoolEnv -Pool $r.Pool -Name 'OTEL_EXPORTER_OTLP_ENDPOINT' -Value $OtlpEndpoint
                Set-PoolEnv -Pool $r.Pool -Name 'OTEL_EXPORTER_OTLP_PROTOCOL' -Value 'http/protobuf'
                [void]$otlpPatchedPools.Add($r.Pool)
            }

            # Set-WebConfigServiceName returns $false when it declines - no web.config,
            # or a classic ASP.NET Framework app with no <aspNetCore> node to write into.
            if (Set-WebConfigServiceName -PhysicalPath $r.PhysicalPath -ServiceName $r.ServiceName -Session $Session) {
                [void]$namedApps.Add($r)
            }
        }
    }

    $unnamed = @($svcMap).Count - $namedApps.Count
    if ($unnamed -gt 0) {
        Write-Warning "[iis-instr] $unnamed app(s) could not be given an OTEL_SERVICE_NAME (see the warnings above). They are EXCLUDED from CX_IIS_SERVICES so the host does not claim ownership of a name this installer did not set. An ASP.NET Framework app in this group still REPORTS - the instrumentation auto-detects 'Site\AppPath' - so the host's Service-ownership list is a subset of what it emits. Give such an app a dedicated pool to bring it under management."
    }

    # Machine env var CX_IIS_SERVICES = comma-joined distinct IIS service name(s).
    # The collector's transform/iis_service_labels processor (remote Fleet config)
    # splits it into an array and stamps it onto INFRASTRUCTURE telemetry, so every
    # host Service-ownership item equals a per-app OTEL_SERVICE_NAME (APM service
    # name) - the alignment guarantee in docs/iis-service-ownership.md.
    #
    # Built from $namedApps, NOT $svcMap. Using the full map broke the guarantee for
    # any app whose name could not be written (shared pool + no web.config, or an
    # ASP.NET Framework app with no <aspNetCore> node): the host advertised ownership
    # of a name that nothing reports under, and because the doctor compares the
    # variable against the names actually present, CX_IIS_SERVICES_DRIFT was reported
    # PERMANENTLY - re-running could never clear it. Found by the E2E loop.
    #
    # The trade is deliberate and one-directional. A Framework app on a shared pool
    # DOES report, under the auto-detected 'Site\AppPath', so this list can be a
    # subset of the services the host actually emits. Under-claiming costs a missing
    # ownership item; over-claiming costs permanent drift. Subset wins.
    $iisServices = Get-IISServiceLabelValue -Map @($namedApps.ToArray())
    if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
        $priorIisSvc = [Environment]::GetEnvironmentVariable('CX_IIS_SERVICES', 'Machine')
        Record-EnvChange -Session $Session -Name 'CX_IIS_SERVICES' -PriorValue $priorIisSvc
    }
    [Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $iisServices, 'Machine')
    $env:CX_IIS_SERVICES = $iisServices
    Write-Host "[iis-instr] set machine CX_IIS_SERVICES=$iisServices (collector stamps it on infra telemetry)" -ForegroundColor Green
}

# ---- 2c. Publish the IIS access-log directories -------------------------------
# The collector's filelog/iis receiver ships ONE hardcoded include:
# C:\inetpub\logs\LogFiles\W3SVC*\*.log. A site with its own logFile directory, or
# a host using central W3C logging, writes somewhere that glob never matches - so
# its access logs simply never arrive, silently. Publish the directories the
# default does not already cover into the fixed CX_IIS_LOG_DIR_n slots the config
# template reads.
#
# Slots, not a list: ${env:VAR} expands to ONE scalar and an OTel `include:` is a
# list, so a single variable cannot become N entries. Overflow is reported, never
# dropped quietly.
$logLib = Join-Path $PSScriptRoot 'Resolve-IISLogPaths.ps1'
if (Test-Path $logLib) {
    . $logLib
    $logCfg = Get-IISLogConfig
    if (-not $logCfg.Ok) {
        Write-Warning "[iis-instr] could not read the IIS log configuration: $($logCfg.Error)"
    } else {
        $logDirs = Get-IISLogDirValue -Config $logCfg
        $slotInfo = Get-IISLogDirSlots -Value $logDirs

        # Empty slots are written as $null on purpose: a slot left over from a
        # previous deploy would otherwise keep pointing the collector at a log
        # directory that no longer belongs to any site.
        foreach ($k in $slotInfo.Slots.Keys) {
            $v = $slotInfo.Slots[$k]
            if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
                Record-EnvChange -Session $Session -Name $k -PriorValue ([Environment]::GetEnvironmentVariable($k, 'Machine'))
            }
            $set = if ($v) { $v } else { $null }
            [Environment]::SetEnvironmentVariable($k, $set, 'Machine')
            Set-Item -Path "env:$k" -Value $v -ErrorAction SilentlyContinue
        }

        if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
            Record-EnvChange -Session $Session -Name 'CX_IIS_LOG_DIRS' -PriorValue ([Environment]::GetEnvironmentVariable('CX_IIS_LOG_DIRS', 'Machine'))
        }
        [Environment]::SetEnvironmentVariable('CX_IIS_LOG_DIRS', $(if ($logDirs) { $logDirs } else { $null }), 'Machine')
        $env:CX_IIS_LOG_DIRS = $logDirs

        if ($logDirs) {
            Write-Host "[iis-instr] non-default IIS log directories -> $logDirs" -ForegroundColor Green
        } else {
            Write-Host "[iis-instr] all IIS access logs are under the collector's default path; no extra log slots needed"
        }
        if ($logCfg.CentralMode -ne 'Site') {
            Write-Host "[iis-instr] centralLogFileMode=$($logCfg.CentralMode): one log for the whole host, per-site attribution unavailable" -ForegroundColor Yellow
        }
        foreach ($s in @($logCfg.Sites | Where-Object { $_.Enabled -and $_.Format -ne 'W3C' })) {
            Write-Warning "[iis-instr] site '$($s.Name)' logs in $($s.Format) format - the collector can tail it but cannot field-parse it (W3C '#Fields:' header required)"
        }
        foreach ($o in @($slotInfo.Overflow)) {
            Write-Warning "[iis-instr] no free log slot for '$o' - the collector config declares $($slotInfo.SlotCount) CX_IIS_LOG_DIR_n slots. Add slots to the config template or consolidate the log directories."
        }
    }
} else {
    Write-Warning "[iis-instr] Resolve-IISLogPaths.ps1 not found next to this script - IIS log directories were not published"
}

# ---- 3. Recycle IIS -----------------------------------------------------------
if ($NoReset) {
    Write-Host "[iis-instr] -NoReset: skipping iisreset. Recycle pools during your maintenance window."
} else {
    Write-Host "[iis-instr] iisreset ..."
    & iisreset.exe | Out-String | Write-Host
}

# ---- Verify -------------------------------------------------------------------
Write-Host ""
Write-Host "[iis-instr] W3SVC status: $((Get-Service W3SVC -ErrorAction SilentlyContinue).Status)"
Write-Host "[iis-instr] done. ASP.NET Core pools must be set to 'No Managed Code' (managedRuntimeVersion='') or they emit no telemetry."
