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
   | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` |
   | `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` |
   | `OTEL_SERVICE_NAME` | the PM2 app name (override-able) |
   | `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` | `otlp` |

3. `pm2 save` — persists the resolved env into the PM2 dump so it survives daemon restart / `pm2 resurrect`.
4. Machine env `CX_NODE_SERVICES` = comma-joined distinct service names (Node analog of
   `CX_IIS_SERVICES`) for host Service-ownership labels.

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

## Notes / caveats
- Run the instrument script in the **same user context** that owns the PM2 daemon (PM2 is per-user
  on Windows).
- Requires npm registry access at deploy time (online), unless the package is pre-staged in
  `InstallPrefix` and `-SkipInstall` is passed.
- The sample app uses `pino` so the **logs** pipeline is exercised (auto-instrumentations-node
  bridges pino/winston/bunyan output to OTLP logs; plain `console.log` is not bridged).
