# Installing the Coralogix OpenTelemetry Collector Config (Windows / IIS)

Instructions for installing `config.yaml` on a Windows server running the Coralogix OpenTelemetry Collector. No scripts or command line required — every step uses standard Windows tools.

The config ships IIS access logs, Windows event logs, host metrics, IIS metrics, application traces/logs/metrics (OTLP), span metrics, and host entity data (Resource Catalog) to Coralogix.

## Prerequisites

1. **Coralogix OpenTelemetry Collector for Windows** is already installed as the `otelcol-contrib` Windows service.
   To check: press **Win+R**, type `services.msc`, press Enter, and look for **OpenTelemetry Collector (otelcol-contrib)** in the list.
2. A **Coralogix Send-Your-Data API key** for your team (Coralogix UI → Data Flow → API Keys).
3. A Windows account with **Administrator rights** on the server.
4. If shipping IIS access logs: IIS W3C logging enabled, writing to `C:\inetpub\logs\LogFiles\W3SVC*` (the IIS default).

## Step 1 — Customize the config file

Open `config.yaml` in Notepad and replace the following values. Use **Edit → Find** (Ctrl+F) to locate each one.

| Find | Current value | Replace with |
|---|---|---|
| `resource/service:` → the `service.namespace` entry's `value:` | `iis-instrumentation-test` | Your application grouping — becomes the Coralogix **application** name |
| `k8s.cluster.name` → the `value:` line below it | `windows-iis` | A name that groups this host or fleet (display only) |
| `domain:` (appears **twice**, under both `coralogix` exporters) and the `opamp` endpoint URL | `eu1.coralogix.com` | Your Coralogix region domain (e.g. `eu2.coralogix.com`, `us1.coralogix.com`) — replace in **all three places** |
| `application_name:` under `exporters.coralogix` | `otel` | Optional: your application grouping name |
| `subsystem_name:` under `exporters.coralogix` | `windows` | Optional: fallback subsystem for signals without a service name |

What these values control:
- **Per-app `service.name` comes from the apps, not this file.** Each IIS application sets its own `OTEL_SERVICE_NAME` (via `Instrument-IIS.ps1` / `deploy-app.ps1`, derived from the site name + app path), so this config deliberately does **not** insert a hard-coded `service.name` — that would stamp one app's name onto every host/infra signal on a multi-app host. Signals that arrive without a `service.name` (hostmetrics, IIS receiver, event logs, access logs) fall back to the `subsystem_name` value below.
- `service.namespace` — mapped by the Coralogix exporter to the **application** name; applied to every signal that lacks it, so the whole host reports under one application.

> **Do not** paste the API key into the file. It is read from an environment variable (next step).

Save the file.

## Step 2 — Set the API key as a system environment variable

1. Press **Win+R**, type `sysdm.cpl`, press Enter.
2. Go to the **Advanced** tab → click **Environment Variables…**
3. In the lower **System variables** section (not "User variables"), click **New…**
4. Variable name: `CORALOGIX_PRIVATE_KEY`
   Variable value: your Send-Your-Data API key
5. Click **OK** on all dialogs.

## Step 3 — Back up the current config

> **Important:** the collector service reads its config from
> `C:\ProgramData\OpenTelemetry\Collector\config.yaml`
> Copies in other locations (for example `C:\otel\config.yaml`) are **ignored** by the service.
> `ProgramData` is a hidden folder — in File Explorer enable **View → Show → Hidden items**, or paste the path directly into the address bar.

1. Open File Explorer and go to `C:\ProgramData\OpenTelemetry\Collector`
2. Right-click the existing `config.yaml` → **Copy**, then **Paste** in the same folder.
3. Rename the copy to `config.yaml.bak` (right-click → **Rename**). If asked for administrator permission, click **Continue**.

## Step 4 — Install the new config

1. Copy your customized `config.yaml` (from Step 1).
2. Paste it into `C:\ProgramData\OpenTelemetry\Collector`, replacing the existing file. Confirm **Replace the file in the destination** and any administrator prompt.

## Step 5 — Restart the collector service

1. Press **Win+R**, type `services.msc`, press Enter.
2. Find **OpenTelemetry Collector (otelcol-contrib)**.
3. Right-click it → **Restart**.
4. Wait a few seconds, then press **F5** to refresh. The **Status** column must show **Running**.

If the status is blank or the service stops immediately, the config has an error — see Troubleshooting below.

## Step 6 — Verify data is flowing

**On the server:**

1. Open a browser and go to `http://127.0.0.1:8888/metrics`
2. Press **Ctrl+F** and search for `otelcol_exporter_sent_metric_points_total` — it should exist with a growing number (refresh the page to see it climb).
3. Search for `send_failed` — every such line should end in ` 0`. Non-zero values mean exports are failing (see Troubleshooting).

**In the Coralogix UI** (allow 2–5 minutes):

- **Explore → Logs**: Windows event logs and IIS access logs arriving.
- Host metrics carry `service_name` and `service_namespace` labels, and appear under the application named by your `service.namespace` value.
- **Infrastructure → Infrastructure Explorer → Hosts**: the host appears; its **Ownership → Service** populates (may take ~15 minutes).

## Rollback

1. In `C:\ProgramData\OpenTelemetry\Collector`, delete the new `config.yaml`.
2. Copy `config.yaml.bak` and rename the copy back to `config.yaml`.
3. Restart the service as in Step 5.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Service won't stay **Running** after restart | Config file error. Open **Event Viewer** (Win+R → `eventvwr.msc`) → **Windows Logs → Application** → look for recent **Error** entries with Source **otelcol-contrib**. The message names the bad config line. Fix or roll back. |
| `send_failed` lines not ending in `0`, or "rate limit exceeded" in Event Viewer | Wrong region domain for your key, or the key lacks send permission. Verify the `domain:` values match your Coralogix account region and the key is a **Send-Your-Data** key. |
| Service runs but nothing appears in Coralogix | Environment variable name typo (`CORALOGIX_PRIVATE_KEY`), or it was created under **User variables** instead of **System variables** — redo Step 2, then restart the service. |
| No IIS access logs | IIS W3C logging is disabled, or logs go to a non-default folder. Enable W3C logging in IIS Manager, or update the path under `filelog/iis:` → `include:` in the config. |
| Config changes have no effect | The edited file is not the one in `C:\ProgramData\OpenTelemetry\Collector` — see the note in Step 3. |
