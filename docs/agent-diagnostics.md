# Host diagnostics — why is telemetry not what I expect?

Read-only diagnostics that run **on a deployed Windows host** and say what is actually
configured, versus what should be. They ship in the deployment package and change nothing.

They exist because of a real incident: a customer reported that `CX_IIS_SERVICES` was never
set, and there was no way to find out why. At least six different causes produce the same
(empty) evidence, and nothing on the host could tell them apart.

## The scripts

| Script | Runs | Purpose |
| --- | --- | --- |
| `doctor.bat` | BatchPatch remote command | Entry point for `Test-Agent.ps1`; propagates the graded exit code |
| `Test-Agent.ps1` | elevated, standalone | All nine checks, or a subset via `-Only` |
| `Test-IISInstrumentation.ps1` | elevated, standalone | Just the IIS instrumentation check |
| `Test-NodeInstrumentation.ps1` | elevated, standalone | Just the Node/PM2 instrumentation check |

The two `Test-*Instrumentation.ps1` scripts are **dual-mode**: run them directly and they
print their own table and set their own exit code; dot-source them and they define a
function returning findings. `Test-Agent.ps1` dot-sources both, so there is one
implementation behind both entry points.

```powershell
# everything
doctor.bat

# just the env vars and the IIS service names
powershell -NoProfile -ExecutionPolicy Bypass -File Test-Agent.ps1 -Only env,iisServiceName

# just the IIS instrumentation, on its own
powershell -NoProfile -ExecutionPolicy Bypass -File Test-IISInstrumentation.ps1
```

> **Run elevated.** `applicationHost.config` is readable by Administrators only. A
> non-elevated run would report every IIS app as unconfigured — i.e. it would confidently
> report the exact symptom you are investigating. The scripts refuse rather than lie.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every check passed, or was legitimately not applicable to this host |
| `1` | **Hard fail** — not elevated, no private key, the collector is down, or a malformed profiler registry |
| `2` | **Degraded** — the collector is up but something is misconfigured |

`info`, `skip` and `unknown` findings never move the exit code. In particular **`unknown`
is not a failure**: it means the script could not determine the answer (no permission, a
missing module, PM2 owned by another user), and reporting that as "broken" would send you
down the wrong path.

> BatchPatch marks any non-zero exit as a failed (red) row, so `1` and `2` both show red.
> The distinction is in the Exit Code column and in the `doctor.bat exit code: N` line.
> Triage `2` rows in bulk; triage `1` rows individually.

`doctor.bat` also accepts, set out-of-band in the remote command:

```
set CX_DOCTOR_ONLY=env,iisServiceName && doctor.bat
set CX_DOCTOR_QUIET=1 && doctor.bat
set CX_DOCTOR_NOFILE=1 && doctor.bat
```

## The checks

| Check | What it proves |
| --- | --- |
| `env` | Machine-scope `CORALOGIX_PRIVATE_KEY` / `CORALOGIX_DOMAIN` / `CX_ENVIRONMENT` / `OTEL_RESOURCE_ATTRIBUTES` / `CX_IIS_SERVICES` |
| `iisServiceName` | Each app's `OTEL_SERVICE_NAME` read back from the pool **or** its `web.config`, and `CX_IIS_SERVICES` compared as a **set** against them |
| `services` | `opampsupervisor` / `otelcol-contrib` running, plus `StartType` |
| `health` | Collector health endpoint `127.0.0.1:13133` |
| `exportCounters` | `127.0.0.1:8888` — is anything actually being exported, and are failure counters non-zero |
| `ports` | OTLP receivers on 4318 (HTTP) and 4317 (gRPC) |
| `effectiveConfig` | `transform/iis_service_labels` present **and wired into** the `logs` and `logs/resource_catalog` pipelines |
| `iisInstrumentation` | The CLR profiler and pool configuration — see below |
| `nodeInstrumentation` | `NODE_OPTIONS`, the register bootstrap, and per-app service names on PM2 apps |

### Why `iisInstrumentation` is separate from `iisServiceName`

`iisServiceName` proves a *name* landed. It says nothing about whether the profiler is
attached — and without the profiler there are no spans at all, however correct the name is.
Nothing in the repo read that back before.

| Finding | Meaning |
| --- | --- |
| `PROFILER_NOT_REGISTERED` | No `CORECLR_PROFILER` in the W3SVC/WAS `Environment` — `Register-OpenTelemetryForIIS` never ran |
| `PROFILER_PATH_MISSING` | The profiler DLL the registry points at no longer exists. IIS starts and emits nothing |
| `PROFILER_REGISTRY_MALFORMED` | An empty element in the `Environment` REG_MULTI_SZ. **This prevents IIS from starting** — the only instrumentation finding graded as a hard fail |
| `POOL_NOT_NO_MANAGED_CODE` | An ASP.NET Core app on a pool that is not "No Managed Code". The app still runs and still reports — Microsoft's wording is that No Managed Code is *"optional but recommended"* — but the pool loads a desktop CLR nothing uses. Hygiene, not an outage |
| `ASPNETCORE_NO_MANAGED_CODE_OK` | The correct pairing: an ASP.NET Core app on a No-Managed-Code pool |
| `FRAMEWORK_POOL_OK` | The correct pairing: an ASP.NET Framework app on a CLR-loading pool |
| `FRAMEWORK_POOL_NO_MANAGED_CLR` | An ASP.NET Framework app on a No-Managed-Code pool. The **app itself is down** — its managed handlers cannot load and IIS fails every request with 500.21. Graded `warn`, not `fail`, because the agent neither caused it nor is blocked by it |
| `NON_DOTNET_APP_NOT_INSTRUMENTED` | Static content, a native/ISAPI handler, PHP/Node/Java behind IIS, or a reverse proxy. `.NET` auto-instrumentation does not apply. `info`, never a verdict — the stock `Default Web Site` is exactly this and exists on nearly every host |
| `RUNTIME_UNKNOWN_NEEDS_OVERRIDE` | The runtime could not be determined, so nothing was written and nothing was claimed. Resolve with `-RuntimeOverrides` |
| `RUNTIME_OVERRIDE_APPLIED` / `RUNTIME_OVERRIDE_UNMATCHED` | An operator override was honoured / matched no application on this host |
| `POOL_ENV_STALE` | See below |
| `OTLP_ENDPOINT_LOCALHOST` | See below |

### Two traps worth knowing

**`localhost` silently drops OTLP.** On a dual-stack host `localhost` resolves to `::1`
first, and export is dropped with no error. `127.0.0.1` is required. The instrumenters now
default `-OtlpEndpoint` to `http://127.0.0.1:4318` **and** rewrite a `localhost` value passed
explicitly (`Resolve-CxOtlpEndpoint`), so a stock deploy no longer trips this. Seeing
`OTLP_ENDPOINT_LOCALHOST` now means the value came from somewhere else — a hand edit, a
pre-existing pool block, or an older install — and it is a genuine finding, not a false
positive.

**A pool's environment block is a snapshot.** A pool that has its own
`<environmentVariables>` **replaces** `applicationPoolDefaults` rather than merging with it.
IIS materialises the defaults into that block the first time `appcmd` writes any variable to
the pool — and that copy never refreshes. So changing `applicationPoolDefaults` afterwards
leaves every already-instrumented pool on the old value. This is the mechanism behind "I
fixed the endpoint centrally and half the fleet still exports nowhere", and it surfaces as
`POOL_ENV_STALE`.

The corollary bites earlier than that. A pool can acquire its own block *before* the agent is
installed — any prior `appcmd` write of any variable creates one, a connection string being
the usual culprit. That block was materialised from defaults that had no OTLP entries, so the
pool never sees the ones the installer sets later, and the defaults still read as correct.
`Instrument-IIS.ps1` therefore writes the OTLP variables directly onto every pool that owns a
block — including *shared* pools, which are otherwise left inheriting. `POOL_LOST_INHERITANCE`
is what an un-repaired pool looks like, and re-running the instrumenter is a real fix for it.

### "No Managed Code" does not mean unsupported

The IIS application pool setting **No Managed Code** (`managedRuntimeVersion=""`) means IIS
does not load the .NET **Framework** CLR into the worker process. It does *not* mean the
application is unmanaged. ASP.NET Core applications are managed; they run on CoreCLR, booted
by the ASP.NET Core Module, not on the IIS-managed .NET Framework pipeline.

So the pool setting on its own decides nothing, and neither `managedRuntimeVersion="" ⇒
supported` nor `managedRuntimeVersion="" ⇒ unsupported` is a sound rule. Every application is
classified first, then the pairing is judged:

| Pool setting | Application | Instrumentable? | What the installer does |
| --- | --- | --- | --- |
| `No Managed Code` | ASP.NET Core | Yes | Instrument, claim in `CX_IIS_SERVICES` |
| `No Managed Code` | ASP.NET Framework | No — the app cannot run at all | Report `FRAMEWORK_POOL_NO_MANAGED_CLR`; still named, so ownership does not drift |
| `No Managed Code` | static / native / ISAPI | No | Skip; report `NON_DOTNET_APP_NOT_INSTRUMENTED` |
| `No Managed Code` | PHP / Node / Java behind IIS | No | Skip; instrument that runtime with its own agent |
| `No Managed Code` | reverse proxy to a backend | Depends — see below | Skip the IIS pool; instrument the backend process |
| `v4.0` / `v2.0` | ASP.NET Framework | Yes | Instrument, claim in `CX_IIS_SERVICES` |
| `v4.0` / `v2.0` | ASP.NET Core | Yes, but wasteful | Instrument anyway; report `POOL_NOT_NO_MANAGED_CODE` |

An **absent** `managedRuntimeVersion` attribute is *not* No Managed Code — IIS defaults it to
`v4.0`. That distinction is why the pool version is never used as evidence of what an
application is: inferring "Framework" from a `v4.0` pool would classify every static site on
`DefaultAppPool` as a .NET app.

**Reverse proxies split two ways.** An IIS site that URL-Rewrites to a backend on another port
is not instrumentable from IIS: the pool's environment never reaches that separate process, so
the backend must be instrumented where it runs. ASP.NET Core's **out-of-process hosting model**
looks the same from outside and is the opposite case — the ASP.NET Core Module launches
`dotnet.exe` as a *child* of `w3wp`, which does inherit the pool environment, so it is
instrumented normally.

Detection uses positive evidence only: `<aspNetCore>` (including inherited from a parent
application whose `<location>` does not set `inheritInChildApplications="false"`) for Core;
`<system.web>` with real content, managed `type=` handlers/modules, `.aspx`/`.asmx`/`.ashx`
mappings, or `Global.asax` for Framework. Where it cannot tell, it says
`RUNTIME_UNKNOWN_NEEDS_OVERRIDE` and writes nothing rather than guessing — a wrong guess puts a
name into `CX_IIS_SERVICES` that no telemetry ever arrives for. Override with
`-RuntimeOverrides` (see below).

### Which apps reach `CX_IIS_SERVICES`

An application is claimed only if **both** hold: the `OTEL_SERVICE_NAME` write succeeded, and
it classified as ASP.NET Core or ASP.NET Framework. Two distinct exclusions follow.

**Non-.NET and undeterminable apps** are never named and never claimed. Nothing reports under
them, so claiming one would point host Service ownership at telemetry that does not exist.

**A classic Framework app that shares a pool** cannot be given a name we choose: it has no
`<aspNetCore>` element, and `appSettings` on a shared pool is promoted process-wide, so the
first app to start would decide for all of them. Such apps are excluded — but they still
**report**, under the auto-detected `SiteName\VirtualPath`. Note the scope: this is specific to
a *shared* pool. A Framework app on its own **dedicated** pool is named from the pool and *is*
claimed, exactly like a Core app.

So a host's Service-ownership list is a legitimate subset of what it emits, and
`IIS_SERVICE_NAME_MISSING` for a shared-pool Framework app means "not named by us", not "not
instrumented". Give the app a dedicated pool to bring it under management.

### Forcing a runtime with `-RuntimeOverrides`

`Instrument-IIS.ps1`, `Test-IISInstrumentation.ps1` and `Test-Agent.ps1` all accept
`-RuntimeOverrides` / `-RuntimeOverridesJson`, and all three read `CX_RUNTIME_OVERRIDES_JSON`
by default so a fleet can stage one file and have the install and the checks agree:

```
set CX_RUNTIME_OVERRIDES_JSON=C:\cx\runtimes.json && deploy.bat
```
```json
{ "Wallet/api": "AspNetCore", "Legacy/": "AspNetFramework", "Static/": "NonDotNet" }
```

**Mind the key space — there are two, and they differ by one character for root apps.**

| Parameter | Keyed by | Root app | Nested app |
| --- | --- | --- | --- |
| `-ServiceNameOverrides` | derived **service name** (the label) | `Wallet` | `Wallet/api` |
| `-RuntimeOverrides` | **application identity** | `Wallet/` | `Wallet/api` |

The runtime key is exactly the string the doctor prints in its `Target` column, so it can be
copied off the diagnostic output. The slash-less form is accepted as an alias for a root app,
and a key matching no application is reported as `RUNTIME_OVERRIDE_UNMATCHED` (warn) rather
than silently ignored — that is nearly always a key pasted from the other key space, a typo, or
a decommissioned site. An invalid *value* fails the run outright.

Pass the same overrides to the install and to the doctor. If only one side sees them, the two
disagree about which apps belong in `CX_IIS_SERVICES` and `CX_IIS_SERVICES_DRIFT` is reported
permanently.

### `CX_NODE_SERVICES` has no consumer

`Instrument-NodePM2.ps1` sets the machine variable `CX_NODE_SERVICES`, but **no collector
config reads `${env:CX_NODE_SERVICES}`** — unlike `CX_IIS_SERVICES`, there is no transform
consuming it, so Node host Service-ownership stays blank. The doctor reports this as
`NODE_SERVICES_NOT_CONSUMED` (info, does not affect the exit code), and it decides that by
*looking* at the effective config, so the finding disappears on its own if a processor is
ever added.

## Every finding code

All 65 codes the three scripts can emit. Severity drives the exit code: any `fail` → `1`,
otherwise any `warn` → `2`, otherwise `0`. `info` / `skip` / `unknown` never move it.

### `fail` — exit 1

| Code | Meaning |
| --- | --- |
| `NOT_ELEVATED` | Not running as Administrator. Nothing else was checked, because the answers would be false. |
| `PRIVATE_KEY_MISSING` | No machine `CORALOGIX_PRIVATE_KEY` — the collector cannot authenticate and nothing reaches Coralogix. |
| `COLLECTOR_SERVICE_MISSING` | Neither `opampsupervisor` nor `otelcol-contrib` is installed. |
| `COLLECTOR_SERVICE_STOPPED` | The service exists but is not Running. |
| `COLLECTOR_PROCESS_MISSING` | `opampsupervisor` is Running but no `otelcol` child process exists — the collector is crash-looping. Check the Application event log, source `otelcol-contrib`. |
| `HEALTH_UNREACHABLE` | No response from `127.0.0.1:13133` after the configured retries. |
| `HEALTH_UNHEALTHY` | The endpoint answered with a non-200 (commonly 503 during a crash-loop). |
| `PROFILER_REGISTRY_MALFORMED` | An empty element in the W3SVC/WAS `Environment` REG_MULTI_SZ. **Prevents IIS from starting** — act-now severity, which is why it outranks every other instrumentation finding. |
| `NODE_PM2_DAEMON_OWNER_MISMATCH` | The PM2 daemon is owned by another account (typically `NT AUTHORITY\LOCAL SERVICE`, PM2 installed as a Windows service) and its apps have been **proven** to exist — worker processes are running, or `dump.pm2` lists them. Nothing this account does with `pm2` can reach them: pm2 answers for an empty daemon of its own and exits 0. Distinct from `NODE_PM2_DAEMON_NOT_VISIBLE`, which is the `unknown` for "we could not look". |
| `NODE_ESM_REQUIRE_MISMATCH` | The app is an ES module but `NODE_OPTIONS` uses `--require`, which cannot load the instrumentation into an ESM graph. The app starts normally and emits nothing, with no error anywhere. Needs `--import` (Node ≥ 20). |

### `warn` — exit 2

| Code | Meaning |
| --- | --- |
| `DOMAIN_MISSING` | `CORALOGIX_DOMAIN` unset; the config default applies and this host ships to **eu1**. Re-deploy with `-Region <code>` / `CX_REGION`, or `-Domain` / `CX_DOMAIN` for a private ingress, if that is not the account. |
| `DOMAIN_NOT_A_KNOWN_REGION` | `CORALOGIX_DOMAIN` is not one of the published region domains (`<region>.coralogix.com` or a legacy per-region domain), so data goes to `ingress.<that domain>`. Expected for a private ingress; a typo otherwise — the collector reports healthy either way. |
| `CX_ENVIRONMENT_MISSING` | `CX_ENVIRONMENT` unset; all telemetry from this host is labelled `unspecified`. |
| `RESOURCE_ATTRS_MISSING` | `OTEL_RESOURCE_ATTRIBUTES` unset; Fleet Management selector attributes will be absent. |
| `CX_IIS_SERVICES_MISSING` | Instrumented apps exist but the variable is unset — Service ownership will be blank. |
| `CX_IIS_SERVICES_STALE` | Set on a host with no IIS or no IIS apps; a leftover still being stamped on this host's telemetry. |
| `CX_IIS_SERVICES_DRIFT` | Set, but does not match the apps present (compared as a **set**, so reordering is not drift). |
| `IIS_SERVICE_NAME_MISSING` | An app has no `OTEL_SERVICE_NAME` on its pool or in its `web.config`; its spans land under a default name. |
| `IIS_SERVICE_NAME_DRIFT` | The name found differs from what the current IIS layout implies — the site was renamed or moved after instrumentation. |
| `PROFILER_NOT_REGISTERED` | No `CORECLR_PROFILER`/`COR_PROFILER` in the service `Environment` — `Register-OpenTelemetryForIIS` never ran. No .NET app on the host is instrumented. |
| `PROFILER_NOT_ENABLED` | The profiler GUID is registered but `CORECLR_ENABLE_PROFILING` is not `1` — registered and switched off. |
| `PROFILER_PATH_MISSING` | The profiler DLL the registry points at does not exist (or no `*_PROFILER_PATH*` entry at all). IIS starts and emits nothing. |
| `AUTO_HOME_MISSING` | `OTEL_DOTNET_AUTO_HOME` unset or pointing at a missing directory — `Install-OpenTelemetryCore` did not complete. |
| `POOL_NOT_NO_MANAGED_CODE` | An ASP.NET Core app on a pool whose `managedRuntimeVersion` is not `""`. The app still runs and still reports — Microsoft's own wording is that No Managed Code is *"optional but recommended"* — but the pool loads a desktop CLR nothing uses. The app stays instrumented and stays in `CX_IIS_SERVICES`. |
| `FRAMEWORK_POOL_NO_MANAGED_CLR` | An ASP.NET Framework app on a No-Managed-Code pool. Its managed handlers cannot load, so **IIS fails every request** with 500.21 — the app is down, independently of telemetry. Set the pool to `v4.0`. Graded `warn` rather than `fail` because the agent neither caused it nor is blocked by it. |
| `RUNTIME_OVERRIDE_UNMATCHED` | A `-RuntimeOverrides` key matches no application on this host, so the classification the caller believes is in force is not. Usually a key copied from `-ServiceNameOverrides` (a different key space), a typo, or a decommissioned site. |
| `IIS_OTLP_DEFAULTS_MISSING` | No effective `OTEL_EXPORTER_OTLP_ENDPOINT` for a pool (or none on `applicationPoolDefaults`). |
| `POOL_LOST_INHERITANCE` | A pool declares its own `<environmentVariables>` (which replaces the defaults) and has no endpoint, while the defaults do. |
| `POOL_ENV_STALE` | A pool's own value disagrees with the current `applicationPoolDefaults` — the block is a snapshot taken when the pool was first written and never refreshes. See the trap below. |
| `OTLP_ENDPOINT_LOCALHOST` | Endpoint uses `localhost`, which resolves to `::1` first and silently drops export. |
| `EXPORT_COUNTERS_ZERO` | Nothing has been exported yet. Normal for a collector restarted moments ago; otherwise the exporter is not reaching Coralogix. |
| `EXPORT_SEND_FAILED` | Non-zero `send_failed`/`enqueue_failed` counters — telemetry is produced but rejected or dropped. |
| `METRICS_UNREACHABLE` | `127.0.0.1:8888` did not respond, so export volume is unknown. |
| `PORT_4318_NOT_LISTENING` | Nothing listening on the OTLP HTTP port; instrumented apps have nowhere to send. |
| `STARTTYPE_NOT_AUTOMATIC` | The service runs now but its StartType is not Automatic — it will not return after a reboot. |
| `EFFECTIVE_PROCESSOR_MISSING` | `transform/iis_service_labels` is absent from the effective config, so `CX_IIS_SERVICES` is never stamped however correct the variable is. Add it to the **remote** Fleet config. |
| `EFFECTIVE_PROCESSOR_NOT_WIRED` | The processor is defined but not listed in a required pipeline's `processors`, so it never runs for that signal. |
| `NODE_PACKAGE_MISSING` | The OTel Node package is not staged under the install prefix. |
| `NODE_OPTIONS_MISSING` | A PM2 app carries no `NODE_OPTIONS=--require <register>` — it is not instrumented. |
| `NODE_REGISTER_PATH_STALE` | `NODE_OPTIONS` points at a register bootstrap that no longer exists. |
| `NODE_SERVICE_NAME_MISSING` | A PM2 app has no `OTEL_SERVICE_NAME`, or `CX_NODE_SERVICES` is unset while apps carry names. |
| `NODE_SERVICE_NAME_DRIFT` | `CX_NODE_SERVICES` does not match the running apps (set comparison). |
| `IIS_LOGDIR_NOT_COVERED` | A site writes access logs to a directory no collector `include` matches, so **those logs never reach Coralogix**. Re-run `Instrument-IIS.ps1` to publish `CX_IIS_LOG_DIR_n`, then restart the collector. |
| `IIS_LOGDIR_SLOTS_EXCEEDED` | More distinct log directories than the config has `CX_IIS_LOG_DIR_n` slots. `${env:VAR}` expands to one scalar and `include:` is a list, so the extras cannot be expressed — consolidate the directories or add slots. |
| `IIS_LOG_FORMAT_UNSUPPORTED` | The site's `logFormat` is not W3C. The lines tail fine but the `csv_parser` needs the W3C `#Fields:` header, so they arrive unsplit. |

### `info` / `skip` / `unknown` — never affect the exit code

| Code | Severity | Meaning |
| --- | --- | --- |
| `INSTRUMENTATION_VERSION_UNKNOWN` | info | No deploy manifest found, so the installed version cannot be confirmed. |
| `IIS_CENTRAL_LOGGING` | info | `centralLogFileMode` is not `Site`: one log file for the whole host, so per-site attribution is unavailable. A valid IIS setup, not a fault. |
| `IIS_LOGGING_DISABLED` | info | Access logging is off for this site. The absence of its logs is intended — reported so nobody hunts a collector fault that does not exist. |
| `IIS_LOGCONFIG_UNREADABLE` | unknown | The logging section of `applicationHost.config` could not be read, so log coverage is unknown. |
| `NODE_SERVICES_NOT_CONSUMED` | info | `CX_NODE_SERVICES` is set but nothing reads it — see below. |
| `IIS_ABSENT` | skip | No IIS on this host; the IIS checks do not apply. |
| `IIS_NO_APPS` | skip | IIS installed but hosting no applications — a legitimate steady state. |
| `NO_PM2` / `NO_PM2_APPS` | skip | PM2 absent, or present with no apps. |
| `NOT_SELECTED` | skip | Excluded by `-Only`. |
| `HELPER_MISSING` | unknown | A required script is not present next to this one; the check could not run. |
| `CHECK_ERRORED` | unknown | A delegated validator threw; the message carries the exception. |
| `WEBADMINISTRATION_MISSING` | unknown | `Get-IISServiceMap` failed, so expected names were derived from `applicationHost.config` instead. |
| `WEBCONFIG_ABSENT` | info | The app has no `web.config`, so neither ASP.NET Core (`<aspNetCore>`) nor classic ASP.NET (`<system.web>`) is configured there. **Expected on the stock `Default Web Site`** — `C:\inetpub\wwwroot` ships `iisstart.htm` and no `web.config`. Only worrying if you believe you deployed an ASP.NET Core app to that path, in which case the publish output is incomplete and IIS is not routing to ANCM either. When the physical directory itself is gone, the message says so. Describes the **file**; the app's verdict is reported alongside it as a separate finding. |
| `WEBCONFIG_UNREADABLE` | unknown | An app's `web.config` exists but could not be opened or parsed (ACL, lock, malformed XML), or the application has no `physicalPath`, so its runtime cannot be determined. The message carries the underlying reason. Distinct from `WEBCONFIG_ABSENT`. |
| `ASPNETCORE_NO_MANAGED_CODE_OK` | pass | An ASP.NET Core app on a No-Managed-Code pool — the correct pairing. |
| `FRAMEWORK_POOL_OK` | pass | An ASP.NET Framework app on a CLR-loading pool — the correct pairing. |
| `NON_DOTNET_APP_NOT_INSTRUMENTED` | info | Static content, a native/ISAPI handler, PHP/Node/Java behind IIS, or a reverse proxy to a backend process. .NET auto-instrumentation does not apply, so no `OTEL_SERVICE_NAME` is written and the app is not claimed in `CX_IIS_SERVICES`. **Never graded higher than `info`** — the stock `Default Web Site` is exactly this, so a warn would pin the entire fleet at exit 2. If IIS reverse-proxies to a backend, instrument that backend where it runs. |
| `RUNTIME_UNKNOWN_NEEDS_OVERRIDE` | unknown | The application's runtime could not be determined — an unreadable `web.config`, an unenumerable app root, or managed assemblies with nothing wiring them to a request pipeline. Nothing was written and nothing was claimed, rather than guessed. Decide it with `-RuntimeOverrides`. |
| `RUNTIME_OVERRIDE_APPLIED` | info | An operator override forced this app's runtime; detection was not consulted. The install must be given the same override. |
| `POOL_NOT_FOUND` | unknown | An application references a pool not declared in `applicationHost.config`. |
| `EFFECTIVE_CONFIG_NOT_FOUND` | unknown | Neither the supervisor effective config nor the base collector config exists. |
| `EFFECTIVE_CONFIG_UNREADABLE` | unknown | The config file exists but could not be read. |
| `EFFECTIVE_PIPELINE_NOT_FOUND` | unknown | A required pipeline block could not be located to confirm the processor is wired into it. |
| `NODE_PM2_DAEMON_NOT_VISIBLE` | unknown | PM2 is installed but its app list is empty/unreadable, and the apps could **not** be proven to exist by other means — almost always the wrong user's daemon. Never a failure. Once they *are* proven, the finding becomes `NODE_PM2_DAEMON_OWNER_MISMATCH` (fail). |
| `NODE_PM2_NOT_ON_PATH` | unknown | Node processes are running but `pm2` is not on this account's PATH. |
| `NODE_PM2_SERVICE_HOSTED` | info | PM2 runs as a Windows service (pm2-installer / node-windows). Reports the owning account, `PM2_HOME` and the worker count. Not a problem in itself — it is the context for how instrument and uninstall have to invoke `pm2`. |
| `NODE_PM2_APPS_FROM_DUMP` | info | `dump.pm2` lists apps the live daemon did not. Either they are stopped, or a second daemon owns them. |

Two codes are computed rather than literal: the `env`/`iisServiceName` checks pick
`APPHOST_ACCESS_DENIED` vs `APPHOST_UNREADABLE` depending on whether reading
`applicationHost.config` failed on permissions or on absence.

### `APPHOST_UNREADABLE` when the deployment clearly worked

The confusing shape of this one is worth spelling out: **the doctor says the config
cannot be read, yet the installer set the pool environment variables just fine.**
That is not a contradiction, because the two use different mechanisms.

| | how it reaches the config |
| --- | --- |
| `Instrument-IIS.ps1` | `appcmd.exe` → the IIS configuration COM API (`ahadmin`) |
| the diagnostics | a plain file read of `…\inetsrv\config\applicationHost.config` |

Same data on a healthy host. Four things break the file read while leaving `appcmd` working:

| Cause | Message you see | Why `appcmd` survives |
| --- | --- | --- |
| **WOW64** — a 32-bit host process | `applicationHost.config not found at …` | `SysWOW64\inetsrv` has `appcmd.exe` but **no** `config\applicationHost.config` (that folder holds only `Schema\` and `Export\`), while the COM API is bitness-agnostic |
| **IIS Shared Configuration** | `not found`, or silently stale results | `redirection.config` points `appcmd` at the UNC store; a file read still hits the local copy |
| Install ran as **SYSTEM**, doctor as an admin *user*, config ACL hardened | `access denied … (run elevated)` → `APPHOST_ACCESS_DENIED` | SYSTEM retained access |
| Transient — WAS rewriting the file mid-read | `could not read/parse …` | `appcmd` writes temp-then-replace; a raw reader can catch it half-written. Passes on re-run |

Since the WOW64 fix, the first row should no longer occur: `deploy.bat` / `uninstall.bat` /
`doctor.bat` re-launch themselves through `%SystemRoot%\Sysnative\…\powershell.exe` when
`PROCESSOR_ARCHITEW6432` is defined, and the scripts resolve the directory themselves via
`Get-CxInetsrvDir` for the case where a `.ps1` is invoked directly from a 32-bit shell. If
you see it anyway, confirm the bitness from an **elevated** prompt on that host:

```powershell
[pscustomobject]@{
  Is64Proc  = [Environment]::Is64BitProcess
  Native    = Test-Path "$env:windir\System32\inetsrv\config\applicationHost.config"
  Sysnative = Test-Path "$env:windir\Sysnative\inetsrv\config\applicationHost.config"
  Shared    = Test-Path "$env:windir\System32\inetsrv\config\redirection.config"
} | Format-List
```

`Is64Proc=False` with `Sysnative=True` and `Native=False` is WOW64, conclusively —
`Sysnative` exists *only* when observed from a 32-bit process. `Shared=True` means IIS
Shared Configuration. Run it elevated or the result is meaningless: `Test-Path` returns
`$false` on a permission-denied path, so a non-elevated `Native=False` proves nothing.

> **Why this mattered beyond the diagnostics.** Before the fix, `Instrument-IIS.ps1` and
> `Uninstall-Agent.ps1` hardcoded the same `System32` path. In a 32-bit host process the
> install still wrote pool env vars through `appcmd`, but `Backup-DeployFile` snapshotted a
> path that did not exist and `Test-PoolEnvPresent` returned `$false` for every variable —
> so the run mutated `applicationHost.config` with **no backup**, and recorded the
> customer's pre-existing `OTEL_*` values as its own, which uninstall would then delete.

## Output

Console output is the surface BatchPatch harvests and is designed to stand alone. A machine
readable report is also written to `agent-doctor.json` next to the scripts — the same
convention as `install-agent-status.json` and `detect-workloads.json`. Suppress it with
`-NoFileOutput`.

## Read-only guarantee

The diagnostics never set an environment variable, never run `appcmd` or `iisreset`, never
start or stop a service, and never download anything. The only writes are the report files.
`test/docker-win/Run-DoctorTest.ps1` asserts this by hashing `applicationHost.config` and
the full machine environment before and after a run.

## Testing

```powershell
pwsh test\docker-win\Run-DoctorTest.ps1
```

Builds `Dockerfile.doctor` (a lightweight IIS image — no Node, no collector), configures a
realistic layout, then asserts each check against a deliberately broken state:
`CX_IIS_SERVICES` cleared and drifted, a pool put back on managed runtime, stale pool env,
a malformed profiler registry, a stale profiler DLL path, plus argument handling,
standalone/aggregator parity, WOW64, and the read-only invariant. Mutations live in
`test/docker-win/break-state.ps1` and only ever touch the disposable container.

Group **E** covers the 32-bit case described above: it runs the validators through
`C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`, asserts `Get-CxInetsrvDir`
returns `Sysnative` there and `System32` in a 64-bit process, asserts a 32-bit run reads
the config rather than reporting `APPHOST_UNREADABLE`, and drives `doctor.bat` from
`SysWOW64\cmd.exe` to prove the `PROCESSOR_ARCHITEW6432` re-launch works. One case
deliberately forces the redirected path to confirm the failure is still reproducible —
otherwise the group could pass because the bug quietly stopped existing.

Container processes run as `ContainerAdministrator`, so the elevation-gated paths execute
without an interactive UAC prompt.
