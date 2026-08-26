# Environment variables

Every variable the deployment package reads or writes, in three groups: the ones **you set** to
steer a deploy, the ones the installer **publishes** for the collector and the diagnostics to
read, and the OTel variables applied to instrumented workloads. It closes with where a value
lives, and which copy wins when two disagree.

Variables are read and written at **machine scope** unless stated otherwise. For the flags that
correspond to these variables see [cli.md](cli.md).

## Inputs you set

Set these before running `deploy.bat` / `doctor.bat` / `uninstall.bat`, or pass the equivalent
flag. `deploy.bat` forwards each one to `Install-Agent.ps1`; **typing any argument skips the
whole environment-variable block**, so use one mechanism or the other, never both.

| Variable | Flag equivalent | What it does |
| --- | --- | --- |
| `CORALOGIX_PRIVATE_KEY` | `-PrivateKey` | The Send-Your-Data **key value**. Not a path — see the warning in [cli.md](cli.md). Persisted so the collector service can read it. |
| `CORALOGIX_DOMAIN` | *(none — deliberately)* | Full ingress domain. Read directly rather than forwarded as a flag, because a previous install persists it at machine scope and a flag would let that leftover outrank a baked-in region. Use `CX_DOMAIN` to express a decision for this run. |
| `CX_REGION` | `-Region` | Region code: `eu1`, `eu2`, `us1`, `us2`, `us3`, `ap1`, `ap2`, `ap3`. Becomes the ingress domain `<region>.coralogix.com` **and** the OpAMP endpoint. An unknown code fails the install. |
| `CX_DOMAIN` | `-Domain` | Full ingress domain for a private or non-standard endpoint, taken verbatim (scheme and trailing slash stripped). Wins over `CX_REGION`. Never persisted, so its presence unambiguously means "decided for this run". |
| `CX_ENVIRONMENT` | `-Environment` | Deployment environment label (`prod`, `staging`, …). Stamped on all signals as `deployment.environment.name`, so Coralogix can split the fleet by environment. |
| `CX_APPLICATION` | `-Application` | Coralogix **application** name for this host. Omit it to let the application name fall back to the host's own name. |
| `CX_TEAM` | `-Team` | Owning team for this host. Persisted as **two** machine variables with one value: `CX_TEAM` and the bare `TEAM`, the name software already on these hosts reads. Env-var only — no processor in the shipped config reads either, so it stamps nothing on telemetry; a remote Fleet Management config consumes it as `${env:CX_TEAM}`. |
| `TEAM` | *(none — read, not forwarded)* | Accepted as **input** when neither `-Team` nor `CX_TEAM` is given, and always **written** when a team is set. `Install-Agent.ps1` reads it directly rather than through `deploy.bat`, so the fallback also applies on the arguments path — which is why it is not listed among the variables an argument makes `deploy.bat` discard. A value the host already carried therefore becomes the fleet label; the install transcript names which source it used. |
| `CX_NO_SUPERVISOR` | `-NoSupervisor` | Install the collector without the OpAMP Supervisor. Changes only the vendor-installer arguments; detection, instrumentation and diagnostics are identical. |
| `CX_SKIP_INSTRUMENT` | `-SkipInstrument` | Install the collector but leave IIS and Node alone. |
| `CX_DOTNET_SERVICE_NAMES` | `-DotNetServices` | Comma-separated Windows service names to instrument as .NET services (outside IIS). Nothing is instrumented if neither is given. |
| `CX_RUNTIME_OVERRIDES_JSON` | `-RuntimeOverridesJson` | Path to a JSON file forcing the runtime of IIS apps detection cannot classify. Read directly by both the install and the doctor so the two cannot disagree about which apps belong in `CX_IIS_SERVICES`. |
| `CX_OTEL_DOTNET_ARCHIVE` | `-LocalArchive` | Path to a pre-staged .NET auto-instrumentation archive, for hosts with no internet access. |
| `CX_OTEL_DOTNET_MODULE` | `-LocalModule` | Path to a pre-staged auto-instrumentation PowerShell module. |
| `CX_PURGE` | `-Purge` | Uninstall also deletes staged config and vendor binaries. |
| `CX_RESTORE` | `-RestoreConfigs` | Uninstall restores configs from the backup instead of making surgical edits. |
| `CX_DOCTOR_ONLY` | `-Only` | Comma-separated check names to run; everything else reports `NOT_SELECTED`. |
| `CX_DOCTOR_QUIET` | `-Quiet` | Drop `pass` and `skip` rows from the doctor's table. |
| `CX_DOCTOR_NOFILE` | `-NoFileOutput` | Do not write the JSON report next to the scripts. |

```bat
REM one variable per decision, then the entry point
set CX_REGION=eu2 && set CX_ENVIRONMENT=prod && deploy.bat
```

## Published by the installer

Written by the install and read by the collector config and the diagnostics. Do not set these by
hand — the next install recomputes them, and a hand-set value shows up as drift.

| Variable | Written by | Consumed by |
| --- | --- | --- |
| `CORALOGIX_DOMAIN` | `Install-CoralogixSupervisor.ps1` | The exporter's endpoint and the OpAMP endpoint. |
| `OTEL_RESOURCE_ATTRIBUTES` | `Detect-Workloads.ps1` | Stamped on all signals and injected into the supervisor `AgentDescription`, so Fleet Management can target hosts by `cx.host.role` and `workload.*`. |
| `CX_IIS_SERVICES` | `Instrument-IIS.ps1` | The `transform/iis_service_labels` processor, which stamps IIS service ownership on host telemetry. Comma-separated; split into an OTel array so each name is a discrete ownership value. |
| `CX_NODE_SERVICES` | `Instrument-NodePM2.ps1`, `Instrument-NodeService.ps1` | Nothing today — no processor reads it, so Node host ownership stays blank. Reported as `NODE_SERVICES_NOT_CONSUMED` (info). |
| `CX_DOTNET_SERVICES` | `Instrument-DotNetService.ps1` | Same: recorded for the union below, not read directly by the config. |
| `CX_SERVICES` | `Install-Agent.ps1` | The union of the three slices above. The collector stamps host ownership from **this** variable: `service`, `tags.service`, `tags.cx_svc`, `tags.CX_SERVICE_NAME` and the matching `cx.infra.labels.*`. Cleared when a host has no instrumented services. |
| `CX_IIS_LOG_DIR_1` … `CX_IIS_LOG_DIR_3` | `Instrument-IIS.ps1` (via `Resolve-IISLogPaths.ps1`) | The `filelog` receiver's `include` globs, one directory per slot. A site logging outside these directories is not tailed at all. |
| `CX_IIS_LOG_DIRS` | `Instrument-IIS.ps1` | Informational summary of every discovered log directory, including any beyond the three slots. Drives `IIS_LOGDIR_SLOTS_EXCEEDED`. |

`Uninstall-Agent.ps1` clears `OTEL_RESOURCE_ATTRIBUTES`, `CORALOGIX_DOMAIN`,
`CORALOGIX_PRIVATE_KEY`, `CX_ENVIRONMENT`, `CX_APPLICATION`, `CX_TEAM`, `CX_IIS_SERVICES`,
`CX_NODE_SERVICES`, `CX_DOTNET_SERVICES` and `CX_SERVICES`, restoring any value that pre-existed
the install. The bare `TEAM` is reversed **only** through the backup manifest — deleted if the
install created it, restored if it did not. With no manifest it is left standing, because that
name may have belonged to the host's own software first.

### Drift markers

Not variables — finding codes the doctor emits *about* the variables above. Full descriptions in
[exit-codes.md](exit-codes.md).

| Code | Means |
| --- | --- |
| `CX_IIS_SERVICES_MISSING` | Instrumented apps exist, variable unset. |
| `CX_IIS_SERVICES_STALE` | Set on a host with no IIS apps. |
| `CX_IIS_SERVICES_DRIFT` | Set, but does not match the apps present (set comparison). |
| `CX_SERVICES_MISSING` / `CX_SERVICES_DRIFT` | The union is unset, or disagrees with its slices. |
| `CX_ENVIRONMENT_MISSING` | Unset, so this host's telemetry is labelled `unspecified`. |
| `CX_ENVIRONMENT_MISMATCH` | `CX_ENVIRONMENT` and the `deployment.environment.name` inside `OTEL_RESOURCE_ATTRIBUTES` disagree — one host reporting two environment identities. |
| `CX_TEAM_MISMATCH` | `CX_TEAM` and `TEAM` hold different values. The install writes both together, so one was edited afterwards and the host's owner depends on which name the reader uses. |
| `CX_TEAM_PARTIAL` | One of the pair is set and the other is not, so anything reading the missing name sees no team. |

## Collector runtime variables

Read by the collector config with a built-in default, so a host works without them.

| Variable | Default | Effect |
| --- | --- | --- |
| `OTEL_LISTEN_INTERFACE` | `127.0.0.1` | Interface the receivers and endpoints bind: OTLP `4317`/`4318`, health `13133`, internal metrics `8888`. |
| `OTEL_MEMORY_LIMIT_MIB` | `1024` | `memory_limiter` hard limit. **An empty value is not the same as unset** — the collector refuses to start with `'limit_mib' or 'limit_percentage' must be greater than zero`. |

## Applied to instrumented workloads

Set on IIS application pools, in an app's `web.config`, or on a Windows service — not at machine
scope — so each workload reports under its own name.

| Variable | Where | Value |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | pool / service | `http://127.0.0.1:4318`. The IPv4 literal is deliberate: `localhost` resolves to `::1` first on a dual-stack Windows host and export is dropped with no error. |
| `OTEL_SERVICE_NAME` | pool or `web.config` / service | Per-app name — site name for a root app, `Site/api` for a nested one; the Windows service name for a service; the PM2 app name for a PM2 app. |
| `OTEL_DOTNET_AUTO_HOME` + `CORECLR_*` / `COR_*` profiler variables | W3SVC/WAS service `Environment`, or the target service | Written by the .NET auto-instrumentation module. An empty element in this REG_MULTI_SZ **stops IIS starting** (`PROFILER_REGISTRY_MALFORMED`). |
| `NODE_OPTIONS` | per PM2 app / Node service / **iisnode app pool** | Loads the OTel bootstrap — `--require` for CommonJS, plus `--experimental-loader=file:///…/hook.mjs` for ESM. The wrong form starts the app and emits nothing. Always **merged** with the app's own flags, never overwritten: an app that sets `--max-old-space-size` for a reason keeps its heap ceiling. For iisnode the value goes on the **app pool**, because `node.exe` is a child of `w3wp` and inherits the pool's environment. |

## Where a value lives, and which copy wins

A value can exist in more than one place. In order of precedence for the collector service:

1. **The per-service environment block** —
   `HKLM\SYSTEM\CurrentControlSet\Services\opampsupervisor\Environment`, a REG_MULTI_SZ written by
   the vendor installer. It typically carries `CORALOGIX_PRIVATE_KEY`, `CORALOGIX_DOMAIN`,
   `OTEL_MEMORY_LIMIT_MIB` and `OTEL_LISTEN_INTERFACE`. **This block wins**: changing the machine
   variable and restarting the service does not change what the collector sees.
   When editing it, rewrite the whole block — dropping a sibling entry such as
   `OTEL_MEMORY_LIMIT_MIB` leaves it empty and the collector will not start.
2. **Machine scope** — what the install scripts write and the diagnostics read back.
3. **The process environment** of whatever shell you are in. Useful for a one-off run, invisible
   to services.

For IIS the equivalent hierarchy is `applicationHost.config`
`applicationPoolDefaults` → a pool's own `<environmentVariables>` → an app's `web.config`. A pool
that owns a block **replaces** the defaults rather than merging with them, and that copy is a
snapshot taken when the block was first written: it never refreshes. Changing the defaults
afterwards therefore leaves already-instrumented pools on the old value
(`POOL_ENV_STALE`, `POOL_LOST_INHERITANCE`). Re-running `Instrument-IIS.ps1` repairs it, because
it writes the variables directly onto every pool that owns a block.

## Known limitations

- **Hosts with no SMBIOS Type 4** (common under hypervisors): the `resourcedetection`
  processor's `host.cpu.*` attributes crash-loop the collector. The base config omits them; a
  remote Fleet Management config that re-adds them re-triggers the loop on those hosts. Physical
  hardware is unaffected.
- **Backslashes in supervisor `AgentDescription` values must be doubled.** The supervisor
  re-serializes these values and parses them a second time, so a Windows path written once
  (`C:\ProgramData\pm2`) is invalid on the second pass and the supervisor exits. Write
  `C:\\ProgramData\\pm2`. Quoting alone does not fix it, and a value that survives parsing but
  contains a valid-but-wrong escape starts the supervisor with silently corrupted attributes.
- **`${env:VAR}` expands to a single scalar**, while a `filelog` `include:` is a list. That is why
  IIS log directories occupy fixed slots (`CX_IIS_LOG_DIR_1..3`) and a fourth directory cannot be
  expressed without editing the config.

## Related

- [cli.md](cli.md) — the flags these variables map to
- [exit-codes.md](exit-codes.md) — the findings that report on them
- [../fleet.md](../fleet.md) — setting them from a fleet deployment tool
