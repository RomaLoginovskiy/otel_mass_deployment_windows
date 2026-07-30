# Command reference

Every command in this repository, with every argument, its default, and what it changes. Ordered
the way an operator meets them: build a package, deploy it, instrument workloads, diagnose,
uninstall.

Conventions used throughout:

- **Elevation.** Anything that writes to `applicationHost.config`, a service, or machine-scope
  environment must run as Administrator. The diagnostics also require it — `applicationHost.config`
  is readable by Administrators only, and a non-elevated run would report every IIS app as
  unconfigured, which is exactly the symptom you would be investigating. They refuse rather than
  lie.
- **PowerShell 5.1.** The .NET auto-instrumentation module requires Windows PowerShell 5.1, not
  PowerShell 7. The `.bat` entry points launch `5.1` for you, and re-launch through
  `%SystemRoot%\Sysnative\…` when started from a 32-bit process so the install never inherits
  WOW64.
- **Exit codes.** `0` success, `1` hard fail, `2` degraded. Full contract and every finding code:
  [exit-codes.md](exit-codes.md).
- **Environment variables** referenced here are documented in [env-vars.md](env-vars.md).

## Package build

### `Build-DeploymentPackage.ps1` (repo root)

Zips `deploy/` into a single archive a fleet tool can push. Run it on your workstation.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-KeyFile` | string | none | Bakes the Send-Your-Data key into the package as `SendDataKey.txt`. Without it the package is built **keyless** — supply `CORALOGIX_PRIVATE_KEY` at deploy time, or drop `SendDataKey.txt` on each host. |
| `-Region` | string | none | Bakes the Coralogix region into `region.txt`, so hosts do not need `CX_REGION` set. |
| `-OutFile` | string | `coralogix-agent-deploy.zip` beside the script | Output path. |

```powershell
.\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx-send-your-data.key -Region eu2
```

> A keyed zip is a secret. Do not commit it, and do not leave it on a share.

## Deploy

### `deploy.bat`

The entry point a fleet tool runs on each host. Launches `Install-Agent.ps1` under PowerShell 5.1
with the execution policy bypassed for that process only, and propagates the exit code so a failed
install shows as a failed row.

Two ways to pass options, and they are **mutually exclusive by design**:

```bat
REM 1. arguments - forwarded verbatim to Install-Agent.ps1
deploy.bat -Region eu2 -Environment prod

REM 2. environment variables - for tools that cannot pass arguments to a remote command
set CX_REGION=eu2 && set CX_ENVIRONMENT=prod && deploy.bat
```

Typing **any** argument skips the environment-variable block entirely. Mixing the two would pass
the same parameter twice, which PowerShell rejects outright ("parameter is specified more than
once") — the script would never run and the fleet tool would show a red row with no diagnostics.

| Variable | Becomes |
| --- | --- |
| `CORALOGIX_PRIVATE_KEY` | `-PrivateKey <value>` |
| `CX_REGION` | `-Region <code>` |
| `CX_DOMAIN` | `-Domain <domain>` |
| `CX_ENVIRONMENT` | `-Environment <label>` |
| `CX_NO_SUPERVISOR` | `-NoSupervisor` |
| `CX_SKIP_INSTRUMENT` | `-SkipInstrument` |

`CORALOGIX_DOMAIN` and `CX_RUNTIME_OVERRIDES_JSON` are **not** forwarded as flags; the scripts read
them directly. See [env-vars.md](env-vars.md) for why.

### `Install-Agent.ps1`

The orchestrator. Detects workloads, installs the collector, conditionally instruments IIS, Node
and .NET services, publishes the ownership variables, then verifies. Opens a backup session first
and records every config it changes.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Region` | string | `region.txt`, then a previous install, then `eu1` | Region code (`eu1`, `eu2`, `us1`, `us2`, `us3`, `ap1`, `ap2`, `ap3`). Resolved to `<region>.coralogix.com` and published as `CORALOGIX_DOMAIN`. An unknown code fails the install rather than shipping nowhere. |
| `-Domain` | string | none | Full ingress domain for a private endpoint. Wins over `-Region`, taken verbatim, not validated against the region list. |
| `-KeyFile` | string | `SendDataKey.txt` beside the script | **Path** to a file holding the Send-Your-Data key. |
| `-PrivateKey` | string | none | The key **value**. Overrides `-KeyFile`. |
| `-Environment` | string | none | `deployment.environment.name` for this host, e.g. `prod`. |
| `-Application` | string | none | Coralogix application name for this host. Omit to fall back to the host's own name. |
| `-NoSupervisor` | switch | off | Install the plain `otelcol-contrib` service with a local config instead of the OpAMP Supervisor. Affects only the vendor-installer arguments. |
| `-SkipInstrument` | switch | off | Install the collector and leave IIS/Node/.NET services alone. |
| `-DotNetServices` | string | none | Comma-separated Windows service names to instrument as .NET services outside IIS. Merged with `CX_DOTNET_SERVICE_NAMES`. Without either, no Windows service is instrumented and the run says so. |
| `-InstrumentVersion` | string | `v1.16.0-beta.1` | Auto-instrumentation release tag forwarded to `Instrument-IIS.ps1`. |

> **`-PrivateKey` takes the key value; `-KeyFile` takes a path.** Nothing validates the shape of
> `-PrivateKey`, so `-PrivateKey .\SendDataKey.txt` is accepted and the *path string* becomes the
> bearer token. The result is an install that reports success while the supervisor gets HTTP 403
> from the OpAMP endpoint and every export fails `Unauthenticated` — no data in Fleet Management
> and none in Infrastructure Explorer. If the package already ships `SendDataKey.txt`, pass
> neither flag.

What it leaves behind: the collector service, machine-scope variables (see
[env-vars.md](env-vars.md)), a backup directory under `C:\ProgramData\CoralogixDeploy\backups\`,
and two reports next to the scripts — `install-agent-status.json` and `detect-workloads.json`.

## Collector install

### `Install-CoralogixSupervisor.ps1`

Installs the Coralogix collector, with the OpAMP Supervisor by default. Called by
`Install-Agent.ps1`; run it directly to install only the collector.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Region` | string | resolved from environment / `region.txt` | Region code, resolved to the ingress domain and published as `CORALOGIX_DOMAIN`. |
| `-Domain` | string | none | Full ingress domain. Wins over `-Region`. Resolution order when neither is given: `CX_DOMAIN`, then `CX_REGION`, then a persisted `CORALOGIX_DOMAIN`, then the baked-in region. |
| `-PrivateKey` | string | none | Key value. If omitted, read from `-KeyFile`. |
| `-KeyFile` | string | `SendDataKey.txt` beside the script | Path to the key file. |
| `-NoSupervisor` | switch | off | Use the vendor installer's regular mode: registers `otelcol-contrib` and passes the config with `-Config` instead of the supervisor flags. |
| `-BaseConfig` | string | `config.supervisor.yaml` beside the script | Source template for the collector config. The name is historical — the file is opamp-free and serves both modes. |
| `-StageDir` | string | the script's own folder | Where the staged config is produced. The vendor installer copies it from there. |
| `-Version` | string | none | Pin a collector version (passed to the vendor installer). |
| `-Environment` | string | none | Persisted as `CX_ENVIRONMENT`; the config stamps it as `deployment.environment.name`. |
| `-Application` | string | none | Persisted as `CX_APPLICATION`; the config stamps it as `service.namespace`, which the exporter maps to the application name. Omit for the host-name fallback. |
| `-ResourceAttributes` | string | machine `OTEL_RESOURCE_ATTRIBUTES` | Attributes injected into the supervisor `AgentDescription` so Fleet Management can target the host. Normally supplied by detection. |
| `-Session` | object | none | An open backup session, so config changes are recorded. Passed by `Install-Agent.ps1`. |

In supervisor mode the collector's configuration is owned **remotely** by Fleet Management; the
base config is only the starting point the supervisor merges into. Deploy scripts set environment
variables, not collector config.

## Workload detection

### `Detect-Workloads.ps1`

Probes the host for IIS, .NET, Node, PM2, Redis, Valkey, SQL Server, DB2, RabbitMQ and
Elasticsearch, and publishes the result as `OTEL_RESOURCE_ATTRIBUTES` (`cx.host.role`,
`workload.*`) so Fleet Management can select hosts by what they actually run.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-SetEnv` | bool | `$true` | Persist `OTEL_RESOURCE_ATTRIBUTES` at machine scope. `-SetEnv:$false` probes and reports only. |
| `-LogPath` | string | `detect-workloads.json` beside the script | Where the JSON report is written. |
| `-ExtraAttributes` | hashtable | `@{}` | Extra attributes merged into the published set. |
| `-Session` | object | none | Open backup session, so the variable change is recorded. |

Dot-source it to get the probe helpers (`Get-IisPresent`, `Get-NodeInfo`, `Get-PM2Info`,
`Get-SqlServerPresent`, …) without running a scan.

## Instrumenters

All four default `-OtlpEndpoint` to `http://127.0.0.1:4318` and rewrite a `localhost` value
passed explicitly: on a dual-stack Windows host `localhost` resolves to `::1` first and OTLP
export is dropped with no error.

The three service/PM2 instrumenters — `Instrument-NodePM2.ps1`, `Instrument-NodeService.ps1` and
`Instrument-DotNetService.ps1` — support `-WhatIf`, because their outward-facing step is
restarting a live app. `-WhatIf` prints every restart and variable write it would perform and
changes nothing, including the ownership variable. `Instrument-IIS.ps1` does not support it; use
`-NoReset` there to keep the change from recycling IIS immediately.

### `Instrument-IIS.ps1`

Zero-code .NET auto-instrumentation for IIS. Classifies every application's runtime first, writes
a distinct `OTEL_SERVICE_NAME` per app, points pools at the local collector, and publishes
`CX_IIS_SERVICES` plus the IIS log-directory slots.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Version` | string | `v1.16.0-beta.1` | Auto-instrumentation release tag to install. |
| `-OtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint written to the pools. |
| `-NoReset` | switch | off | Skip the final `iisreset` — recycle manually during a maintenance window. |
| `-LocalArchive` | string | `CX_OTEL_DOTNET_ARCHIVE` | Pre-staged auto-instrumentation archive, for hosts with no internet access. |
| `-LocalModule` | string | `CX_OTEL_DOTNET_MODULE` | Pre-staged auto-instrumentation PowerShell module. |
| `-ServiceNameOverrides` | hashtable | `@{}` | Rename apps, keyed by the **derived service name**: `@{ 'Wallet/api' = 'wallet-api' }`. Merged over the JSON file if both are given. |
| `-OverridesJson` | string | none | Path to a JSON file of the same `{ autoName = overrideName }` shape. |
| `-RuntimeOverrides` | hashtable | `@{}` | Force an app's runtime when detection cannot decide, keyed by **application identity**: `@{ 'Wallet/api' = 'AspNetCore'; 'Static/' = 'NonDotNet' }`. Allowed values `AspNetCore`, `AspNetFramework`, `NonDotNet`; anything else fails the run. |
| `-RuntimeOverridesJson` | string | `CX_RUNTIME_OVERRIDES_JSON` | Path to a JSON file of `{ "Site/AppPath": "AspNetCore" }` pairs, optionally wrapped as `{ "runtimeOverrides": { … } }`. |
| `-NodeInstallPrefix` | string | `C:\cx\otel-node` | Where the OTel **Node** package is staged, for iisnode apps. Same package and default as `Instrument-NodePM2.ps1 -InstallPrefix`. Never installed by this script — see below. |
| `-NoIisnode` | switch | off | Leave iisnode applications alone. They are still classified and reported; only the writing is suppressed. |
| `-Session` | object | none | Open backup session. |

**iisnode applications** are instrumented **by default**: `NODE_OPTIONS` (merged with the app's own
flags), `OTEL_SERVICE_NAME`, endpoint, protocol and the three exporter variables go on the **app
pool**, because iisnode's `node.exe` is a child of `w3wp` and inherits the pool's environment. Their
names join `CX_NODE_SERVICES`, not `CX_IIS_SERVICES`. This path never runs `npm install` — the
package must already be staged, or the app is reported `IISNODE_PACKAGE_MISSING` and left alone.
Full behaviour: [nodejs-pm2.md](../nodejs-pm2.md#node-under-iisnode).

The two override parameters use **different key spaces**, differing by one character for a root
app: service-name keys are `Wallet` / `Wallet/api`, runtime keys are `Wallet/` / `Wallet/api`. The
runtime key is exactly the string the doctor prints in its `Target` column. Pass the same runtime
overrides to the install and the doctor, or they will disagree about which apps belong in
`CX_IIS_SERVICES` and report drift permanently.

### `Instrument-NodePM2.ps1`

Zero-code instrumentation for Node.js apps managed by PM2, via per-app `NODE_OPTIONS`. Runs `pm2`
as the daemon's owning account when PM2 is hosted as a Windows service.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-OtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint written to each app. |
| `-InstallPrefix` | string | `C:\cx\otel-node` | Directory the OTel Node package is installed under. |
| `-Package` | string | `@opentelemetry/auto-instrumentations-node` | npm package providing the `register` bootstrap. |
| `-ServiceNameOverrides` | hashtable | `@{}` | Rename apps, keyed by PM2 app name. |
| `-OverridesJson` | string | none | JSON file of the same `{ pm2Name = overrideName }` shape. |
| `-Apps` | string[] | all apps | Instrument only these PM2 apps — a staged rollout. |
| `-ExcludeApps` | string[] | none | Skip these PM2 apps. |
| `-NoRestart` | switch | off | Set the variables and install the package but skip `pm2 restart` / `pm2 save`. The change applies at the next restart. |
| `-SkipInstall` | switch | off | Skip `npm install`; the package is already staged under `-InstallPrefix`. |
| `-Pm2OwnerCredential` | pscredential | none | Credential for the account owning the PM2 daemon, when it cannot be impersonated automatically. |
| `-Session` | object | none | Open backup session. |

CommonJS apps get `--require`, ESM apps get `--import`. The wrong form starts the app and emits
nothing — reported as `NODE_ESM_REQUIRE_MISMATCH`.

### `Instrument-NodeService.ps1`

For Node apps that run as a Windows **service** with no PM2 involved. Does not run `npm install`,
so it works on a host with no registry access.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Services` | string[] | `@()` | Windows service names to instrument. |
| `-OtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint written to the service. |
| `-InstallPrefix` | string | `C:\cx\otel-node` | Where the OTel Node package already is. Must exist. |
| `-Package` | string | `@opentelemetry/auto-instrumentations-node` | Package providing the bootstrap. |
| `-ServiceNameOverrides` | hashtable | `@{}` | Service → `OTEL_SERVICE_NAME`. Without an override the Windows service name is used. |
| `-NssmPath` | string | auto-detected | Path to `nssm.exe`, for services wrapped by NSSM whose environment lives in the NSSM parameters rather than the service key. |
| `-Remove` | switch | off | Take the OTel variables back out and restart, leaving anything the service already had. |

### `Instrument-DotNetService.ps1`

For .NET apps that run as a Windows **service**, outside IIS.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Services` | string[] | **required** | Windows service names to instrument. |
| `-OtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint written to the service. |
| `-AutoHome` | string | derived from W3SVC | `OTEL_DOTNET_AUTO_HOME` to use when W3SVC carries no profiler variables — i.e. a host with no IIS. Profiler paths are derived from it the way the vendor module lays them out. |
| `-ServiceNameOverrides` | hashtable | `@{}` | Service → `OTEL_SERVICE_NAME`. |
| `-Remove` | switch | off | Remove the OTel variables and restart. |

Publishes `CX_DOTNET_SERVICES`, which `Install-Agent.ps1` folds into `CX_SERVICES`.

## Diagnostics

Read-only: they never set a variable, never run `appcmd` or `iisreset`, never start or stop a
service, and never download anything. The only writes are their JSON reports.

### `doctor.bat`

Entry point for `Test-Agent.ps1`; propagates the graded exit code and prints
`doctor.bat exit code: N`. Same argument-or-environment exclusivity as `deploy.bat`.

| Variable | Becomes |
| --- | --- |
| `CX_DOCTOR_ONLY` | `-Only <checks>` |
| `CX_DOCTOR_QUIET` | `-Quiet` |
| `CX_DOCTOR_NOFILE` | `-NoFileOutput` |

### `Test-Agent.ps1`

The host doctor: environment variables, per-app service-name readback, services, health, export
counters, OTLP ports, the effective collector config, and both instrumentation validators.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Only` | string[] | all nine checks | Run a subset. Accepted names, matched case-insensitively and also accepted comma-joined in one string: `env`, `iisServiceName`, `services`, `health`, `exportCounters`, `ports`, `effectiveConfig`, `iisInstrumentation`, `nodeInstrumentation`. Unselected checks report `NOT_SELECTED`; an unrecognised name is a hard fail (`BAD_ARGUMENT`, exit `1`) rather than a silent no-op. |
| `-JsonPath` | string | `agent-doctor.json` beside the script | Where the machine-readable report goes. |
| `-NoFileOutput` | switch | off | Do not write the report. |
| `-Quiet` | switch | off | Drop `pass` and `skip` rows from the table. |
| `-PassThru` | switch | off | Emit the findings as objects for further processing. |
| `-HealthUrl` | string | `http://127.0.0.1:13133` | Collector health endpoint. |
| `-MetricsUrl` | string | `http://127.0.0.1:8888/metrics` | Collector internal-metrics endpoint, used for export counters. |
| `-OtlpHttpPort` | int | `4318` | OTLP HTTP port to test. |
| `-OtlpGrpcPort` | int | `4317` | OTLP gRPC port to test. |
| `-EffectiveConfig` | string | `C:\ProgramData\opampsupervisor\state\effective.yaml` | Supervisor effective config — what the collector is really running. |
| `-BaseCollectorConfig` | string | the supervisor's base `collector.yaml` | Fallback when there is no effective config yet. |
| `-LocalCollectorConfig` | string | the non-supervisor collector's config path | Fallback for a `-NoSupervisor` install, where no supervisor state exists. |
| `-RequiredProcessors` | string[] | the IIS service-label transform | Processors that must be present **and wired** into a pipeline. |
| `-RequiredPipelines` | string[] | the logs and resource-catalog pipelines | Pipelines those processors must appear in. |
| `-ExpectedOtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint pools and services are expected to carry. |
| `-ServiceNameOverrides` | hashtable | `@{}` | Same overrides the install was given, so expected names match. |
| `-OverridesJson` | string | none | JSON form of the above. |
| `-RuntimeOverrides` | hashtable | `@{}` | Same runtime overrides the install was given. |
| `-RuntimeOverridesJson` | string | `CX_RUNTIME_OVERRIDES_JSON` | JSON form of the above. |
| `-HealthRetries` | int | `3` | Health-endpoint attempts before reporting unreachable. |
| `-HealthDelaySec` | int | `5` | Delay between those attempts. |
| `-TimeoutSec` | int | `8` | Per-request timeout. |
| `-NodeInstallPrefix` | string | `C:\cx\otel-node` | Where the Node instrumentation package should be. |

```powershell
# everything
doctor.bat

# just the environment variables and the IIS service names
powershell -NoProfile -ExecutionPolicy Bypass -File Test-Agent.ps1 -Only env,iisServiceName
```

### `Test-IISInstrumentation.ps1`

Validates that the IIS instrumentation actually landed: CLR profiler registration, the profiler
DLL, pool OTLP variables, pool/runtime pairing, and IIS log coverage.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-ExpectedOtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint the pools should carry. |
| `-AppHostConfig` | string | resolved from the IIS directory | Path to `applicationHost.config`. Resolved per process bitness, so a 32-bit shell reads the real file rather than the redirected one. |
| `-BackupRoot` | string | `C:\ProgramData\CoralogixDeploy\backups` | Where to read the install manifest, for the installed-version finding. |
| `-RuntimeOverrides` | hashtable | `@{}` | Same runtime overrides the install was given. |
| `-RuntimeOverridesJson` | string | `CX_RUNTIME_OVERRIDES_JSON` | JSON form of the above. |
| `-Quiet` | switch | off | Drop `pass` and `skip` rows. |
| `-PassThru` | switch | off | Emit findings as objects. |

### `Test-NodeInstrumentation.ps1`

The same for Node/PM2: `NODE_OPTIONS`, the register bootstrap, per-app service names, PM2 daemon
ownership.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-InstallPrefix` | string | `C:\cx\otel-node` | Where the OTel Node package should be. |
| `-Package` | string | `@opentelemetry/auto-instrumentations-node` | Package expected under that prefix. |
| `-ExpectedOtlpEndpoint` | string | `http://127.0.0.1:4318` | Endpoint apps should carry. |
| `-EffectiveConfig` | string | the supervisor effective config | Read to decide whether anything consumes `CX_NODE_SERVICES`. |
| `-Quiet` | switch | off | Drop `pass` and `skip` rows. |
| `-PassThru` | switch | off | Emit findings as objects. |

Both validators are **dual-mode**: run them directly and they print their own table and set their
own exit code; dot-source them and they define a function returning findings, which is how
`Test-Agent.ps1` reuses them. One implementation, two entry points.

## Uninstall

### `uninstall.bat`

Entry point for `Uninstall-Agent.ps1`.

| Variable | Becomes |
| --- | --- |
| `CX_PURGE` | `-Purge` |
| `CX_RESTORE` | `-RestoreConfigs` |

### `Uninstall-Agent.ps1`

Reverses what the install did, guided by the backup manifest, so only the installer's **own**
changes are touched: removes the collector/supervisor service, unregisters the IIS profiler,
strips the `OTEL_*` pool and `web.config` entries it added (restoring any pre-existing value), and
clears the machine variables it set. Hosted applications are left alone.

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Purge` | switch | off | Also delete the staged config and the vendor binaries (`C:\otel`, the collector and supervisor data directories, the OpenTelemetry Program Files directories). Off by default so a re-install stays fast. |
| `-RestoreConfigs` | switch | off | Restore `applicationHost.config`, each `web.config` and the supervisor `config.yaml` from the backup instead of making surgical edits. The profiler is still unregistered and services still removed. |
| `-NoReset` | switch | off | Skip the final `iisreset`. |
| `-InstrumentVersion` | string | manifest value, then `v1.16.0-beta.1` | Auto-instrumentation release tag for the vendor module used to unregister. |
| `-BackupRoot` | string | `C:\ProgramData\CoralogixDeploy\backups` | Where to look for the manifest. `latest.json` points at the newest run. |

## Dot-sourced helper libraries

These are libraries, not commands: dot-source them to get their functions. The install, uninstall
and diagnostic scripts all use them, which is why a single behaviour cannot drift between install
time and check time.

| File | Key functions | Purpose |
| --- | --- | --- |
| `Resolve-CxRegion.ps1` | `Resolve-CxDomain`, `Get-CxRegions`, `Get-CxRegionForDomain`, `Format-CxRegionList` | Region ↔ domain resolution, and the validation that rejects an unknown region code. |
| `Resolve-IISServiceNames.ps1` | `Get-IISServiceMap`, `Get-IISServiceLabelValue`, `Set-WebConfigServiceName`, `Remove-WebConfigServiceName` | Per-app `OTEL_SERVICE_NAME` mapping and `web.config` read/write. Accepts `-Overrides`, `-RuntimeOverrides`, and `-SkipRuntimeClassification` when the caller has already classified the apps. |
| `Resolve-IISAppRuntime.ps1` | `Resolve-IISAppRuntime`, `Get-IISAppInstrumentability`, `Resolve-IISRuntimeOverrides` | Classifies one application's real runtime. Takes `-Site` and `-AppPath` — the same identity used as a runtime-override key. |
| `Resolve-IISLogPaths.ps1` | `Get-IISLogConfig`, `Get-IISLogDirSlots`, `Test-IISLogDirCovered` | Discovers where IIS really writes access logs and fills the `CX_IIS_LOG_DIR_n` slots. `-AppHostConfig` overrides the config path. |
| `Resolve-NodeServiceNames.ps1` | `Get-CxPm2Topology`, `Invoke-CxPm2AsOwner`, `Merge-CxNodeOptions`, `Get-NodeServiceLabelValue` | PM2 topology, per-app Node service names, and running `pm2` as the daemon's owner. |
| `Backup-Config.ps1` | `New-BackupSession`, `Backup-DeployFile`, `Record-EnvChange`, `Save-Manifest`, `Restore-DeployFile` | The backup session every install opens. `-BackupRoot` and `-Timestamp` control where a session writes; the default timestamp is generated per run, so pass it only to reuse an existing session directory. |
| `Write-DeployLog.ps1` | `New-Finding`, `Get-GradedExitCode`, `Write-FindingTable`, `Resolve-CxOtlpEndpoint` | The shared finding model, the graded exit-code rule, and the `localhost` → `127.0.0.1` rewrite. |

## Operator-side verification

In `scripts/`. These run on **your workstation**, not the host, and query the Coralogix API to
confirm what actually arrived. They need a Coralogix **query** key (not a Send-Your-Data key).

| Script | Answers |
| --- | --- |
| `Verify-CoralogixServiceTelemetry.ps1` | Which service names are reporting from one host — and which are correctly reporting nothing. Exit 0 only when every expectation holds. |
| `Verify-CoralogixInfraLabels.ps1` | Which IIS service-label attribute keys reach ingestion on infrastructure telemetry, and which resolve to a queryable label and Service ownership. |
| `Verify-CoralogixAppName.ps1` | Whether the application name resolved as intended on all signal paths. |
| `Verify-CoralogixNodeSpans.ps1` | Whether PM2-managed Node apps report traces and logs, and whether a cluster app reports per worker. |
| `Verify-Pm2Coverage.ps1` | Which PM2 apps a host runs versus which are actually reporting. Needs no host access. |

Arguments common to all five:

| Flag | Type | Default | What it does |
| --- | --- | --- | --- |
| `-Region` | string | `eu1` | Selects the query endpoint. The bare `ng-api-http.coralogix.com` host is the **US** cluster and answers 403 for an EU account, so this must match the account. |
| `-ApiUrl` | string | derived from `-Region` | Full DataPrime query URL, for a private endpoint. |
| `-ApiHost` | string | the default query host | Host-only form of the above, used by `Verify-Pm2Coverage.ps1`. |
| `-QueryKeyFile` | string | none | File holding the query key. Accepts `label - token` lines, so one file can hold several keys. |
| `-KeyLabel` | string | first Coralogix key in the file | Which labelled key to use. |
| `-HostName` | string | none (**required** by `Verify-Pm2Coverage.ps1`) | Host to ask about. Without it, a shared account will answer from another machine's telemetry. |
| `-LookbackMinutes` | int | 60–90 depending on the script | Query window. |
| `-Tiers` | string[] | frequent search, then archive | Storage tiers to query. Data routed away from frequent search is only visible in the archive tier. |

Per-script arguments:

| Script | Flag | Default | What it does |
| --- | --- | --- | --- |
| `Verify-CoralogixServiceTelemetry.ps1` | `-Services` | empty | Service names that must be reporting. |
| | `-MustBeSilent` | empty | Service names that must **not** report — a negative gate. |
| | `-RequireLogs` | off | Require logs as well as spans. |
| `Verify-CoralogixInfraLabels.ps1` | `-ExpectedValue` | machine `CX_IIS_SERVICES` | The ownership value the host's labels should carry. |
| | `-MustNotContain` | empty | Names that must not appear on the host's labels; turns the report into a gate. |
| | `-DumpSample` | off | Print a sample document for eyeballing. |
| `Verify-CoralogixAppName.ps1` | `-ExpectedApplication` | a repository fixture value — **always pass this** | The application name every signal path should carry, normally the host's own name. |
| | `-LegacyApplication` | a repository fixture value | A previous application name that must have **zero** rows left for this host. |
| | `-PromUrl` | the region's PromQL endpoint | Metrics are checked over PromQL, not DataPrime. |
| `Verify-CoralogixNodeSpans.ps1` | `-Services` | repository fixture names — **always pass these** | PM2 service names that must report spans and logs. |
| | `-ClusterService` | a fixture name | The cluster-mode app expected to report from several workers. |
| | `-MinClusterWorkers` | `2` | How many distinct workers that app must show. |
| `Verify-Pm2Coverage.ps1` | `-ExpectedApps` | derived from `pm2_up` | Override the expected app list instead of deriving it. |
| | `-ExcludeApps` | PM2's own utility apps | Apps to leave out of the comparison. |
| | `-UserAgent` | a browser-like value | Some default agents get a Cloudflare 403 from every region host, which looks identical to a bad key. |

Several parameters default to values from this repository's own fixtures. Always pass the ones
that describe *your* host and services explicitly rather than relying on a default.

`CxQuery.Common.ps1` is the shared library behind them; dot-source it for `Get-CxQueryKey -Path
<file> [-Label <label>]` and `Invoke-CxDataPrime`. Two things it exists to prevent: an HTTP
failure being reported as "no data" (a non-200 raises, and 401/403 is named as unauthorised), and
the whole multi-line key file being sent as one token. `Get-CxQueryKey` returns an **object** with
`.Label` and `.Token` — pass `.Token`, not the object, or the request goes out as
`Bearer @{Label=…}` and every query 403s.

## Sample-app helpers

Also in `scripts/`, for exercising the instrumentation on a test box. Windows PowerShell 5.1,
elevated, and they assume a collector on `127.0.0.1:4318`.

`deploy-app.ps1` builds, deploys and instruments the repository's sample ASP.NET Core application
on IIS in one pass:

| Flag | Default | What it does |
| --- | --- | --- |
| `-SourceDir` | the sample app's project directory | What to build. |
| `-PublishDir` | `publish` beside the script | Where `dotnet publish` output goes. |
| `-SitePath` | a path under `C:\inetpub` | Filesystem root for the IIS site. |
| `-SiteName` | the sample app's name | IIS site to create or update. |
| `-AppPool` | the sample app's pool name | Application pool to create or update. |
| `-Port` | `8080` | HTTP binding port. |
| `-ServiceName` | the site name | `OTEL_SERVICE_NAME` for the deployed app. |
| `-OtlpEndpoint` | `http://127.0.0.1:4318` | Collector endpoint written to the pool. |
| `-Configuration` | `Release` | Build configuration. |
| `-Environment` | empty | Sets `CX_ENVIRONMENT` and stamps the environment tags. |
| `-LoadSweeps` | `40` | How many request sweeps to fire after deploying, so spans exist immediately. |
| `-InstrumentAllApps` | off | Instrument and name **every** IIS site and application on the host, not just the sample app. |

`generate-load.ps1` sends steady traffic to a deployed app:

| Flag | Default | What it does |
| --- | --- | --- |
| `-Port` | `8080` | Target port on localhost. |
| `-Paths` | the sample app's routes | Paths to request in rotation. |
| `-DelayMs` | `200` | Delay between requests. |
| `-DurationMinutes` | `0` (run until stopped) | How long to keep going. |
| `-StatsEverySec` | `10` | How often to print a summary. |

## Linux hosts

In `deploy-linux/`. Installs the OpAMP Supervisor and collector on a Linux database host so its
config is owned remotely by Fleet Management, matching the Windows pattern. Driven entirely by
environment variables — see [../linux.md](../linux.md) for the full table.

| Script | Purpose |
| --- | --- |
| `install-supervisor-default.sh` | Single-command install for one host. `APP_TYPE` selects the database receiver, `ENV_TYPE` labels the environment. |
| `templates/install-supervisor-by-apptype.sh` | The same install, parameterised by app type, for pushing across a mixed fleet. |

Core variables: `CORALOGIX_PRIVATE_KEY`, `CORALOGIX_REGION` (or `CORALOGIX_DOMAIN`), `APP_TYPE`,
`ENV_TYPE`, plus the credentials the selected receiver needs (`POSTGRES_*`, `REDIS_*`,
`VALKEY_*`, `ELASTICSEARCH_ENDPOINT`).

## Legacy single-host scripts

In `misc/`. Superseded by `deploy/` — kept because they are self-contained and occasionally
useful on a single machine. They do not open a backup session and are not manifest-guided, so
they cannot be rolled back the way `Uninstall-Agent.ps1` rolls back an install.

| Script | Purpose | Notable arguments |
| --- | --- | --- |
| `install-coralogix-collector.ps1` | Installs the collector on one host from `CORALOGIX_PRIVATE_KEY`. | none |
| `uninstall-coralogix-collector.ps1` | Removes it. | `-RemoveConfig` also deletes the config. |
| `apply-config.ps1` | Applies a local collector config and restarts the service. | none |
| `Set-CxServiceLabels.ps1` | Self-contained setup and diagnosis of `CX_IIS_SERVICES` for IIS **and** PM2 apps on one host. | `-Apply` (write, otherwise report only), `-RestartCollector` (default `$true`), `-NoUnion`, `-SkipIis`, `-SkipNode`, `-ServiceNameOverrides`, `-OverridesJson`, `-LogPath` |
| `Enable-IisnodeInstrumentation.ps1` | Turns on zero-code OTel for **iisnode** apps on an already-deployed host, without re-running `Instrument-IIS.ps1`. App pool environment only: no `npm install`, no PM2, no `CX_*` labels, no collector, no .NET profiler. Recycles only the pools it changed — never `iisreset`. | `-Apply` (write + recycle, otherwise report only), `-Recycle` (default `$true`), `-Pools`, `-Apps`, `-InstallPrefix` (default `C:\cx\otel-node`), `-OtlpEndpoint`, `-ServiceNameOverrides`, `-OverridesJson`, `-LogPath` |
| `Test-CxInstrumentation.ps1` | Read-only validator: is auto-instrumentation configured, and is every receiver in the config producing data? | `-Only`, `-CollectorConfig`, `-SampleSeconds` (default `35`), `-Fast`, `-ProbeEndpoints`, `-SendTestSpan`, `-JsonPath`, `-Quiet`, `-PassThru` |
| `wire-db.ps1` | Wires database receivers into a local collector config. | none |

Prefer `deploy/doctor.bat` over `misc/Test-CxInstrumentation.ps1`: the doctor is the one with the
graded exit code, the finding catalog, and the read-only guarantee.

## Related

- [env-vars.md](env-vars.md) — every variable these commands read or write
- [exit-codes.md](exit-codes.md) — what a non-zero exit means
- [../fleet.md](../fleet.md) — the deployment runbook these commands serve
- [../single-host.md](../single-host.md) — the manual, one-host path
