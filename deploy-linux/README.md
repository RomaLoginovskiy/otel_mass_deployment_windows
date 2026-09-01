# Coralogix OTel Collector on Linux (Supervisor mode)

Installs the **Coralogix OpAMP Supervisor + OpenTelemetry Collector** on a Linux host so
collector configuration is owned remotely by Fleet Management. Fleet Management holds the
live config; the Supervisor writes it to `/var/lib/opampsupervisor/effective.yaml`.

This is the Linux counterpart to the Windows fleet path in
[`../docs/fleet-deployment.md`](../docs/fleet-deployment.md).

## Choose an installer

| Installer | Use when | Credentials it expects |
| --- | --- | --- |
| [`install-supervisor-default.sh`](install-supervisor-default.sh) | One host runs several databases, or you want a single command for the whole estate | All database settings together. `POSTGRES_OTEL_PASSWORD` is **always** required |
| [`templates/install-supervisor-by-apptype.sh`](templates/install-supervisor-by-apptype.sh) | Each host runs one database role | Only the selected `APP_TYPE`'s variables. Unrelated ones may be omitted |

Both do the same six things:

| Step | Action |
| --- | --- |
| 1 | Run Coralogix's official installer with `--supervisor` (empty/default local base config) |
| 2 | Tag the agent for Fleet grouping: `app.type`, `env.type` |
| 3 | Collect and validate receiver credentials |
| 4 | Write them to `/etc/opampsupervisor/opampsupervisor.conf` (mode `0600`) |
| 5 | Patch `/etc/opampsupervisor/config.yaml` so those vars reach the collector child (`agent.env`) |
| 6 | Restart `opampsupervisor` and check it is active |

Neither installer installs the databases themselves, and neither pushes a full local
`config.yaml` as base config — a Fleet remote config is the goal.

**Why credentials are needed at install time.** When you later Activate a remote config
containing Redis / Valkey / PostgreSQL / Elasticsearch receivers, the collector needs the
matching endpoint and password variables. Without them it crash-loops or fails to
authenticate, and no database metrics appear.

## Architecture

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
| `/etc/opampsupervisor/collector.yaml` | Local base config (kept minimal) |
| `/var/lib/opampsupervisor/effective.yaml` | **Live** config after a Fleet Activate |

## Prerequisites

On each target host:

- Linux with **systemd**, root / `sudo`
- Outbound HTTPS to Coralogix (`ingress.<your-domain>`)
- `curl`, `python3`
- The databases the remote config scrapes already running, or their endpoints reachable

From Coralogix:

- A **Send-Your-Data** API key
- The domain for your region
- Access to **Integrations → Fleet Management**
- `REMOTE-CONFIGURATION:MANAGE` permission to Activate a configuration

### Domain reference

| Region / UI | `CORALOGIX_DOMAIN` |
| --- | --- |
| India | `app.coralogix.in` |
| US1 | `coralogix.com` |
| EU2 | `eu2.coralogix.com` |

The OpAMP endpoint becomes `https://ingress.<CORALOGIX_DOMAIN>/opamp/v1`. A wrong domain
means the agent never appears in Fleet Management.

## Install

Copy the script to the host and make it executable:

```bash
scp install-supervisor-default.sh ubuntu@<host>:~/
ssh ubuntu@<host>
sed -i 's/\r$//' ./install-supervisor-default.sh   # only if you hit `bash\r` errors (CRLF)
chmod +x ~/install-supervisor-default.sh
```

Use `sudo env ...` so the variables are not dropped by `sudo`.

### Combined — all databases on one host

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
  ./install-supervisor-default.sh
```

Elasticsearch username and password are optional here; leave both empty for an
unauthenticated endpoint. Set both to non-empty values when Elasticsearch requires
authentication — supplying only one is rejected.

### Per-role — one database per host

Use `templates/install-supervisor-by-apptype.sh` and pass only that role's variables.

```bash
# PostgreSQL
sudo env CORALOGIX_PRIVATE_KEY="<key>" CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="postgresql" ENV_TYPE="prod" \
  POSTGRES_OTEL_PASSWORD="<otel_monitor_password>" \
  ./install-supervisor-by-apptype.sh

# Redis
sudo env CORALOGIX_PRIVATE_KEY="<key>" CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="redis" ENV_TYPE="prod" REDIS_ENDPOINT="localhost:6379" \
  ./install-supervisor-by-apptype.sh

# Valkey
sudo env CORALOGIX_PRIVATE_KEY="<key>" CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="valkey" ENV_TYPE="prod" VALKEY_ENDPOINT="localhost:6380" \
  ./install-supervisor-by-apptype.sh

# Elasticsearch (credentials required for this role)
sudo env CORALOGIX_PRIVATE_KEY="<key>" CORALOGIX_DOMAIN="eu2.coralogix.com" \
  APP_TYPE="elasticsearch" ENV_TYPE="prod" \
  ELASTICSEARCH_ENDPOINT="http://localhost:9200" \
  ELASTICSEARCH_USERNAME="elastic" ELASTICSEARCH_PASSWORD="<password>" \
  ./install-supervisor-by-apptype.sh
```

## Environment variables

### Always required

| Variable | Description |
| --- | --- |
| `CORALOGIX_PRIVATE_KEY` | Send-Your-Data API key |
| `CORALOGIX_DOMAIN` | Region domain, e.g. `eu2.coralogix.com` |

### Fleet labels

| Variable | Default | Sets Supervisor attribute |
| --- | --- | --- |
| `APP_TYPE` | `databases` | `app.type` |
| `ENV_TYPE` | `databases` | `env.type` |

`ENV_TYPE` defaults to `databases`, not to an environment name. Set it explicitly.

`APP_TYPE` accepts `postgresql` (or `postgres`), `redis`, `valkey`, `elasticsearch` (or
`elastic`, `es`), and `databases` (or `all`, `mixed`).

### Receiver credentials

`install-supervisor-by-apptype.sh` requires only the rows matching the selected
`APP_TYPE`. `install-supervisor-default.sh` always requires `POSTGRES_OTEL_PASSWORD`.

| Variable | Default | Required for `APP_TYPE` |
| --- | --- | --- |
| `POSTGRES_OTEL_PASSWORD` | — | `postgresql`, `databases` |
| `POSTGRES_ENDPOINT` | `localhost:5432` | optional |
| `POSTGRES_OTEL_USER` | `otel_monitor` | optional |
| `POSTGRES_OTEL_DATABASE` | `appdb` | optional |
| `REDIS_ENDPOINT` | `localhost:6379` | optional |
| `REDIS_PASSWORD` | empty | optional |
| `VALKEY_ENDPOINT` | `localhost:6380` | optional |
| `VALKEY_PASSWORD` | empty | optional |
| `ELASTICSEARCH_ENDPOINT` | `http://localhost:9200` | optional |
| `ELASTICSEARCH_USERNAME` | empty | `elasticsearch` |
| `ELASTICSEARCH_PASSWORD` | empty | `elasticsearch` |

For `APP_TYPE=databases`, the Elasticsearch credentials are optional but must be supplied
as a pair — both set, or both empty.

## Fleet Management

### Create and Activate a remote configuration

1. **Integrations → Fleet Management → Configurations**
2. **Create** a configuration group, e.g. `linux-redis-prod`
3. **Agent selector:** match the labels set at install time, e.g. `app.type = redis` and
   `env.type = prod`
4. Paste or upload the collector YAML for that role:

   | `APP_TYPE` | Remote config to Activate |
   | --- | --- |
   | `redis` | [`templates/redis.yaml`](templates/redis.yaml) |
   | `valkey` | [`templates/redis_valkey.yaml`](templates/redis_valkey.yaml) |
   | `postgresql` | [`templates/postgress.yaml`](templates/postgress.yaml) |
   | `elasticsearch` | [`templates/elasticsearch.yaml`](templates/elasticsearch.yaml) |
   | `databases` | [`config.yaml`](config.yaml) |

5. Use **Preview → Agent list** and confirm only the intended hosts match
6. **Activate**, then ensure **Remote configuration** is enabled on the agent

> **Valkey.** OpenTelemetry has no dedicated Valkey receiver. Valkey is scraped with the
> `redis` receiver and therefore emits Redis metric names. `redis_valkey.yaml` stamps
> `valkey=true` and `db.system=valkey` via its `resource/valkey` processor, so filter on
> `db_system=valkey` to separate Valkey series from Redis.

## Verify

### On the host

```bash
sudo systemctl status opampsupervisor
sudo grep endpoint /etc/opampsupervisor/config.yaml
sudo grep -A6 non_identifying_attributes /etc/opampsupervisor/config.yaml
sudo tail -n 50 /var/log/opampsupervisor/opampsupervisor.log
```

Expect the service **active (running)**, an endpoint like
`https://ingress.eu2.coralogix.com/opamp/v1`, the `app.type` / `env.type` attributes you
passed, and a `Connected to the OpAMP server.` log line.

After Activating a configuration:

```bash
sudo wc -l /var/lib/opampsupervisor/effective.yaml   # non-empty
sudo head -n 40 /var/lib/opampsupervisor/effective.yaml
curl -s http://127.0.0.1:8888/metrics | head -30     # Prometheus text, not empty
```

The collector child should stay up rather than restarting every few seconds.

### In Coralogix

1. **Integrations → Fleet Management → Agents** — find the hostname, then **Group by**
   `app.type` or `env.type`.
2. **Explore → Metrics** — search for series from the Activated config, e.g. `redis.*`,
   `postgresql.*`, `elasticsearch.*`, or host metrics.

If the agent does not appear within a few minutes, check the domain, the API key and the
account it belongs to, outbound 443, and the supervisor log for `401` / `403`.

## Rollout

1. Decide the label scheme — `APP_TYPE` for the database role, `ENV_TYPE` for environment.
2. Install on each host with the correct labels and only that role's credentials.
3. Create one Fleet configuration group per label combination you want to control
   independently.
4. Preview the matching agents, then Activate.
5. New hosts joining with the same labels match the active selector automatically.

| Host role | `APP_TYPE` | `ENV_TYPE` | Fleet config group | Remote config |
| --- | --- | --- | --- | --- |
| Redis nodes | `redis` | `prod` | `linux-redis-prod` | `templates/redis.yaml` |
| Valkey nodes | `valkey` | `prod` | `linux-valkey-prod` | `templates/redis_valkey.yaml` |
| Postgres nodes | `postgresql` | `prod` | `linux-postgres-prod` | `templates/postgress.yaml` |
| Elasticsearch nodes | `elasticsearch` | `prod` | `linux-es-prod` | `templates/elasticsearch.yaml` |
| Mixed DB host | `databases` | `prod` | `linux-databases-prod` | `config.yaml` |

## Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `/usr/bin/env: 'bash\r': No such file or directory` | Windows CRLF line endings | `sed -i 's/\r$//' ./<script>.sh`, then re-run |
| `CORALOGIX_PRIVATE_KEY: Set CORALOGIX_PRIVATE_KEY` under sudo | `sudo` dropped the environment | Use `sudo env VAR=... ./<script>.sh` |
| `POSTGRES_OTEL_PASSWORD is required when APP_TYPE=postgresql` | Password not passed for that role | Include `POSTGRES_OTEL_PASSWORD` for `postgresql` and `databases` |
| `ELASTICSEARCH_USERNAME is required when APP_TYPE=elasticsearch` | Elasticsearch credentials not passed | Supply non-empty username **and** password |
| Agent not in Fleet Management | Wrong domain, key or network | Check the OpAMP endpoint and the supervisor log for connect/auth errors |
| `missing password` / collector exit code 1 | Credentials not reaching the collector, or the remote YAML expects a database this host did not configure | Re-run with the correct `APP_TYPE` variables; Activate a YAML matching that role |
| Elasticsearch authentication error | Credentials missing or invalid | Re-run with matching username and password; leave both empty only for an unauthenticated endpoint |
| `journald` / `_SYSTEMD_UNIT` error | Remote YAML includes `journald` on a host that rejects it | Use a role YAML without `journald` |
| `effective.yaml` empty / `AllowNoPipelines` | No remote config Activated | Create and Activate a configuration; enable Remote configuration |
| `:8888/metrics` empty | Collector not running pipelines | Fix credentials, Activate a remote config, confirm the collector child stays up |
| Metrics missing in the UI but local `:8888` works | Exporter domain/key mismatch in the remote YAML | Align `domain` and key in the Activated config with your account |

```bash
sudo systemctl status opampsupervisor
sudo journalctl -u opampsupervisor -n 100 --no-pager
sudo tail -n 100 /var/log/opampsupervisor/opampsupervisor.log
sudo head -80 /var/lib/opampsupervisor/effective.yaml
curl -s http://127.0.0.1:8888/metrics | head -30
```

## Security

- Prefer `sudo env ...`; do not paste API keys into tickets or chat.
- `/etc/opampsupervisor/opampsupervisor.conf` is mode `0600` (root-only).
- Rotate any key that was exposed.
- Demo stacks often disable Elasticsearch security. Do not carry that into a production
  remote config unchanged.

## Reference files

| File | Purpose |
| --- | --- |
| `install-supervisor-default.sh` | Combined installer; expects all database variables together |
| `templates/install-supervisor-by-apptype.sh` | `APP_TYPE`-scoped installer; expects only that role's variables |
| `config.yaml` | Mixed metrics/logs remote config, for `APP_TYPE=databases` |
| `templates/redis.yaml`, `redis_valkey.yaml`, `postgress.yaml`, `elasticsearch.yaml` | Role-specific remote configs to Activate in Fleet |

## Screenshots

Expected Coralogix UI after install, remote-config Activate, and metrics flowing.

**Fleet Management → Configurations.** A configuration group with version history; *Active*
marks the version matching agents should run. The green/amber/red counts show how many
agents applied it. Activate a new version to roll out a change; keep older versions
inactive for rollback.

<img alt="Fleet Management Configurations list showing a configuration group with three versions and per-agent status counts" src="https://github.com/user-attachments/assets/1c745c4f-e2bc-4278-8e6a-e41ca221c087" />

**Agent selector and preview.** Selector rules (left/centre) and the hosts currently
matching them (right). Always check Preview before Activate so a config does not reach the
wrong fleet.

<img alt="Configuration editor showing agent selector rules alongside a preview list of matching agents" src="https://github.com/user-attachments/assets/e247dc5a-d97b-4687-9b66-9e7098492b73" />
<img alt="Fleet Management configuration group with agent selector and OTel YAML editor" src="https://github.com/user-attachments/assets/394b3031-2bf4-448a-aa0e-b4a41eeeb467" />
<img alt="Fleet Management agent list showing live agents with version and pipeline columns" src="https://github.com/user-attachments/assets/fb229f3f-bc98-44da-833f-0cdeffc82a0a" />

**Explore → Metrics, Valkey.** A Redis-named metric carrying `db_system=valkey` and
`valkey=true`, which is how Valkey series are told apart from Redis.

<img alt="Metrics Explore showing a Redis-named metric labelled db_system=valkey" src="https://github.com/user-attachments/assets/87502577-ff03-4f0f-925e-53dcceec5170" />

**Explore → Metrics, PostgreSQL.** A PostgreSQL connection metric with a stable series,
confirming the collector scrapes Postgres with the credentials passed at install time.

<img alt="Metrics Explore showing a PostgreSQL connection metric time series" src="https://github.com/user-attachments/assets/ec2682b7-4508-4290-a13f-f54e04c426a8" />
