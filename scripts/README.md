# scripts/

Single-host and testing helpers. The scripted **fleet** path lives in
[`deploy/`](../deploy); these scripts target one box, exercise the sample app, or query
Coralogix from an operator workstation.

## Host-side (run on the target machine)

| Script | What it does |
| --- | --- |
| `deploy-app.ps1` | Build, deploy, and zero-code OTEL-instrument `SimpleWebApp` on IIS in one elevated pass. `-InstrumentAllApps` enumerates every IIS site/app (via [`deploy/Resolve-IISServiceNames.ps1`](../deploy/Resolve-IISServiceNames.ps1)) and assigns a distinct `OTEL_SERVICE_NAME`; `-Environment <name>` stamps environment tags. Windows PowerShell **5.1**, elevated. |
| `generate-load.ps1` | Send steady HTTP traffic (`/`, `/health`, `/db`) to the deployed app so HTTP + DB spans flow. |

Both assume a Coralogix OTel collector listening on `127.0.0.1:4318`. Install the
collector via the single-host runbook in
[`docs/iis-instrumentation.md`](../docs/iis-instrumentation.md).

## Operator-side (run from your workstation, against the Coralogix API)

All read a **query** key (not the send key) from `querydata_key.txt` at the repo root
(gitignored) and are server-side gates — they prove data actually landed.

| Script | What it does |
| --- | --- |
| `Verify-CoralogixInfraLabels.ps1` | DataPrime query proving the 7 Service-ownership keys reached ingestion on this host's infra/entity telemetry. Mostly a **report** — which keys landed is printed, not asserted. It becomes a **gate** when `-MustNotContain` is given: exits **1** if any named service appears on this host's labels, which is how the E2E loop proves a static site or reverse proxy was never claimed as a Service. `-HostName` scopes every query to one host, without which a shared account happily answers from some other machine's telemetry. |
| `Verify-CoralogixNodeSpans.ps1` | DataPrime gate for the Node/PM2 path: passes when each PM2 service has spans, and the cluster app shows ≥ 2 distinct workers. Exits **1** on failure. |
| `Verify-Pm2Coverage.ps1` | Coverage gate for a host you have **no access to**. Derives the expected PM2 app list from the pm2 exporter's own `pm2_up` series (PromQL), the observed set from span `process.serviceName` + `telemetry.sdk.language` (DataPrime), and prints per-app PASS/GAP. Exits **1** on any gap, **2** when the expected set could not be established. Use after a staged `Instrument-NodePM2.ps1 -Apps <app>` rollout. |
| `Verify-CoralogixAppName.ps1` | Gate for the application-name fallback: host logs, app logs, spans **and** metrics from a host must all carry that host's own name as the Coralogix application, with zero rows left under the legacy name. Exits **1** on failure. Spans/logs via DataPrime, metrics via PromQL (`https://api.<domain>/metrics/api/v1/query`). |

## Diagnosing a host — look in `deploy/`, not here

Nothing in `scripts/` ships to customers. The **read-only host diagnostics** are part of
the deployment package and run on the target machine:

| Script | |
| --- | --- |
| [`deploy/Test-Agent.ps1`](../deploy/Test-Agent.ps1) (`doctor.bat`) | Nine checks — env vars, per-app `OTEL_SERVICE_NAME` readback, services, health, export counters, OTLP ports, effective-config processor, plus both instrumentation validators. Graded exit `0`/`1`/`2`. |
| [`deploy/Test-IISInstrumentation.ps1`](../deploy/Test-IISInstrumentation.ps1) | Did the IIS instrumentation actually land — CLR profiler, profiler DLL, pool OTLP env, and each app's **runtime classification** (ASP.NET Core / Framework / non-.NET / undeterminable) checked against its pool's CLR setting. "No Managed Code" is right for Core and wrong for Framework, so the app is classified before the pairing is judged. |
| [`deploy/Test-NodeInstrumentation.ps1`](../deploy/Test-NodeInstrumentation.ps1) | Same for Node/PM2 — `NODE_OPTIONS`, register bootstrap, per-app service names. |

Order of operations when something is wrong: run the **host** diagnostic first (it
separates "misconfigured on the box" from "configured fine, not arriving"), then confirm
server-side with the `Verify-Coralogix*.ps1` scripts above. Full finding reference:
[`docs/agent-diagnostics.md`](../docs/agent-diagnostics.md).
