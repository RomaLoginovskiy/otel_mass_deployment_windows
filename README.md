# IIS Instrumentation → Coralogix

Tooling and runbooks for shipping **Windows / IIS / .NET** telemetry to
[Coralogix](https://coralogix.com) via the OpenTelemetry Collector — from a
single host up to a scripted fleet rollout.

The collector runs as a Windows service (or under the OpAMP Supervisor for
remote config), scrapes host + IIS + .NET metrics, tails Windows event and IIS
logs, and receives OTLP traces from apps that are **zero-code auto-instrumented**
on the box. Span metrics (RED) are generated on the agent so Coralogix APM,
Infrastructure Explorer, and Database Monitoring light up.

```mermaid
flowchart LR
  A["IIS .NET app (auto-instrumented)"] -->|OTLP localhost:4318| C["OTel Collector (Windows service)"]
  H["Host + IIS metrics, Event Log, IIS logs"] --> C
  C -->|OTLP over HTTPS| X["Coralogix"]
```

## Repository layout

| Path | What it is |
| --- | --- |
| `docs/iis-instrumentation.md` | **Start here.** Single-host runbook: install the collector, zero-code .NET/IIS instrumentation, shared app-pool config, troubleshooting, full reference `config.yaml`. |
| `docs/fleet-deployment.md` | Fleet-scale runbook: build a package, push with BatchPatch, Supervisor mode, workload detection → selector attributes, Fleet Management. |
| `deploy/` | The deployment package payload (see below). |
| `Build-DeploymentPackage.ps1` | Zips `deploy/` into `coralogix-agent-deploy.zip`. |
| `poc/` | VirtualBox harness to validate the package on a throwaway Windows Server 2025 VM before fleet rollout. |
| `SimpleWebApp/` | A minimal ASP.NET Core 8 app (with a SQL Server call) used as an instrumentation target for testing. |
| `misc/` | One-off / earlier scripts (single-host install, config fixes, load generation). |
| `batchpatch.zip` | The BatchPatch tool itself — **not** the deploy package. |

## Two paths

### Single host (manual)

Follow [`docs/iis-instrumentation.md`](docs/iis-instrumentation.md). In short:

1. Install the Coralogix OTel Collector as a Windows service with the reference
   `config.yaml`.
2. Install the OpenTelemetry .NET auto-instrumentation (Windows PowerShell **5.1**,
   elevated): `Import-Module` → `Install-OpenTelemetryCore` → `Register-OpenTelemetryForIIS`.
3. Point apps at the local collector (`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`).
   `Instrument-IIS.ps1` (or `deploy-app.ps1 -InstrumentAllApps`) auto-discovers every IIS
   site/app and sets a distinct `OTEL_SERVICE_NAME` per app from the site name + app path
   (root app → site name; nested `/api` → `Site/api`).
4. ASP.NET **Core** pools must be **"No Managed Code"** or they emit nothing.

### Fleet (scripted)

Follow [`docs/fleet-deployment.md`](docs/fleet-deployment.md).

```powershell
# 1. Build the package (from repo root)
.\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx-send-your-data.key
#    -> coralogix-agent-deploy.zip

# 2. Push with BatchPatch to a 2-3 host pilot, then the full fleet.
#    Each host runs deploy.bat -> Install-Agent.ps1:
#      detect workloads -> install collector (Supervisor mode) -> conditional IIS -> verify

# 3. Assign remote config in Coralogix Fleet Management, targeting agents by
#    the cx.host.role / workload.* selector attributes detection published.
```

## The `deploy/` package

| File | Role |
| --- | --- |
| `deploy.bat` | BatchPatch entry point; launches the orchestrator under PowerShell 5.1. |
| `Install-Agent.ps1` | Orchestrator: detect → install supervisor → conditional IIS → verify. |
| `Detect-Workloads.ps1` | Detects IIS, .NET, Node, Redis, Valkey, SQL Server, DB2, RabbitMQ, Elasticsearch → `OTEL_RESOURCE_ATTRIBUTES`. |
| `Install-CoralogixSupervisor.ps1` | Collector install with `-Supervisor`; injects selector attributes into the OpAMP AgentDescription. |
| `Instrument-IIS.ps1` | Zero-code .NET auto-instrumentation, IIS hosts only. |
| `config.supervisor.yaml` | Base config = reference `config.yaml` **minus the `opamp` extension** (the Supervisor owns that connection). |
| `SendDataKey.txt` | Send-Your-Data key (baked in via `-KeyFile`, or supplied at deploy time). |

## POC (VirtualBox)

`poc/Run-TestVM.ps1` spins up a disposable Windows Server 2025 VM to validate the
package end-to-end before touching real servers. Preferred flow is fully scripted:

```powershell
cd poc
.\Run-TestVM.ps1 -Action Unattended            # auto Windows install + Guest Additions (~20-40 min)
.\Run-TestVM.ps1 -Action Snapshot -SnapshotName baseline
.\Run-TestVM.ps1 -Action Configure             # enable IIS + WinRM/firewall in guest
..\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx.key
.\Run-TestVM.ps1 -Action Deploy                # copy + expand + run deploy.bat
```

Validated end-to-end on Windows Server 2025 (2026-07-14 and 2026-07-15): supervisor
registered with Fleet Management, collector healthy, selector attributes published,
IIS zero-code instrumentation configured.

> **VM-only gotcha:** VirtualBox exposes no SMBIOS Type 4, so `resourcedetection`
> `host.cpu.*` attributes crash-loop the collector. The base config drops them; a
> Fleet-Management remote config that re-adds them re-triggers it on SMBIOS-less
> hosts. Real fleet hardware is unaffected. See `docs/fleet-deployment.md`.

## Prerequisites

- Windows 10/11 or Windows Server 2016+, Administrator access.
- **Windows PowerShell 5.1** (the .NET auto-instrumentation module requires 5.1, not 7).
- A Coralogix **Send-Your-Data API key** and your Coralogix **domain** (e.g. `eu1.coralogix.com`).
- IIS role installed if using the IIS receivers.

> **Security:** never commit the Send-Your-Data key. The collector reads it from
> the `CORALOGIX_PRIVATE_KEY` environment variable; keyed deploy zips are secrets.
