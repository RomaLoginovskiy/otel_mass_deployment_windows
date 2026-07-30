# Windows Docker test harnesses

| Harness | Kind | Runner | In git |
| --- | --- | --- | --- |
| **Diagnostics** | **Offline, self-asserting** — no keys, no network | `Run-DoctorTest.ps1` | ✅ |
| **Full deploy loop** | Drives `deploy.bat` / `doctor.bat` over an 8-shape IIS host, injects faults | `Run-E2ELoop.ps1` | ✅ |
| **IIS + supervisor E2E** (below) | Ships telemetry to Coralogix; human reads the verdict | `Run-DockerWinTest.ps1` | — |
| **Node.js + PM2 variant** | Same image, PM2 apps added | `Run-DockerWinTest.ps1` + `scripts/Verify-CoralogixNodeSpans.ps1` | — |
| **RabbitMQ variant** | Ships RabbitMQ metrics/logs | `Run-RabbitmqTest.ps1` | — |

**Only the two asserting harnesses are committed.** They have expected results, exit
non-zero on failure, and run from a clean clone. The three telemetry-shipping harnesses
are deliberately **not** in git: they need multi-GB baked binaries (`otelcol-contrib.exe`,
`node.zip`, `otel-dotnet.zip`), host-installed `node_modules`, and live Coralogix keys, so
committing them would add files nobody could run. Their sections below are kept as the
build-and-run recipe for whoever recreates them locally — the `.gitignore` allowlist says
exactly which files are tracked.

> `Run-E2ELoop.ps1` is the only harness that exercises the **real** `deploy.bat` path
> rather than re-implementing it. It found three defects in shipped scripts that the
> offline diagnostics matrix could not — see
> [`iis-e2e-matrix.md`](../iis-e2e-matrix.md). Note the container cannot
> install a collector (Server Core .NET cannot fetch the MSI); those phases skip.

All require Docker Desktop in **Windows-container** mode and build from the **repo root**.

---

## IIS + Coralogix supervisor E2E — Service-ownership tags

End-to-end test that proves the deploy automation's **`CX_IIS_SERVICES`** env var populates the
Coralogix **Service ownership** tags through the real **OpAMP supervisor + IIS** path, with the
values **aligned to the per-app `OTEL_SERVICE_NAME`**.

## What it does

- Builds a Windows image (`servercore/iis`) containing the real `deploy/` automation + the base
  collector config (`deploy/config.supervisor.yaml`, which carries the
  `transform/iis_service_labels` processor).
- On start (`entrypoint.ps1`):
  1. Creates several distinctly-named IIS sites (`CX_TEST_SITES`, default `shop,wallet,blog`),
     each on its own dedicated pool → multiple service names.
  2. Assigns each app's `OTEL_SERVICE_NAME` and sets `CX_IIS_SERVICES` from **one**
     `Get-IISServiceMap` result (`Get-IISServiceLabelValue -Map $svcMap`) → the ownership set
     equals the per-app APM service names (alignment guarantee).
  3. Runs the Coralogix collector against the base config in **hybrid mode**: the local base
     config (`config.supervisor.yaml`, which carries the `transform/iis_service_labels`
     processor) is authoritative — exactly what the supervisor treats as effective when no Fleet
     remote config is assigned. The collector binary is **baked into the image**
     (`otelcol-contrib.exe`) and run directly, because the vendor supervisor installer's GitHub
     MSI download fails inside a minimal Server Core container (TLS/cert artifact — real hosts
     and the POC VM install the full supervisor fine).
- Validation (`Run-DockerWinTest.ps1`): waits for the container to configure + start, prints the
  name-alignment result, queries Coralogix host logs for the tags, and points you at
  Infrastructure Explorer for the final Service-ownership confirmation.

## Prerequisites

- **Docker Desktop in Windows-container mode** (Hyper-V isolation on Win11 clients).
  Enable + switch:
  ```powershell
  & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine
  ```
  > If this returns *"windows containers have been disabled for this installation"* (as on the
  > dev box used to author this), re-run the Docker Desktop installer / enable Windows containers
  > first, or use a Windows host/VM with them enabled. The base image is a multi-GB first pull.
- Coralogix **send key** at `SimpleWebApp/coralogix/SendDataKey.txt` and **query key** at
  `querydata_key.txt` (both gitignored).
- For the Node.js/PM2 variant, fetch on the host (all gitignored, baked into the image — the
  Server Core base cannot reliably run npm/HTTPS-download: an intermittent OpenSSL AES-GCM cipher
  fault, same class of reason the collector is baked):
  ```powershell
  $b = 'test/docker-win'
  # 1. Node.js runtime zip
  Invoke-WebRequest 'https://nodejs.org/dist/v20.11.0/node-v20.11.0-win-x64.zip' -OutFile "$b/node.zip" -UseBasicParsing
  # 2. node_modules (pm2, the sample app's pino, and the OTel Node package)
  npm install -g pm2 --prefix "$b/npm-global"
  npm install --prefix "$b/nodeapp" --omit=dev
  New-Item -ItemType Directory -Force "$b/otel-node" | Out-Null
  npm install --prefix "$b/otel-node" '@opentelemetry/auto-instrumentations-node' '@opentelemetry/api'
  ```

## Run

```powershell
# from the repo root (build context must be the repo root)
./test/docker-win/Run-DockerWinTest.ps1
# options: -Sites 'a,b,c'  -HostName cx-owner-test  -Application my-app
```

`-Application` is empty by default on purpose: the container then exercises the **hostname
fallback** for the Coralogix application name (`CX_APPLICATION` unset → `service.namespace` never
set → the exporter falls through to `host.name`). Pass it to test the override branch instead.

## Pass criteria

- Container log shows `[names] aligned: True` and `CX_IIS_SERVICES` = the site set.
- Container log shows `[appname] CX_APPLICATION unset -> expect Coralogix application = host.name`.
- Every signal from the container (host logs, IIS/Node logs, spans, host metrics) carries the
  container's `host.name` as its Coralogix **application** name, and nothing from this host still
  reports under `iis-instrumentation-test`. Gate:
  `scripts\Verify-CoralogixAppName.ps1 -ExpectedApplication cx-owner-test`.
  `host.name` comes from the default `hostname_sources: [dns, os]`, so it is whatever DNS returns
  for the container — here the short `cx-owner-test`, but earlier runs on this box recorded
  `cx-owner-test.lan`. On a domain-joined fleet host expect the FQDN. Pass
  `-ExpectedApplication <what host.name actually is>` if they differ.
- `opampsupervisor` reaches Running and connects to Coralogix OpAMP.
- Coralogix host logs / entity for the container host carry the 7 keys
  (`service`, `tags.{service,cx_svc,CX_SERVICE_NAME}`, `cx.infra.labels.{service,cx_svc,CX_SERVICE_NAME}`)
  as arrays.
- **Infrastructure Explorer → Hosts → `<hostname>` → Ownership → Service** lists one item per IIS
  app (`shop`, `wallet`, `blog`, `Default Web Site`) — server-side, ~15 min.

## Validation status — application-name fallback, PASSED

Ran 2026-07-27, both branches, `scripts\Verify-CoralogixAppName.ps1` → exit 0:

| Branch | Container | `CX_APPLICATION` | Coralogix application |
| --- | --- | --- | --- |
| Fallback | `cx-owner-test` | unset | `cx-owner-test` (= `host.name`) |
| Override | `cx-appname-override` | `cx-override-app` | `cx-override-app` |

- Proven per signal: logs (`$l.applicationname`), spans (`$l.applicationName`), metrics
  (`cx_application_name` label, 38 / 125 series), plus **exclusivity** — grouping each host's logs
  and spans by application yields exactly one value.
- A span from `cx-owner-test` carries `host.name: cx-owner-test` and **no `service.namespace` key
  at all** — the transform correctly did nothing, and the exporter fell through to `host.name`.
- Nothing from either host reports under the old `iis-instrumentation-test`.
- The `windows` host stream was empty for `cx-owner-test` in the window and populated (50 rows) for
  `cx-appname-override`; the Windows event channels are simply sparse in a Server Core container,
  which is why that row is informational in the gate.
- `Run-DoctorTest.ps1`: **27 passed, 0 failed** after the change.

## Validation status — Service ownership, PASSED

Ran here on 2026-07-23 (Windows containers enabled, Hyper-V isolation):

- `[names] aligned: True` — `CX_IIS_SERVICES = Default Web Site,shop,wallet,blog` == the set of
  per-app `OTEL_SERVICE_NAME`.
- Collector healthy (`:13133` = 200), exporting to Coralogix eu1: `sent_log_records{coralogix}`
  climbing + `{coralogix/resource_catalog}` (host entity), `send_failed` = 0.
- **Coralogix host logs (`host.name = cx-owner-test.lan`) carry all 7 keys as 4-element arrays**
  = `["Default Web Site","shop","wallet","blog"]` (`service`, `tags.{service,cx_svc,CX_SERVICE_NAME}`,
  `cx.infra.labels.{service,cx_svc,CX_SERVICE_NAME}`), confirmed by DataPrime query.
- Final Service-ownership (multi-item) resolves in Infrastructure Explorer server-side (~15 min).

Two container-only notes (not product issues; the `cx-fleet-test` VM ran the true supervisor path):
the vendor supervisor installer's GitHub MSI download fails in Server Core (so the collector is
baked in and run directly — hybrid base config), and the `resourcedetection/region` cloud detectors
time out (~13s) before the collector reaches ready.

---

## Node.js + PM2 (zero-code) variant

The same image now also installs **Node.js + PM2** and runs the sample app in
`test/docker-win/nodeapp/` under both PM2 exec modes (gated by `CX_TEST_NODE=1`, default on):

- `nodeapp-fork` — fork mode, port 9081.
- `nodeapp-cluster` — cluster mode, 2 workers, port 9082 (shared listen socket).

On start, `entrypoint.ps1` runs `pm2 start ecosystem.config.js`, then the real
`deploy/Instrument-NodePM2.ps1` (npm-installs `@opentelemetry/auto-instrumentations-node`, sets
per-app `NODE_OPTIONS`/`OTEL_*` via `pm2 restart --update-env`, `pm2 save`), then generates HTTP
load against both ports in the keep-alive loop. See
[`docs/nodejs-pm2.md`](../../docs/nodejs-pm2.md).

Pass criteria (confirm in Coralogix via DataPrime, not the UI):
- Container log `[node] pm2_pids=...` shows 3 PIDs (1 fork + 2 cluster workers) and
  `CX_NODE_SERVICES=nodeapp-cluster,nodeapp-fork`; `[export] sent_spans` / `sent_metric_points` climb.
- `scripts\Verify-CoralogixNodeSpans.ps1` → **PASS**: each service has spans > 0 and logs > 0, and
  `nodeapp-cluster` shows **≥ 2 distinct `process.pid`** (per-worker telemetry under one service name).

### Not covered here: iisnode

**No container variant covers iisnode** (Node hosted *by* IIS, `node.exe` as a child of `w3wp`).
The image has IIS and it has Node, but not the iisnode module, so nothing in this harness exercises
the pool-environment write path in `Instrument-IIS.ps1` or
`misc\Enable-IisnodeInstrumentation.ps1`. Stated rather than left implied: a green E2E run here says
nothing about iisnode.

What does gate it today:

- `test\Test-IisnodeInstrumentation.ps1` — fixture-only, ~1s, no IIS. Covers classification
  (including that a hybrid app keeps its .NET verdict), ESM detection, the `NODE_OPTIONS`
  merge/strip round trip, and drift between the patch script's standalone fallbacks and the deploy
  libraries.
- A real host. The pool identity ACL grant, the recycle, and whether the ESM loader hook still
  works on the host's Node major are only provable there — verify by DataPrime query, not the UI.

Adding iisnode to the image (an MSI install plus a site whose `web.config` wires the handler) would
close the gap and is the obvious next step for this harness.

---

## RabbitMQ variant

`Dockerfile.rabbitmq` + `entrypoint.rabbitmq.ps1` + `Run-RabbitmqTest.ps1` are a sibling E2E for the
RabbitMQ monitoring fragment (`deploy/templates/rabbitmq.yaml`). Self-contained: the image installs
RabbitMQ (Erlang + management plugin) via Chocolatey, the entrypoint starts the node, enables the
management plugin, publishes a few messages, then runs the collector against `rabbitmq.yaml` so the
`rabbitmq` receiver scrapes `localhost:15672` and `filelog/rabbitmq` tails the RabbitMQ log dir.

```powershell
# from the repo root
./test/docker-win/Run-RabbitmqTest.ps1
```

Pass criteria:
- Container log `[rabbit] management API up: True` and `[rabbit-recv]` shows
  `otelcol_receiver_accepted_metric_points{...receiver="rabbitmq"...} > 0` (scraped + accepted).
- `[export] send_failed = 0`, `sent_metrics`/`sent_logs` climbing.
- **LOGS**: DataPrime host-log query returns rows carrying `messaging.system=rabbitmq` / `rabbit@` lines.
- **METRICS**: PromQL `rabbitmq_node_mem_used` returns a non-empty series.

Teardown: `docker rm -f cx-rabbitmq-test`.

---

## Diagnostics harness (offline, self-asserting)

`Dockerfile.doctor` + `entrypoint.doctor.ps1` + `break-state.ps1` + `Run-DoctorTest.ps1`.

Unlike the E2E harnesses above — which ship telemetry to Coralogix and leave the verdict to a
human — this is a **self-contained asserting test**. Every case has an expected finding code
and an expected exit code, and the run fails (exit 1) on any mismatch. **No Coralogix keys, no
network, no collector.**

The image is a lightweight `servercore/iis` (no Node, no collector binary), so it rebuilds in
seconds — `COPY deploy/` sits above the expensive Node layers in the main `Dockerfile`, so
editing a deploy script there invalidates all of them. Container processes run as
`ContainerAdministrator`, which satisfies the doctor's elevation gate without an interactive
UAC prompt. Collector-dependent checks are **expected** to FAIL/WARN — exercising those
branches is the point.

```powershell
# from the repo root
./test/docker-win/Run-DoctorTest.ps1
# options: -SkipBuild  -KeepContainer  -Image cx-doctor-test  -Container cx-doctor
```

27 assertions in six groups:

- **A. baseline** — missing collector → exit 1; `Default Web Site` pool resolved via
  `<sites><applicationDefaults>`; `web.config` readback on a shared pool; no PM2 → `NO_PM2`
  (a skip, not a failure).
- **B. argument handling** — `-Only` comma form (what `doctor.bat` forwards), space form
  *rejected* rather than silently mis-bound, case-insensitivity, bad name failing loudly.
- **C. standalone/aggregator parity** — `Test-IISInstrumentation.ps1` run directly emits the
  same finding codes as the same check run through `Test-Agent.ps1`. This is what proves the
  two entry points share one implementation instead of drifting.
- **D. broken states** — `CX_IIS_SERVICES_MISSING`, `CX_IIS_SERVICES_DRIFT`,
  `POOL_NOT_NO_MANAGED_CODE`, `POOL_ENV_STALE`, `PROFILER_REGISTRY_MALFORMED` (hard fail,
  exit 1), `PROFILER_PATH_MISSING`.
- **E. WOW64 (32-bit host process)** — the validators run through
  `SysWOW64\WindowsPowerShell\v1.0\powershell.exe`, and `doctor.bat` is driven from
  `SysWOW64\cmd.exe`. Asserts `Get-CxInetsrvDir` returns `Sysnative` under WOW64 and
  `System32` otherwise, that a 32-bit run reads `applicationHost.config` instead of
  reporting `APPHOST_UNREADABLE`, and — by forcing the redirected path explicitly — that
  the underlying failure is still reproducible, so the group cannot pass vacuously.
  Skipped with a notice if the image has no 32-bit PowerShell.
- **F. read-only invariant** — SHA-256 of `applicationHost.config` plus the whole machine
  environment, taken before and after a full run, must be identical; `-NoFileOutput` leaves
  no `agent-doctor.json`; the default run writes one that parses. The `-NoFileOutput` case
  clears any report an earlier group left behind first — `doctor.bat` in group E writes one
  by default, and without the reset this would assert the run's history rather than the switch.

Mutations live in `break-state.ps1` (`-Case clearIisServices|poolEnvStale|profilerMalformed|…`)
and are **destructive by design** — only ever safe because the container is disposable. Keeping
them in a baked script rather than inline `docker exec … -Command "…"` strings avoids escaping
appcmd's collection syntax through two shells.

Teardown is automatic; `-KeepContainer` leaves `cx-doctor` up for manual poking:

```powershell
docker exec cx-doctor powershell -File C:\cx\break-state.ps1 -Case inspect
docker exec cx-doctor powershell -File C:\cx\deploy\Test-Agent.ps1 -Only iisInstrumentation
```

See [`docs/reference/exit-codes.md`](../../docs/reference/exit-codes.md) for every finding code.
