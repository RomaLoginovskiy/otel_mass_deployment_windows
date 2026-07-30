# Zero-code OpenTelemetry for Node.js managed by PM2

Extends the fleet zero-code instrumentation (previously IIS/.NET only) to Node.js apps run under
the **PM2** process manager. Detection, instrumentation, service naming, uninstall, and the
Windows-container E2E test all mirror the IIS path.

## Data flow

```
PM2 app (fork or cluster worker)  --OTLP http/protobuf-->  local collector :4318  --OTLP/HTTPS-->  Coralogix
        ^ instrumented by NODE_OPTIONS=--require @opentelemetry/auto-instrumentations-node/register
```

The collector already exposes the OTLP receiver on `127.0.0.1:4317` (gRPC) / `127.0.0.1:4318`
(HTTP) — no collector config change is needed for Node.

## Mechanism

Per PM2 app (`deploy/Instrument-NodePM2.ps1`):

1. `npm install --prefix C:\cx\otel-node @opentelemetry/auto-instrumentations-node @opentelemetry/api`
   (online). The absolute path of the package's `register` bootstrap is resolved via
   `node -e "require.resolve('@opentelemetry/auto-instrumentations-node/register')"`.
2. For each app (from `pm2 jlist`), set in the current process env, then `pm2 restart <name> --update-env`:

   | Env var | Value |
   |---|---|
   | `NODE_OPTIONS` | `--require <C:/cx/otel-node/.../register.js>` |
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://127.0.0.1:4318` |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` |
   | `OTEL_SERVICE_NAME` | the PM2 app name (override-able) |
   | `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `otlp` |

   > ⚠️ **`localhost` vs `127.0.0.1`.** The IPv4 literal is deliberate: on a dual-stack host
   > `localhost` resolves to `::1` first, the collector listens on IPv4 only, and OTLP export
   > is **silently dropped** — no exporter error, the app just looks instrumented and nothing
   > arrives. `Instrument-NodePM2.ps1` defaults to `http://127.0.0.1:4318` and rewrites a
   > `localhost` value passed to `-OtlpEndpoint` (`Resolve-CxOtlpEndpoint`).
   > `Test-NodeInstrumentation.ps1` still flags `OTLP_ENDPOINT_LOCALHOST` if it finds one from
   > another source — a genuine finding, not a false positive.

3. `pm2 save` — persists the resolved env into the PM2 dump so it survives daemon restart / `pm2 resurrect`.
4. Machine env `CX_NODE_SERVICES` = comma-joined distinct service names (Node analog of
   `CX_IIS_SERVICES`).

   > ⚠️ **`CX_NODE_SERVICES` has no consumer yet.** No collector config in this repo reads
   > `${env:CX_NODE_SERVICES}` — there is no `transform/node_service_labels` counterpart to
   > `transform/iis_service_labels`, so **host Service ownership stays blank on a Node-only
   > host**. The variable is set now so a processor can be added later without redeploying
   > every host. `Test-NodeInstrumentation.ps1` reports this as `NODE_SERVICES_NOT_CONSUMED`
   > (info — it does not affect the exit code), and it decides that by *looking* at the
   > effective config, so the finding disappears on its own once something consumes the
   > variable.

### Why `NODE_OPTIONS`, not PM2 `node_args`
PM2's ecosystem `node_args` is **not re-applied on a plain `pm2 restart`** (long-standing quirk).
`NODE_OPTIONS` is an ordinary env var the worker inherits on every (re)start, so the `--require`
hook always loads.

### Why per-app, not machine-wide `NODE_OPTIONS`
A machine-wide value would self-instrument the PM2 God daemon and every `pm2` CLI call (junk spans)
and force one host-wide service name. Setting it per app via `--update-env` keeps the daemon clean
and gives each app its own service name — the direct analog of setting IIS env per app pool.

### PM2 hosted as a Windows service — the case that silently instrumented nothing

PM2 is usually described as **per-user**: the daemon belongs to whoever started it. On Windows
production hosts it is more often installed **as a service** (`pm2-installer`,
`pm2-windows-service`, or node-windows by hand), which looks like this:

```
node.exe  node-windows\lib\wrapper.js --file C:\ProgramData\pm2\service\index.js   <- service shim
 └─ node.exe  C:\ProgramData\pm2\service\index.js                                  <- God daemon
     ├─ node.exe  pm2\lib\ProcessContainerFork.js                                  <- app
     └─ ... one per app
```

with `PM2_HOME=C:\ProgramData\pm2`, the npm prefix at `C:\ProgramData\npm`, and every process
owned by **`NT AUTHORITY\LOCAL SERVICE`**.

Everything about that layout defeats a naive deploy, and none of it produces an error:

| What the deploy assumes | What actually happens |
|---|---|
| `pm2` is on the deploying account's PATH | it is in `C:\ProgramData\npm`, often not on the PATH of the account a fleet tool runs as |
| `~\.pm2` or `$env:PM2_HOME` exists for us | the home is `C:\ProgramData\pm2` and belongs to the service account |
| `pm2 jlist` lists the apps | the daemon's IPC pipe belongs to `LOCAL SERVICE`; pm2 answers for an empty daemon of **our** own and exits 0 |
| `pm2 restart <app> --update-env` applies the env | it restarts nothing, and reports success |

The result observed on a real host: PM2 detection reported absent, so
`Install-Agent.ps1`'s `if ($roles.PM2 -and -not $SkipInstrument)` gate never fired, and a host
running **26 PM2 apps produced zero Node telemetry** — with nothing in any log saying why. The
`pm2-prometheus-exporter` on the same host was being scraped happily the whole time, so the
collector knew PM2 was there while the detection script did not.

How the scripts handle it now:

* **Detection** (`Detect-Workloads.ps1` → `Get-CxPm2Topology`) probes machine-wide instead of
  per-account: `Win32_Process` command lines for the wrapper/daemon/worker processes,
  `Win32_Service.StartName` for the owning account, `dump.pm2` on disk for the app set. It
  publishes `workload.pm2.hosting`, `workload.pm2.owner` and `workload.pm2.home` alongside
  `workload.pm2` / `workload.pm2.apps`.
* **App enumeration** (`Get-PM2ProcessList`) pins `PM2_HOME` before calling `pm2 jlist`, and when
  the daemon still says nothing it falls back to `dump.pm2`, then to `<home>\logs\<app>-out.log`
  basenames. Each record carries the `Source` it came from.
* **Applying the env** (`Invoke-CxPm2AsOwner`) runs `pm2 restart --update-env` / `pm2 save` **as
  the owning account** through a transient scheduled task. A scheduled task rather than an
  impersonation API because `LOCAL SERVICE` / `NETWORK SERVICE` / a gMSA have no password to log
  on with, and Task Scheduler's `ServiceAccount` principal needs none.
* **Uninstall** takes the same route — otherwise it no-ops on exactly the hosts where install had
  to use it, leaving apps pointing at a register path the uninstall just deleted.
* **The doctor** reports `NODE_PM2_SERVICE_HOSTED` (info) plus, when it can prove apps exist that
  it cannot reach, `NODE_PM2_DAEMON_OWNER_MISMATCH` (**fail**). Previously this host shape came
  out as `unknown` / exit 0, which is why it went unnoticed.

### IIS in front of PM2

The common shape on these hosts is IIS as a **reverse proxy** (ARR + URL Rewrite) forwarding to a
PM2 app on localhost. Two consequences worth stating before someone reads them as bugs:

* Those IIS sites have **no managed code**, so .NET auto-instrumentation has nothing to attach to
  and produces no spans for them. `Test-IISInstrumentation.ps1` reports
  `NON_DOTNET_APP_NOT_INSTRUMENTED` — correct, not a gap. The app telemetry has to come from the
  Node side, which is precisely why the Node path failing silently is expensive here.
* ARR is a native module and does not inject `traceparent`, so **Node spans are trace roots**.
  There is no IIS→Node parent-child link to look for unless the caller upstream already
  propagates context.

### Staged rollout

Instrumenting is a restart, and these hosts carry dev/qa/uat/sandbox apps side by side. Restarting
two dozen of them because a deploy script ran is not the script's call:

```powershell
# one app, in a change window
.\Instrument-NodePM2.ps1 -Apps qa.jackpotcity

# see what it would touch, change nothing
.\Instrument-NodePM2.ps1 -WhatIf
```

`-Apps` also merges (rather than replaces) `CX_NODE_SERVICES`, so a later pass does not strip the
ownership label off apps instrumented in an earlier one. PM2's own utility apps
(`pm2-logrotate`, `pm2-prometheus-exporter`, ...) are excluded by default — instrumenting them
would put PM2's log rotator and metrics exporter into APM as services. Pass `-ExcludeApps @()` to
include them.

### CommonJS vs ESM

`--require` cannot load the instrumentation into an ES module graph: the app starts perfectly and
emits nothing. `Instrument-NodePM2.ps1` picks the flag per app — `--import` for an `.mjs` entry
point or a `package.json` with `"type": "module"`, `--require` otherwise — and skips an ESM app
with a warning on Node < 20, where `--import` does not exist. The doctor reports a wrong pairing
it finds as `NODE_ESM_REQUIRE_MISMATCH`.

### Cluster mode = per-worker telemetry
PM2 cluster workers are separate Node PIDs that each inherit `NODE_OPTIONS` + `OTEL_SERVICE_NAME`,
so each loads its own instrumentation and reports independently. They share **one**
`OTEL_SERVICE_NAME` (the app name) so Coralogix rolls them up as a single service; the OTel
`process` resource detector separates workers by `process.pid`.

## End-to-end flow

`Detect-Workloads.ps1` (adds `Get-PM2Info`, `workload.pm2=true`, `workload.pm2.apps=<count>`,
`PrimaryRole=nodejs-pm2`) → `Install-Agent.ps1` gate `if ($roles.PM2 -and -not $SkipInstrument)`
→ `Instrument-NodePM2.ps1`. `Uninstall-Agent.ps1` reverses via `Remove-NodeInstrumentation`
(clears `NODE_OPTIONS`, `pm2 restart --update-env`, `pm2 save`) and clears `CX_NODE_SERVICES`.
`Build-DeploymentPackage.ps1` bundles `Instrument-NodePM2.ps1` + `Resolve-NodeServiceNames.ps1`.

## Test (Windows container) + Coralogix verification

Image `test/docker-win/` (servercore/iis) now also installs Node.js + PM2 and runs a sample app
(`test/docker-win/nodeapp/`) in **both** PM2 modes: `nodeapp-fork` (fork, :9081) and
`nodeapp-cluster` (cluster, 2 workers, :9082). The entrypoint starts them, runs
`Instrument-NodePM2.ps1`, and generates HTTP load continuously.

```powershell
pwsh test/docker-win/Run-DockerWinTest.ps1     # build + run (Docker in Windows-container mode)
# wait ~10-15 min for ingestion, then:
pwsh scripts/Verify-CoralogixNodeSpans.ps1     # DataPrime gate
```

`Verify-CoralogixNodeSpans.ps1` (DataPrime API `ng-api-http.coralogix.com`, Bearer query key from
`querydata_key.txt`) PASSES when each service has **spans > 0 and logs > 0**, and
`nodeapp-cluster` shows **>= 2 distinct `process.pid`** (per-worker proof). Metrics are confirmed
via the collector exporter counters printed in the container log (`[export] sent_metric_points=`)
and Coralogix APM/Metrics.

## Verify on a real host

The container test above proves the mechanism. On a deployed host use the validator that
ships in the package — read-only, no Docker, no Coralogix key:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Test-NodeInstrumentation.ps1
doctor.bat -Only nodeInstrumentation      # or as part of the full sweep
```

Exit `0` pass / `1` hard fail / `2` degraded. It is also **dual-mode**: dot-source it to get
`Test-NodeInstrumentation` returning finding objects, which is how `Test-Agent.ps1` consumes
it. Full code list: [`agent-diagnostics.md`](./agent-diagnostics.md).

### The shapes this covers

Node runs on Windows in more ways than one, and the difference decides whether zero-code
instrumentation reaches the process at all:

* **PM2 per-user**, fork and cluster mode — covered; `NODE_OPTIONS` is written into the app's PM2
  environment and applied with `pm2 restart --update-env`.
* **PM2 hosted as a Windows service** under `LOCAL SERVICE`, `LocalSystem` or an ordinary account —
  covered, but the daemon's `PM2_HOME` and owning account decide which apps are visible, so the
  instrumenter reports the daemon's topology rather than assuming the per-user default.
* **A stopped daemon** with only `dump.pm2` on disk — the app list is read from the dump, and the
  finding says so, because a dump is a snapshot and can disagree with what will run next.
* **Node as a Windows service without PM2** (`winsw`, `nssm`, or a bare SCM command line) — covered
  by `Instrument-NodeService.ps1`.
* **Bare `node.exe`** from a scheduled task, **iisnode**, and **IIS ARR in front of PM2** — reported
  as out of scope rather than silently assumed. For the ARR case the IIS side is deliberately not
  claimed: the pool's environment never reaches the backend process, so the backend has to be
  instrumented where it runs.

### Verify coverage with no host access at all

When you cannot log into the host — the usual case for a customer fleet — Coralogix already holds
both halves of the answer, and `scripts/Verify-Pm2Coverage.ps1` diffs them:

```powershell
.\scripts\Verify-Pm2Coverage.ps1 -HostName OTIOMWQA01 `
    -ApiHost ng-api-http.eu2.coralogix.com -KeyLabel sga
```

* **expected** — `last_over_time(pm2_up{host_name=~"(?i)<host>"}[<lookback>m])`. The pm2 prometheus
  exporter publishes one series per managed app, labelled with the app name, so this *is* the app
  list straight off the host.
* **observed** — `source spans | filter ... | groupby $d.process.serviceName, telemetry.sdk.language`.

Expected minus observed is the coverage gap. Exit `0` all covered / `1` at least one gap /
`2` the expected set could not be established. Use it after a staged `-Apps` rollout to confirm
each app before widening.

Three things it encodes that cost time to discover:

* Attribute keypaths need **bracket** syntax — `$d.resource.attributes['host.name']`. The
  single-quoted and backtick forms are compile errors, and the dotted
  `$d.resource.attributes.host.name` compiles to a keypath that does not exist and aggregates
  everything as `null`.
* Use `last_over_time(...[Nm])`, not a bare instant query: `pm2_up` is scraped periodically, and an
  instant query at `now` returns an empty result while reporting `seriesFetched: 28` — which reads
  exactly like "this host runs no PM2 apps".
* Send a normal `User-Agent`. Some defaults get a Cloudflare `403 error code: 1010` from every
  region host, which looks identical to a bad key. Accounts with archive-only retention also
  answer on `TIER_ARCHIVE` and return nothing for `TIER_FREQUENT_SEARCH`, so both tiers are tried.

## Troubleshooting

| Symptom | Finding | Cause / fix |
| --- | --- | --- |
| No spans from any PM2 app | `NODE_OPTIONS_MISSING` | The instrument script never ran for this app, or a plain `pm2 restart` without `--update-env` dropped the env and no `pm2 save` followed. |
| Spans stopped after a redeploy or npm cleanup | `NODE_REGISTER_PATH_STALE` | `NODE_OPTIONS` points at a `register.js` that no longer exists. Node starts fine and emits nothing. Re-run the instrument script. |
| Package never staged | `NODE_PACKAGE_MISSING` | `@opentelemetry/auto-instrumentations-node` is not under `-InstallPrefix` (default `C:\cx\otel-node`) — the npm install failed at deploy time (offline host). |
| Doctor reports no apps on a host you know runs apps | `NODE_PM2_DAEMON_NOT_VISIBLE` / `NO_PM2_APPS` | PM2 is **per-user** on Windows; the daemon belongs to another account, so `pm2 jlist` is empty for the caller, and nothing else proved the apps exist. Reported as `unknown`, never a failure — re-run as the owning account. |
| Apps demonstrably running, none instrumented, install claimed success | `NODE_PM2_DAEMON_OWNER_MISMATCH` | PM2 is hosted as a Windows service owned by another account. Re-run `Instrument-NodePM2.ps1`, which routes `pm2` through that account. See **PM2 hosted as a Windows service** above. |
| `pm2` not found | `NODE_PM2_NOT_ON_PATH` | PM2 installed for a different user, or not on the machine PATH. If a PM2 daemon *is* running, this is reported as an ownership problem instead. |
| App starts fine and emits nothing, `NODE_OPTIONS` looks right | `NODE_ESM_REQUIRE_MISMATCH` | ES module entry point preloaded with `--require`. Needs `--import` (Node ≥ 20). |
| Doctor lists apps the live daemon did not | `NODE_PM2_APPS_FROM_DUMP` | `dump.pm2` knows about stopped apps, or a second daemon owns them. |
| Service name wrong or missing in Coralogix | `NODE_SERVICE_NAME_MISSING` / `NODE_SERVICE_NAME_DRIFT` | `OTEL_SERVICE_NAME` no longer matches the app set (renamed app, or an override the doctor was not told about). |
| Everything reports configured, still no data | `OTLP_ENDPOINT_LOCALHOST` | `localhost` → `::1`, export silently dropped. Use `http://127.0.0.1:4318`. |
| `doctor.bat` prints its whole report and then never returns | — | A `pm2` command that has to **spawn** the God daemon leaves the daemon holding the caller's stdout pipe, so the remote-execution session hangs after the script has already finished. Every pm2 call now goes through the bounded `Invoke-CxPm2` for this reason. If you see it again, something is calling `& pm2` inline. |
| Detection or the doctor reports "PM2 manages no apps" on a host that plainly runs them | — | Check `Get-CxPm2CommandPath`: npm installs `pm2`, `pm2.cmd` **and** `pm2.ps1` side by side, `Get-Command pm2` may return the `.ps1`, and `CreateProcess` cannot launch a `.ps1` — so pm2 never runs and the empty output reads as "no apps". The helper forces the `.cmd`. |
| APM fine, but host Service ownership blank | `NODE_SERVICES_NOT_CONSUMED` (info) | Expected — no collector processor reads `CX_NODE_SERVICES`. See **Mechanism** step 4. |

## Notes / caveats
- Run the instrument script in the **same user context** that owns the PM2 daemon (PM2 is per-user
  on Windows).
- Requires npm registry access at deploy time (online), unless the package is pre-staged in
  `InstallPrefix` and `-SkipInstall` is passed.
- The sample app uses `pino` so the **logs** pipeline is exercised (auto-instrumentations-node
  bridges pino/winston/bunyan output to OTLP logs; plain `console.log` is not bridged).
