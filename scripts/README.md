# scripts/

Single-host and testing helpers. The scripted **fleet** path lives in
[`deploy/`](../deploy); these scripts target one box or exercise the sample app.

| Script | What it does |
| --- | --- |
| `deploy-app.ps1` | Build, deploy, and zero-code OTEL-instrument `SimpleWebApp` on IIS in one elevated pass. `-InstrumentAllApps` enumerates every IIS site/app (via [`deploy/Resolve-IISServiceNames.ps1`](../deploy/Resolve-IISServiceNames.ps1)) and assigns a distinct `OTEL_SERVICE_NAME`; `-Environment <name>` stamps environment tags. Windows PowerShell **5.1**, elevated. |
| `generate-load.ps1` | Send steady HTTP traffic (`/`, `/health`, `/db`) to the deployed app so HTTP + DB spans flow. |

Both assume a Coralogix OTel collector listening on `127.0.0.1:4318`. Install the
collector via the single-host runbook in
[`docs/iis-instrumentation.md`](../docs/iis-instrumentation.md).
