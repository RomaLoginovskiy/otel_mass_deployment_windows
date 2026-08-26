# Exit codes and finding codes

Every diagnostic in the deployment package reports the same way: a table of findings, each with
a severity, and one graded process exit code derived from those severities. This page is the
complete catalog — the graded contract, then all 76 finding codes with what each one means and
what to do about it.

Applies to `doctor.bat`, `Test-Agent.ps1`, `Test-IISInstrumentation.ps1` and
`Test-NodeInstrumentation.ps1`. For how to invoke them, see [cli.md](cli.md); for the reasoning
behind the individual checks, see [../diagnostics.md](../diagnostics.md).

## The graded contract

| Code | Meaning |
| --- | --- |
| `0` | Every check passed, or was legitimately not applicable to this host |
| `1` | **Hard fail** — not elevated, no private key, the collector is down, or a malformed profiler registry |
| `2` | **Degraded** — the collector is up but something is misconfigured |

The rule lives in one place (`Get-GradedExitCode` in `deploy/Write-DeployLog.ps1`) so a
standalone validator and the aggregating doctor cannot drift:

```text
1  any fail
2  no fail, at least one warn
0  otherwise
```

`pass`, `info`, `skip` and `unknown` never move the code. In particular **`unknown` is not a
failure**: it means the script could not determine the answer (no permission, a missing module,
a PM2 daemon owned by another account). Reporting that as "broken" would send you down the
wrong path.

BatchPatch marks any non-zero exit as a failed (red) row, so `1` and `2` both show red. The
distinction is in the Exit Code column and in the `doctor.bat exit code: N` line the entry point
prints. Triage `2` rows in bulk; triage `1` rows individually.

## Severity summary

Counts are **distinct `-Code` values actually emitted** by `Test-Agent.ps1`,
`Test-IISInstrumentation.ps1` and `Test-NodeInstrumentation.ps1` — not documented rows — so they can be
re-derived from the scripts rather than trusted. `pass` and most `info` findings carry no code.

| Severity | Codes | Effect on exit code |
| --- | --- | --- |
| `fail` | 14 | Sets `1` |
| `warn` | 41 | Sets `2` unless a `fail` is also present |
| `pass` | 0 (uncoded) | None |
| `info` | 10 | None |
| `skip` | 5 | None |
| `unknown` | 14 | None |

## `fail` — exit 1

| Code | Meaning | Fix |
| --- | --- | --- |
| `NOT_ELEVATED` | Not running as Administrator. Nothing else was checked, because the answers would be false. | Re-run elevated. |
| `BAD_ARGUMENT` | An argument was rejected (for example an invalid `-RuntimeOverrides` value). Nothing ran. | Correct the argument; see [cli.md](cli.md). |
| `PRIVATE_KEY_MISSING` | No machine `CORALOGIX_PRIVATE_KEY` — the collector cannot authenticate and nothing reaches Coralogix. | Re-deploy with a key, or set the variable and restart the service. |
| `COLLECTOR_SERVICE_MISSING` | Neither `opampsupervisor` nor `otelcol-contrib` is installed. | Re-run the install. |
| `COLLECTOR_SERVICE_STOPPED` | The service exists but is not Running. | Start it, then check the Application event log for why it stopped. |
| `COLLECTOR_PROCESS_MISSING` | `opampsupervisor` is Running but no `otelcol` child process exists — the collector is crash-looping. | Application event log, source `otelcol-contrib`; usually an invalid remote config. |
| `HEALTH_UNREACHABLE` | No response from the health endpoint after the configured retries. | Confirm the process is up and nothing else owns port 13133. |
| `HEALTH_UNHEALTHY` | The endpoint answered with a non-200 (commonly 503 during a crash-loop). | Same as above; the event log carries the reason. |
| `PROFILER_REGISTRY_MALFORMED` | An empty element in the W3SVC/WAS `Environment` REG_MULTI_SZ. **Prevents IIS from starting** — act-now severity, which is why it outranks every other instrumentation finding. | Repair the REG_MULTI_SZ, or restore it from the install backup. |
| `PROFILER_FOREIGN_OWNER` | The service registers a CLR profiler CLSID that is **not** the OpenTelemetry one, so another APM agent (Dynatrace, New Relic, AppDynamics, AppNeta, TingYun, Datadog, …) owns .NET on this host. Only **one** CLR profiler can attach to a process, so our .NET auto-instrumentation emits nothing for anything that service starts — however healthy the collector is. Decided by comparing against our CLSID, not by recognising a vendor, so an unknown agent fails it too. | Decide which agent owns .NET here: keep theirs and instrument those applications another way, or remove/exclude theirs and re-run the install. See [../exception-foreign-profiler.md](../exception-foreign-profiler.md). |
| `PROFILER_PATH_FOREIGN` | Our CLSID with **somebody else's library**: a `*_PROFILER_PATH*` entry points outside `OTEL_DOTNET_AUTO_HOME`. The CLR loads that DLL, asks it for our CLSID, gets nothing, and attaches no profiler — silently, with every variable reading as configured. The CLR prefers `*_PATH_64` over the unsuffixed name, so this is the shape a leftover from another agent takes. | Re-run the install (it writes the bitness-specific names too), or remove the foreign `*_PATH_64` / `*_PATH_32` value. |
| `PROFILER_NOT_LOADED_IN_PROCESS` | Registration is ours and correct, **and our native library is in none of the worker processes that could be scanned** — so .NET auto-instrumentation produces no spans while every variable reads as configured. Registration is not attachment. Measured on a host running Dynatrace OneAgent fullstack: W3SVC carried our CLSID and all four bitness paths, and `OpenTelemetry.AutoInstrumentation.Native.dll` was absent from every process. Only raised when at least one process was successfully scanned — see `PROFILER_LOAD_UNVERIFIED_SCAN_FAILED` for the no-evidence case. | If a foreign profiler is named in the message, see [../exception-foreign-profiler.md](../exception-foreign-profiler.md). Otherwise check the profiler DLL path and that the worker restarted after the install. |
| `NODE_PM2_DAEMON_OWNER_MISMATCH` | The PM2 daemon is owned by another account (typically `NT AUTHORITY\LOCAL SERVICE`, PM2 installed as a Windows service) and its apps have been **proven** to exist. Nothing this account does with `pm2` can reach them: `pm2` answers for an empty daemon of its own and exits 0. | Run `pm2` as the owning account — `Instrument-NodePM2.ps1` does this automatically; see [../nodejs-pm2.md](../nodejs-pm2.md). |
| `NODE_ESM_REQUIRE_MISMATCH` | The app is an ES module but `NODE_OPTIONS` carries no `--experimental-loader` hook, so nothing patches its import graph. The app starts normally and emits nothing, with no error anywhere. | Re-run the Node instrumenter: it adds the loader hook for ESM apps. Note `--import` alone is **not** the fix — measured against a real ESM app, both `--require` and `--import` yield zero spans; only `--experimental-loader=file:///…/hook.mjs` plus `--require` produces telemetry. |
| `IISNODE_ESM_NOT_HOSTABLE` | **warn, not fail.** An **iisnode** app that is an ES module. iisnode's `interceptor.js` does a CommonJS `require()` of the entry point, so an ESM app fails with `ERR_REQUIRE_ESM` and returns HTTP 500 on **every** request — measured on iisnode 0.2.26 / Node 20, with and without instrumentation, for both an `.mjs` entry and a `"type":"module"` package.json. Not instrumented and not claimed: there is no working process to instrument. The loader hook cannot help here (unlike the PM2 path) because the app never gets far enough to load one. | Application-side and unrelated to telemetry: give it a CommonJS entry point that `import()`s the ESM app, or host it under PM2 / a Windows service instead of iisnode. |

## `warn` — exit 2

### The check itself could not run

| Code | Meaning | Fix |
| --- | --- | --- |
| `CHECK_ERRORED` | A delegated validator threw; the message carries the exception. **Graded `warn`, not `unknown`**: `unknown` does not move the exit code, so a validator that crashed outright used to grade the host `exit=0` — a green doctor that checked nothing. A check that could not run is not a pass. | Read the exception. `HELPER_MISSING` stays `unknown` because a hand-assembled deploy directory is a legitimate state; a validator that threw is not. |

### Environment and identity

| Code | Meaning | Fix |
| --- | --- | --- |
| `DOMAIN_MISSING` | `CORALOGIX_DOMAIN` unset; the config default applies and this host ships to **eu1**. | Re-deploy with `-Region` / `CX_REGION`, or `-Domain` / `CX_DOMAIN` for a private ingress. |
| `DOMAIN_NOT_A_KNOWN_REGION` | `CORALOGIX_DOMAIN` is not one of the published region domains, so data goes to `ingress.<that domain>`. Expected for a private ingress; a typo otherwise — the collector reports healthy either way. | Confirm the domain is deliberate. |
| `CX_ENVIRONMENT_MISSING` | `CX_ENVIRONMENT` unset; all telemetry from this host is labelled `unspecified`. | Re-deploy with `-Environment` / `CX_ENVIRONMENT`. |
| `CX_ENVIRONMENT_MISMATCH` | The environment label is persisted twice — machine `CX_ENVIRONMENT` and `deployment.environment.name` inside `OTEL_RESOURCE_ATTRIBUTES` — and the two disagree, so one host reports two environment identities. Each store passed its own check individually, which is how a host turned up in the field labelled one environment in APM and another in Infrastructure Explorer. | Re-deploy with `-Environment` to rewrite both stores together. |
| `CX_TEAM_MISMATCH` | `CX_TEAM` and the bare `TEAM` hold different values. Every install path writes the pair together, so the two only diverge when something edited one afterwards — and the host's owner then depends on which name the reader happens to use. | Re-deploy with `-Team` to rewrite both. |
| `CX_TEAM_PARTIAL` | One of `CX_TEAM` / `TEAM` is set and the other is not, so anything reading the missing name sees no team. Absent from **both** is only `info` — the label stamps nothing on telemetry — but half-present is a real misconfiguration. | Re-deploy with `-Team <value>` to set both. |
| `RESOURCE_ATTRS_MISSING` | `OTEL_RESOURCE_ATTRIBUTES` unset; Fleet Management selector attributes will be absent. | Re-run `Detect-Workloads.ps1` or the full install. |
| `STARTTYPE_NOT_AUTOMATIC` | The service runs now but its StartType is not Automatic — it will not return after a reboot. | `sc.exe config … start= delayed-auto`. |

### Service ownership variables

| Code | Meaning | Fix |
| --- | --- | --- |
| `CX_IIS_SERVICES_MISSING` | Instrumented apps exist but the variable is unset — Service ownership will be blank. | Re-run `Instrument-IIS.ps1`. |
| `CX_IIS_SERVICES_STALE` | Set on a host with no IIS or no IIS apps; a leftover still being stamped on this host's telemetry. | Re-run `Instrument-IIS.ps1` to clear it. |
| `CX_IIS_SERVICES_DRIFT` | Set, but does not match the apps present (compared as a **set**, so reordering is not drift). | Re-run the instrumenter; if it persists, the install and the doctor disagree about runtime overrides. |
| `CX_SERVICES_DRIFT` | The union variable does not match the per-workload slices it is built from. | Re-run the install so the union is republished. |
| `IIS_SERVICE_NAME_MISSING` | An app has no `OTEL_SERVICE_NAME` on its pool or in its `web.config`; its spans land under a default name. | Expected for a Framework app on a shared pool — see [../diagnostics.md](../diagnostics.md). Otherwise re-run the instrumenter. |
| `IIS_SERVICE_NAME_DRIFT` | The name found differs from what the current IIS layout implies — the site was renamed or moved after instrumentation. | Re-run the instrumenter, or pin the name with `-ServiceNameOverrides`. |
| `NODE_SERVICE_NAME_MISSING` | A PM2 app has no `OTEL_SERVICE_NAME`, or `CX_NODE_SERVICES` is unset while apps carry names. | Re-run `Instrument-NodePM2.ps1`. |
| `NODE_SERVICE_NAME_DRIFT` | `CX_NODE_SERVICES` does not match the running apps (set comparison). | Re-run the Node instrumenter. |
| `RUNTIME_OVERRIDE_UNMATCHED` | A `-RuntimeOverrides` key matches no application on this host, so the classification the caller believes is in force is not. Usually a key copied from `-ServiceNameOverrides` (a different key space), a typo, or a decommissioned site. | Fix the key; see the two key spaces in [../diagnostics.md](../diagnostics.md). |

### IIS instrumentation

| Code | Meaning | Fix |
| --- | --- | --- |
| `PROFILER_NOT_REGISTERED` | No `CORECLR_PROFILER`/`COR_PROFILER` in the service `Environment` — `Register-OpenTelemetryForIIS` never ran. No .NET app on the host is instrumented. | Re-run `Instrument-IIS.ps1`. |
| `PROFILER_NOT_ENABLED` | The profiler GUID is registered but `CORECLR_ENABLE_PROFILING` is not `1` — registered and switched off. | Re-run the instrumenter. |
| `PROFILER_PATH_MISSING` | The profiler DLL the registry points at does not exist (or there is no `*_PROFILER_PATH*` entry). IIS starts and emits nothing. | Re-run the instrumenter to reinstall the module. |
| `PROFILER_WORKER_ENUM_FAILED` | The registration is ours and correct, but `Win32_Process` could not be enumerated, so whether the profiler **loads** is unknown — not verified and not disproved. Previously this failure was swallowed and reported as "no worker process is running", which conflates a WMI failure with an idle host. | Re-run elevated. If it persists, use the module-scan snippet in [exception-foreign-profiler.md](../exception-foreign-profiler.md). |
| `PROFILER_MODULE_SCAN_FAILED` | The loaded modules of one or more worker processes could not be read, so those processes contribute no evidence either way. Names each pid and reason. A 64-bit `w3wp` read from a 32-bit host process, a worker that exited mid-scan, and an access denial all land here. The accompanying verdict rests only on the processes that *were* readable. | Re-run from an elevated 64-bit shell. Companion to the verdict finding, not a verdict itself. |
| `PROFILER_LOAD_UNVERIFIED_SCAN_FAILED` | Registration is ours, workers are running, but **none** could be scanned — so attachment is unknown. Deliberately not a `fail`: grading it one would accuse a host that may be perfectly instrumented, which is the mirror image of the false green. | Read the `PROFILER_MODULE_SCAN_FAILED` reasons, then re-scan elevated. |
| `AUTO_HOME_MISSING` | `OTEL_DOTNET_AUTO_HOME` unset or pointing at a missing directory — `Install-OpenTelemetryCore` did not complete. | Re-run the instrumenter. |
| `POOL_NOT_NO_MANAGED_CODE` | An ASP.NET **Core** app on a pool whose `managedRuntimeVersion` is not `""`. The app still runs and still reports; the pool merely loads a desktop CLR nothing uses. Stays instrumented and stays in `CX_IIS_SERVICES`. | Optional hygiene: set the pool to No Managed Code. |
| `FRAMEWORK_POOL_NO_MANAGED_CLR` | An ASP.NET **Framework** app on a No-Managed-Code pool. Its managed handlers cannot load, so **IIS fails every request** with 500.21 — the app is down, independently of telemetry. Graded `warn` because the agent neither caused it nor is blocked by it. | Set the pool back to `v4.0`. |
| `IIS_OTLP_DEFAULTS_MISSING` | No effective `OTEL_EXPORTER_OTLP_ENDPOINT` for a pool (or none on `applicationPoolDefaults`). | Re-run the instrumenter. |
| `POOL_LOST_INHERITANCE` | A pool declares its own `<environmentVariables>` (which replaces the defaults) and has no endpoint, while the defaults do. | Re-run the instrumenter — it writes the variables directly onto pools that own a block. |
| `POOL_ENV_STALE` | A pool's own value disagrees with the current `applicationPoolDefaults`. The block is a snapshot taken when the pool was first written and never refreshes. | Re-run the instrumenter. |
| `OTLP_ENDPOINT_LOCALHOST` | Endpoint uses `localhost`, which resolves to `::1` first on a dual-stack host and silently drops export. | Use `http://127.0.0.1:4318`; the instrumenters rewrite this automatically, so seeing it means the value came from elsewhere. |

### Export path and collector config

| Code | Meaning | Fix |
| --- | --- | --- |
| `EXPORT_COUNTERS_ZERO` | Nothing has been exported yet. Normal for a collector restarted moments ago; otherwise the exporter is not reaching Coralogix. | Re-check after a minute, then look for authentication errors in the event log. |
| `EXPORT_SEND_FAILED` | Non-zero `send_failed`/`enqueue_failed` counters — telemetry is produced but rejected or dropped. | Almost always the key or the region: an `Unauthenticated` response means the key does not belong to this domain. |
| `METRICS_UNREACHABLE` | The internal metrics endpoint did not respond, so export volume is unknown. | Confirm the collector is up and the port is not taken. |
| `PORT_4318_NOT_LISTENING` | Nothing listening on the OTLP HTTP port; instrumented apps have nowhere to send. | Check the receiver block in the effective config. |
| `EFFECTIVE_PROCESSOR_MISSING` | A required processor (for example `transform/iis_service_labels`) is absent from the effective config, so `CX_IIS_SERVICES` is never stamped however correct the variable is. | Add it to the **remote** Fleet Management config. |
| `EFFECTIVE_PROCESSOR_NOT_WIRED` | The processor is defined but not listed in a required pipeline's `processors`, so it never runs for that signal. | Wire it into the pipeline in the remote config. |
| `ENV_PROCESSOR_MISSING` | `transform/environment` is absent from the effective config, so `CX_ENVIRONMENT` is never stamped and this host's signals arrive with no environment label however correct the variable is. Checked on **every** host, not only IIS ones. | Add it to the **remote** Fleet Management config. |
| `ENV_PROCESSOR_NOT_WIRED` | `transform/environment` is defined but missing from the named pipeline's `processors`, so that signal carries no environment label. A stamp wired into `logs` but not `traces` is how spans end up unlabelled while every other check passes. | Wire it into the pipeline in the remote config. |

### Node instrumentation

| Code | Meaning | Fix |
| --- | --- | --- |
| `NODE_PACKAGE_MISSING` | The OTel Node package is not staged under the install prefix. | Re-run `Instrument-NodePM2.ps1` without `-SkipInstall`, or pre-stage the package. |
| `NODE_OPTIONS_MISSING` | A PM2 app carries no `NODE_OPTIONS` bootstrap — it is not instrumented. | Re-run the Node instrumenter. |
| `NODE_REGISTER_PATH_STALE` | `NODE_OPTIONS` points at a register bootstrap that no longer exists. | Re-run the Node instrumenter. |
| `IISNODE_NODE_OPTIONS_MISSING` | An **iisnode** application's app pool carries no bootstrap, so it emits nothing. iisnode spawns `node.exe` as a child of `w3wp`, so the environment must be on the **pool** — `Instrument-NodePM2.ps1` cannot reach these apps however healthy PM2 looks. | `Instrument-IIS.ps1`, or `misc\Enable-IisnodeInstrumentation.ps1 -Apply` on an already-deployed host. |
| `IISNODE_REGISTER_PATH_STALE` | The pool's `NODE_OPTIONS` points at a register bootstrap that is gone, so `node` fails the preload and serves uninstrumented. | Re-run either writer. |
| `IISNODE_SHARED_POOL_AMBIGUOUS` | A pool-sharing iisnode application could not be named per-app either — the write into its own `web.config` `<appSettings>` did not succeed — so nothing was written. A shared pool is normally fine: see `IISNODE_APP_NAMED_PER_APP`. | Make that `web.config` present and writable, or give the application its own pool. |
| `ASPNETCORE_RUNTIME_BELOW_MINIMUM` | Graded `info`. An ASP.NET Core app targeting a .NET version below the auto-instrumentation's minimum (8). MEASURED on .NET 6.0.36: the native profiler attaches to `w3wp` and the StartupHook then refuses the runtime — `6.0.36 is not supported`, `Automatic Instrumentation won't be loaded` — because the module follows the .NET support lifecycle. No `OTEL_SERVICE_NAME` is written and the app is **not** claimed in `CX_IIS_SERVICES`, since a claimed name that never reports reads as an outage. The application itself is unaffected and serves normally. Target version comes from the app's own `runtimeconfig.json`; an unreadable one is *undetermined*, not "too old", and does not refuse the app. | Upgrade the app to a supported .NET version. |
| `IISNODE_SHARED_POOL_FRAMEWORK` | The application is iisnode **and** instrumented classic ASP.NET Framework, on a **shared** pool. Per-app naming is unsafe here: on .NET Framework the OTel SDK promotes `web.config` `OTEL_*` values to **process-level** environment variables, so the name would leak through `w3wp` and rename the pool's other applications. Nothing is written. | Give the application its own app pool — then the name goes on the pool and there is nobody to leak onto. |
| `IISNODE_POOL_NAME_SHADOWS_APP` | The app pool carries an `OTEL_SERVICE_NAME` this installer did not write, and the application shares that pool. iisnode copies the pool environment **before** appending the app's `<appSettings>`, and Windows resolves the **first** entry in the block, so the pool value shadows the per-app one — the per-app name would have no effect. Nothing is written. | Remove `OTEL_SERVICE_NAME` from the pool (it cannot correctly name a shared pool anyway), then re-run. |
| `IISNODE_PACKAGE_MISSING` | An iisnode app was found but the OTel Node package is not staged. The IIS path deliberately does not run `npm install` — IIS hosts are frequently offline. | Stage it with `Instrument-NodePM2.ps1`, or copy a prepared `node_modules` tree into the prefix. |
| `IISNODE_SERVICE_NAME_MISSING` | The bootstrap is on the pool but `OTEL_SERVICE_NAME` is not, so spans land under the SDK default (`unknown_service:node`). | Re-run either writer. |

### IIS access logs

| Code | Meaning | Fix |
| --- | --- | --- |
| `IIS_LOGDIR_NOT_COVERED` | A site writes access logs to a directory no collector `include` matches, so **those logs never reach Coralogix**. | Re-run `Instrument-IIS.ps1` to publish `CX_IIS_LOG_DIR_n`, then restart the collector. |
| `IIS_LOGDIR_SLOTS_EXCEEDED` | More distinct log directories than the config has `CX_IIS_LOG_DIR_n` slots. `${env:VAR}` expands to one scalar and `include:` is a list, so the extras cannot be expressed. | Consolidate the directories, or add slots to the config. |
| `IIS_LOG_FORMAT_UNSUPPORTED` | The site's `logFormat` is not W3C. The lines tail fine, but the `csv_parser` needs the W3C `#Fields:` header, so they arrive unsplit. | Switch the site to W3C logging. |

## `pass` — the correct pairings, reported explicitly

| Code | Meaning |
| --- | --- |
| `ASPNETCORE_NO_MANAGED_CODE_OK` | An ASP.NET Core app on a No-Managed-Code pool. |
| `FRAMEWORK_POOL_OK` | An ASP.NET Framework app on a CLR-loading pool. |

## `processStatus` — one row per IIS-owned process

Emitted as `info`, one finding per discovered process, so a per-pid answer is greppable independently of
the per-service verdict. Modelled on OneAgent's per-process injection decision.

| Status | Meaning |
| --- | --- |
| `INJECTED` | our native library is loaded in this process — runtime-verified |
| `FOREIGN_PROFILER` | another vendor's profiler module is in this process, which is why ours is not |
| `NOT_INJECTED` | readable, hosting a CLR, and our library is absent |
| `NO_CLR` | readable but no `coreclr`/`clr`/`mscorwks` mapped, so no CLR profiler can attach. Counts in **neither** tally — `conhost.exe`, which IIS spawns as a console host, lands here |
| `SCAN_FAILED` | the module list could not be read (commonly a 32-bit doctor against a 64-bit worker) — proves nothing either way |
| `UNKNOWN` | none of the above could be established |

`PENDING_RESTART`, `UNCOVERED` and `EXCLUDED` are **not** emitted yet — those checks do not exist in
this build, and printing them as absent would imply they had been evaluated.

## Evidence: config-verified vs runtime-verified

Every finding carries a `verified` field — `config`, `runtime` or `none` — and the summary prints
`evidence: N runtime-verified, M config-verified`. A `pass` backed only by configuration means "set up
correctly", **not** "telemetry is arriving": registration is not attachment. When nothing is
runtime-verified the summary says so explicitly.

Node is `config`-only by nature — its SDK loads no distinctive module, so a host-side check cannot
observe it in-process. A measured example from `cx-e2e-c1`: the IIS validator reports
`2 runtime-verified, 50 config-verified`, while the Node validator reports `0 runtime-verified` plus the
explicit note. Only a Coralogix query closes that gap.

## `info` — context, not a verdict

| Code | Meaning |
| --- | --- |
| `INSTRUMENTATION_VERSION_UNKNOWN` | No deploy manifest found, so the installed version cannot be confirmed. |
| `IIS_CENTRAL_LOGGING` | `centralLogFileMode` is not `Site`: one log file for the whole host, so per-site attribution is unavailable. A valid IIS setup, not a fault. |
| `IIS_LOGGING_DISABLED` | Access logging is off for this site. The absence of its logs is intended — reported so nobody hunts a collector fault that does not exist. |
| `WEBCONFIG_ABSENT` | The app has no `web.config`, so neither `<aspNetCore>` nor `<system.web>` is configured there. Expected on the stock default site. Describes the **file**; the app's verdict is a separate finding. |
| `NON_DOTNET_APP_NOT_INSTRUMENTED` | Static content, a native/ISAPI handler, PHP/Node/Java behind IIS, or a reverse proxy to a backend. .NET auto-instrumentation does not apply, so no name is written and the app is not claimed. Never graded higher than `info` — the stock default site is exactly this, and a warn would pin an entire fleet at exit 2. |
| `RUNTIME_OVERRIDE_APPLIED` | An operator override forced this app's runtime; detection was not consulted. The install must be given the same override. |
| `NODE_PM2_SERVICE_HOSTED` | PM2 runs as a Windows service. Reports the owning account, `PM2_HOME` and the worker count. Context for how instrument and uninstall have to invoke `pm2`. |
| `NODE_PM2_APPS_FROM_DUMP` | `dump.pm2` lists apps the live daemon did not. Either they are stopped, or a second daemon owns them. |
| `NODE_SERVICES_NOT_CONSUMED` | `CX_NODE_SERVICES` is set but no processor in the effective config reads it, so Node host Service ownership stays blank. Decided by looking at the effective config, so it disappears on its own once a processor is added. |
| `IISNODE_APP_INSTRUMENTED` | Graded `pass`. The pool carries the bootstrap, so `w3wp`'s `node.exe` child loads the SDK. |
| `IISNODE_APP_NAMED_PER_APP` | Graded `pass`. A **pool-sharing** iisnode application named in its own `web.config` `<appSettings>`, which iisnode appends to the environment it builds for `node.exe`. The pool carries the shared bootstrap and no `OTEL_SERVICE_NAME`, so no co-tenant is renamed — this is how one pool holds a .NET application and a Node application, each under its own service name. |
| `IISNODE_SERVICES_INCLUDED` | The Node doctor found iisnode service names published into `CX_NODE_SERVICES` by the IIS path. Reported so the set is not mistaken for PM2 drift — `Test-IISInstrumentation.ps1` grades those apps. |
| `IISNODE_CUSTOM_COMMAND_LINE` | The app sets `<iisnode nodeProcessCommandLine>`, which replaces the `node.exe` invocation. Pool `NODE_OPTIONS` still applies, but if that command line preloads its own OTel bootstrap the SDK could load twice. |
| `IISNODE_ESM_UNDETERMINED` | Graded `unknown`. The bootstrap is present, but `Resolve-NodeServiceNames.ps1` was not next to the doctor, so the app's module system could not be determined and a `--require`-only bootstrap cannot be graded a pass. |
| `CX_SERVICES_MISSING` | The union variable is unset while per-workload slices exist. |
| `CX_SERVICES_NOT_CONSUMED` | **warn.** `CX_SERVICES` is set and correct, but the collector config **in force** does not read `${env:CX_SERVICES}` — it stamps host ownership from `CX_IIS_SERVICES` only (the pre-`CX_SERVICES` fallback). Every non-IIS service is therefore published in the variables and **claimed by no host**, while still reporting in APM — which reads as a Coralogix-side problem rather than a config one. Decided from the **effective** config when one exists: that is the base merged with what Fleet Management sends and is literally `otelcol`'s `--config`, so a newer base config on disk does **not** override it. Fix in the remote config for the host, using `deploy/config.supervisor.yaml`'s `transform/iis_service_labels` as the reference. |
| `CX_SERVICES_CONSUMER_UNKNOWN` | No collector config was readable, so whether ownership is stamped from `CX_SERVICES` could not be determined. Graded `unknown`, not a failure. |

## `skip` — legitimately not applicable

| Code | Meaning |
| --- | --- |
| `IIS_ABSENT` | No IIS on this host; the IIS checks do not apply. |
| `IIS_NO_APPS` | IIS installed but hosting no applications — a legitimate steady state. |
| `NO_PM2` | PM2 is not installed. |
| `NO_PM2_APPS` | PM2 is installed but manages no apps. |
| `NOT_SELECTED` | Excluded by `-Only`. |

## `unknown` — could not determine, never a failure

| Code | Meaning |
| --- | --- |
| `HELPER_MISSING` | A required script is not present next to this one; the check could not run. Rebuild the package. |
| `WEBADMINISTRATION_MISSING` | The IIS PowerShell module was unavailable, so expected names were derived from `applicationHost.config` instead. |
| `WEBCONFIG_UNREADABLE` | An app's `web.config` exists but could not be opened or parsed (ACL, lock, malformed XML), or the app has no `physicalPath`. Distinct from `WEBCONFIG_ABSENT`. |
| `PROFILER_LOAD_UNVERIFIED` | Registration is ours and correct, but **no IIS worker process is running**, so whether the profiler loads could not be verified. An idle pool has nothing to load it into yet, which is why this is never a failure. Distinct from `PROFILER_WORKER_ENUM_FAILED` (enumeration broke) and `PROFILER_LOAD_UNVERIFIED_SCAN_FAILED` (workers present but unreadable). |
| `POOL_NOT_FOUND` | An application references a pool not declared in `applicationHost.config`. |
| `RUNTIME_UNKNOWN_NEEDS_OVERRIDE` | The application's runtime could not be determined. Nothing was written and nothing was claimed, rather than guessed. Decide it with `-RuntimeOverrides`. |
| `APPHOST_ACCESS_DENIED` | `applicationHost.config` could not be read because of permissions. Run elevated. |
| `APPHOST_UNREADABLE` | `applicationHost.config` could not be found, read or parsed. See the causes in [../diagnostics.md](../diagnostics.md) — this can happen while the install itself worked. |
| `IIS_LOGCONFIG_UNREADABLE` | The logging section of `applicationHost.config` could not be read, so log coverage is unknown. |
| `EFFECTIVE_CONFIG_NOT_FOUND` | Neither the supervisor effective config nor the base collector config exists. |
| `EFFECTIVE_CONFIG_UNREADABLE` | The config file exists but could not be read. |
| `EFFECTIVE_PIPELINE_NOT_FOUND` | A required pipeline block could not be located, so the processor could not be confirmed as wired into it. |
| `ENV_PIPELINE_NOT_FOUND` | A pipeline the environment stamp is expected on could not be located, so `transform/environment` could not be confirmed as wired into it. |
| `NODE_PM2_DAEMON_NOT_VISIBLE` | PM2 is installed but its app list is empty or unreadable, and the apps could **not** be proven to exist by other means — almost always another account's daemon. Once they are proven, the finding becomes `NODE_PM2_DAEMON_OWNER_MISMATCH` (fail). |
| `NODE_PM2_NOT_ON_PATH` | Node processes are running but `pm2` is not on this account's PATH. |

## Related

- [cli.md](cli.md) — how to run each diagnostic and what its flags do
- [env-vars.md](env-vars.md) — the variables the findings refer to
- [../diagnostics.md](../diagnostics.md) — why the checks are shaped this way, and how to read a confusing result
