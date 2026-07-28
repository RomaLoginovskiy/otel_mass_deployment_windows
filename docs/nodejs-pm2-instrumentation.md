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

## Troubleshooting

| Symptom | Finding | Cause / fix |
| --- | --- | --- |
| No spans from any PM2 app | `NODE_OPTIONS_MISSING` | The instrument script never ran for this app, or a plain `pm2 restart` without `--update-env` dropped the env and no `pm2 save` followed. |
| Spans stopped after a redeploy or npm cleanup | `NODE_REGISTER_PATH_STALE` | `NODE_OPTIONS` points at a `register.js` that no longer exists. Node starts fine and emits nothing. Re-run the instrument script. |
| Package never staged | `NODE_PACKAGE_MISSING` | `@opentelemetry/auto-instrumentations-node` is not under `-InstallPrefix` (default `C:\cx\otel-node`) — the npm install failed at deploy time (offline host). |
| Doctor reports no apps on a host you know runs apps | `NODE_PM2_DAEMON_NOT_VISIBLE` / `NO_PM2_APPS` | PM2 is **per-user** on Windows; the daemon belongs to another account, so `pm2 jlist` is empty for the caller. Reported as `unknown`, never a failure — re-run as the owning account. |
| `pm2` not found | `NODE_PM2_NOT_ON_PATH` | PM2 installed for a different user, or not on the machine PATH. |
| Service name wrong or missing in Coralogix | `NODE_SERVICE_NAME_MISSING` / `NODE_SERVICE_NAME_DRIFT` | `OTEL_SERVICE_NAME` no longer matches the app set (renamed app, or an override the doctor was not told about). |
| Everything reports configured, still no data | `OTLP_ENDPOINT_LOCALHOST` | `localhost` → `::1`, export silently dropped. Use `http://127.0.0.1:4318`. |
| APM fine, but host Service ownership blank | `NODE_SERVICES_NOT_CONSUMED` (info) | Expected — no collector processor reads `CX_NODE_SERVICES`. See **Mechanism** step 4. |

## Notes / caveats
- Run the instrument script in the **same user context** that owns the PM2 daemon (PM2 is per-user
  on Windows).
- Requires npm registry access at deploy time (online), unless the package is pre-staged in
  `InstallPrefix` and `-SkipInstall` is passed.
- The sample app uses `pino` so the **logs** pipeline is exercised (auto-instrumentations-node
  bridges pino/winston/bunyan output to OTLP logs; plain `console.log` is not bridged).
