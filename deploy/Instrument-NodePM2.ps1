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

.NOTES
  Run in the SAME user context that owns the PM2 daemon (PM2 is per-user on Windows). Requires
  node, npm and pm2 on PATH, and (for the machine env var) an elevated session. Online npm access
  is required unless -SkipInstall. Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string]    $OtlpEndpoint         = 'http://127.0.0.1:4318',
    [string]    $InstallPrefix        = 'C:\cx\otel-node',
    [string]    $Package              = '@opentelemetry/auto-instrumentations-node',
    [hashtable] $ServiceNameOverrides = @{},
    [string]    $OverridesJson,
    [switch]    $NoRestart,
    [switch]    $SkipInstall,
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
foreach ($tool in 'node','npm','pm2') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Warning "[node-instr] '$tool' not found on PATH - skipping Node/PM2 instrumentation."
        return
    }
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

# ---- 2. Per-app OTEL_SERVICE_NAME + NODE_OPTIONS ------------------------------
# Merge overrides: JSON file first, then the -ServiceNameOverrides hashtable on top.
if ($OverridesJson) {
    if (-not (Test-Path $OverridesJson)) { throw "Overrides JSON not found: $OverridesJson" }
    $fromFile = Get-Content -LiteralPath $OverridesJson -Raw | ConvertFrom-Json
    foreach ($p in $fromFile.PSObject.Properties) {
        if (-not $ServiceNameOverrides.ContainsKey($p.Name)) { $ServiceNameOverrides[$p.Name] = $p.Value }
    }
}

$svcMap = Get-PM2ServiceMap -Overrides $ServiceNameOverrides

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
    $Session.Manifest.nodeInstrumented  = $true
    $Session.Manifest.nodeInstallPrefix = $InstallPrefix
}

Write-Host "[node-instr] instrumenting $(@($svcMap).Count) PM2 app(s):"
foreach ($r in $svcMap) {
    Write-Host ("  {0,-20} mode={1,-13} instances={2} -> OTEL_SERVICE_NAME={3}" -f $r.Name, $r.ExecMode, $r.Instances, $r.ServiceName)
    # Set the per-app env in THIS process; `pm2 restart --update-env` refreshes the app's
    # runtime env from it. OTEL_SERVICE_NAME is set fresh each iteration (it differs per app).
    $env:NODE_OPTIONS                = $nodeOptions
    $env:OTEL_EXPORTER_OTLP_ENDPOINT = $OtlpEndpoint
    $env:OTEL_EXPORTER_OTLP_PROTOCOL = 'http/protobuf'
    $env:OTEL_SERVICE_NAME           = $r.ServiceName
    $env:OTEL_TRACES_EXPORTER        = 'otlp'
    $env:OTEL_METRICS_EXPORTER       = 'otlp'
    $env:OTEL_LOGS_EXPORTER          = 'otlp'
    if (-not $NoRestart) {
        # No 2>&1 redirect (PS 5.1 NativeCommandError under Stop) - let pm2 write to the console.
        & pm2 restart $r.Name --update-env
        if ($LASTEXITCODE -ne 0) { Write-Warning "[node-instr] pm2 restart $($r.Name) exited $LASTEXITCODE" }
    }
}

if ($NoRestart) {
    Write-Host "[node-instr] -NoRestart: env prepared but apps not restarted. Run 'pm2 restart all --update-env; pm2 save' later."
} else {
    # Persist the updated env into the PM2 dump so it survives daemon restart / `pm2 resurrect`.
    & pm2 save
}

# ---- 3. Machine env var CX_NODE_SERVICES --------------------------------------
# Comma-joined distinct Node service name(s), built from the SAME $svcMap whose .ServiceName
# was just assigned as each app's OTEL_SERVICE_NAME. The collector stamps it onto INFRASTRUCTURE
# telemetry (Node analog of CX_IIS_SERVICES) so host Service-ownership == the APM service names.
$nodeServices = Get-NodeServiceLabelValue -Map $svcMap
if ($Session -and (Get-Command Record-EnvChange -ErrorAction SilentlyContinue)) {
    $prior = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
    Record-EnvChange -Session $Session -Name 'CX_NODE_SERVICES' -PriorValue $prior
}
[Environment]::SetEnvironmentVariable('CX_NODE_SERVICES', $nodeServices, 'Machine')
$env:CX_NODE_SERVICES = $nodeServices
Write-Host "[node-instr] set machine CX_NODE_SERVICES=$nodeServices" -ForegroundColor Green

Write-Host ""
Write-Host "[node-instr] done. $(@($svcMap).Count) app(s) export OTLP to $OtlpEndpoint (traces+metrics+logs)."
Write-Host "[node-instr] cluster workers share their app's OTEL_SERVICE_NAME; process.pid separates them."
