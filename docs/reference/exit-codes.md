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

| Severity | Count | Effect on exit code |
| --- | --- | --- |
| `fail` | 11 | Sets `1` |
| `warn` | 36 | Sets `2` unless a `fail` is also present |
| `pass` | 2 | None |
| `info` | 8 | None |
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
| `NODE_PM2_DAEMON_OWNER_MISMATCH` | The PM2 daemon is owned by another account (typically `NT AUTHORITY\LOCAL SERVICE`, PM2 installed as a Windows service) and its apps have been **proven** to exist. Nothing this account does with `pm2` can reach them: `pm2` answers for an empty daemon of its own and exits 0. | Run `pm2` as the owning account — `Instrument-NodePM2.ps1` does this automatically; see [../nodejs-pm2.md](../nodejs-pm2.md). |
| `NODE_ESM_REQUIRE_MISMATCH` | The app is an ES module but `NODE_OPTIONS` uses `--require`, which cannot load the instrumentation into an ESM graph. The app starts normally and emits nothing, with no error anywhere. | Re-run the Node instrumenter so it emits `--import` (Node ≥ 20). |

## `warn` — exit 2

### Environment and identity

| Code | Meaning | Fix |
| --- | --- | --- |
| `DOMAIN_MISSING` | `CORALOGIX_DOMAIN` unset; the config default applies and this host ships to **eu1**. | Re-deploy with `-Region` / `CX_REGION`, or `-Domain` / `CX_DOMAIN` for a private ingress. |
| `DOMAIN_NOT_A_KNOWN_REGION` | `CORALOGIX_DOMAIN` is not one of the published region domains, so data goes to `ingress.<that domain>`. Expected for a private ingress; a typo otherwise — the collector reports healthy either way. | Confirm the domain is deliberate. |
| `CX_ENVIRONMENT_MISSING` | `CX_ENVIRONMENT` unset; all telemetry from this host is labelled `unspecified`. | Re-deploy with `-Environment` / `CX_ENVIRONMENT`. |
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

### Node instrumentation

| Code | Meaning | Fix |
| --- | --- | --- |
| `NODE_PACKAGE_MISSING` | The OTel Node package is not staged under the install prefix. | Re-run `Instrument-NodePM2.ps1` without `-SkipInstall`, or pre-stage the package. |
| `NODE_OPTIONS_MISSING` | A PM2 app carries no `NODE_OPTIONS` bootstrap — it is not instrumented. | Re-run the Node instrumenter. |
| `NODE_REGISTER_PATH_STALE` | `NODE_OPTIONS` points at a register bootstrap that no longer exists. | Re-run the Node instrumenter. |

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
| `CX_SERVICES_MISSING` | The union variable is unset while per-workload slices exist. |

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
| `CHECK_ERRORED` | A delegated validator threw; the message carries the exception. |
| `WEBADMINISTRATION_MISSING` | The IIS PowerShell module was unavailable, so expected names were derived from `applicationHost.config` instead. |
| `WEBCONFIG_UNREADABLE` | An app's `web.config` exists but could not be opened or parsed (ACL, lock, malformed XML), or the app has no `physicalPath`. Distinct from `WEBCONFIG_ABSENT`. |
| `POOL_NOT_FOUND` | An application references a pool not declared in `applicationHost.config`. |
| `RUNTIME_UNKNOWN_NEEDS_OVERRIDE` | The application's runtime could not be determined. Nothing was written and nothing was claimed, rather than guessed. Decide it with `-RuntimeOverrides`. |
| `APPHOST_ACCESS_DENIED` | `applicationHost.config` could not be read because of permissions. Run elevated. |
| `APPHOST_UNREADABLE` | `applicationHost.config` could not be found, read or parsed. See the causes in [../diagnostics.md](../diagnostics.md) — this can happen while the install itself worked. |
| `IIS_LOGCONFIG_UNREADABLE` | The logging section of `applicationHost.config` could not be read, so log coverage is unknown. |
| `EFFECTIVE_CONFIG_NOT_FOUND` | Neither the supervisor effective config nor the base collector config exists. |
| `EFFECTIVE_CONFIG_UNREADABLE` | The config file exists but could not be read. |
| `EFFECTIVE_PIPELINE_NOT_FOUND` | A required pipeline block could not be located, so the processor could not be confirmed as wired into it. |
| `NODE_PM2_DAEMON_NOT_VISIBLE` | PM2 is installed but its app list is empty or unreadable, and the apps could **not** be proven to exist by other means — almost always another account's daemon. Once they are proven, the finding becomes `NODE_PM2_DAEMON_OWNER_MISMATCH` (fail). |
| `NODE_PM2_NOT_ON_PATH` | Node processes are running but `pm2` is not on this account's PATH. |

## Related

- [cli.md](cli.md) — how to run each diagnostic and what its flags do
- [env-vars.md](env-vars.md) — the variables the findings refer to
- [../diagnostics.md](../diagnostics.md) — why the checks are shaped this way, and how to read a confusing result
