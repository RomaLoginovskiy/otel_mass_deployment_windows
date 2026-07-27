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
| `POOL_NOT_NO_MANAGED_CODE` | An ASP.NET Core app on a pool that is not "No Managed Code". Emits no telemetry at all |
| `POOL_ENV_STALE` | See below |
| `OTLP_ENDPOINT_LOCALHOST` | See below |

### Two traps worth knowing

**`localhost` silently drops OTLP.** On a dual-stack host `localhost` resolves to `::1`
first, and export is dropped with no error. `127.0.0.1` is required. `Instrument-IIS.ps1`
still defaults `-OtlpEndpoint` to `http://localhost:4318`, so a stock deploy will raise
`OTLP_ENDPOINT_LOCALHOST` on every pool. That is a genuine finding, not a false positive.

**A pool's environment block is a snapshot.** A pool that has its own
`<environmentVariables>` **replaces** `applicationPoolDefaults` rather than merging with it.
IIS materialises the defaults into that block the first time `appcmd` writes any variable to
the pool — and that copy never refreshes. So changing `applicationPoolDefaults` afterwards
leaves every already-instrumented pool on the old value. This is the mechanism behind "I
fixed the endpoint centrally and half the fleet still exports nowhere", and it surfaces as
`POOL_ENV_STALE`.

### `CX_NODE_SERVICES` has no consumer

`Instrument-NodePM2.ps1` sets the machine variable `CX_NODE_SERVICES`, but **no collector
config reads `${env:CX_NODE_SERVICES}`** — unlike `CX_IIS_SERVICES`, there is no transform
consuming it, so Node host Service-ownership stays blank. The doctor reports this as
`NODE_SERVICES_NOT_CONSUMED` (info, does not affect the exit code), and it decides that by
*looking* at the effective config, so the finding disappears on its own if a processor is
ever added.

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
standalone/aggregator parity, and the read-only invariant. Mutations live in
`test/docker-win/break-state.ps1` and only ever touch the disposable container.

Container processes run as `ContainerAdministrator`, so the elevation-gated paths execute
without an interactive UAC prompt.
