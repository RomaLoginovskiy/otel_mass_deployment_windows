# Coralogix OTel Collector — Supervisor Mode (fully remote configuration)

Installs the Coralogix OpenTelemetry Collector on Windows in **supervisor mode**:
an OpAMP supervisor (`opampsupervisor` service) connects to Coralogix **Fleet
Management** and pulls the collector's configuration **remotely**. No local
config file is used — the effective config is whatever Fleet Management assigns.

- Docs: https://coralogix.com/docs/external/telemetry-shippers/otel-installer/windows/
- Region/domain used here: **`eu1.coralogix.com`**
- Installed version: **0.155.0** (supervisor + collector)
- Verified on: DESKTOP-B137S7F, 2026-07-13

Local-config mode is documented separately in
`SimpleWebApp/coralogix/INSTALL.md`. This file is the supervisor-mode path.

## Prerequisites

- Windows 10/11 or Server 2016+; PowerShell 5.1+.
- **Administrator** privileges (the working shell here is NOT elevated — every
  step below runs elevated via a UAC prompt).
- Coralogix **Send-Your-Data API key**. Stored in
  `SimpleWebApp\coralogix\SendDataKey.txt` (read into an env var, never printed
  or committed).
- Supervisor mode requires collector ≥ 0.144.0 (the installer auto-selects a
  compatible version — 0.155.0 here).

## Environment variables

| Variable | Required | Value used |
|---|---|---|
| `CORALOGIX_PRIVATE_KEY` | Yes | contents of `SendDataKey.txt` |
| `CORALOGIX_DOMAIN` | Yes (supervisor mode only) | `eu1.coralogix.com` |

## Steps

### 1. Remove any prior local-mode collector (avoid port clash)

Supervisor mode runs its own collector; a leftover local-mode `otelcol-contrib`
service would clash on ports 4317/4318/8888. On this box no service was present,
only a stale `C:\ProgramData\OpenTelemetry\Collector` config dir, which was
removed. If a local-mode collector IS installed, remove it first:

```powershell
# from repo root, elevated
.\uninstall-coralogix-collector.ps1 -RemoveConfig
```

### 2. Install supervisor mode (elevated)

Run in an **elevated** PowerShell. Note: **no `-Config`** flag → configuration is
fully remote (pulled from Fleet Management). Passing `-Config` or
`-SupervisorCollectorBaseConfig` would inject local config instead.

```powershell
$u='https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f="$env:TEMP\coralogix-otel-collector.ps1"
Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing
$env:CORALOGIX_DOMAIN     = 'eu1.coralogix.com'
$env:CORALOGIX_PRIVATE_KEY = (Get-Content '<repo>\SimpleWebApp\coralogix\SendDataKey.txt' -Raw).Trim()
& $f -Supervisor
```

From the non-elevated working shell, this was launched via:

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"<runner>.ps1`""
```

The installer:
- downloads + MSI-installs the collector binary, then **removes** the MSI's
  collector service (the supervisor manages the collector process itself),
- downloads + MSI-installs the OpAMP supervisor,
- creates the supervisor service `opampsupervisor` and starts it.

### 3. Assign a config in Coralogix Fleet Management (manual, required)

Because config is fully remote, the collector starts with an empty base
(`nop` receivers/exporters) and ships **nothing** until a config is assigned.
In the Coralogix UI (eu1) → **Data Flow → Fleet Management**: find this agent
(host `DESKTOP-B137S7F`) and attach/assign a collector configuration. The
supervisor pulls it automatically; the base config must **not** contain an
`opamp` extension (the supervisor owns the OpAMP connection).

## Install locations & service

| Component | Path / name |
|---|---|
| Supervisor service | `opampsupervisor` (Windows Service) |
| Supervisor binary | `C:\Program Files\OpenTelemetry OpAMP Supervisor\opampsupervisor.exe` |
| Supervisor config | `C:\Program Files\OpenTelemetry OpAMP Supervisor\config.yaml` |
| Collector binary | `C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe` |
| Collector base config | `C:\Program Files\OpenTelemetry OpAMP Supervisor\collector.yaml` |
| Effective (merged) config | `C:\ProgramData\opampsupervisor\state\effective.yaml` |
| Logs | Windows Application Event Log, source `opampsupervisor` |

## Verification

```powershell
Get-Service opampsupervisor                                    # Status: Running
Get-Process otelcol-contrib -ErrorAction SilentlyContinue      # collector process (managed by supervisor)
Get-Content "C:\ProgramData\opampsupervisor\state\effective.yaml"
Get-EventLog -LogName Application -Source opampsupervisor -Newest 20 | Format-List
```

Confirmed on install (2026-07-13):
- `opampsupervisor` → **Running**; collector process PID present.
- Event log: **"Connected to the OpAMP server"** and **"Received remote config
  from server"** (config hash logged) → Fleet Management link is live.
- `effective.yaml` present. Currently `nop` pipelines — expected until a real
  config is assigned in Fleet Management (step 3).

In the Coralogix UI (allow 2–5 min after assigning a config): the agent shows
**Connected** in Fleet Management and telemetry begins arriving.

## Service management

```powershell
Restart-Service opampsupervisor
Stop-Service    opampsupervisor
Start-Service   opampsupervisor
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Supervisor won't stay Running | `Get-EventLog -LogName Application -Source opampsupervisor -Newest 50 \| Format-List` — check for connection/auth errors. |
| Not connecting to OpAMP server | Wrong `CORALOGIX_DOMAIN` for the key's region, or bad key. eu1 verified here; **eu2 rate-limits/rejects** this key. |
| No data in Coralogix | No config assigned in Fleet Management (step 3), or assigned config has no receivers/exporters. Check `effective.yaml`. |
| Port clash / collector won't start | A leftover local-mode `otelcol-contrib` service — uninstall it (step 1). |

## Rollback / uninstall

```powershell
# elevated; vendor uninstaller handles the supervisor + collector
$u='https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f="$env:TEMP\coralogix-otel-collector.ps1"; Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing
& $f -Uninstall            # keeps config;  add -Purge to remove all configuration
```
