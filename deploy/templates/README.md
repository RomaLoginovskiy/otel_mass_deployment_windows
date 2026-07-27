# Windows collector templates (per-workload fragments)

Optional collector configs that layer a single workload's monitoring on top of the supervisor
base (`deploy/config.supervisor.yaml`). Use one **only on a host that actually runs that
workload** — same convention as `deploy-linux/templates/` and the guidance in
`docs/iis-instrumentation.md` ("keep components as separate template fragments layered on the
vanilla config only where that component actually runs").

The supervisor base (host + IIS + Windows signals) is left intact in each template; the fragment
only **adds** a receiver + pipeline. Deploy a template the same way as the base config — pass it
as `-SupervisorCollectorBaseConfig` (or assign it as the Fleet remote config for that host group).

## `rabbitmq.yaml`

Supervisor base **+ RabbitMQ logs and metrics**.

| Addition | What it does |
| --- | --- |
| receiver `rabbitmq` | Node/queue/message metrics via the RabbitMQ **Management plugin** HTTP API. `rabbitmq.node.*` are enabled explicitly (disabled by default in the receiver). |
| receiver `filelog/rabbitmq` | Tails the RabbitMQ log dir (plain-text lines); tags records `messaging.system=rabbitmq`. |
| processor `resource/rabbitmq` | Stamps `messaging.system=rabbitmq` on the metrics pipeline. |
| pipeline `metrics/rabbitmq` | `rabbitmq` receiver → shared resource/env processors → `coralogix`. |
| `logs` pipeline | `filelog/rabbitmq` appended to the existing receivers. |

### Prerequisites
- RabbitMQ **Management plugin** enabled (`rabbitmq-plugins enable rabbitmq_management`) — exposes `:15672`.
- A monitoring-level user. The default `guest`/`guest` only authenticates over **loopback**, so it
  works when the collector runs on the RabbitMQ host itself; a remote scrape needs a real user.

### Env vars (all optional; defaults suit a co-located broker)
| Var | Default | Purpose |
| --- | --- | --- |
| `RABBITMQ_ENDPOINT` | `http://localhost:15672` | Management API URL. |
| `RABBITMQ_USERNAME` | `guest` | Monitoring user. |
| `RABBITMQ_PASSWORD` | `guest` | Monitoring password. |
| `RABBITMQ_LOG_GLOB` | `C:\rabbitmq\log\*.log` | Log files to tail. |

### Test
End-to-end (self-contained Windows container that installs RabbitMQ + runs the collector against
this config, then verifies logs + metrics landed in Coralogix):
```powershell
# from the repo root
./test/docker-win/Run-RabbitmqTest.ps1
```
See `test/docker-win/README.md` (RabbitMQ variant).

> Version note: the OTel `rabbitmqreceiver` README lists tested RabbitMQ 3.8/3.9. The `/api/nodes`
> metrics endpoint is stable on 4.x, but if node metrics come back empty, pin an older RabbitMQ in
> the test image (`choco install rabbitmq --version=<3.12.x>` + matching `erlang`).
