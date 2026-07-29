<#
.SYNOPSIS
  Fleet agent orchestrator: detect workloads -> install Coralogix collector in
  Supervisor mode -> conditionally configure IIS zero-code instrumentation.

.DESCRIPTION
  This is the single entry point BatchPatch invokes on each target server (via
  deploy.bat). It is idempotent and transcript-logged. Steps:
    1. Detect workloads (Detect-Workloads.ps1) and publish agent-selector
       attributes to machine-level OTEL_RESOURCE_ATTRIBUTES.
    2. Install the collector in Supervisor mode (Install-CoralogixSupervisor.ps1),
       so Coralogix Fleet Management can push remote config.
    3. If IIS is present, run zero-code .NET auto-instrumentation
       (Instrument-IIS.ps1) unless -SkipInstrument.
    4. Restart the collector so it re-reads OTEL_RESOURCE_ATTRIBUTES, then verify
       and write a JSON status summary.

.PARAMETER Region
  Coralogix region code: eu1, eu2, us1, us2, us3, ap1, ap2, ap3 (see
  Resolve-CxRegion.ps1). Forwarded to Install-CoralogixSupervisor.ps1, which resolves
  it to <region>.coralogix.com and publishes it as CORALOGIX_DOMAIN. An unknown code
  fails the install rather than defaulting. Outranked by -Domain and by the CX_DOMAIN
  environment variable.

.PARAMETER Domain
  Full Coralogix ingress domain, for a private / non-standard endpoint. Wins over
  -Region. With neither given the domain falls back to CX_DOMAIN in the environment
  (the domain-shaped equivalent, which deploy.bat forwards here), then CX_REGION, then
  a CORALOGIX_DOMAIN exported for this run, then region.txt in this folder, then
  whatever a previous install persisted, then eu1.coralogix.com - resolved by
  Install-CoralogixSupervisor.ps1, which documents the order.

.PARAMETER KeyFile
  File containing the Send-Your-Data key. Default: .\SendDataKey.txt

.PARAMETER PrivateKey
  Key value (overrides KeyFile). Prefer passing via a secured file / BatchPatch.

.PARAMETER Environment
  Optional deployment.environment.name resource attribute (e.g. production).

.PARAMETER Application
  Optional Coralogix application name for this host (machine env var CX_APPLICATION).
  Omit it to let the application name fall back to the host's own name (host.name).

.PARAMETER NoSupervisor
  Install the collector WITHOUT the OpAMP Supervisor, i.e. as the plain
  'otelcol-contrib' Windows service reading a local config.

  This switch is forwarded verbatim and affects ONLY the arguments handed to the
  Coralogix vendor installer. Detection, IIS/Node instrumentation, the env vars
  that get set, and the diagnostics all behave identically in both modes.

.PARAMETER SkipInstrument
  Skip IIS zero-code instrumentation even if IIS is detected.

.PARAMETER InstrumentVersion
  Auto-instrumentation release tag forwarded to Instrument-IIS.ps1.

.NOTES
  Run elevated. Exit code 0 = success (BatchPatch treats non-zero as failure).
#>
[CmdletBinding()]
param(
    # Region/domain are resolved in Install-CoralogixSupervisor.ps1 (one authority for
    # the fallback chain), so both default to $null here and are forwarded only when set.
    [string] $Region            = $null,
    [string] $Domain            = $null,
    [string] $KeyFile           = $null,
    [string] $PrivateKey        = $null,
    [string] $Environment       = $null,
    [string] $Application       = $null,
    [switch] $NoSupervisor,
    [switch] $SkipInstrument,
    # Comma-separated .NET Windows services (outside IIS) to instrument, e.g. 'cxworkersvc,billing'.
    # Also readable from CX_DOTNET_SERVICE_NAMES so a fleet can set it per host without threading a
    # flag through deploy.bat. Deliberately opt-in: unlike Node services, which are discovered by
    # their command line, "every .NET service on this box" includes Windows' own services, and
    # attaching a CLR profiler to those is not a decision a deploy script should make unprompted.
    [string] $DotNetServices    = $null,
    [string] $InstrumentVersion = 'v1.16.0-beta.1'
)

$ErrorActionPreference = 'Stop'
# Resolve script dir robustly - $PSScriptRoot can be empty when invoked via
# `powershell -File <relative-path>`, so fall back to the invocation path.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $KeyFile) { $KeyFile = Join-Path $here 'SendDataKey.txt' }
$logDir = $here
$transcript = Join-Path $logDir 'install-agent.log'
try { Start-Transcript -Path $transcript -Append | Out-Null } catch {}

# Backup/manifest helper: every config the child scripts mutate is snapshotted
# under a single timestamped session dir, and each change recorded, so
# Uninstall-Agent.ps1 can reverse exactly what this run added.
. (Join-Path $here 'Backup-Config.ps1')
$session = $null

$status = [ordered]@{
    host          = $env:COMPUTERNAME
    started       = (Get-Date).ToString('s')
    primaryRole   = $null
    workloads     = @()
    # 'supervisor' | 'no-supervisor'. The boolean below is kept because
    # poc/Deploy-FromHost.ps1 and existing runbooks read it; it means "the
    # collector install step completed", not "the supervisor is running".
    mode          = $(if ($NoSupervisor) { 'no-supervisor' } else { 'supervisor' })
    # Effective Coralogix ingress domain, filled in after the collector step from what
    # was actually persisted (see below) - not from the -Region/-Domain arguments.
    domain        = $null
    supervisor    = $false
    iisInstrumented = $false
    pm2Instrumented = $false
    healthOk      = $false
    backupDir     = $null
    result        = 'unknown'
    error         = $null
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Install-Agent must run elevated (Administrator)."
    }
}

try {
    Assert-Admin
    Write-Host "=== Coralogix fleet agent install on $($env:COMPUTERNAME) ==="

    # Open a backup/manifest session for this install run.
    $session = New-BackupSession
    $status.backupDir = $session.Dir
    Write-Host "[agent] config backup session -> $($session.Dir)"

    # -- 1. Detect workloads ----------------------------------------------------
    $extra = @{}
    if ($Environment) { $extra['deployment.environment.name'] = $Environment }
    $roles = & (Join-Path $here 'Detect-Workloads.ps1') -SetEnv $true -ExtraAttributes $extra -Session $session
    $status.primaryRole = $roles.PrimaryRole
    $status.workloads = @('iis','dotnet','nodejs','pm2','rabbitmq','redis','valkey','sqlserver','db2','elasticsearch' |
        Where-Object {
            switch ($_) {
                'iis'           { $roles.IIS }
                'dotnet'        { $roles.DotNet }
                'nodejs'        { $roles.NodeJs }
                'pm2'           { $roles.PM2 }
                'rabbitmq'      { $roles.RabbitMQ }
                'redis'         { $roles.Redis }
                'valkey'        { $roles.Valkey }
                'sqlserver'     { $roles.SqlServer }
                'db2'           { $roles.Db2 }
                'elasticsearch' { $roles.Elasticsearch }
            }
        })

    # -- 2. Install the collector ----------------------------------------------
    # -NoSupervisor selects the vendor installer's regular mode. Everything else
    # about this call is identical between the two modes.
    # Pass -Region/-Domain ONLY when actually given: an empty value here would look
    # explicit to the child script and short-circuit its env/region.txt fallbacks.
    $supArgs = @{ BaseConfig = (Join-Path $here 'config.supervisor.yaml') }
    if ($Region) { $supArgs['Region'] = $Region }
    if ($Domain) { $supArgs['Domain'] = $Domain }
    if ($NoSupervisor) { $supArgs['NoSupervisor'] = $true }
    if ($PrivateKey) { $supArgs['PrivateKey'] = $PrivateKey } else { $supArgs['KeyFile'] = $KeyFile }
    # Persist CX_ENVIRONMENT (machine) so the collector's resource/environment
    # processor stamps the env label onto all signals.
    if ($Environment) { $supArgs['Environment'] = $Environment }
    # Persist CX_APPLICATION (machine) so transform/appname stamps service.namespace.
    # Unset = the transform is skipped and the exporter falls back to host.name.
    if ($Application) { $supArgs['Application'] = $Application }
    # Publish the detected selector attributes in the OpAMP AgentDescription (Fleet Mgmt).
    if ($roles.OtelResourceAttributes) { $supArgs['ResourceAttributes'] = $roles.OtelResourceAttributes }
    $supArgs['Session'] = $session
    & (Join-Path $here 'Install-CoralogixSupervisor.ps1') @supArgs
    $status.supervisor = $true
    # Read the region back off what the child persisted rather than echoing the
    # argument: with no -Region/-Domain the effective value comes from the env or
    # region.txt, and the status summary is what a fleet rollout is audited against.
    $status.domain = [Environment]::GetEnvironmentVariable('CORALOGIX_DOMAIN', 'Machine')

    # -- 3. Conditional IIS zero-code instrumentation ---------------------------
    if ($roles.IIS -and -not $SkipInstrument) {
        Write-Host "[agent] IIS detected -> configuring zero-code .NET instrumentation"
        & (Join-Path $here 'Instrument-IIS.ps1') -Version $InstrumentVersion -Session $session
        $status.iisInstrumented = $true
    } elseif ($roles.IIS) {
        Write-Host "[agent] IIS detected but -SkipInstrument set; skipping instrumentation"
    } else {
        Write-Host "[agent] IIS not detected; skipping zero-code instrumentation"
    }

    # -- 3b. Conditional Node.js / PM2 zero-code instrumentation ----------------
    if ($roles.PM2 -and -not $SkipInstrument) {
        Write-Host "[agent] PM2 detected -> configuring zero-code Node.js instrumentation"
        if ($roles.PM2Hosting -eq 'service') {
            Write-Host "[agent] PM2 is hosted as a Windows service owned by $($roles.PM2Owner) - its apps are restarted as that account"
        }
        & (Join-Path $here 'Instrument-NodePM2.ps1') -Session $session
        # Read the outcome back off the shared manifest instead of assuming success. An install
        # that could not reach the PM2 daemon must not be reported as instrumented - that claim
        # in the status summary is how a host ends up believed-covered and silent.
        $status.pm2Instrumented = [bool]$session.Manifest.nodeInstrumented
    } elseif ($roles.PM2) {
        Write-Host "[agent] PM2 detected but -SkipInstrument set; skipping instrumentation"
    } else {
        Write-Host "[agent] PM2 not detected; skipping Node.js zero-code instrumentation"
    }

    # -- 3c. Windows services outside IIS and outside PM2 ------------------------
    # Node started by the SCM with no PM2, and .NET services that are not hosted by IIS. Both were
    # out of scope until now, and both are silent on a host that reports a fully successful install:
    # the IIS path only reaches w3wp, and the PM2 path only reaches apps a daemon manages.
    #
    # Node services are DISCOVERED (the instrumenter enumerates services whose command line runs
    # node.exe, excluding PM2's own). .NET services are NOT: "every .NET service on the box"
    # includes Windows' own, and attaching a profiler to those is not a decision a deploy script
    # should take by itself - so they must be named explicitly via CX_DOTNET_SERVICES.
    if (-not $SkipInstrument) {
        $nodeSvcScript = Join-Path $here 'Instrument-NodeService.ps1'
        if (Test-Path $nodeSvcScript) {
            Write-Host "[agent] checking for Node.js Windows services (no PM2) ..."
            & $nodeSvcScript
            # Exit 1 means at least one service was refused with a reason, which is information, not
            # a reason to fail the whole install - the reasons are already printed.
            $status.nodeServiceInstrumented = ($LASTEXITCODE -eq 0)
        }

        $dotnetSvcScript = Join-Path $here 'Instrument-DotNetService.ps1'
        $dotnetSvcNames  = @()
        foreach ($src in @($DotNetServices, $env:CX_DOTNET_SERVICE_NAMES)) {
            if ($src) { $dotnetSvcNames += @(($src -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        }
        $dotnetSvcNames = @($dotnetSvcNames | Sort-Object -Unique)
        if ((Test-Path $dotnetSvcScript) -and $dotnetSvcNames.Count) {
            Write-Host "[agent] instrumenting .NET Windows service(s): $($dotnetSvcNames -join ', ')"
            & $dotnetSvcScript -Services $dotnetSvcNames
            $status.dotnetServiceInstrumented = ($LASTEXITCODE -eq 0)
        } elseif ($dotnetSvcNames.Count) {
            Write-Warning "[agent] .NET services requested ($($dotnetSvcNames -join ', ')) but Instrument-DotNetService.ps1 is missing from the payload"
        } else {
            Write-Host "[agent] no .NET Windows services requested (-DotNetServices / CX_DOTNET_SERVICE_NAMES); skipping"
        }
    }

    # -- 3d. Publish CX_SERVICES: every service this host actually claims ---------
    # The collector stamps host-ownership labels from ONE variable, but each instrumenter only ever
    # publishes its own slice: CX_IIS_SERVICES, CX_NODE_SERVICES, CX_DOTNET_SERVICES. Without a union
    # a Node or .NET service shows up in APM through its own spans while the HOST entity never claims
    # it - so Infrastructure Explorer shows no Service ownership for it and APM<->host correlation is
    # impossible. On a Node-only host the collector's guard was false and NO labels were stamped at
    # all. Computed here because this is the first point at which every instrumenter has run; step 4
    # restarts the collector, which is what makes the new value take effect.
    $svcSeen  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $svcUnion = New-Object System.Collections.Generic.List[string]
    foreach ($varName in 'CX_IIS_SERVICES', 'CX_NODE_SERVICES', 'CX_DOTNET_SERVICES') {
        $raw = [Environment]::GetEnvironmentVariable($varName, 'Machine')
        if (-not $raw) { continue }
        foreach ($n in ($raw -split ',')) {
            $t = "$n".Trim()
            # HashSet.Add returns false for a name another instrumenter already claimed, which is how
            # an IIS app fronting a PM2 process is counted once rather than twice.
            if ($t -and $svcSeen.Add($t)) { [void]$svcUnion.Add($t) }
        }
    }
    if ($svcUnion.Count) {
        $cxServices = ($svcUnion.ToArray() -join ',')
        [Environment]::SetEnvironmentVariable('CX_SERVICES', $cxServices, 'Machine')
        Write-Host "[agent] set machine CX_SERVICES=$cxServices ($($svcUnion.Count) service(s) claimed for host ownership)" -ForegroundColor Green
    } elseif ([Environment]::GetEnvironmentVariable('CX_SERVICES', 'Machine')) {
        # Nothing instrumented, or everything was refused. Clear the stale value instead of leaving
        # the host advertising ownership of services it no longer runs.
        [Environment]::SetEnvironmentVariable('CX_SERVICES', $null, 'Machine')
        Write-Host '[agent] no instrumented services on this host; cleared stale CX_SERVICES'
    }

    # -- 4. Restart collector to pick up OTEL_RESOURCE_ATTRIBUTES ----------------
    # In Supervisor mode there is NO 'otelcol-contrib' service - the collector runs
    # as a CHILD process of 'opampsupervisor'. Restart the supervisor (which
    # relaunches the collector) so it re-reads the machine OTEL_RESOURCE_ATTRIBUTES.
    # Fall back to the 'otelcol-contrib' service for local (non-supervisor) mode.
    $sup = Get-Service -Name 'opampsupervisor'  -ErrorAction SilentlyContinue
    $col = Get-Service -Name 'otelcol-contrib'  -ErrorAction SilentlyContinue
    if ($sup) {
        Write-Host "[agent] restarting opampsupervisor to apply resource attributes"
        Restart-Service -Name 'opampsupervisor' -Force -ErrorAction SilentlyContinue
    } elseif ($col) {
        Write-Host "[agent] restarting otelcol-contrib to apply resource attributes"
        Restart-Service -Name 'otelcol-contrib' -Force -ErrorAction SilentlyContinue
    }

    # Health check WITH RETRIES: the collector needs a moment to come up, and the
    # supervisor may relaunch it once during the initial OpAMP handshake. A single
    # immediate probe reports a false negative (503 while starting).
    $status.healthOk = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        try {
            $r = Invoke-WebRequest -Uri 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 8
            if ($r.StatusCode -eq 200) { $status.healthOk = $true; break }
        } catch { }
    }

    $status.result = if ($status.supervisor) { 'success' } else { 'partial' }
    Write-Host "=== done: role=$($status.primaryRole) workloads=[$($status.workloads -join ',')] iisInstrumented=$($status.iisInstrumented) pm2Instrumented=$($status.pm2Instrumented) health=$($status.healthOk) ==="
}
catch {
    $status.result = 'error'
    $status.error  = $_.Exception.Message
    Write-Error $_
}
finally {
    $status.finished = (Get-Date).ToString('s')
    # Persist the backup manifest (+ refresh latest.json) so uninstall can find it.
    if ($session) { try { Save-Manifest -Session $session } catch {} }
    try { $status | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $logDir 'install-agent-status.json') -Encoding utf8 } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

if ($status.result -eq 'error') { exit 1 } else { exit 0 }
