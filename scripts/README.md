# scripts/

Single-host and operator-side helpers. The scripted **fleet** path lives in
[`deploy/`](../deploy); these scripts either drive one box directly or query Coralogix from an
operator workstation.

Full argument tables for everything here: [`docs/reference/cli.md`](../docs/reference/cli.md).

## Host-side — run on the target machine

Windows PowerShell **5.1**, elevated. Both assume a collector listening on `127.0.0.1:4318`;
install it with [`docs/single-host.md`](../docs/single-host.md).

| Script | What it does |
| --- | --- |
| `deploy-app.ps1` | Builds, deploys and zero-code instruments the repository's sample ASP.NET Core app on IIS in one pass. `-InstrumentAllApps` enumerates every IIS site and application via [`deploy/Resolve-IISServiceNames.ps1`](../deploy/Resolve-IISServiceNames.ps1) and assigns a distinct `OTEL_SERVICE_NAME`; `-Environment <name>` stamps the environment tags. |
| `generate-load.ps1` | Sends steady HTTP traffic to the deployed app so HTTP and database spans flow. `-Port`, `-Paths`, `-DelayMs`, `-DurationMinutes`, `-StatsEverySec`. |

## Operator-side — run from your workstation

These query the Coralogix API to prove data actually landed. They need a **query** key, not the
Send-Your-Data key: pass `-QueryKeyFile <path>` and, when the file holds several labelled keys,
`-KeyLabel <label>`.

| Script | What it answers | Exit codes |
| --- | --- | --- |
| `Verify-CoralogixServiceTelemetry.ps1` | Which service names are reporting from one host, and which are correctly reporting nothing. `-Services` for what must report, `-MustBeSilent` for what must not, `-RequireLogs` to demand logs as well as spans. | `0` every expectation held |
| `Verify-CoralogixInfraLabels.ps1` | Which Service-ownership keys reached ingestion on this host's infrastructure and entity telemetry. A report by default — the keys that landed are printed, not asserted. `-MustNotContain` turns it into a gate. `-HostName` scopes every query to one host; without it a shared account will happily answer from another machine's telemetry. | `1` if a `-MustNotContain` name appears |
| `Verify-CoralogixNodeSpans.ps1` | Whether each PM2-managed Node service reports spans, and whether a cluster app reports from more than one worker. | `1` on failure |
| `Verify-Pm2Coverage.ps1` | Coverage for a host you have **no access to**: expected app list from the pm2 exporter's own `pm2_up` series (PromQL), observed set from span service names (DataPrime), printed per app. | `1` on any gap, `2` if the expected set could not be established |
| `Verify-CoralogixAppName.ps1` | Whether host logs, app logs, spans **and** metrics from a host all carry the intended Coralogix application name. Spans and logs via DataPrime, metrics via PromQL. | `1` on failure |
| `CxQuery.Common.ps1` | Dot-sourced library behind the rest: `Get-CxQueryKey` (returns an object — pass `.Token`) and `Invoke-CxDataPrime`, which **raises** on a non-200 so an authorisation failure can never be mistaken for an absence of data. | — |

Region matters: the bare `ng-api-http.coralogix.com` host is the **US** cluster and answers 403 for
an EU account. Pass `-Region` (or a full `-ApiUrl`) that matches the account.

## Diagnosing a host — look in `deploy/`, not here

Nothing in `scripts/` ships to a customer host. The read-only diagnostics are part of the
deployment package and run on the target machine:

| Script | Checks |
| --- | --- |
| [`deploy/Test-Agent.ps1`](../deploy/Test-Agent.ps1), via `doctor.bat` | Environment variables, per-app `OTEL_SERVICE_NAME` readback, services, health, export counters, OTLP ports, the effective-config processors, plus both instrumentation validators. Graded exit `0`/`1`/`2`. |
| [`deploy/Test-IISInstrumentation.ps1`](../deploy/Test-IISInstrumentation.ps1) | Whether the IIS instrumentation landed: CLR profiler, profiler DLL, pool OTLP variables, and each application's runtime classification judged against its pool's CLR setting. |
| [`deploy/Test-NodeInstrumentation.ps1`](../deploy/Test-NodeInstrumentation.ps1) | The same for Node and PM2: `NODE_OPTIONS`, the register bootstrap, per-app service names. |

Order of operations when something is wrong: run the **host** diagnostic first — it separates
"misconfigured on the box" from "configured fine, not arriving" — then confirm server-side with the
`Verify-Coralogix*.ps1` scripts above. Full finding reference:
[`docs/reference/exit-codes.md`](../docs/reference/exit-codes.md).
