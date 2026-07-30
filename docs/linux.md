# Linux database hosts

Installs the **Coralogix OpAMP Supervisor + OpenTelemetry Collector** on a Linux host so its
collector configuration is owned **remotely** by Fleet Management — the same pattern as the Windows
fleet path. Intended for database servers: Redis, Valkey, PostgreSQL, Elasticsearch.

The installer lives at [`../deploy-linux/install-supervisor-default.sh`](../deploy-linux/install-supervisor-default.sh).
Everything is driven by environment variables; there are no positional arguments.

## What the installer does

| Step | Action |
| --- | --- |
| 1 | Runs Coralogix's official installer with `--supervisor` only, leaving an empty local base config |
| 2 | Tags the agent for Fleet grouping: `app.type`, `env.type` |
| 3 | Loads database receiver credentials, from the environment or `/opt/<your-app-folder>/otel-monitor.env` |
| 4 | Writes those credentials to `/etc/opampsupervisor/opampsupervisor.conf` (mode `0600`) |
| 5 | Patches `/etc/opampsupervisor/config.yaml` so the variables are passed into the collector child via `agent.env` |
| 6 | Restarts `opampsupervisor` and confirms it is active |

Credentials matter because the remote config you later activate includes the database receivers.
Without them the collector crash-loops and the internal metrics endpoint stays empty.

It does **not** install the databases, and does not push a full local `config.yaml` as base config —
a remote Fleet configuration is the goal.

## Where things live after install

```text
┌─────────────────────┐     OpAMP      ┌──────────────────────────┐
│  Linux host         │ ◄────────────► │  Coralogix Fleet Manager │
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
| `/etc/opampsupervisor/config.yaml` | Supervisor settings: OpAMP endpoint, Fleet attributes, environment pass-through |
| `/etc/opampsupervisor/opampsupervisor.conf` | Secrets and endpoints, mode `0600` |
| `/etc/opampsupervisor/collector.yaml` | Local base config, kept minimal by the default install |
| `/var/lib/opampsupervisor/effective.yaml` | The **live** config after a Fleet activation |

## Prerequisites

On each host: Linux with **systemd**, root or `sudo`, outbound HTTPS to `ingress.<your-domain>`,
`curl` and `python3`, and the databases reachable if the remote config scrapes them.

From Coralogix: a **Send-Your-Data** API key, the **region** that key belongs to, access to
**Integrations → Fleet Management**, and permission to manage remote configuration
(`REMOTE-CONFIGURATION:MANAGE` to activate).

### Regions

Set `CORALOGIX_REGION=<code>` (or `--region <code>`) and the script resolves the domain as
`<code>.coralogix.com`:

| `CORALOGIX_REGION` | Region | Resolved `CORALOGIX_DOMAIN` |
| --- | --- | --- |
| `us1` | AWS us-east-2 (Ohio) | `us1.coralogix.com` |
| `us2` | AWS us-west-2 (Oregon) | `us2.coralogix.com` |
| `us3` | GCP us-central1 (Iowa) | `us3.coralogix.com` |
| `eu1` | AWS eu-west-1 (Ireland) | `eu1.coralogix.com` |
| `eu2` | AWS eu-north-1 (Stockholm) | `eu2.coralogix.com` |
| `ap1` | AWS ap-south-1 (Mumbai) | `ap1.coralogix.com` |
| `ap2` | AWS ap-southeast-1 (Singapore) | `ap2.coralogix.com` |
| `ap3` | AWS ap-southeast-3 (Jakarta) | `ap3.coralogix.com` |

Set `CORALOGIX_DOMAIN` directly only for a private ingress or a legacy per-region domain
(`app.coralogix.in`, `coralogix.us`, `coralogixsg.com`, …); it overrides `CORALOGIX_REGION` when
both are set. An unknown region code aborts the install — a key used against the wrong region
authenticates nowhere and the agent never appears in Fleet Management. Do not use your team
hostname (`<team>.app.<region>.coralogix.com`) here.

The OpAMP endpoint becomes `https://ingress.<CORALOGIX_DOMAIN>/opamp/v1`. The resolved domain is
written to `opampsupervisor.conf` and passed to the collector as `CORALOGIX_DOMAIN`, because the
config templates reference `${env:CORALOGIX_DOMAIN}` rather than hardcoding a domain.

## Install

### Step 1 — copy the script to the host

```bash
scp install-supervisor-default.sh <user>@<host>:~/
ssh <user>@<host>
chmod +x ~/install-supervisor-default.sh
```

### Step 2 — choose the Fleet labels

| Variable | Meaning | Examples |
| --- | --- | --- |
| `APP_TYPE` | Application or database role | `redis`, `valkey`, `postgresql`, `elasticsearch`, `databases` |
| `ENV_TYPE` | Environment | `prod`, `staging`, `dev` |

Both default to `databases` when unset.

### Step 3 — run it

```bash
sudo env \
  CORALOGIX_PRIVATE_KEY="<send-your-data-key>" \
  CORALOGIX_REGION="eu2" \
  APP_TYPE="postgresql" \
  ENV_TYPE="prod" \
  POSTGRES_OTEL_PASSWORD="<otel_monitor_password>" \
  POSTGRES_OTEL_USER="otel_monitor" \
  POSTGRES_OTEL_DATABASE="appdb" \
  POSTGRES_ENDPOINT="localhost:5432" \
  ./install-supervisor-default.sh
```

`sudo` drops the environment, which is why the variables go through `sudo env`. Passing them any
other way produces `Set CORALOGIX_PRIVATE_KEY` even though you did.

### Step 4 — verify the supervisor locally

```bash
sudo systemctl status opampsupervisor
sudo grep endpoint /etc/opampsupervisor/config.yaml
sudo grep -A6 non_identifying_attributes /etc/opampsupervisor/config.yaml
sudo tail -n 50 /var/log/opampsupervisor/opampsupervisor.log
```

Expect the service **active (running)**, an endpoint of `https://ingress.<domain>/opamp/v1`, your
`app.type` and `env.type` attributes, and a `Connected to the OpAMP server.` log line.

### Step 5 — confirm the agent in Coralogix

**Integrations → Fleet Management → Agents**, find the hostname, then **Group by** `app.type` or
`env.type`. If it does not appear within a few minutes the cause is almost always the domain, the
key, or outbound 443 — the supervisor log will show a `401`, `403` or a connection error.

### Step 6 — create and activate a remote configuration

1. **Integrations → Fleet Management → Configurations**.
2. **Create** a configuration group, for example `linux-redis-prod`.
3. Set the **agent selector** to match your labels, e.g. `app.type = redis` and `env.type = prod`.
4. Paste your collector YAML. [`../deploy-linux/config.yaml`](../deploy-linux/config.yaml) is a
   metrics/logs starting point, and [`../deploy-linux/templates/`](../deploy-linux/templates/)
   holds per-database variants.
5. Use **Preview → Agent list** and confirm only the intended hosts match.
6. **Activate**, and make sure remote configuration is enabled on the agent.

Then, on the host:

```bash
sudo wc -l /var/lib/opampsupervisor/effective.yaml
sudo head -n 40 /var/lib/opampsupervisor/effective.yaml
```

`effective.yaml` should be non-empty and contain your pipelines.

### Step 7 — verify metrics

```bash
curl -s http://127.0.0.1:8888/metrics | head -30
sudo systemctl status opampsupervisor
```

The collector child should stay up rather than restarting every few seconds. In Coralogix,
**Explore → Metrics** should show series from the activated config (`redis.*`, `postgresql.*`, host
metrics).

## Environment variable reference

### Required

| Variable | Description |
| --- | --- |
| `CORALOGIX_PRIVATE_KEY` | Send-Your-Data API key. |
| `CORALOGIX_REGION` | Region code → `<code>.coralogix.com`. Also accepted as `--region <code>`. Required **unless** `CORALOGIX_DOMAIN` is set instead. |
| `CORALOGIX_DOMAIN` | Full ingress domain; overrides `CORALOGIX_REGION`. For a private or legacy per-region domain. |
| `POSTGRES_OTEL_PASSWORD` | Required for the PostgreSQL receiver unless present in `otel-monitor.env`. |

### Fleet labels

| Variable | Default | Supervisor attribute |
| --- | --- | --- |
| `APP_TYPE` | `databases` | `app.type` |
| `ENV_TYPE` | `databases` | `env.type` |

### Receiver endpoints

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

## Rolling out across many hosts

1. Decide the label scheme — `APP_TYPE` for the database role, `ENV_TYPE` for the environment.
2. Install the supervisor on each host with the right labels.
   [`../deploy-linux/templates/install-supervisor-by-apptype.sh`](../deploy-linux/templates/install-supervisor-by-apptype.sh)
   is the same install parameterised by app type, for pushing across a mixed fleet.
3. In Fleet Management create **one configuration group per label combination** you want to control
   independently.
4. Activate updates only on the group you intend, previewing the agent list first.
5. New hosts that join with the same labels match the active selector automatically.

| Host role | `APP_TYPE` | `ENV_TYPE` | Fleet config group |
| --- | --- | --- | --- |
| Redis nodes | `redis` | `prod` | `linux-redis-prod` |
| PostgreSQL nodes | `postgresql` | `prod` | `linux-postgres-prod` |
| Mixed database hosts | `databases` | `prod` | `linux-databases-prod` |

Valkey has no dedicated OTel receiver — it is scraped with the **Redis** receiver, and the metric
names are identical. Have the remote config stamp Valkey scrapes with `db.system=valkey` so the two
can be told apart in Coralogix instead of mixing.

## Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `Set CORALOGIX_PRIVATE_KEY` under `sudo` | `sudo` dropped the environment | Use `sudo env VAR=… ./install-supervisor-default.sh` |
| Agent not in Fleet Management | Wrong domain, key or network | Check the OpAMP endpoint and the supervisor log for connect/auth errors |
| `missing password`, collector exits 1 | Credentials not passed to the collector | Re-run with `POSTGRES_OTEL_PASSWORD` |
| `effective.yaml` empty, or `AllowNoPipelines` | No remote config activated | Create and activate a configuration; enable remote configuration on the agent |
| `:8888/metrics` empty | Collector is running no pipelines | Fix the credentials, activate the remote config, confirm the child process stays up |
| Metrics missing in the UI while local `:8888` works | Exporter, domain or key issue in the remote YAML | Align the `domain` and key in the activated config with your account |

```bash
sudo systemctl status opampsupervisor
sudo journalctl -u opampsupervisor -n 100 --no-pager
sudo tail -n 100 /var/log/opampsupervisor/opampsupervisor.log
sudo head -n 80 /var/lib/opampsupervisor/effective.yaml
curl -s http://127.0.0.1:8888/metrics | head -30
```

## Security

- Prefer `sudo env …`, and keep API keys out of tickets and chat.
- `/etc/opampsupervisor/opampsupervisor.conf` is mode `0600`, root-only.
- Rotate any key that was exposed.
- Keep database and Elasticsearch authentication appropriate for production. Demo stacks often
  disable Elasticsearch security — do not carry that into a production remote config.

## Related

- [`../deploy-linux/templates/README.md`](../deploy-linux/templates/README.md) — the per-database config templates
- [fleet.md](fleet.md) — the Windows equivalent of this runbook
- [reference/cli.md](reference/cli.md) — the Windows command reference
