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

## Diagnose / set the Service-ownership labels (`Set-CxServiceLabels.ps1`)

`misc\Set-CxServiceLabels.ps1` is a **standalone** script (no dependency on `deploy\`) that
answers the three questions you have when Infrastructure Explorer shows no **Service** ownership
for a host:

1. what *should* the label value be here, 2. was it actually set, 3. why has it not taken effect.

It discovers **both** workload types — IIS sites/applications and Node.js apps under PM2 — using
naming rules identical to `deploy\Resolve-IISServiceNames.ps1` / `deploy\Resolve-NodeServiceNames.ps1`,
and prints a `cause`/`fix` line for every degraded step.

```powershell
# read-only: shows what it WOULD set and every reason a step degraded
.\misc\Set-CxServiceLabels.ps1

# write the machine env vars and restart the collector service
.\misc\Set-CxServiceLabels.ps1 -Apply
```

| Variable | Written value |
|---|---|
| `CX_IIS_SERVICES` | distinct **union** of the IIS service names and the PM2 service names |
| `CX_NODE_SERVICES` | the PM2 service names only |

The union is deliberate: the collector config reads `CX_IIS_SERVICES` only — nothing consumes
`CX_NODE_SERVICES` yet — so folding the PM2 names in is what makes Node apps appear as host
Service ownership today. Pass `-NoUnion` for strict deploy-script parity (the script then says,
loudly, that Node names will not reach Coralogix).

Useful flags: `-NoUnion`, `-SkipIis`, `-SkipNode`, `-RestartCollector:$false`,
`-ServiceNameOverrides @{ 'Wallet/api' = 'wallet-api' }`, `-OverridesJson <path>`, `-LogPath <path>`.
Exit codes: `0` no failures, `1` at least one FAIL, `2` preflight abort (not elevated).

What the verify stage catches that nothing else does:

- **Stale collector** — a process reads the machine environment once, at start. The script compares
  the collector's process start time against the last-write time of the
  `Session Manager\Environment` registry key and flags a collector that is still stamping the old
  value. It handles the collector running as a **service** (`opampsupervisor` / `otelcol-contrib`)
  *and* as a bare process (test container, manual launch); it refuses to kill a non-service process.
- **Config that never consumes the variable** — searches the supervisor base config, the merged
  `effective.yaml`, the local-mode config dir and `C:\otel`; FAILs when no config references
  `CX_IIS_SERVICES`, and notes when the transform defines `log_statements` only (spans and metrics
  are then untagged — expected with the current template).
- **PM2's per-user daemon** — an empty app list is reported with the identity the script ran as,
  which is the usual reason a host with running Node apps reports none.

Container test: `test\docker-win\Run-CxServiceLabelsTest.ps1` runs the whole thing against a live
IIS + PM2 Windows container and asserts, among other cases, that the names it derives equal the
names the real deploy automation derived.

## Rollback / uninstall

```powershell
# elevated; vendor uninstaller handles the supervisor + collector
$u='https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f="$env:TEMP\coralogix-otel-collector.ps1"; Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing
& $f -Uninstall            # keeps config;  add -Purge to remove all configuration
```
