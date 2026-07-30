# Zero-code OpenTelemetry for Node.js under PM2

Extends the fleet's zero-code instrumentation to Node.js apps run under the **PM2** process
manager. Detection, instrumentation, service naming and uninstall all mirror the IIS path, so one
deploy covers a host that runs both.

Flags and defaults for every script named here: [reference/cli.md](reference/cli.md).

## Data flow

```text
PM2 app (fork or cluster worker)  --OTLP http/protobuf-->  local collector :4318  --OTLP/HTTPS-->  Coralogix
        ^ instrumented by NODE_OPTIONS, which preloads the OTel bootstrap
```

The collector already exposes the OTLP receiver on `127.0.0.1:4317` (gRPC) and `127.0.0.1:4318`
(HTTP), so **no collector config change is needed for Node**.

## Mechanism

Per PM2 app, `deploy/Instrument-NodePM2.ps1`:

1. Installs `@opentelemetry/auto-instrumentations-node` and `@opentelemetry/api` under
   `-InstallPrefix` (default `C:\cx\otel-node`), then resolves the absolute path of the package's
   `register` bootstrap with `node -e "require.resolve(…)"`.
2. Sets these variables per app and applies them with `pm2 restart <name> --update-env`:

   | Variable | Value |
   | --- | --- |
   | `NODE_OPTIONS` | `--require <prefix>\…\register.js` (CommonJS) or `--import` (ESM) |
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://127.0.0.1:4318` |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` |
   | `OTEL_SERVICE_NAME` | the PM2 app name, override-able |
   | `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `otlp` |

3. Runs `pm2 save`, so the resolved environment survives a daemon restart or `pm2 resurrect`.
4. Publishes `CX_NODE_SERVICES` — the comma-joined distinct service names, the Node analog of
   `CX_IIS_SERVICES`.

> **`localhost` vs `127.0.0.1`.** The IPv4 literal is deliberate: on a dual-stack host `localhost`
> resolves to `::1` first, the collector listens on IPv4 only, and OTLP export is **silently
> dropped** — no exporter error, the app just looks instrumented and nothing arrives. The
> instrumenter defaults to `http://127.0.0.1:4318` and rewrites a `localhost` value passed to
> `-OtlpEndpoint`. `Test-NodeInstrumentation.ps1` still flags `OTLP_ENDPOINT_LOCALHOST` when it
> finds one from another source.

> **`CX_NODE_SERVICES` has no consumer.** No collector config reads `${env:CX_NODE_SERVICES}` —
> there is no `transform/node_service_labels` counterpart to `transform/iis_service_labels`. Node
> services reach host Service ownership through the union variable `CX_SERVICES` instead. The
> doctor reports `NODE_SERVICES_NOT_CONSUMED` (info) and decides it by *looking* at the effective
> config, so the finding disappears on its own if a processor is added.

### Why `NODE_OPTIONS`, not PM2 `node_args`

PM2's ecosystem `node_args` is **not re-applied on a plain `pm2 restart`** — a long-standing quirk.
`NODE_OPTIONS` is an ordinary environment variable the worker inherits on every start, so the
preload always loads.

### Why per-app, not machine-wide `NODE_OPTIONS`

A machine-wide value would self-instrument the PM2 daemon and every `pm2` CLI call, producing junk
spans, and would force one host-wide service name. Per-app via `--update-env` keeps the daemon
clean and gives each app its own service name — the direct analog of setting environment variables
per IIS application pool.

## PM2 hosted as a Windows service

PM2 is usually described as **per-user**: the daemon belongs to whoever started it. On Windows
production hosts it is more often installed **as a service** (`pm2-installer`,
`pm2-windows-service`, or node-windows by hand), which looks like this:

```text
node.exe  node-windows\lib\wrapper.js --file C:\ProgramData\pm2\service\index.js   <- service shim
 └─ node.exe  C:\ProgramData\pm2\service\index.js                                  <- daemon
     ├─ node.exe  pm2\lib\ProcessContainerFork.js                                  <- app
     └─ ... one per app
```

with `PM2_HOME=C:\ProgramData\pm2`, the npm prefix at `C:\ProgramData\npm`, and every process owned
by **`NT AUTHORITY\LOCAL SERVICE`**.

Everything about that layout defeats a naive deploy, and none of it produces an error:

| What a naive deploy assumes | What actually happens |
| --- | --- |
| `pm2` is on the deploying account's PATH | it is in `C:\ProgramData\npm`, often not on the PATH of the account a fleet tool runs as |
| `~\.pm2` or `$env:PM2_HOME` belongs to us | the home is `C:\ProgramData\pm2` and belongs to the service account |
| `pm2 jlist` lists the apps | the daemon's IPC pipe belongs to `LOCAL SERVICE`; pm2 answers for an empty daemon of **our** own and exits 0 |
| `pm2 restart <app> --update-env` applies the environment | it restarts nothing, and reports success |

The failure mode this produces is expensive: PM2 detection reports absent, the install's
`if ($roles.PM2 -and -not $SkipInstrument)` gate never fires, and a host running two dozen PM2 apps
produces **zero Node telemetry** with nothing in any log saying why. A `pm2-prometheus-exporter` on
the same host can be scraped happily throughout, so the collector knows PM2 is there while
detection does not.

How the scripts handle it:

- **Detection** (`Detect-Workloads.ps1` → `Get-CxPm2Topology`) probes machine-wide instead of
  per-account: `Win32_Process` command lines for the wrapper, daemon and worker processes,
  `Win32_Service.StartName` for the owning account, and `dump.pm2` on disk for the app set. It
  publishes `workload.pm2.hosting`, `workload.pm2.owner` and `workload.pm2.home` alongside
  `workload.pm2` and `workload.pm2.apps`.
- **App enumeration** (`Get-PM2ProcessList`) pins `PM2_HOME` before calling `pm2 jlist`; when the
  daemon still says nothing it falls back to `dump.pm2`, then to `<home>\logs\<app>-out.log`
  basenames. Each record carries the `Source` it came from.
- **Applying the environment** (`Invoke-CxPm2AsOwner`) runs `pm2 restart --update-env` and
  `pm2 save` **as the owning account**, through a transient scheduled task. A scheduled task rather
  than an impersonation API because `LOCAL SERVICE`, `NETWORK SERVICE` and a gMSA have no password
  to log on with, and Task Scheduler's `ServiceAccount` principal needs none.
- **Uninstall** takes the same route — otherwise it no-ops on exactly the hosts where install had
  to use it, leaving apps pointing at a register path the uninstall just deleted.
- **The doctor** reports `NODE_PM2_SERVICE_HOSTED` (info) plus, when it can prove apps exist that it
  cannot reach, `NODE_PM2_DAEMON_OWNER_MISMATCH` (**fail**).

## IIS in front of PM2

A common shape on these hosts is IIS as a **reverse proxy** (ARR + URL Rewrite) forwarding to a PM2
app on localhost. Two consequences, so neither reads as a bug:

- Those IIS sites have no managed code, so .NET auto-instrumentation has nothing to attach to and
  produces no spans for them. `Test-IISInstrumentation.ps1` reports
  `NON_DOTNET_APP_NOT_INSTRUMENTED` — correct, not a gap. The application telemetry has to come
  from the Node side, which is exactly why a silent Node failure is expensive here.
- ARR is a native module and does not inject `traceparent`, so **Node spans are trace roots**.
  There is no IIS→Node parent-child link to look for unless the caller upstream already propagates
  context.

## Staged rollout

Instrumenting is a restart, and these hosts often carry dev, QA, UAT and sandbox apps side by side.
Restarting two dozen of them because a deploy script ran is not the script's call:

```powershell
# one app, in a change window
.\Instrument-NodePM2.ps1 -Apps <pm2-app-name>

# see what it would touch, change nothing
.\Instrument-NodePM2.ps1 -WhatIf
```

`-Apps` **merges** rather than replaces `CX_NODE_SERVICES`, so a later pass does not strip the
ownership label off apps instrumented in an earlier one. PM2's own utility apps (`pm2-logrotate`,
`pm2-prometheus-exporter`, …) are excluded by default — instrumenting them would put PM2's log
rotator and metrics exporter into APM as services. Pass `-ExcludeApps @()` to include them.

## CommonJS vs ESM

`--require` cannot load the instrumentation into an ES module graph: the app starts perfectly and
emits nothing. `Instrument-NodePM2.ps1` picks the flag per app — `--import` for an `.mjs` entry
point or a `package.json` with `"type": "module"`, `--require` otherwise — and skips an ESM app with
a warning on Node < 20, where `--import` does not exist. A wrong pairing found on a host is reported
as `NODE_ESM_REQUIRE_MISMATCH`.

## Cluster mode is per-worker telemetry

PM2 cluster workers are separate Node processes that each inherit `NODE_OPTIONS` and
`OTEL_SERVICE_NAME`, so each loads its own instrumentation and reports independently. They share
**one** `OTEL_SERVICE_NAME` (the app name) so Coralogix rolls them up as a single service; the OTel
`process` resource detector separates workers by `process.pid`.

## The shapes this covers

Node runs on Windows in more ways than one, and the difference decides whether zero-code
instrumentation reaches the process at all:

- **PM2 per-user**, fork and cluster mode — covered; `NODE_OPTIONS` is written into the app's PM2
  environment and applied with `pm2 restart --update-env`.
- **PM2 hosted as a Windows service** under `LOCAL SERVICE`, `LocalSystem` or an ordinary account —
  covered, but the daemon's `PM2_HOME` and owning account decide which apps are visible, so the
  instrumenter reports the daemon's topology rather than assuming the per-user default.
- **A stopped daemon** with only `dump.pm2` on disk — the app list is read from the dump, and the
  finding says so, because a dump is a snapshot and can disagree with what will run next.
- **Node as a Windows service without PM2** (`winsw`, `nssm`, or a bare SCM command line) — covered
  by `Instrument-NodeService.ps1`.
- **Bare `node.exe`** from a scheduled task, **iisnode**, and **IIS ARR in front of PM2** — reported
  as out of scope rather than silently assumed. For the ARR case the IIS side is deliberately not
  claimed: the pool's environment never reaches the backend process, so the backend has to be
  instrumented where it runs.

## Verify on the host

Read-only, ships in the package, needs no Coralogix key:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Test-NodeInstrumentation.ps1

REM or as part of the full sweep
set CX_DOCTOR_ONLY=nodeInstrumentation && doctor.bat
```

Exit `0` pass, `1` hard fail, `2` degraded. The validator is dual-mode: dot-source it to get
findings as objects, which is how `Test-Agent.ps1` consumes it. Full code list:
[reference/exit-codes.md](reference/exit-codes.md).

## Verify with no host access

When you cannot log into the host — the usual case for a customer fleet — Coralogix already holds
both halves of the answer, and `scripts/Verify-Pm2Coverage.ps1` diffs them:

```powershell
.\scripts\Verify-Pm2Coverage.ps1 -HostName <host> `
    -ApiHost ng-api-http.<region>.coralogix.com -QueryKeyFile <path> -KeyLabel <label>
```

- **Expected** — `last_over_time(pm2_up{host_name=~"(?i)<host>"}[<lookback>m])`. The pm2 Prometheus
  exporter publishes one series per managed app, labelled with the app name, so this *is* the app
  list straight off the host.
- **Observed** — the distinct service names reporting Node spans for that host.

Expected minus observed is the coverage gap. Exit `0` all covered, `1` at least one gap, `2` the
expected set could not be established. Use it after a staged `-Apps` rollout to confirm each app
before widening.

Three query details it encodes, each of which otherwise costs an afternoon:

- Attribute keypaths need **bracket** syntax — `$d.resource.attributes['host.name']`. The
  single-quoted and backtick forms are compile errors, and the dotted
  `$d.resource.attributes.host.name` compiles to a keypath that does not exist and aggregates
  everything as `null`.
- Use `last_over_time(...[Nm])`, not a bare instant query: `pm2_up` is scraped periodically, and an
  instant query at `now` returns an empty result while still reporting series fetched — which reads
  exactly like "this host runs no PM2 apps".
- Send a normal `User-Agent`, and try both storage tiers. Some default agents get a Cloudflare
  `403 error code: 1010` from every region host, which looks identical to a bad key; accounts with
  archive-only retention answer on the archive tier and return nothing for frequent search.

## Troubleshooting

| Symptom | Finding | Cause and fix |
| --- | --- | --- |
| No spans from any PM2 app | `NODE_OPTIONS_MISSING` | The instrument script never ran for this app, or a plain `pm2 restart` without `--update-env` dropped the environment and no `pm2 save` followed. |
| Spans stopped after a redeploy or npm cleanup | `NODE_REGISTER_PATH_STALE` | `NODE_OPTIONS` points at a `register.js` that no longer exists. Node starts fine and emits nothing. Re-run the instrumenter. |
| Package never staged | `NODE_PACKAGE_MISSING` | The OTel package is not under `-InstallPrefix` — the npm install failed at deploy time, typically an offline host. Pre-stage it and pass `-SkipInstall`. |
| Doctor reports no apps on a host you know runs apps | `NODE_PM2_DAEMON_NOT_VISIBLE` / `NO_PM2_APPS` | The daemon belongs to another account, so `pm2 jlist` is empty for the caller and nothing else proved the apps exist. Reported as `unknown`, never a failure — re-run as the owning account. |
| Apps demonstrably running, none instrumented, install claimed success | `NODE_PM2_DAEMON_OWNER_MISMATCH` | PM2 is hosted as a Windows service owned by another account. Re-run `Instrument-NodePM2.ps1`, which routes `pm2` through that account. |
| `pm2` not found | `NODE_PM2_NOT_ON_PATH` | PM2 installed for a different user, or not on the machine PATH. If a daemon *is* running, this is reported as an ownership problem instead. |
| App starts fine and emits nothing, `NODE_OPTIONS` looks right | `NODE_ESM_REQUIRE_MISMATCH` | ES module entry point preloaded with `--require`. Needs `--import` (Node ≥ 20). |
| Doctor lists apps the live daemon did not | `NODE_PM2_APPS_FROM_DUMP` | `dump.pm2` knows about stopped apps, or a second daemon owns them. |
| Service name wrong or missing in Coralogix | `NODE_SERVICE_NAME_MISSING` / `NODE_SERVICE_NAME_DRIFT` | `OTEL_SERVICE_NAME` no longer matches the app set — a renamed app, or an override the doctor was not told about. |
| Everything reports configured, still no data | `OTLP_ENDPOINT_LOCALHOST` | `localhost` resolves to `::1` and export is dropped. Use `http://127.0.0.1:4318`. |
| `doctor.bat` prints its whole report and then never returns | — | A `pm2` command that has to **spawn** the daemon leaves the daemon holding the caller's stdout pipe, so a remote-execution session hangs after the script has already finished. Every pm2 call goes through the bounded `Invoke-CxPm2` for this reason. If it recurs, something is calling `& pm2` inline. |
| Detection reports "PM2 manages no apps" on a host that plainly runs them | — | npm installs `pm2`, `pm2.cmd` **and** `pm2.ps1` side by side; `Get-Command pm2` may return the `.ps1`, and `CreateProcess` cannot launch a `.ps1`, so pm2 never runs and the empty output reads as "no apps". `Get-CxPm2CommandPath` forces the `.cmd`. |
| APM fine, but host Service ownership blank for Node | `NODE_SERVICES_NOT_CONSUMED` (info) | Expected — no collector processor reads `CX_NODE_SERVICES`. Ownership comes from `CX_SERVICES`. |

## Caveats

- Run the instrumenter in the **same user context** that owns the PM2 daemon, or let it route
  through the owning account as described above.
- npm registry access is required at deploy time, unless the package is pre-staged under
  `-InstallPrefix` and `-SkipInstall` is passed.
- Only logging libraries the auto-instrumentation bridges (pino, winston, bunyan) reach the OTLP
  logs pipeline. Plain `console.log` output is not bridged.

## Related

- [reference/cli.md](reference/cli.md) — every flag on the Node scripts
- [reference/exit-codes.md](reference/exit-codes.md) — every Node finding code
- [reference/env-vars.md](reference/env-vars.md) — `CX_NODE_SERVICES`, `CX_SERVICES` and the rest
- [diagnostics.md](diagnostics.md) — reading a confusing doctor result
- [fleet.md](fleet.md) — rolling this out across a fleet
