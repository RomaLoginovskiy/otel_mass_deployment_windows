# OTel Collector + zero-code .NET instrumentation on Windows/IIS

Install the OpenTelemetry (OTel) Collector as a Windows service and wire up zero-code
instrumentation for .NET apps on IIS so they report to Coralogix. Single-host runbook;
for the scripted fleet path see [`fleet-deployment.md`](./fleet-deployment.md).

## Overview

There are two moving parts, and both are needed before Coralogix shows APM data.

First, the **OTel Collector** runs as a Windows service on each host. It receives telemetry over OTLP from your apps, scrapes host and IIS metrics on its own, and ships everything to Coralogix. Part 2 covers the config that drives it.

Second, the **application instrumentation** is what makes each app emit traces. Apps fall into two groups. Some teams already added the OpenTelemetry SDK to their code, so they emit OTLP directly and only need the collector running. Other teams have no SDK in their code, so they need zero-code (also called no-code) auto-instrumentation, which is installed separately on the box. Part 3 covers the second case for .NET on IIS.

Data flow:

```mermaid
flowchart LR
  A["IIS .NET app (auto-instrumented)"] -->|OTLP localhost:4318| C["OTel Collector (Windows service)"]
  H["Host + IIS metrics, Event Log, IIS logs"] --> C
  C -->|OTLP over HTTPS| X["Coralogix"]
```

This guide targets bare Windows hosts running .NET on IIS. It does not use Kubernetes. Node.js front ends and standalone Windows services are noted as separate variations near the end.

---

## Prerequisites

- Windows 10/11 or Windows Server 2016 or later, with Administrator access.
- PowerShell 5.1 or later. The .NET auto-instrumentation module requires Windows PowerShell 5.1 specifically, not PowerShell 7.
- A Coralogix Send-Your-Data API key (Data Flow > API Keys in the Coralogix UI).
- Your Coralogix domain, for example `eu1.coralogix.com` or `eu2.coralogix.com`.
- The Web Server (IIS) role installed if you plan to use the IIS receivers in the config.

---

## Part 1: Install the OTel Collector on Windows

### 1. Prepare the config file

The installer requires a config file. Start from
[`SimpleWebApp/coralogix/config.yaml`](../SimpleWebApp/coralogix/config.yaml) and save it on
the machine, for example `C:\otel\config.yaml`.

Before installing, update these values for your environment:

- `domain`: your Coralogix region domain. The shipped file uses `eu1.coralogix.com` in
  **three** places — both `coralogix` exporters and the `opamp` endpoint.
- `resource/service` → `service.namespace`: your application grouping. The shipped file
  uses `iis-instrumentation-test`.
- `private_key` is read from the `CORALOGIX_PRIVATE_KEY` environment variable, which the
  installer sets for you. Do not paste the key into the file.

[`SimpleWebApp/coralogix/INSTALL.md`](../SimpleWebApp/coralogix/INSTALL.md) documents every
value to change, with a click-through install for operators who prefer not to use the CLI.

### 2. Run the installer

Run this in an elevated PowerShell (Run as Administrator), as a single line. Replace the key and the config path.

```powershell
$u='https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'; $f="$env:TEMP\coralogix-otel-collector.ps1"; Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing; $env:CORALOGIX_PRIVATE_KEY='<your-private-key>'; & $f -Config 'C:\otel\config.yaml'
```

The key must be inside single quotes with the closing quote before the semicolon. On Windows Server 2016 or older, prepend `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;`  so the GitHub download succeeds.

The installer places the collector here:

| Component | Location |
| --- | --- |
| Binary | `C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe` |
| Config | `C:\ProgramData\OpenTelemetry\Collector\config.yaml` |
| Service | `otelcol-contrib` (Windows service) |
| Logs | Windows Event Log (Application), source `otelcol-contrib` |

### 3. Verify it is running

```powershell
# Service status
Get-Service otelcol-contrib

# Validate the config
& "C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe" validate --config "C:\ProgramData\OpenTelemetry\Collector\config.yaml"

# Recent errors if it did not start
Get-EventLog -LogName Application -Source otelcol-contrib -Newest 20
```

The config exposes a health check on `127.0.0.1:13133` and internal collector metrics on `127.0.0.1:8888`, which you can use to confirm the collector is healthy.

### 4. Useful install variants

```powershell
# Listen on all interfaces so other hosts can send to this one (gateway mode).
# Requires your config to reference ${env:OTEL_LISTEN_INTERFACE}.
& $f -ListenInterface 0.0.0.0

# Raise the memory limit (config must reference ${env:OTEL_MEMORY_LIMIT_MIB}).
& $f -MemoryLimit 2048

# Enable header-based parsing for IIS logs. Also required if your config uses the
# file_storage extension, otherwise the service fails to start.
& $f -EnableDynamicIISParsing

# Pin a specific version
& $f -Version 0.144.0
```

> ⚠️ The shipped config listens on `127.0.0.1` only, which is correct when the instrumented apps run on the same host. If apps run on other machines, install that collector as a gateway with `-ListenInterface 0.0.0.0`.

### 5. Service management

```powershell
Restart-Service otelcol-contrib
Stop-Service otelcol-contrib
Start-Service otelcol-contrib
```

---

## Part 2: What the collector config collects

The repo ships two collector configs. They are **not** interchangeable:

| Config | Deployment mode | `opamp` extension |
| --- | --- | --- |
| [`SimpleWebApp/coralogix/config.yaml`](../SimpleWebApp/coralogix/config.yaml) | Standalone Windows service (Part 1 of this guide) | Present — the collector holds the OpAMP connection itself |
| [`deploy/config.supervisor.yaml`](../deploy/config.supervisor.yaml) | Under the OpAMP Supervisor (fleet, see [`fleet-deployment.md`](./fleet-deployment.md)) | Absent — the Supervisor owns that connection |

Adding an `opamp` extension to the Supervisor base config makes the collector fail to
start. For a click-through install of the standalone config, see
[`SimpleWebApp/coralogix/INSTALL.md`](../SimpleWebApp/coralogix/INSTALL.md).

Either config is a single per-host agent: it collects local signals, receives app
telemetry over OTLP, and ships to Coralogix.

| Component | What you get in Coralogix |
| --- | --- |
| `otlp` receiver — `:4317` gRPC, `:4318` HTTP, bound to `${env:OTEL_LISTEN_INTERFACE:-127.0.0.1}` | Entry point for app traces, metrics, and logs |
| `spanmetrics` connector (+ `/compact`, `/db`, `/db_compact`) | APM Service Catalog, RED metrics, latency / error / Apdex, Dependencies and Database Monitoring |
| `hostmetrics` — cpu, memory, disk, filesystem, network, paging, process; 10s | Infrastructure Explorer host dashboards, including the Process tab |
| `iis` receiver | IIS request and connection metrics |
| `windowseventlog/application`, `/security`, `/system` | Windows event logs |
| `filelog/iis` | IIS W3C access logs, with `#Fields:` header parsing |
| `prometheus` — scrapes the collector's own `:8888` | Collector self-monitoring |
| `resourcedetection/entity`, `/env`, `/region` | Host-entity correlation; `/env` promotes `OTEL_RESOURCE_ATTRIBUTES` into Fleet Management selector attributes |
| `resource/environment` | Per-environment split, from `CX_ENVIRONMENT` |
| `transform/iis_service_labels` | IIS Service ownership — see [`iis-service-ownership.md`](./iis-service-ownership.md) |
| `coralogix` + `coralogix/resource_catalog` exporters | Telemetry ingest, and the Infrastructure Explorer host entity |

### Span metrics drive APM

The `spanmetrics` connector generates RED metrics (Request rate, Error rate, Duration)
from every span. It runs on the agent, so it sees 100% of spans before any downstream
sampling. Its dimensions unlock specific features: `service.version` enables
group-by-version, `http.response.status_code` and `rpc.grpc.status_code` enable error
tracking, and `db.system` / `db.namespace` / `db.operation.name` enable Dependencies and
Database Monitoring.

> Version floors: `aggregation_cardinality_limit` on span metrics needs collector
> v0.130.0 or later; the Prometheus pull reader used for internal telemetry needs v0.123
> or later.

### Host correlation

`resourcedetection` adds `host.name` to every signal, including app spans arriving over
OTLP. Matching `host.name` on both spans and host metrics is what lets Coralogix tie a
service to the host it runs on, and it gives each host's span metrics a distinct resource
so multi-host aggregation adds up instead of overwriting.

Neither config inserts a hard-coded `service.name` — on a multi-app host that would stamp
one app's name onto every shared signal. Per-app `service.name` arrives from each app's
`OTEL_SERVICE_NAME` (Part 3); signals without one fall back to the exporter's
`subsystem_name`.

> ⚠️ **`host.cpu.*` and SMBIOS.** `SimpleWebApp/coralogix/config.yaml` enables six
> `host.cpu.*` resource attributes. Reading them requires SMBIOS Type 4, which VirtualBox
> and some cloud VMs do not expose; on collector v0.155.0 the mere presence of a
> `host.cpu.*` key initialises the SMBIOS reader and crash-loops the collector
> (`failed getting host cpuinfo: SMBIOS processor information not found`).
> `deploy/config.supervisor.yaml` omits them for that reason. Real hardware is unaffected.

---

## Part 3: Instrument .NET apps on IIS (zero-code)

Use this when the app team has not added the OpenTelemetry SDK to their code. If the app already emits OTLP from its own SDK, skip this part and just make sure it points at the collector on `localhost:4317` or `4318`.

### 1. Install the auto-instrumentation module

Run in an elevated Windows PowerShell 5.1 session. This downloads the module, installs the core files, and registers IIS.

```powershell
# Set to the current release tag from the releases page, e.g. v1.16.0-beta.1
$version = "v1.16.0-beta.1"
$module_url = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$version/OpenTelemetry.DotNet.Auto.psm1"
$download_path = Join-Path $env:temp "OpenTelemetry.DotNet.Auto.psm1"
Invoke-WebRequest -Uri $module_url -OutFile $download_path -UseBasicParsing

# Import, install core files, and register IIS
Import-Module $download_path
Install-OpenTelemetryCore
Register-OpenTelemetryForIIS
```

`Register-OpenTelemetryForIIS` restarts IIS by default. Use `-NoReset` to skip the restart and recycle later.


### 2. ASP.NET Core app pools need "No Managed Code"

For ASP.NET Core apps hosted in IIS, set the application pool's .NET CLR Version to "No Managed Code". If this is wrong, no telemetry is generated at all. .NET Framework apps do not need this.

### 3. Point the apps at the collector and set a service name

The apps need a few environment variables. The most important are the OTLP endpoint (the local collector) and a unique service name per app.

| Variable | Value | Purpose |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Send to the local collector |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | Match the HTTP endpoint |
| `OTEL_SERVICE_NAME` | unique per app | Names the service in APM |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment=production,service.version=1.0.0` | Extra APM dimensions |

> **Environment label.** To split telemetry by environment in Coralogix (Infra
> Explorer / APM), set `CX_ENVIRONMENT` on the host. `deploy-app.ps1 -Environment
> <staging|production|...>` sets the machine var and appends `tags.cx_environment`,
> `tags.cx_env`, and `deployment.environment.name` to the app pool's
> `OTEL_RESOURCE_ATTRIBUTES`; the collector's `resource/environment` processor (in
> `SimpleWebApp\coralogix\config.yaml`) stamps the same three keys onto host/infra
> signals from `${env:CX_ENVIRONMENT:-unspecified}`. Restart the collector after
> setting the machine var so host signals pick it up.

> **Service label on infrastructure data.** The deploy scripts set the machine var
> `CX_IIS_SERVICES` to the comma-joined service name(s) the host runs on IIS, via
> `Get-IISServiceLabelValue -Map $svcMap` — the **same** map whose `.ServiceName` becomes each
> app's `OTEL_SERVICE_NAME` (`deploy-app.ps1` single app or `-InstrumentAllApps`; fleet
> `Instrument-IIS.ps1` the full set). So every host Service-ownership item equals a per-app
> `OTEL_SERVICE_NAME` — aligned. The `transform/iis_service_labels` processor (in the **remote
> Fleet config**; the repo collector YAMLs are the reference template) splits it into an
> **array** and stamps **7 keys** — `service`, `tags.{service,cx_svc,CX_SERVICE_NAME}`,
> `cx.infra.labels.{service,cx_svc,CX_SERVICE_NAME}` — onto the **logs-related pipelines only**
> (`logs` + `logs/resource_catalog`, the host entity that drives ownership). The array yields
> multiple discrete Service values (one per app), which APM resource correlation needs to match
> a single service to the host. Bare `cx_service` / `CX_SERVICE_NAME` were ignored by ownership
> and dropped. Automation sets only the env var (no config push); set it at machine scope and
> restart the supervisor so the collector picks it up. Full detail:
> [`iis-service-ownership.md`](./iis-service-ownership.md).

There are three places to set these, in increasing order of scope.

**Per app, ASP.NET Core.** Add an `<environmentVariables>` block inside `<aspNetCore>` in that app's `web.config`.

```xml
<configuration>
  <system.webServer>
    <aspNetCore processPath="dotnet" arguments=".\MyApp.dll">
      <environmentVariables>
        <environmentVariable name="OTEL_SERVICE_NAME" value="wallet-api" />
        <environmentVariable name="OTEL_EXPORTER_OTLP_ENDPOINT" value="http://localhost:4318" />
        <environmentVariable name="OTEL_EXPORTER_OTLP_PROTOCOL" value="http/protobuf" />
      </environmentVariables>
    </aspNetCore>
  </system.webServer>
</configuration>
```

**Per app, ASP.NET Framework.** Use `appSettings` in that app's `Web.config`, for example `<add key="OTEL_SERVICE_NAME" value="wallet-api" />`. If you do not set a service name, one is generated as `SiteName\VirtualDirectoryPath`. Services therefore appear in APM even with no configuration, under a name you did not choose — set it explicitly.

**For all apps at once (host-wide).** Set the variables on the `W3SVC` and `WAS` Windows services in the registry. `Register-OpenTelemetryForIIS` already writes the profiler variables here, so you append the OTLP settings to the same multi-string value.

Registry path:

```
HKLM\SYSTEM\CurrentControlSet\Services\W3SVC\Environment
```

This is a REG_MULTI_SZ value with one `NAME=VALUE` entry per line. Add lines such as `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` and `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`. Do the same under the `WAS` service. Service name is the one thing you usually keep per app rather than host-wide, so set `OTEL_SERVICE_NAME` in each app's config even when everything else is global.

There is also a per app pool option: `Enable-OpenTelemetryForIISAppPool -AppPoolName <name>` and its `Disable-` counterpart toggle instrumentation for a single pool. An app pool environment variable takes precedence over the host-wide W3SVC registration. For setting the OTLP variables once across the apps that share a pool, see Part 4.

**Automated multi-app naming (recommended).** Instead of editing each app by hand, `deploy/Instrument-IIS.ps1` (fleet) and `scripts/deploy-app.ps1 -InstrumentAllApps` (single host) enumerate every IIS site and application via `deploy/Resolve-IISServiceNames.ps1` and assign each a distinct `OTEL_SERVICE_NAME`:

- **Naming (site + app path).** A site's root application takes the site name (e.g. `Wallet`); a nested application mounted at `/api` becomes `Wallet/api`. This is the clean, explicit form of the `SiteName\VirtualDirectoryPath` name the profiler would otherwise auto-generate.
- **Scope (dedicated pool vs shared pool).** An application that owns its app pool gets the name set on the pool — and the OTLP endpoint/protocol are re-set on that pool too, because a pool that declares its own `<environmentVariables>` stops inheriting `applicationPoolDefaults` (see Part 4). Applications that **share** a pool instead get the name written into each one's own `web.config`, since a single pool-level variable cannot distinguish co-hosted apps. Note: ASP.NET Core **in-process** hosting allows only one app per pool (a second in-process app in the same pool returns HTTP 500), so pool-sharing in practice means **out-of-process** or ASP.NET **Framework** apps — in-process apps each land on their own pool and take the pool-scoped path anyway.
- **Overrides.** Rename specific apps with `-ServiceNameOverrides @{ 'Wallet/api' = 'wallet-api' }` or `-OverridesJson <file>` (keys are the auto-derived names).

Classic ASP.NET **Framework** apps have no `<aspNetCore>` element, so the web.config writer skips them with a warning — set their name via `appSettings` as shown above. Because no app's name is stamped host-wide, host/infrastructure signals (hostmetrics, IIS receiver, event logs, access logs) no longer collapse under one app; they fall back to the collector's neutral `subsystem_name`.

### 4. Restart IIS or the pools

After changing config, recycle so the workers pick up the new environment.

```powershell
# Full IIS restart
iisreset.exe

# Or target the W3SVC service directly
Stop-Service -Name W3SVC -Force
Restart-Service -Name W3SVC
Start-Service -Name W3SVC
```

If the registry value has a trailing blank line, IIS refuses to start with "cannot contain empty strings". Remove the empty entry.

### 5. Uninstall / rollback (single host)

To reverse the instrumentation on one box, run the inverse of the register steps
(elevated, Windows PowerShell 5.1). This clears the CLR-profiler entries from the
`W3SVC`/`WAS` service `Environment` and removes the core files:

```powershell
Import-Module .\OpenTelemetry.DotNet.Auto.psm1
Unregister-OpenTelemetryForIIS      # removes the profiler env from W3SVC/WAS + recycles IIS
Uninstall-OpenTelemetryCore         # removes the auto-instrumentation core files
```

Then remove the per-app `OTEL_SERVICE_NAME` from any `web.config` you set it in,
and the OTLP variables from `applicationPoolDefaults` / individual pools
(the `appcmd ... /-` removal form — note `applicationPoolDefaults` takes **no**
`[name=...]` predicate). Finally `iisreset`. Confirm `Get-Service W3SVC` is
**Running** — a leftover trailing blank line in the profiler `Environment` value
blocks IIS start (see the note above).

> On a **fleet-deployed** host, do NOT do this by hand — run `uninstall.bat` /
> `Uninstall-Agent.ps1`, which reverses all of the above from the backup manifest
> (and removes the collector/supervisor too). See `docs/fleet-deployment.md`.

---

## Part 4: Configuring shared IIS application pools

To set the OTLP variables once for many apps instead of editing every `web.config`: IIS lets you set environment variables at the application pool level, and every app assigned to that pool inherits them. This is the set-once answer for pools that several apps share.

### Where the variables can live, and what wins

There are four levels, from broadest to most specific. A more specific level overrides a broader one.

| Level | Where it is set | Applies to |
| --- | --- | --- |
| Service level (W3SVC, WAS) | Registry `Environment` value, written by `Register-OpenTelemetryForIIS` | Every worker process on the host |
| Application pool defaults | `applicationHost.config`, `<applicationPoolDefaults>` | Every pool that does not define its own variables |
| A specific application pool | `applicationHost.config`, that pool's `<environmentVariables>` | All apps assigned to that pool |
| A single app | that app's `web.config` | One app only |

For OpenTelemetry specifically, a pool-level variable takes precedence over the host-wide W3SVC registration. The clean pattern is to put the shared values (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, and shared resource attributes such as `deployment.environment`) at the pool-defaults or pool level, and keep only `OTEL_SERVICE_NAME` per app when a pool hosts more than one service.

> ⚠️ Inheritance rule: if a pool defines its own `<environmentVariables>` collection, it does NOT inherit anything from `<applicationPoolDefaults>`. Every variable that pool needs must be listed on the pool itself. Defaults only reach pools that have no `<environmentVariables>` of their own.

> Requirement: per-pool environment variables need IIS 10.0 (Windows Server 2016 or Windows 10) or later. On older IIS, use the host-wide W3SVC and WAS registry approach from Part 3, or run the pool under a dedicated identity whose user environment carries the variables.

### Option A: Set defaults for all pools

This is the closest to a true set-once and is ideal for the shared OTLP endpoint. It reaches every pool that has not defined its own environment variables.

PowerShell (run as Administrator):

```powershell
Import-Module WebAdministration

Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
  -filter "system.applicationHost/applicationPools/applicationPoolDefaults/environmentVariables" `
  -name "." -value @{name='OTEL_EXPORTER_OTLP_ENDPOINT'; value='http://localhost:4318'}

Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
  -filter "system.applicationHost/applicationPools/applicationPoolDefaults/environmentVariables" `
  -name "." -value @{name='OTEL_EXPORTER_OTLP_PROTOCOL'; value='http/protobuf'}
```

Or with appcmd from an elevated Command Prompt, one line per variable:

```bash
%windir%\system32\inetsrv\appcmd.exe set config -section:system.applicationHost/applicationPools /+"applicationPoolDefaults.environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT',value='http://localhost:4318']" /commit:apphost
```

### Option B: Set the variables on one shared pool

Use this when several apps share a single pool and you want the variables scoped to just that pool. The resulting `applicationHost.config` (at `C:\Windows\System32\inetsrv\config\applicationHost.config`, under `<system.applicationHost><applicationPools>`) looks like this:

```xml
<applicationPools>
  <add name="SharedAppPool" managedRuntimeVersion="v4.0">
    <environmentVariables>
      <add name="OTEL_EXPORTER_OTLP_ENDPOINT" value="http://localhost:4318" />
      <add name="OTEL_EXPORTER_OTLP_PROTOCOL" value="http/protobuf" />
      <add name="OTEL_RESOURCE_ATTRIBUTES" value="deployment.environment=production" />
    </environmentVariables>
  </add>
</applicationPools>
```

For an ASP.NET Core pool, use `managedRuntimeVersion=""`, which is the "No Managed Code" setting the runtime requires (see Part 3).

Rather than editing the file by hand, set it with PowerShell:

```powershell
Import-Module WebAdministration
$pool = "SharedAppPool"

Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
  -filter "system.applicationHost/applicationPools/add[@name='$pool']/environmentVariables" `
  -name "." -value @{name='OTEL_EXPORTER_OTLP_ENDPOINT'; value='http://localhost:4318'}
```

or with appcmd:

```bash
%windir%\system32\inetsrv\appcmd.exe set config -section:system.applicationHost/applicationPools /+"[name='SharedAppPool'].environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT',value='http://localhost:4318']" /commit:apphost
```

To change or remove a variable later with appcmd:

```bash
REM change an existing value
%windir%\system32\inetsrv\appcmd.exe set config -section:system.applicationHost/applicationPools /"[name='SharedAppPool'].environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT'].value:'http://localhost:4318'" /commit:apphost

REM remove one variable
%windir%\system32\inetsrv\appcmd.exe set config -section:system.applicationHost/applicationPools /"[name='SharedAppPool'].environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT']" /commit:apphost
```

### Editing through IIS Manager

There is no dedicated field for pool environment variables in the IIS Manager UI, but you can manage them through Configuration Editor: open IIS Manager, select the server, open Configuration Editor, choose the `system.applicationHost/applicationPools` section, expand the pool (or `applicationPoolDefaults`), open the `environmentVariables` collection, add your entries, then use the Generate Script action to capture the exact appcmd or PowerShell so you can script the rest of the fleet.

### Turning instrumentation on or off per pool

Registering IIS enables the profiler for every pool. To exclude one pool, run `Disable-OpenTelemetryForIISAppPool -AppPoolName <name>`, which sets `COR_ENABLE_PROFILING=0` on that pool; `Enable-OpenTelemetryForIISAppPool -AppPoolName <name>` turns it back on. Because it is set on the pool, it overrides the host-wide registration. The app pool name is case sensitive.

### Applying the change

Editing `applicationHost.config` recycles the affected pools by default, so the new variables take effect on the next request. If you need to avoid an unplanned recycle during a rollout, set `disallowRotationOnConfigChange` to true on the pool so it does not auto-recycle on config changes, then recycle it yourself in a maintenance window:

```powershell
Restart-WebAppPool -Name "SharedAppPool"
```

---

## Part 5: Rolling this out across the fleet

Pilot on a handful of servers first, then automate. Two options for scale:

**Existing Windows tooling.** Both the collector installer and the auto-instrumentation steps are PowerShell, so any tool that pushes files and runs remote PowerShell across many servers (for example BatchPatch) can deploy them. Configuring IIS pool or registry variables scripts the same way.

**Central configuration management.** Use Coralogix Fleet Management (the OpAMP Supervisor). Install the collector with `-Supervisor` and set `CORALOGIX_DOMAIN` as well as the key. In this mode the collector config is managed remotely and merged with a local base config. The config must not contain an `opamp` extension, because the supervisor owns that connection. This is the cleaner path when you have around 100 or more hosts to keep consistent.

```powershell
$u='https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'; $f="$env:TEMP\coralogix-otel-collector.ps1"; Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing; $env:CORALOGIX_DOMAIN='<your-domain>'; $env:CORALOGIX_PRIVATE_KEY='<your-private-key>'; & $f -Supervisor -SupervisorCollectorBaseConfig 'C:\otel\config.yaml'
```

---

## Troubleshooting

**Spans arrive but the APM Service Catalog or span metrics stay empty.** Traces are visible in the tracing view, but no APM metrics are generated. Likely causes: the `service.name` contains dots or hyphens that need normalizing, or the span-metrics connector is not producing metrics. Confirm the `spanmetrics` connector is in the traces pipeline, check that spans carry `http.response.status_code` (semantic conventions 1.21 or later) for error tracking, and review the service naming. Give it a few minutes after a change, since span metrics flush on an interval.

**"Could not find path to OpenTelemetry" or the module is not found.** The register or install step ran before the module was imported or the core files were installed. Run the steps in order: download, `Import-Module`, `Install-OpenTelemetryCore`, then `Register-OpenTelemetryForIIS`.

**No telemetry from an ASP.NET Core app.** The app pool is probably not set to "No Managed Code". Fix the pool and recycle it.

**Service fails to start.** Common causes: the config uses an IIS or `file_storage` feature the host is missing (install the IIS role, or re-run with `-EnableDynamicIISParsing`), the config is invalid (run the `validate` command), or `CORALOGIX_PRIVATE_KEY` is not set on the service. Check `Get-EventLog -LogName Application -Source otelcol-contrib -Newest 20`.

**GitHub download fails with an SSL/TLS error.** The host is defaulting to TLS 1.0. Enable TLS 1.2 first: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`.

**PowerShell execution policy blocks the script.** Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`, or launch with `powershell -ExecutionPolicy Bypass`.

**IIS will not start after editing the registry variables.** A trailing empty line in the REG_MULTI_SZ triggers "cannot contain empty strings". Remove the blank entry.

---

## Choosing the right setup (template matrix)

Use a small set of repeatable templates keyed to what each host runs. This guide covers the Windows / IIS / .NET case. The others, for reference:

| Scenario | What to use |
| --- | --- |
| Windows, IIS, .NET app, no SDK in code | Collector (this config) + zero-code IIS auto-instrumentation (Part 3) |
| Windows, standalone .NET service (EXE), no SDK | Collector + `Register-OpenTelemetryForWindowsService -WindowsServiceName <svc> -OTelServiceName <name>` |
| App already has the OpenTelemetry SDK in code | Collector only; point the app at `localhost:4317` or `4318` |
| Linux box (for example with Redis) | Separate Linux collector config with the matching receivers; not covered here |
| Node.js front end | Node.js auto-instrumentation; separate template, not covered here |

Component receivers (Redis, SQL Server, Elasticsearch and so on) are add-ons, not part of the baseline. Layer them as separate config fragments only on hosts that actually run that component.


