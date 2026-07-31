<#
.SYNOPSIS
  Configure zero-code OpenTelemetry auto-instrumentation for Node.js apps managed by PM2,
  and point every app at the local collector. The Node/PM2 analog of Instrument-IIS.ps1.

.DESCRIPTION
  Runs only on hosts where PM2 was detected (the orchestrator gates this). Steps:
    1. Ensure the OTel Node auto-instrumentation package is present in a fixed prefix
       (npm install @opentelemetry/auto-instrumentations-node) and resolve the absolute
       path of its `register` bootstrap.
    2. Enumerate PM2-managed apps (Resolve-NodeServiceNames.ps1) and, per app, set
       NODE_OPTIONS=--require <register> plus the OTEL_* export vars and a per-app
       OTEL_SERVICE_NAME, then `pm2 restart <name> --update-env` so the app's runtime env
       is refreshed. `pm2 save` persists the resolved env across a daemon restart / resurrect.
    3. Publish the machine env var CX_NODE_SERVICES (comma-joined distinct service names)
       so the collector can stamp Node service ownership onto infrastructure telemetry,
       aligned with the per-app OTEL_SERVICE_NAME (the Node analog of CX_IIS_SERVICES).

  WHY NODE_OPTIONS (not PM2 node_args): PM2's ecosystem `node_args` is not re-applied on a
  plain `pm2 restart` (long-standing quirk), whereas NODE_OPTIONS is an ordinary env var the
  worker inherits on every (re)start. WHY per-app (not machine-wide NODE_OPTIONS): a
  machine-wide value would self-instrument the PM2 God daemon and every `pm2` CLI call, and
  force one host-wide service name. Setting it per app via --update-env keeps the daemon clean
  and gives each app its own service name - the direct analog of setting IIS env per pool.

  CLUSTER MODE: PM2 cluster workers are separate Node PIDs that each inherit this env, so each
  loads its own instrumentation and reports independently. They share ONE OTEL_SERVICE_NAME
  (the app name) so Coralogix rolls them up as one service; the OTel process resource detector
  still separates workers by process.pid.

.PARAMETER OtlpEndpoint
  Local collector OTLP HTTP endpoint. Default: http://127.0.0.1:4318

  Deliberately the IPv4 literal, not `localhost`. The collector's receivers bind
  ${env:OTEL_LISTEN_INTERFACE:-127.0.0.1}, and on a dual-stack host `localhost`
  resolves to ::1 first - nothing listens there and the export is dropped with no
  exporter error to show for it. A `localhost` value passed here is rewritten (see
  Resolve-CxOtlpEndpoint in Write-DeployLog.ps1) rather than honored.

.PARAMETER InstallPrefix
  Directory the OTel Node package is installed under (its node_modules/). Default: C:\cx\otel-node

.PARAMETER Package
  The npm package that provides the `register` bootstrap. Default: @opentelemetry/auto-instrumentations-node

.PARAMETER ServiceNameOverrides
  Optional hashtable to rename specific apps, keyed by the PM2 app name (e.g. @{ 'api' = 'orders-api' }).

.PARAMETER OverridesJson
  Optional path to a JSON file of the same { pm2Name = overrideName } shape.

.PARAMETER NoRestart
  Set env + install the package but skip `pm2 restart`/`pm2 save` (apply during a maintenance window).

.PARAMETER SkipInstall
  Skip `npm install` (the package was pre-staged in InstallPrefix).

.PARAMETER Apps
  Instrument only these PM2 apps (by PM2 app name). Default: every app PM2 manages.

  This exists because instrumenting is a RESTART. A host can easily carry two dozen apps
  spanning dev/qa/uat, and restarting all of them because a deploy script ran is not a decision
  this script gets to make - prove one app end to end, then widen.

.PARAMETER ExcludeApps
  Apps to leave alone. Defaults to PM2's own utility apps (pm2-logrotate,
  pm2-prometheus-exporter, ...) - instrumenting those puts PM2's log rotator and metrics
  exporter into APM as services. Pass @() to include them.

.NOTES
  Requires node + npm on PATH when installing the package, the pm2 CLI somewhere findable, and
  (for the machine env var) an elevated session. Online npm access is required unless
  -SkipInstall. Windows PowerShell 5.1 compatible.

  PM2 OWNERSHIP. PM2 is per-user when someone started it by hand, but a Windows host that runs
  PM2 in production usually has it installed AS A SERVICE (pm2-installer / node-windows:
  PM2_HOME=C:\ProgramData\pm2, daemon owned by NT AUTHORITY\LOCAL SERVICE). The daemon's IPC
  pipe belongs to that account, so `pm2 restart --update-env` from any other identity - SYSTEM
  included - does not reach the running apps. It does not error either: pm2 answers for the
  caller's own (empty) daemon and exits 0. This script therefore detects the daemon owner and
  routes the per-app env through Invoke-CxPm2AsOwner when it is not us. If that cannot be done
  it says so and exits non-zero, rather than reporting success over apps that never changed.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]    $OtlpEndpoint         = 'http://127.0.0.1:4318',
    [string]    $InstallPrefix        = 'C:\cx\otel-node',
    [string]    $Package              = '@opentelemetry/auto-instrumentations-node',
    [hashtable] $ServiceNameOverrides = @{},
    [string]    $OverridesJson,
    [switch]    $NoRestart,
    [switch]    $SkipInstall,
    # Take over an app that already exports to an OFF-BOX OTLP endpoint. Off by default - that endpoint
    # belongs to another OpenTelemetry deployment and repointing it silently moves their telemetry here.
    [switch]    $ForceEndpoint,
    # X-6: trace sample ratio. 1.0 (default) writes parentbased_always_on, which is what an app with no
    # sampler configured already does - so the default changes nothing and the knob now exists.
    [ValidateRange(0.0, 1.0)][double] $SampleRatio = 1.0,
    [string[]]  $Apps,
    [string[]]  $ExcludeApps,
    # Only needed when the PM2 daemon is owned by an ORDINARY account. The built-in service
    # identities (LOCAL SERVICE / NETWORK SERVICE / SYSTEM) and gMSAs log on without a password;
    # a normal user cannot, and no mechanism can impersonate it without one.
    [pscredential] $Pm2OwnerCredential,
    # Optional backup/manifest session (from Backup-Config.ps1, created by the orchestrator).
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

# Optional backup/manifest recording (shared session from the orchestrator).
$backupHelper = Join-Path $PSScriptRoot 'Backup-Config.ps1'
if (Test-Path $backupHelper) { . $backupHelper }
. (Join-Path $PSScriptRoot 'Resolve-NodeServiceNames.ps1')

# Normalize a `localhost` endpoint to the IPv4 literal before it reaches NODE_OPTIONS.
# Guarded because the helper is optional in a hand-assembled deploy directory; the
# param default is already correct, so a missing helper only loses the rewrite for an
# operator who passed `localhost` explicitly (the doctor still warns in that case).
$logHelper = Join-Path $PSScriptRoot 'Write-DeployLog.ps1'
if (Test-Path $logHelper) { . $logHelper }
if (Get-Command Resolve-CxOtlpEndpoint -ErrorAction SilentlyContinue) {
    $OtlpEndpoint = Resolve-CxOtlpEndpoint -Endpoint $OtlpEndpoint
}

# ---- 0. Prerequisites ---------------------------------------------------------
# node/npm are needed to stage the package and to resolve the register bootstrap; pm2 is looked
# up by path rather than required on PATH. `pm2-installer` puts the CLI in C:\ProgramData\npm,
# which is frequently absent from the PATH of the account a fleet tool runs the deploy as - and
# demanding it here is what silently skipped this whole step on such a host.
foreach ($tool in 'node','npm') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Warning "[node-instr] '$tool' not found on PATH - skipping Node/PM2 instrumentation."
        return
    }
}
$pm2Cli = Get-CxPm2CommandPath
if (-not $pm2Cli) {
    Write-Warning "[node-instr] the pm2 CLI could not be located (PATH, C:\ProgramData\npm, %APPDATA%\npm) - skipping Node/PM2 instrumentation."
    return
}

# How PM2 is hosted decides HOW the env has to be applied, so resolve it before anything else.
$topo = Get-CxPm2Topology
Write-Host "[node-instr] pm2 cli       : $pm2Cli"
Write-Host "[node-instr] pm2 hosting   : $($topo.Hosting)$(if ($topo.ServiceName) { " (service '$($topo.ServiceName)', state $($topo.ServiceState))" })"
Write-Host "[node-instr] pm2 owner     : $(if ($topo.Owner) { $topo.Owner } else { '<unknown>' })   running as: $($topo.Identity)"
Write-Host "[node-instr] PM2_HOME      : $(if ($topo.Home) { $topo.Home } else { '<unknown>' })"

# The apps only answer to the account that owns their daemon. Route through a scheduled task
# running as that account when it is not us; refuse to pretend otherwise.
$applyAsOwner = ($topo.OwnerMismatch -and $topo.Owner -and $topo.Hosting -ne 'none')
if ($applyAsOwner) {
    Write-Host "[node-instr] the PM2 daemon belongs to $($topo.Owner), not to us - pm2 will be invoked as that account." -ForegroundColor Yellow
}

# ---- 1. Install the OTel Node auto-instrumentation package + resolve register --
$nodeModules = Join-Path $InstallPrefix 'node_modules'
if (-not $SkipInstall) {
    New-Item -ItemType Directory -Force -Path $InstallPrefix | Out-Null
    Write-Host "[node-instr] npm install $Package @opentelemetry/api -> $InstallPrefix ..."
    # No 2>&1 redirect: npm writes progress to stderr, and merging it into the pipeline under
    # $ErrorActionPreference=Stop raises a terminating NativeCommandError in Windows PowerShell
    # 5.1. Let output flow to the console and gate on $LASTEXITCODE instead.
    & npm install --prefix $InstallPrefix $Package '@opentelemetry/api' --no-fund --no-audit --loglevel=error
    if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE). Check network / npm registry access, or pre-stage the package and pass -SkipInstall." }
}

# Resolve the absolute path of the package's `register` bootstrap. Prefer Node's own
# require.resolve (with NODE_PATH pointed at our prefix); fall back to a file search so we
# never hard-code the internal build layout.
$env:NODE_PATH = $nodeModules
$registerPath = $null
try { $registerPath = (& node -e "console.log(require.resolve('$Package/register'))" 2>$null | Out-String).Trim() } catch {}
if (-not $registerPath -or -not (Test-Path $registerPath)) {
    $pkgDir = Join-Path $nodeModules ($Package -replace '/','\')
    $registerPath = Get-ChildItem -Path $pkgDir -Recurse -Filter 'register.js' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $registerPath -or -not (Test-Path $registerPath)) {
    throw "[node-instr] could not resolve the '$Package/register' bootstrap under $nodeModules."
}
# NODE_OPTIONS parses backslashes awkwardly; forward slashes are safe on Windows Node.
$registerPath = $registerPath -replace '\\','/'
$nodeOptions  = "--require $registerPath"
Write-Host "[node-instr] register bootstrap: $registerPath"

# ---- ESM apps: the loader hook, plus --require --------------------------------
# An ES module app needs the instrumentation's ESM LOADER HOOK. Both obvious alternatives were
# measured against a real ESM app with a console span exporter, and both are wrong:
#
#   --import C:/.../register.js                     -> the app CRASHES at startup with
#                                                      ERR_UNSUPPORTED_ESM_URL_SCHEME, because Node's
#                                                      ESM resolver reads `C:` as a URL scheme
#   --import file:///C:/.../register.js             -> starts cleanly, SDK loads, and produces
#                                                      ZERO spans: nothing patches ESM imports
#   --experimental-loader=file:///.../hook.mjs
#     --require C:/.../register.js                  -> 17 spans. This is the one that works.
#
# So: the hook registers itself in the ESM resolution chain (and must be a file:// URL for the same
# scheme reason), while --require still starts the SDK (register.js is CommonJS, so a plain Windows
# path is correct there). Without the hook an ESM app looks perfectly healthy and emits nothing -
# which is exactly the failure mode this tooling exists to eliminate, so a missing hook is reported
# rather than silently accepted.
$hookPath = $null
try {
    $instrDir = Join-Path $nodeModules '@opentelemetry\instrumentation'
    $hookPath = Get-ChildItem -Path $instrDir -Filter 'hook.mjs' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
} catch { }
$esmSupported   = [bool]$hookPath
$nodeOptionsEsm = $null
if ($esmSupported) {
    $hookUrl        = 'file:///' + ($hookPath -replace '\\','/')
    $nodeOptionsEsm = "--experimental-loader=$hookUrl --require $registerPath"
    Write-Host "[node-instr] ESM loader hook  : $hookUrl"
} else {
    Write-Warning "[node-instr] no @opentelemetry/instrumentation/hook.mjs under $nodeModules - ESM apps cannot be instrumented (the SDK would load and emit nothing). CommonJS apps are unaffected."
}

# ---- 2. Per-app OTEL_SERVICE_NAME + NODE_OPTIONS ------------------------------
# Merge overrides: JSON file first, then the -ServiceNameOverrides hashtable on top.
if ($OverridesJson) {
    if (-not (Test-Path $OverridesJson)) { throw "Overrides JSON not found: $OverridesJson" }
    $fromFile = Get-Content -LiteralPath $OverridesJson -Raw | ConvertFrom-Json
    foreach ($p in $fromFile.PSObject.Properties) {
        if (-not $ServiceNameOverrides.ContainsKey($p.Name)) { $ServiceNameOverrides[$p.Name] = $p.Value }
    }
}

$mapArgs = @{ Overrides = $ServiceNameOverrides; Topology = $topo }
if ($PSBoundParameters.ContainsKey('ExcludeApps')) { $mapArgs['ExcludeApps'] = $ExcludeApps }
$svcMap = Get-PM2ServiceMap @mapArgs

# -Apps narrows to a named subset AFTER enumeration, so an unknown name is reported instead of
# quietly instrumenting nothing.
if ($Apps) {
    $known   = @($svcMap | ForEach-Object { $_.Name })
    $unknown = @($Apps | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Warning "[node-instr] -Apps named app(s) PM2 does not manage: $($unknown -join ', '). Known: $($known -join ', ')"
    }
    $svcMap = @($svcMap | Where-Object { $Apps -contains $_.Name })
    if (@($svcMap).Count -eq 0) { throw "[node-instr] none of the -Apps names match a PM2 app on this host." }
}

if (-not $svcMap -or @($svcMap).Count -eq 0) {
    Write-Warning "[node-instr] PM2 is present but manages no apps - nothing to instrument."
    # Clear any stale CX_NODE_SERVICES from a prior run so the collector stops stamping a
    # now-removed Node service onto this host's infra/ownership telemetry.
    $stale = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
    if ($stale) {
        if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
            Record-EnvChange -Session $Session -Name 'CX_NODE_SERVICES' -PriorValue $stale
        }
        [Environment]::SetEnvironmentVariable('CX_NODE_SERVICES', $null, 'Machine')
        $env:CX_NODE_SERVICES = $null
        Write-Host "[node-instr] cleared stale CX_NODE_SERVICES (no PM2 apps present)" -ForegroundColor Yellow
    }
    return
}

if ($Session) {
    $Session.Manifest.nodeInstallPrefix = $InstallPrefix
    $Session.Manifest.nodePm2Hosting    = $topo.Hosting
    $Session.Manifest.nodePm2Owner      = $topo.Owner
    $Session.Manifest.nodePm2Home       = $topo.Home
    # Set to the truth at the END of the run, not optimistically here: the orchestrator reads it
    # for its status summary, and an install that reached no app must not report as instrumented.
    $Session.Manifest.nodeInstrumented  = $false
}

Write-Host "[node-instr] instrumenting $(@($svcMap).Count) PM2 app(s) (source: $(@($svcMap)[0].Source)):"

# N-1: the node.exe the PM2 DAEMON runs, as the fallback interpreter for apps that declare none.
# The daemon itself IS a node process, so its ExecutablePath is the most reliable host-level answer -
# and it is the one PM2 uses to fork workers. Resolved once; per-app interpreters still win.
$daemonNode = $null
try {
    $daemonProc = @(Get-CxPm2Processes | Where-Object { $_.Kind -eq 'daemon' } | Select-Object -First 1)
    if (@($daemonProc).Count -gt 0 -and $daemonProc[0].Pid) {
        $daemonNode = (Get-Process -Id $daemonProc[0].Pid -ErrorAction SilentlyContinue).Path
    }
} catch { }

$failed = @()
$refused = @()
# N-2: extra blocklist patterns an operator added, read once.
$blocklistExtra = @()
if (Get-Command Get-CxNodeBlocklistPatterns -ErrorAction SilentlyContinue) { $blocklistExtra = @(Get-CxNodeBlocklistPatterns) }

foreach ($r in $svcMap) {
    # N-2: never instrument a tool process or a process under the debugger. PM2 can be managing a build
    # watcher or a codegen script alongside real applications; naming those as services pollutes the
    # service list in Coralogix and they are not applications anybody wants traces for.
    if (Get-Command Test-CxNodeProcessBlocked -ErrorAction SilentlyContinue) {
        $blockProbe = "$($r.Interpreter) $($r.Script) $($r.NodeOptions)"
        $blk = Test-CxNodeProcessBlocked -CommandLine $blockProbe -Name $r.Name -ExtraPatterns $blocklistExtra
        if ($blk.Blocked) {
            Write-Host "  $($r.Name): SKIPPED [$($blk.Rule)] $($blk.Reason)" -ForegroundColor Yellow
            $failed  += $r.Name
            $refused += [pscustomobject]@{ Name = $r.Name; Code = "BLOCKED_$($blk.Rule.ToUpperInvariant())"; Version = $null }
            continue
        }
    }

    # N-1 RUNTIME GATE, before anything is written. An app on a Node below the SDK minimum is the one
    # silent failure this deployment could still create by itself: NODE_OPTIONS is accepted, the app
    # starts normally, and it emits NOTHING - forever, with no error and a doctor that used to call the
    # host healthy. Refusing is the same rule that governs CX_IIS_SERVICES: a claimed service that never
    # reports is worse than no service.
    #
    # Candidates most-authoritative first: the app's own interpreter, the RUNNING worker's exe, the
    # daemon's node. Never PATH - see Get-CxNodeVersion for why that fallback is deliberately disabled
    # once candidates exist.
    # D-7: an app already exporting off-box belongs to another OpenTelemetry deployment. Repointing it
    # silently moves their telemetry to us. Per-app rather than a whole-run refusal, because PM2 hosts
    # unrelated apps side by side and one customer-wired app must not block the rest.
    if (Get-Command Test-CxEndpointOverwriteAllowed -ErrorAction SilentlyContinue) {
        $epChk = Test-CxEndpointOverwriteAllowed -Existing $r.OtlpEndpoint -Ours $OtlpEndpoint -Force:$ForceEndpoint
        if (-not $epChk.Allowed) {
            Write-Warning "[node-instr] $($r.Name) REFUSED (OTLP_ENDPOINT_FOREIGN): $($epChk.Reason)"
            $failed  += $r.Name
            $refused += [pscustomobject]@{ Name = $r.Name; Code = 'OTLP_ENDPOINT_FOREIGN'; Version = $null }
            continue
        }
        if ($epChk.Foreign) { Write-Warning "[node-instr] $($r.Name): $($epChk.Reason)" }
    }

    $workerExe = $null
    if ($r.Pid) { try { $workerExe = (Get-Process -Id $r.Pid -ErrorAction SilentlyContinue).Path } catch { } }
    $nodeVer = Get-CxNodeVersion -Candidates @($r.Interpreter, $workerExe, $daemonNode)
    $gate = Test-CxNodeRuntimeSupported -Version $nodeVer -IsEsm ([bool]$r.IsEsm) -Extensionless ([bool]$r.Extensionless)
    if (-not $gate.Ok) {
        Write-Warning "[node-instr] $($r.Name) REFUSED ($($gate.Code)): $($gate.Reason)"
        $failed  += $r.Name
        $refused += [pscustomobject]@{ Name = $r.Name; Code = $gate.Code; Version = $nodeVer }
        continue
    }

    # ESM entry points additionally need the loader hook; everything else just --require. See the
    # note above the $nodeOptionsEsm assignment for what was measured and why.
    $appNodeOptions = $nodeOptions
    if ($r.IsEsm) {
        if ($esmSupported) {
            $appNodeOptions = $nodeOptionsEsm
            # N-5: on a Node that supports module.register(), use the shim instead of the deprecated
            # --experimental-loader. Measured equivalent (3 spans vs 3) on Node 20.11; falls back silently
            # to the old pair when the shim cannot be written, because a working deprecated form beats a
            # broken modern one.
            if ((Get-Command Get-CxNodeEsmBootstrapForm -ErrorAction SilentlyContinue) -and
                (Get-CxNodeEsmBootstrapForm -Version $nodeVer) -eq 'register') {
                $shimUrl = New-CxEsmRegisterShim -InstallPrefix $InstallPrefix -RegisterPath $registerPath -HookUrl $hookUrl
                if ($shimUrl) {
                    $appNodeOptions = "--import $shimUrl"
                    Write-Host "      ESM via module.register() shim (Node $nodeVer); --experimental-loader is deprecated from 20.6"
                }
            }
        } else {
            Write-Warning "[node-instr] $($r.Name) is an ES module but the ESM loader hook is not available - instrumenting it would start the SDK and produce no telemetry, so it is left alone."
            $failed += $r.Name
            continue
        }
    }
    # Merge, never replace: an app that already sets NODE_OPTIONS for its own reasons (a heap
    # limit, TLS behaviour, ICU data) must keep those flags. A prior bootstrap of ours is dropped
    # so re-running cannot load the SDK twice.
    # Both artifacts are declared as ours so a re-run cannot leave a stale hook behind: an app that
    # switches from ESM to CommonJS produces a bootstrap mentioning only register.js, and the ESM
    # loader would otherwise survive every future re-deploy.
    # The shim is declared as ours too, so switching an app between forms (or ESM->CommonJS) strips the
    # previous bootstrap instead of accumulating two.
    $ownedTargets = @($registerPath, $(if ($esmSupported) { $hookUrl }), (Join-Path $InstallPrefix 'cx-esm-register.mjs')) | Where-Object { $_ }
    $appNodeOptions = Merge-CxNodeOptions -Existing $r.NodeOptions -Bootstrap $appNodeOptions -OwnedTargets $ownedTargets
    $flag = if ($r.IsEsm) { 'esm+hook' } else { '--require' }
    Write-Host ("  {0,-24} mode={1,-13} instances={2} {3,-9} -> OTEL_SERVICE_NAME={4}" -f `
        $r.Name, $r.ExecMode, $r.Instances, $flag, $r.ServiceName)
    if ($r.NodeOptions) { Write-Host "      preserving the app's own NODE_OPTIONS: $($r.NodeOptions)" }

    # The env the app must come back up with. Applied either in THIS process (when we own the
    # daemon and `pm2 restart --update-env` will read it) or inside the task that runs as the
    # owner - the same set either way.
    $appEnv = [ordered]@{
        NODE_OPTIONS                = $appNodeOptions
        OTEL_EXPORTER_OTLP_ENDPOINT = $OtlpEndpoint
        OTEL_EXPORTER_OTLP_PROTOCOL = 'http/protobuf'
        OTEL_SERVICE_NAME           = $r.ServiceName
        OTEL_TRACES_EXPORTER        = 'otlp'
        OTEL_METRICS_EXPORTER       = 'otlp'
        OTEL_LOGS_EXPORTER          = 'otlp'
    }
    # X-6: sampling as a stated decision. Default 1.0 writes parentbased_always_on, which is what these
    # apps already do implicitly - the difference is that it is now visible and adjustable.
    if (Get-Command Get-CxTelemetryPolicyVars -ErrorAction SilentlyContinue) {
        foreach ($kv in (Get-CxTelemetryPolicyVars -SampleRatio $SampleRatio -Runtime 'node').GetEnumerator()) {
            $appEnv[$kv.Key] = $kv.Value
        }
    }
    # N-8: per-app resource attributes mirroring the reference agent's PGI inputs (NODEJS_SCRIPT_NAME,
    # NODEJS_APP_BASE_DIR) plus a per-INSTANCE id. Cluster workers share one service name, so without
    # service.instance.id there is no way to tell four workers apart in the backend.
    $resAttrs = @()
    if ($r.Script) { $resAttrs += "node.script.path=$([string]$r.Script -replace '[,=]','_')" }
    if ($r.Cwd)    { $resAttrs += "node.app.base.dir=$([string]$r.Cwd -replace '[,=]','_')" }
    # N-4: the instance id comes from InstanceKey (name + pid) so cluster workers are distinguishable,
    # and the identity that survives a rename travels as its own attribute.
    $resAttrs += "service.instance.id=$(if ($r.InstanceKey) { $r.InstanceKey } else { $r.Name })"
    if ($r.Identity) { $resAttrs += "cx.node.identity=$([string]$r.Identity -replace '[,=]','_')" }
    if (@($resAttrs).Count -gt 0) { $appEnv['OTEL_RESOURCE_ATTRIBUTES'] = ($resAttrs -join ',') }

    if ($NoRestart) {
        # SetEnvironmentVariable, not Set-Item: Set-Item refuses an EMPTY value and, silenced, that
        # refusal is invisible - the same trap that made uninstall a no-op.
        foreach ($k in $appEnv.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$appEnv[$k], 'Process') }
        continue
    }
    # Restarting a live app is the outward-facing part of this script, so it is what -WhatIf
    # gates on - everything above only reads or stages files.
    if (-not $PSCmdlet.ShouldProcess($r.Name, "pm2 restart --update-env (OTEL_SERVICE_NAME=$($r.ServiceName))")) { continue }

    if ($applyAsOwner) {
        $ownerArgs = @{ Owner = $topo.Owner; Pm2Home = $topo.Home; Env = $appEnv
                        Pm2ArgSets = @(, @('restart', [string]$r.Name, '--update-env')) }
        if ($Pm2OwnerCredential) { $ownerArgs['OwnerCredential'] = $Pm2OwnerCredential }
        $res = Invoke-CxPm2AsOwner @ownerArgs
        if ($res.Output) { Write-Host $res.Output }
        if ($res.Mechanism -and $res.Mechanism -ne 'none') { Write-Host "[node-instr] $($r.Name): applied via $($res.Mechanism)" }
        if (-not $res.Ok) {
            Write-Warning "[node-instr] $($r.Name): restart as $($topo.Owner) failed - $($res.Reason)"
            $failed += $r.Name
        }
    } else {
        # Set the per-app env in THIS process; `pm2 restart --update-env` refreshes the app's
        # runtime env from it. OTEL_SERVICE_NAME is set fresh each iteration (it differs per app).
        # SetEnvironmentVariable, not Set-Item: Set-Item refuses an EMPTY value and, silenced, that
        # refusal is invisible - the same trap that made uninstall a no-op.
        foreach ($k in $appEnv.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$appEnv[$k], 'Process') }
        # No 2>&1 redirect (PS 5.1 NativeCommandError under Stop) - let pm2 write to the console.
        & $pm2Cli restart $r.Name --update-env
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[node-instr] pm2 restart $($r.Name) exited $LASTEXITCODE"
            $failed += $r.Name
        }
    }
}

if ($NoRestart) {
    Write-Host "[node-instr] -NoRestart: env prepared but apps not restarted. Run 'pm2 restart all --update-env; pm2 save' later."
} elseif ($PSCmdlet.ShouldProcess('pm2 dump', 'pm2 save')) {
    # Persist the updated env into the PM2 dump so it survives daemon restart / `pm2 resurrect`.
    if ($applyAsOwner) {
        $saveArgs = @{ Owner = $topo.Owner; Pm2Home = $topo.Home; Pm2ArgSets = @(, @('save')) }
        if ($Pm2OwnerCredential) { $saveArgs['OwnerCredential'] = $Pm2OwnerCredential }
        $res = Invoke-CxPm2AsOwner @saveArgs
        if ($res.Output) { Write-Host $res.Output }
        if (-not $res.Ok) { Write-Warning "[node-instr] pm2 save as $($topo.Owner) failed - $($res.Reason). The env is live but will not survive a daemon restart." }
    } else {
        & $pm2Cli save
    }
}

# A partial apply must not read as success: the operator has to know which apps are still dark.
if ($failed.Count -gt 0) {
    Write-Warning "[node-instr] NOT instrumented: $($failed -join ', ')"
}
# Refusals are reported SEPARATELY from failures, because they are a different thing: nothing was
# attempted and nothing is broken - the runtime simply cannot carry the instrumentation, and writing
# NODE_OPTIONS anyway would have produced an app that emits nothing while looking healthy. Grouped by
# code so a fleet run shows "11 apps on Node 16" as one line rather than eleven warnings.
if (@($refused).Count -gt 0) {
    Write-Host "[node-instr] refused by the runtime gate (nothing written, not claimed as services):" -ForegroundColor Yellow
    foreach ($g in ($refused | Group-Object Code)) {
        $vers = @($g.Group | ForEach-Object { if ($_.Version) { "$($_.Version)" } else { 'unknown' } } | Select-Object -Unique) -join ', '
        Write-Host ("    {0,-32} {1} app(s) [Node {2}]: {3}" -f $g.Name, $g.Count, $vers, (@($g.Group | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
    }
}

# ---- 3. Machine env var CX_NODE_SERVICES --------------------------------------
# Comma-joined distinct Node service name(s), built from the SAME $svcMap whose .ServiceName
# was just assigned as each app's OTEL_SERVICE_NAME. The collector stamps it onto INFRASTRUCTURE
# telemetry (Node analog of CX_IIS_SERVICES) so host Service-ownership == the APM service names.
$instrumented = @($svcMap | Where-Object { $failed -notcontains $_.Name })
$nodeServices = Get-NodeServiceLabelValue -Map $instrumented

# -WhatIf skipped every restart, so no app carries the env and claiming ownership of their service
# names would be a lie written to the machine environment. Report and stop here.
if (-not $PSCmdlet.ShouldProcess('machine environment', "set CX_NODE_SERVICES=$nodeServices")) {
    Write-Host "[node-instr] -WhatIf: would set machine CX_NODE_SERVICES=$nodeServices"
    return
}

# A staged rollout (-Apps) instruments a subset, so the var must be the UNION with what is
# already there - overwriting it would strip the ownership label off apps instrumented in an
# earlier pass, which reads in Coralogix as those services having gone away.
if ($Apps) {
    $existing = @()
    $priorVar = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
    if ($priorVar) { $existing = @($priorVar -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $union = @(@($existing) + @($instrumented | ForEach-Object { $_.ServiceName }) | Where-Object { $_ } | Select-Object -Unique)
    $nodeServices = ($union -join ',')
}
if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
    $prior = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
    Record-EnvChange -Session $Session -Name 'CX_NODE_SERVICES' -PriorValue $prior
}
[Environment]::SetEnvironmentVariable('CX_NODE_SERVICES', $nodeServices, 'Machine')
$env:CX_NODE_SERVICES = $nodeServices
Write-Host "[node-instr] set machine CX_NODE_SERVICES=$nodeServices" -ForegroundColor Green

# CX_NODE_SERVICES is an INPUT; the collector reads CX_SERVICES. A standalone run of this script
# (the staged `-Apps <app>` rollout, or closing a gap on one host) would otherwise leave the union
# stale, and a stale union is invisible: the app reports spans in APM while the host entity claims
# no ownership for it. Under the orchestrator ($Session set) Install-Agent.ps1 recomputes the union
# and restarts the collector itself, so the restart here is standalone-only.
if (Get-Command Update-CxServicesUnion -ErrorAction SilentlyContinue) {
    Update-CxServicesUnion -Session $Session -RestartCollector:(-not $Session) -LogPrefix '[node-instr]' | Out-Null
} else {
    Write-Warning '[node-instr] Write-DeployLog.ps1 is missing, so CX_SERVICES was not republished. The collector reads THAT variable for host Service ownership.'
}

if ($Session) {
    $Session.Manifest.nodeInstrumented        = (@($instrumented).Count -gt 0)
    $Session.Manifest.nodeInstrumentedApps    = @($instrumented | ForEach-Object { $_.Name })
    $Session.Manifest.nodeInstrumentFailedApps = @($failed)
    # Recorded so the doctor can tell "refused by the gate" apart from "we tried and it broke", and so
    # a later re-run on an upgraded runtime can see what changed.
    $Session.Manifest.nodeRefusedApps = @($refused | ForEach-Object {
        [ordered]@{ name = $_.Name; code = $_.Code; nodeVersion = "$($_.Version)" } })
}

Write-Host ""
if (@($instrumented).Count -eq 0) {
    # Loud, but not a throw: the collector is already installed and the orchestrator still has
    # to restart and verify it. The doctor (Test-NodeInstrumentation.ps1) is what grades this
    # host afterwards, and it will report the ownership mismatch as a hard fail.
    Write-Warning "[node-instr] NO app was instrumented. Nothing exports Node telemetry from this host yet - run doctor.bat -Only nodeInstrumentation for the reason."
} else {
    Write-Host "[node-instr] done. $(@($instrumented).Count) app(s) export OTLP to $OtlpEndpoint (traces+metrics+logs)."
    Write-Host "[node-instr] cluster workers share their app's OTEL_SERVICE_NAME; process.pid separates them."
}
