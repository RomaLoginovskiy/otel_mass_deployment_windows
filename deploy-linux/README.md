# Fleet Deployment Runbook — Coralogix OTel Collector (Supervisor Mode) for Linux machines

# Supervisor default install — customer guide


Step-by-step guide for **`install-supervisor-default.sh`**.

This script installs the **Coralogix OpAMP Supervisor + OpenTelemetry Collector** so you can manage collector configuration **remotely from Fleet Management**. Fleet Management owns the live config via `/var/lib/opampsupervisor/effective.yaml`.

---

## What this script does

| Step | Action |
| --- | --- |
| 1 | Runs Coralogix’s official installer with `--supervisor` only (empty/default local base config) |
| 2 | Tags the agent for Fleet grouping: `app.type`, `env.type` |
| 3 | Loads DB receiver credentials (from env or `/opt/{YOUR-APPLICATION-FOLDER}/otel-monitor.env`) |
| 4 | Writes credentials to `/etc/opampsupervisor/opampsupervisor.conf` |
| 5 | Patches `/etc/opampsupervisor/config.yaml` so those env vars are passed into the collector child (`agent.env`) |
| 6 | Restarts `opampsupervisor` and checks it is active |

**Why credentials are needed:** when you later Activate a remote config that includes Redis / Valkey / PostgreSQL / Elasticsearch receivers (for example this repo’s `config.yaml`), the collector needs `POSTGRES_OTEL_PASSWORD`, related endpoints, and optional Elasticsearch credentials. Without matching values the collector crash-loops or cannot authenticate, and you see no database metrics.

**What it does not do:**

- Does not install Redis / Valkey / PostgreSQL / Elasticsearch
- Does not install the sample app
- Does not push a full local `config.yaml` as base config (Fleet remote config is the goal)

---

## Architecture (after install)

```
┌─────────────────────┐     OpAMP      ┌──────────────────────────┐
│  This Linux host    │ ◄────────────► │  Coralogix Fleet Manager │
│                     │                │  (remote configurations) │
│  opampsupervisor    │                └──────────────────────────┘
│       │             │
│       ▼             │
│  otelcol-contrib    │
│  effective.yaml     │ ──── metrics/logs ───► Coralogix
└─────────────────────┘
```

| Path | Role |
| --- | --- |
| `/etc/opampsupervisor/config.yaml` | Supervisor settings (OpAMP endpoint, Fleet attributes, env pass-through) |
| `/etc/opampsupervisor/opampsupervisor.conf` | Secrets / endpoints (mode `0600`) |
| `/etc/opampsupervisor/collector.yaml` | Local base (kept minimal by default install) |
| `/var/lib/opampsupervisor/effective.yaml` | **Live** config after Fleet Activate |

---

## Prerequisites

On each target host:

- Linux with **systemd**, root / `sudo`
- Outbound HTTPS to Coralogix (`ingress.<your-domain>`)
- `curl`, `python3`
- Databases already running (or endpoints reachable), if your remote config scrapes them

From Coralogix:

- A **Send-Your-Data** API key
- Correct domain for your region (examples below)
- Access to **Integrations → Fleet Management**
- Permission to manage remote configuration (`REMOTE-CONFIGURATION:MANAGE` for Activate)

### Domain cheat sheet

| Region / UI | `CORALOGIX_DOMAIN`  |
| --- | --- |
| India | `app.coralogix.in` |
| US1 | `coralogix.com` |
| EU2 | `eu2.coralogix.com` |

Use the value that matches your Coralogix account. Wrong domain → agent never appears in Fleet Management.

OpAMP endpoint becomes: `https://ingress.<CORALOGIX_DOMAIN>/opamp/v1`

---

## Customer implementation (step by step)

### Step 1 — Prepare the host

Copy the script onto the server (example):

```bash
scp install-supervisor-default.sh ubuntu@<host>:~/
ssh ubuntu@<host>
chmod +x ~/install-supervisor-default.sh
```

### Step 2 — Choose Fleet labels for this host

Pick values that match how you want to group servers:

| Variable | Meaning | Examples |
| --- | --- | --- |
| `APP_TYPE` | Application / DB role | `redis`, `valkey`, `postgresql`, `elasticsearch`, `databases` |
| `ENV_TYPE` | Environment | `prod`, `staging`, `dev` |

Defaults if unset: both `databases`.

### Step 3 — Run the install script

#### Pass credentials explicitly

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<your-send-your-data-key>" \
  CORALOGIX_DOMAIN="app.coralogix.in" \
  APP_TYPE="databases" \
  ENV_TYPE="prod" \
  POSTGRES_OTEL_PASSWORD="<otel_monitor_password>" \
  POSTGRES_OTEL_USER="otel_monitor" \
  POSTGRES_OTEL_DATABASE="appdb" \
  POSTGRES_ENDPOINT="localhost:5432" \
  REDIS_ENDPOINT="localhost:6379" \
  VALKEY_ENDPOINT="localhost:6380" \
  ELASTICSEARCH_ENDPOINT="http://localhost:9200" \
  ELASTICSEARCH_USERNAME="" \
  ELASTICSEARCH_PASSWORD="" \
  ./install-supervisor-default.sh
```

Set `ELASTICSEARCH_USERNAME` and `ELASTICSEARCH_PASSWORD` to non-empty values when Elasticsearch requires authentication. Leave both empty for an unauthenticated endpoint.

### Step 4 — Verify the Supervisor locally

```bash
sudo systemctl status opampsupervisor
sudo grep endpoint /etc/opampsupervisor/config.yaml
sudo grep -A6 non_identifying_attributes /etc/opampsupervisor/config.yaml
sudo tail -n 50 /var/log/opampsupervisor/opampsupervisor.log
```

You want to see:

- Service **active (running)**
- Endpoint like `https://ingress.app.coralogix.in/opamp/v1`
- Attributes `app.type: "redis"` and `env.type: "prod"` (your values)
- Log line similar to: `Connected to the OpAMP server.`

### Step 5 — Confirm the agent in Coralogix

1. Open Coralogix (same account/region as the key + domain).
2. Go to **Integrations → Fleet Management → Agents**.
3. Find this hostname.
4. Use **Group by** → `app.type` or `env.type`.

If the agent does not appear within a few minutes:

- Domain wrong (e.g. `coralogix.in` instead of `app.coralogix.in`)
- API key wrong / wrong account
- Outbound 443 blocked
- Check supervisor log for `401` / `403` / connection errors

### Step 6 — Create and Activate a remote configuration

1. **Integrations → Fleet Management → Configurations**
2. **Create** a configuration group (example name: `linux-redis-prod`)
3. **Agent selector:** match your labels, e.g.
    - `app.type` = `redis`
    - `env.type` = `prod`
4. Paste or upload your collector YAML (this repo’s `config.yaml` is a metrics/logs starting point)
5. Use **Preview → Agent list** and confirm only the intended hosts match
6. **Activate** the configuration
7. On the agent, ensure **Remote configuration** is enabled

<img width="1136" height="702" alt="image" src="https://github.com/user-attachments/assets/394b3031-2bf4-448a-aa0e-b4a41eeeb467" />
<img width="1888" height="814" alt="image" src="https://github.com/user-attachments/assets/fb229f3f-bc98-44da-833f-0cdeffc82a0a" />


After Activate, on the host:

```bash
sudo wc -l /var/lib/opampsupervisor/effective.yaml
sudo head -n 40 /var/lib/opampsupervisor/effective.yaml
```

`effective.yaml` should be non-empty and contain your pipelines.

### Step 7 — Verify metrics

```bash
# Collector self-metrics (should return Prometheus text, not empty)
curl -s http://127.0.0.1:8888/metrics | head -30

# Service health
sudo systemctl status opampsupervisor
# Child process should stay up (not restarting every few seconds)
```

In Coralogix **Explore → Metrics**, search for series from your remote config (e.g. `redis.*`, `postgresql.*`, host metrics).

---

## Environment variables reference

### Required

| Variable | Description |
| --- | --- |
| `CORALOGIX_PRIVATE_KEY` | Send-Your-Data API key |
| `CORALOGIX_DOMAIN` | Region domain, e.g. `app.coralogix.in` |
| `POSTGRES_OTEL_PASSWORD` | Required unless present in `otel-monitor.env` |

### Fleet labels

| Variable | Default | Sets Supervisor attribute |
| --- | --- | --- |
| `APP_TYPE` | `databases` | `app.type` |
| `ENV_TYPE` | `databases` | `env.type` |

### Receiver settings (optional overrides)

| Variable | Default |
| --- | --- |
| `REDIS_ENDPOINT` | `localhost:6379` |
| `REDIS_PASSWORD` | empty |
| `VALKEY_ENDPOINT` | `localhost:6380` |
| `VALKEY_PASSWORD` | empty |
| `POSTGRES_ENDPOINT` | `localhost:5432` |
| `POSTGRES_OTEL_USER` | `otel_monitor` |
| `POSTGRES_OTEL_DATABASE` | `appdb` |
| `ELASTICSEARCH_ENDPOINT` | `http://localhost:9200` |
| `ELASTICSEARCH_USERNAME` | empty |
| `ELASTICSEARCH_PASSWORD` | empty |

---

## How to roll out across many servers (customer pattern)

1. Decide label scheme, e.g. `APP_TYPE` = DB role, `ENV_TYPE` = environment.
2. Install Supervisor on each host with the correct labels (Step 3).
3. In Fleet Management, create **one Configuration group per label combination** you want to control independently.
4. Activate updates only on the group you intend (Preview first).
5. New hosts that join with the same `app.type` / `env.type` automatically match the active selector.

Example:

| Host role | `APP_TYPE` | `ENV_TYPE` | Fleet config group |
| --- | --- | --- | --- |
| Redis nodes | `redis` | `prod` | `linux-redis-prod` |
| Postgres nodes | `postgresql` | `prod` | `linux-postgres-prod` |
| Mixed demo box | `databases` | `prod` | `linux-databases-prod` |

---

## Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `CORALOGIX_PRIVATE_KEY: Set CORALOGIX_PRIVATE_KEY` under sudo | `sudo` dropped env | Use `sudo env VAR=... ./install-supervisor-default.sh` |
| Agent not in Fleet Management | Wrong domain/key/network | Check OpAMP endpoint + supervisor log for connect/auth errors |
| `missing password` / collector exit code 1 | Credentials not passed to collector | Re-run script with `POSTGRES_OTEL_PASSWORD` |
| Elasticsearch authentication error | Elasticsearch credentials missing or invalid | Re-run with matching `ELASTICSEARCH_USERNAME` and `ELASTICSEARCH_PASSWORD`; leave both empty only for unauthenticated Elasticsearch |
| `effective.yaml` empty / `AllowNoPipelines` | No remote config Activated | Create + Activate a Configuration; enable Remote configuration |
| `:8888/metrics` empty | Collector not running pipelines | Fix credentials + Activate remote config; confirm collector child stays up |
| Metrics missing in UI but local `:8888` works | Exporter/domain/key issue in remote YAML | Align `domain` and key in the Activated config with your account |

Useful commands:

```bash
sudo systemctl status opampsupervisor
sudo journalctl -u opampsupervisor -n 100 --no-pager
sudo tail -n 100 /var/log/opampsupervisor/opampsupervisor.log
sudo cat /var/lib/opampsupervisor/effective.yaml | head -80
curl -s http://127.0.0.1:8888/metrics | head -30
```

---

## Related files in this repo

| File | Purpose |
| --- | --- |
| `install-supervisor-default.sh` | This installer |
| `config.yaml` | Suggested remote collector config (metrics/logs; activate via Fleet) |
| `install-otel-collector.sh` | Alternate path: Supervisor + local `config.yaml` base config |

---

## Security notes

- Prefer `sudo env ...` and avoid pasting API keys into tickets or chat.
- `/etc/opampsupervisor/opampsupervisor.conf` is mode `0600` (root-only).
- Rotate any key that was exposed.
- Keep Elasticsearch / DB auth appropriate for production; demo stacks often disable ES security — do not copy that into production remote configs unchanged.

## Example screenshots (How it looks like)

Screenshots show the expected Coralogix UI after Supervisor install + remote config Activate + metrics flowing.

### 1. Fleet Management — Configurations list

Fleet Management Configurations list

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/1c745c4f-e2bc-4278-8e6a-e41ca221c087" />


**What you are looking at**

- **Integrations → Fleet Management → Configurations**
- A configuration group (example: `otel-database1`) with version history (Version 1 / 2 / 3)
- **Active** on the latest version means that YAML is what matching agents should run
- Agent status counts (green / amber / red) show how many agents applied the config successfully vs warning/error

**Why it matters**

This is where you control updates for a group of database hosts. Activate a new version to roll out a collector change; keep older versions Inactive for rollback.

---

### 2. Fleet Management — Agent selector + preview

Configuration editor with Agent selector and preview

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/e247dc5a-d97b-4687-9b66-9e7098492b73" />


**What you are looking at**

- Left: versions of the same configuration group
- Center: **Agent selector** rules (example: `host.name` **and** `app.type == redis`) plus the OTel YAML (Coralogix exporter `domain`, etc.)
- Right: **Preview → Agent list** — hosts that currently match the selector (status **Live**, agent type `standalone`, version, pipelines)

**Why it matters**

Selectors are how you target only Redis hosts, only Postgres hosts, or only `prod` — using the `APP_TYPE` / `ENV_TYPE` tags set by `install-supervisor-default.sh`. Always check Preview before Activate so you do not push config to the wrong fleet.

---

### 3. Explore → Metrics — Valkey identified

Metrics Explore showing Valkey labels on Redis-named metrics. 

**IMPORTANT NOTE: otel doesn’t have separate receiver for valkey, so we are using the redis receiver instead. The metrics for redis and valkey are same and below is how identify the valkey metirc.**

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/87502577-ff03-4f0f-925e-53dcceec5170" />

**What you are looking at**

- **Explore → Metrics** with a Redis-compatible metric (example: `redis_clients_blocked…`) filtered by `host_name`
- Labels on the series include `app_type`, host, and — importantly — `db_system=valkey` and `valkey=true`

**Why it matters**

Valkey is scraped with the Redis receiver (same metric names). The remote config should stamp Valkey scrapes with `valkey` / `db.system=valkey` so you can filter Valkey vs Redis in Coralogix instead of mixing them.

---

### 4. Explore → Metrics — PostgreSQL flowing

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/ec2682b7-4508-4290-a13f-f54e04c426a8" />

Metrics Explore showing PostgreSQL connection metric

**What you are looking at**

- A PostgreSQL metric (example: `postgresql_connection_max…`) with a stable time series
- Resource labels such as `cx_application_name`, `cx_subsystem_name`, and `host_name`

**Why it matters**

Confirms the collector can scrape Postgres with the credentials you passed at install time (`POSTGRES_OTEL_*`) and that data reaches Coralogix after the remote config is Active. Use similar queries for `redis.*`, `elasticsearch.*`, and host metrics from your Activated YAML.
