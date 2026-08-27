# Fleet Deployment Runbook — Coralogix OTel Collector (Supervisor Mode) for Linux machines

# Supervisor install by app type — customer guide

Step-by-step guide for **`install-supervisor-by-apptype.sh`**.

This script installs the **Coralogix OpAMP Supervisor + OpenTelemetry Collector** so you can manage collector configuration **remotely from Fleet Management**. Fleet Management owns the live config via `/var/lib/opampsupervisor/effective.yaml`.

**What changed vs `install-supervisor-default.sh`:** credentials and endpoints are **scoped by `APP_TYPE`**. You only pass the env vars for that role (e.g. Postgres-only hosts need Postgres vars; Redis-only hosts need Redis vars). The script does **not** fail if unrelated DB env vars are omitted.

---

## What this script does

| Step | Action |
| --- | --- |
| 1 | Runs Coralogix’s official installer with `--supervisor` only (empty/default local base config) |
| 2 | Tags the agent for Fleet grouping: `app.type`, `env.type` |
| 3 | Validates / collects **only** the credentials needed for the selected `APP_TYPE` |
| 4 | Writes those credentials to `/etc/opampsupervisor/opampsupervisor.conf` |
| 5 | Patches `/etc/opampsupervisor/config.yaml` so those env vars are passed into the collector child (`agent.env`) |
| 6 | Restarts `opampsupervisor` and checks it is active |

**Why credentials are needed:** when you later Activate a remote config that includes Redis / Valkey / PostgreSQL / Elasticsearch receivers, the collector needs the matching endpoint/username/password env vars. Without them the collector crash-loops and you see no metrics on `:8888`.

**What it does not do:**

- Does not install Redis / Valkey / PostgreSQL / Elasticsearch
- Does not push a full local `config.yaml` as base config (Fleet remote config is the goal)
- Does not require every DB env var on every host — only those for the chosen `APP_TYPE`

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
- The database for that host’s role already running (or endpoint reachable), if your remote config scrapes it

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
scp install-supervisor-by-apptype.sh ubuntu@<host>:~/
ssh ubuntu@<host>
# If you hit bash\r errors (Windows line endings):
sed -i 's/\r$//' ./install-supervisor-by-apptype.sh
chmod +x ~/install-supervisor-by-apptype.sh
```

### Step 2 — Choose Fleet labels for this host

Pick values that match how you want to group servers:

| Variable | Meaning | Examples |
| --- | --- | --- |
| `APP_TYPE` | Application / DB role | `redis`, `valkey`, `postgresql`, `elasticsearch`, `databases` |
| `ENV_TYPE` | Environment | `prod`, `staging`, `dev` |

Defaults if unset: both `databases`.

`APP_TYPE` also controls **which credentials are required** (see Step 3).

### Step 3 — Run the install script

**Important:** use `sudo env ...` so variables are not dropped by `sudo`.

#### PostgreSQL host (only Postgres vars)

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<your-send-your-data-key>" \
  CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="postgresql" \
  ENV_TYPE="prod" \
  POSTGRES_OTEL_PASSWORD="<otel_monitor_password>" \
  POSTGRES_OTEL_USER="otel_monitor" \
  POSTGRES_OTEL_DATABASE="appdb" \
  POSTGRES_ENDPOINT="localhost:5432" \
  ./install-supervisor-by-apptype.sh
```

#### Redis host (only Redis vars; password may be empty)

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<your-send-your-data-key>" \
  CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="redis" \
  ENV_TYPE="prod" \
  REDIS_ENDPOINT="localhost:6379" \
  REDIS_PASSWORD="" \
  ./install-supervisor-by-apptype.sh
```

#### Valkey host

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<your-send-your-data-key>" \
  CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="valkey" \
  ENV_TYPE="prod" \
  VALKEY_ENDPOINT="localhost:6380" \
  VALKEY_PASSWORD="" \
  ./install-supervisor-by-apptype.sh
```

#### Elasticsearch host

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<your-send-your-data-key>" \
  CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="elasticsearch" \
  ENV_TYPE="prod" \
  ELASTICSEARCH_ENDPOINT="http://localhost:9200" \
  ELASTICSEARCH_USERNAME="elastic" \
  ELASTICSEARCH_PASSWORD="<elasticsearch_password>" \
  ./install-supervisor-by-apptype.sh
```

#### Mixed / all databases on one host (`APP_TYPE=databases`)

Requires Postgres password plus the other endpoints (same idea as the older default installer):

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<your-send-your-data-key>" \
  CORALOGIX_DOMAIN="eu2.coralogix.com" \
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
  ./install-supervisor-by-apptype.sh
```

For `APP_TYPE=databases`, Elasticsearch username/password are optional and may stay empty for an unauthenticated endpoint.

### Step 4 — Verify the Supervisor locally

```bash
sudo systemctl status opampsupervisor
sudo grep endpoint /etc/opampsupervisor/config.yaml
sudo grep -A6 non_identifying_attributes /etc/opampsupervisor/config.yaml
sudo tail -n 50 /var/log/opampsupervisor/opampsupervisor.log
```

You want to see:

- Service **active (running)**
- Endpoint like `https://ingress.eu2.coralogix.com/opamp/v1` (or your region)
- Attributes `app.type` / `env.type` matching what you passed
- Log line similar to: `Connected to the OpAMP server.`

### Step 5 — Confirm the agent in Coralogix

1. Open Coralogix (same account/region as the key + domain).
2. Go to **Integrations → Fleet Management → Agents**.
3. Find this hostname.
4. Use **Group by** → `app.type` or `env.type`.

If the agent does not appear within a few minutes:

- Domain wrong (e.g. `coralogix.in` instead of `app.coralogix.in` / `eu2.coralogix.com`)
- API key wrong / wrong account
- Outbound 443 blocked
- Check supervisor log for `401` / `403` / connection errors

### Step 6 — Create and Activate a remote configuration

1. **Integrations → Fleet Management → Configurations**
2. **Create** a configuration group (example name: `linux-redis-prod`)
3. **Agent selector:** match your labels, e.g.
    - `app.type` = `redis`
    - `env.type` = `prod`
4. Paste or upload the matching collector YAML for that role, for example:
    - Redis → `redis.yaml`
    - Valkey → `redis_valkey.yaml`
    - PostgreSQL → `postgress.yaml`
    - Elasticsearch → `elasticsearch.yaml`
    - Mixed → `config.yaml`
5. Use **Preview → Agent list** and confirm only the intended hosts match
6. **Activate** the configuration
7. On the agent, ensure **Remote configuration** is enabled

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

In Coralogix **Explore → Metrics**, search for series from your remote config (e.g. `redis.*`, `postgresql.*`, host metrics).

---

## Environment variables reference

### Always required

| Variable | Description |
| --- | --- |
| `CORALOGIX_PRIVATE_KEY` | Send-Your-Data API key |
| `CORALOGIX_DOMAIN` | Region domain, e.g. `eu2.coralogix.com`, `app.coralogix.in` |

### Fleet labels

| Variable | Default | Sets Supervisor attribute |
| --- | --- | --- |
| `APP_TYPE` | `databases` | `app.type` |
| `ENV_TYPE` | `databases` | `env.type` |

### Credentials by `APP_TYPE` (only these are required / written)

| `APP_TYPE` | Required / used env vars |
| --- | --- |
| `postgresql` | `POSTGRES_OTEL_PASSWORD` (required); `POSTGRES_ENDPOINT`, `POSTGRES_OTEL_USER`, `POSTGRES_OTEL_DATABASE` (optional, have defaults) |
| `redis` | `REDIS_ENDPOINT` (default `localhost:6379`); `REDIS_PASSWORD` (optional, may be empty) |
| `valkey` | `VALKEY_ENDPOINT` (default `localhost:6380`); `VALKEY_PASSWORD` (optional, may be empty) |
| `elasticsearch` | `ELASTICSEARCH_USERNAME`, `ELASTICSEARCH_PASSWORD` (required); `ELASTICSEARCH_ENDPOINT` (default `http://localhost:9200`) |
| `databases` | All endpoints and credentials above; `POSTGRES_OTEL_PASSWORD` required; Elasticsearch username/password optional and may be empty |

### Receiver defaults (when that APP_TYPE uses them)

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
| `ELASTICSEARCH_USERNAME` | empty unless `APP_TYPE=elasticsearch` (then required) |
| `ELASTICSEARCH_PASSWORD` | empty unless `APP_TYPE=elasticsearch` (then required) |

---

## How to roll out across many servers (customer pattern)

1. Decide label scheme, e.g. `APP_TYPE` = DB role, `ENV_TYPE` = environment.
2. Install Supervisor on each host with the correct `APP_TYPE` and **only that role’s credentials** (Step 3).
3. In Fleet Management, create **one Configuration group per label combination** you want to control independently.
4. Activate the matching YAML for that `app.type` (Preview first).
5. New hosts that join with the same `app.type` / `env.type` automatically match the active selector.

Example:

| Host role | `APP_TYPE` | `ENV_TYPE` | Fleet config group | Suggested YAML |
| --- | --- | --- | --- | --- |
| Redis nodes | `redis` | `prod` | `linux-redis-prod` | `redis.yaml` |
| Valkey nodes | `valkey` | `prod` | `linux-valkey-prod` | `redis_valkey.yaml` |
| Postgres nodes | `postgresql` | `prod` | `linux-postgres-prod` | `postgress.yaml` |
| Elasticsearch nodes | `elasticsearch` | `prod` | `linux-es-prod` | `elasticsearch.yaml` |
| Mixed DB host | `databases` | `prod` | `linux-databases-prod` | `config.yaml` |

---

## Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `/usr/bin/env: ‘bash\r’: No such file or directory` | Windows CRLF line endings | `sed -i 's/\r$//' ./install-supervisor-by-apptype.sh` then re-run |
| `CORALOGIX_PRIVATE_KEY: Set CORALOGIX_PRIVATE_KEY` under sudo | `sudo` dropped env | Use `sudo env VAR=... ./install-supervisor-by-apptype.sh` |
| `POSTGRES_OTEL_PASSWORD is required when APP_TYPE=postgresql` | Password not passed for that role | Include `POSTGRES_OTEL_PASSWORD=...` for `postgresql` / `databases` |
| `ELASTICSEARCH_USERNAME is required when APP_TYPE=elasticsearch` or matching password error | Elasticsearch credentials not passed for that role | Include non-empty `ELASTICSEARCH_USERNAME` and `ELASTICSEARCH_PASSWORD` |
| Agent not in Fleet Management | Wrong domain/key/network | Check OpAMP endpoint + supervisor log for connect/auth errors |
| `missing password` / collector exit code 1 | Credentials not passed to collector, or remote YAML expects a DB this host did not configure | Re-run with the correct `APP_TYPE` vars; Activate a YAML that matches that role |
| `journald` / `_SYSTEMD_UNIT` error | Remote YAML includes `journald` on a host that rejects it | Use role YAML without `journald` (e.g. updated `redis.yaml`) |
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
| `install-supervisor-by-apptype.sh` | **This** installer (APP_TYPE-scoped credentials) |
| `install-supervisor-default.sh` | Older installer that expects all DB env vars together |
| `redis.yaml` / `redis_valkey.yaml` / `postgress.yaml` / `elasticsearch.yaml` | Role-specific remote configs to Activate in Fleet |
| `config.yaml` | Mixed metrics/logs remote config |
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

**What you are looking at**

- Left: versions of the same configuration group
- Center: **Agent selector** rules (example: `host.name` **and** `app.type == redis`) plus the OTel YAML (Coralogix exporter `domain`, etc.)
- Right: **Preview → Agent list** — hosts that currently match the selector (status **Live**, agent type `standalone`, version, pipelines)

**Why it matters**

Selectors are how you target only Redis hosts, only Postgres hosts, or only `prod` — using the `APP_TYPE` / `ENV_TYPE` tags set by `install-supervisor-by-apptype.sh`. Always check Preview before Activate so you do not push config to the wrong fleet.

---

### 3. Explore → Metrics — Valkey identified

Metrics Explore showing Valkey labels on Redis-named metrics.

**IMPORTANT NOTE: otel doesn’t have separate receiver for valkey, so we are using the redis receiver instead. The metrics for redis and valkey are same and below is how identify the valkey metirc.**

**What you are looking at**

- **Explore → Metrics** with a Redis-compatible metric (example: `redis_clients_blocked…`) filtered by `host_name`
- Labels on the series include `app_type`, host, and — importantly — `db_system=valkey` and `valkey=true`

**Why it matters**

Valkey is scraped with the Redis receiver (same metric names). The remote config should stamp Valkey scrapes with `valkey` / `db.system=valkey` so you can filter Valkey vs Redis in Coralogix instead of mixing them.

---

### 4. Explore → Metrics — PostgreSQL flowing

Metrics Explore showing PostgreSQL connection metric

**What you are looking at**

- A PostgreSQL metric (example: `postgresql_connection_max…`) with a stable time series
- Resource labels such as `cx_application_name`, `cx_subsystem_name`, and `host_name`

**Why it matters**

Confirms the collector can scrape Postgres with the credentials you passed at install time (`POSTGRES_OTEL_*`) and that data reaches Coralogix after the remote config is Active. Use similar queries for `redis.*`, `elasticsearch.*`, and host metrics from your Activated YAML.