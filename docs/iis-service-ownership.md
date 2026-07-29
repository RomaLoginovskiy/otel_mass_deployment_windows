# IIS → Coralogix Service Ownership

How this repo populates the **Service** ownership attribute for a Windows/IIS host in
Coralogix Infrastructure Explorer, which resource-attribute keys are used, and the exact
value format — with the empirical test results that chose them.

## What it does

A bare Windows/IIS host is not an EC2/Azure instance and not a Kubernetes workload, so
Coralogix cannot read Service ownership from cloud tags or k8s labels. The only remaining
path is **runtime discovery** — Coralogix reads resource attributes off the host telemetry
and its Infrastructure-Explorer host **entity**.

The collector therefore stamps the name(s) of the service(s) running on IIS onto the
host-entity/log telemetry, under a set of ownership keys, so that Infrastructure Explorer →
Hosts → *host* → **Ownership → Service** is populated. On a host running several IIS apps,
the value is a multi-item list so each app appears as a distinct Service value.

## Which keys are used

Stamped by the `transform/iis_service_labels` processor (7 keys). All were **verified to
resolve to Service ownership and to split a multi-value array into distinct items**:

| Key | Resolves to Service ownership | Multi-app array splits |
| --- | --- | --- |
| `service` | ✅ | ✅ |
| `tags.service` | ✅ | ✅ |
| `tags.cx_svc` | ✅ | ✅ |
| `tags.CX_SERVICE_NAME` | ✅ | ✅ |
| `cx.infra.labels.service` | ✅ | ✅ |
| `cx.infra.labels.cx_svc` | ✅ | ✅ |
| `cx.infra.labels.CX_SERVICE_NAME` | ✅ | ✅ |

All seven resolve to the **same** Service ownership attribute, so Coralogix merges and
de-duplicates them — the set is intentionally redundant for robustness. The minimal
equivalent is the single OTel-standard key `service`.

### Keys that were tested and dropped

| Key | Result |
| --- | --- |
| `cx_service` (bare) | ❌ **ignored** by Service ownership |
| `CX_SERVICE_NAME` (bare) | ❌ **ignored** (this is a cloud-tag-only key — AWS EC2 / Azure VM — and does not resolve via runtime discovery on a bare host) |

> Note: `cx_svc` is not a documented Coralogix key, but under the `tags.` / `cx.infra.labels.`
> prefixes it still resolved in testing, so it is kept for coverage.

## Value format

- The machine environment variable **`CX_IIS_SERVICES`** holds the distinct IIS service
  name(s), **comma-joined** — e.g. `Default Web Site,SimpleWebApp`. It is produced by
  `Get-IISServiceLabelValue -Map $svcMap` in `deploy/Resolve-IISServiceNames.ps1` and set by
  the deploy scripts (`deploy/Instrument-IIS.ps1`, `scripts/deploy-app.ps1`). The `$svcMap`
  passed in is the exact `Get-IISServiceMap` result whose `.ServiceName` is also assigned as
  each app's `OTEL_SERVICE_NAME` — see **Alignment** below.
- In the collector each key is set to an **OpenTelemetry array**, by splitting that env
  value on the comma:

  ```
  set(resource.attributes["service"], Split("${env:CX_IIS_SERVICES:-}", ","))
  ```

- Resulting attribute value (OTLP array of strings):

  ```json
  ["Default Web Site", "SimpleWebApp"]
  ```

  A single-app host yields a one-element array `["SimpleWebApp"]`.

**Why an array, not a comma-string:** a single comma-joined string
(`"Default Web Site,SimpleWebApp"`) resolves to **one** Service value that matches no
individual service, so APM/service correlation cannot select a single service. An array
resolves to **multiple discrete** Service values (one per app). Verified: array values split
into separate items in ownership.

**Per-signal rendering (informational):**
- **Logs / host entity** (where ownership is resolved): the value stays a genuine array in
  `$d.resource.attributes` — `["Default Web Site","SimpleWebApp"]`.
- **Metrics** (not used here): a resource-attribute array collapses to a single comma-string
  label because Prometheus label values are single strings. This does not affect ownership,
  which is resolved from the entity, not metric labels.

## Alignment with APM service names

Each host's **Service ownership** items are **exactly the per-app `OTEL_SERVICE_NAME`**
(the APM service names). This is guaranteed by a single source, not by coincidence:

- `deploy/Instrument-IIS.ps1` (and `scripts/deploy-app.ps1 -InstrumentAllApps`) build the app
  list **once** with `Get-IISServiceMap`. Each record's `.ServiceName` is assigned as that
  app's `OTEL_SERVICE_NAME` (pool env or `web.config`).
- The records whose assignment **succeeded** are passed to `Get-IISServiceLabelValue`, which
  produces `CX_IIS_SERVICES` (distinct `.ServiceName`, comma-joined). The collector splits it
  into the ownership array.
- Therefore `set(CX_IIS_SERVICES) == set(OTEL_SERVICE_NAME across apps)`. In the single-app
  `deploy-app.ps1` path, `CX_IIS_SERVICES = $ServiceName`, which is exactly that pool's
  `OTEL_SERVICE_NAME`.

> **Succeeded, not merely attempted.** Some apps cannot be named at all: a shared-pool app
> with no `web.config`, or a classic ASP.NET Framework app with no `<aspNetCore>` element to
> write into. Those are **excluded** from `CX_IIS_SERVICES`. Including them (which the script
> used to do) advertised ownership of a name nothing reports under and made the doctor report
> `CX_IIS_SERVICES_DRIFT` **permanently**, since re-running reproduced the same value. See
> [`iis-e2e-matrix.md`](iis-e2e-matrix.md).
>
> **And instrumentable, not merely nameable.** A second exclusion sits in front of the first:
> an app is only named if its runtime classifies as ASP.NET Core or ASP.NET Framework. A static
> site, a native/ISAPI handler, PHP or Node behind IIS, a URL-Rewrite reverse proxy, or an app
> whose runtime cannot be determined is skipped outright — .NET auto-instrumentation emits
> nothing for it, so claiming it would point Service ownership at telemetry that never arrives.
> This used to bite whenever such an app had a pool to itself: naming was decided by pool arity
> alone, so a dedicated pool was enough to get named and claimed. The membership rule is now
> **named AND .NET**, which is strictly narrower than before — it can only ever under-claim
> further, never start over-claiming. `Test-Agent.ps1` applies the identical filter when it
> rebuilds the expected set; the two must change together.
>
> **So the ownership list can be a subset.** An excluded ASP.NET Framework app still reports —
> the instrumentation auto-detects `SiteName\VirtualPath` — so it appears in APM while the host
> does not claim it. That is deliberate and one-directional: under-claiming costs one missing
> ownership item, over-claiming costs permanent drift. To bring such an app under management,
> give it a dedicated app pool so the pool variable can carry a name we chose.

Result: an APM service (e.g. `SimpleWebApp`) always matches one of its host's Service-ownership
items, so APM ↔ infrastructure resource correlation can select a single service.

## Config management (remote)

- The `transform/iis_service_labels` processor is delivered via the **Coralogix Fleet
  Management remote config** (OpAMP), which the supervisor merges on top of the local base.
- The repo collector YAMLs (`deploy/config.supervisor.yaml`,
  `SimpleWebApp/coralogix/config.yaml`) and `iis-service-ownership.collector.yaml` are the
  **reference source** to copy the processor + pipeline wiring into the remote config. The
  automation does **not** push or manage that config; the supervisor's base-stage →
  pull-remote → merge flow is left unchanged.
- The **deploy scripts set only the `CX_IIS_SERVICES` env var**. Because a remote config that
  redefines the `logs`/`logs/resource_catalog` pipelines replaces the base's processor list,
  the processor must be present in the **remote** config to take effect in production. (The
  base's copy is used for deterministic *hybrid-mode* tests, where no remote config is
  assigned to the test agent.)

> **Checking this on a host.** `doctor.bat -Only effectiveConfig` reads
> `C:\ProgramData\opampsupervisor\state\effective.yaml` — the **merged** config the collector
> is actually running — and reports `EFFECTIVE_PROCESSOR_MISSING` when
> `transform/iis_service_labels` is absent, or `EFFECTIVE_PROCESSOR_NOT_WIRED` when it is
> defined but not listed in the `logs` / `logs/resource_catalog` pipelines. This is the exact
> failure this section warns about, and from Coralogix it is **indistinguishable** from "the
> env var was never set" — both produce blank ownership. The check is a text match (no YAML
> parser in PS 5.1) with comment lines excluded; it can confirm the name is present and
> inside the pipeline block, not that the processor is semantically correct.

## Scope (pipelines)

Wired into the **logs-related pipelines only**:

- `logs` — Windows Event Log + IIS access logs (host/app logs).
- `logs/resource_catalog` — the Infrastructure-Explorer host **entity** (the pipeline that
  drives ownership).

It is **not** in `traces` or `metrics`. Because both target pipelines carry the *logs*
signal, the processor defines only `log_statements`. It is guarded so a host with no IIS
services (`CX_IIS_SERVICES` empty) is left untouched.

## Processor (as deployed)

From `deploy/config.supervisor.yaml` and `SimpleWebApp/coralogix/config.yaml` (identical):

```yaml
  transform/iis_service_labels:
    error_mode: silent
    log_statements:
    - context: resource
      conditions:
      - '"${env:CX_IIS_SERVICES:-}" != ""'
      statements:
      - set(resource.attributes["service"], Split("${env:CX_IIS_SERVICES:-}", ","))
      - set(resource.attributes["tags.service"], Split("${env:CX_IIS_SERVICES:-}", ","))
      - set(resource.attributes["tags.cx_svc"], Split("${env:CX_IIS_SERVICES:-}", ","))
      - set(resource.attributes["tags.CX_SERVICE_NAME"], Split("${env:CX_IIS_SERVICES:-}", ","))
      - set(resource.attributes["cx.infra.labels.service"], Split("${env:CX_IIS_SERVICES:-}", ","))
      - set(resource.attributes["cx.infra.labels.cx_svc"], Split("${env:CX_IIS_SERVICES:-}", ","))
      - set(resource.attributes["cx.infra.labels.CX_SERVICE_NAME"], Split("${env:CX_IIS_SERVICES:-}", ","))
```

Wired into the two logs pipelines immediately after `resource/environment`:

```yaml
    logs:
      processors: [ ..., resource/environment, transform/iis_service_labels, transform/reduce, transform/iis, batch ]
    logs/resource_catalog:
      processors: [ ..., resource/environment, transform/iis_service_labels, resourcedetection/entity, resourcedetection/region, transform/entity-event ]
```

The full reference collector config is in
[`iis-service-ownership.collector.yaml`](./iis-service-ownership.collector.yaml).

## How it was verified

A per-key proof-of-concept ran 18 disposable Linux collector containers (Docker), each a
distinct Coralogix host entity stamping exactly **one** candidate key:

- 9 `own-<key>` hosts — single unique value per key → which key drives Service ownership.
- 9 `multi-<key>` hosts — a 3-element array per key → whether the array splits into multiple
  Service items.

Result: the 7 keys above populated ownership and split arrays into 3 items; bare `cx_service`
and `CX_SERVICE_NAME` produced no ownership. Data landing was confirmed by DataPrime / PromQL
query against the ingested telemetry; ownership resolution was read from Infrastructure
Explorer.

That POC established **which keys work**, once. To verify a **live** host today, do not
re-run it — use the packaged diagnostics, which check the three things that can independently
break:

| Question | Check |
| --- | --- |
| Is the variable set, and does it match the apps? | `doctor.bat -Only env,iisServiceName` |
| Does a processor actually consume it? | `doctor.bat -Only effectiveConfig` |
| Did Coralogix resolve ownership from the stamped keys? | `scripts/Verify-CoralogixInfraLabels.ps1`, then Infrastructure Explorer (~15 min) |

Only the last one needs a query key and server-side lag; the first two are read-only and
instant on the host.

## Operational notes

- Set `CX_IIS_SERVICES` (machine scope) before the collector starts; a Windows service reads
  the machine environment at start, so restart the collector after changing it.
  The doctor's `env` check reports `CX_IIS_SERVICES_MISSING` when it is unset,
  `CX_IIS_SERVICES_STALE` when it holds a value on a host with no IIS or no IIS apps (a
  leftover from a prior deploy, still being stamped onto that host's telemetry), and
  `CX_IIS_SERVICES_DRIFT` when the value no longer matches the apps actually present.
- On IIS, point the app's `OTEL_EXPORTER_OTLP_ENDPOINT` at `http://127.0.0.1:4318` (not
  `localhost`, which resolves to `::1` first and can silently drop OTLP export). Reported
  per pool as `OTLP_ENDPOINT_LOCALHOST` by `Test-IISInstrumentation.ps1`.
- The alignment guarantee described above is a **construction-time** property — it holds
  because one `Get-IISServiceMap` result feeds both assignments. To confirm it on a **live**
  host, run `doctor.bat -Only iisServiceName`: it reads each app's `OTEL_SERVICE_NAME` back
  from the pool **or** its `web.config` and compares `CX_IIS_SERVICES` against them as a
  **set**. That is the only check that catches sites added or renamed *after* the deploy ran.
  Pass the same `-ServiceNameOverrides` / `-OverridesJson` the install used, or every app
  reports false drift.
- Pass the same **`-RuntimeOverrides` / `-RuntimeOverridesJson`** too, for the same reason and
  with a sharper failure mode: they decide which apps are eligible for the list at all, so an
  install that saw an override and a doctor that did not will disagree about membership and
  report drift no re-run can clear. All three scripts default that parameter to
  `CX_RUNTIME_OVERRIDES_JSON`, so setting the variable machine-wide keeps them in step without
  threading a flag through `deploy.bat` and `doctor.bat`. Note the key space is app identity
  (`Site/`, `Site/api`) — **not** the service-name keys `-ServiceNameOverrides` uses.
- A transform processor applies **per-signal** statement blocks — this one covers only the
  logs signal, so it defines only `log_statements`. (If the label is ever needed on spans or
  metrics, add `trace_statements` / `metric_statements` with the same body and wire the
  processor into those pipelines.)
