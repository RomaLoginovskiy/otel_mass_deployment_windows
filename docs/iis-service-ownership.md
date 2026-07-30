# Service ownership for a Windows host

How a Windows/IIS host gets its **Service** ownership attribute in Coralogix Infrastructure
Explorer: which resource-attribute keys carry it, the exact value format, and how it stays aligned
with the APM service names the same host reports.

## Why runtime discovery

A bare Windows host is not an EC2 or Azure instance and not a Kubernetes workload, so Coralogix
cannot read Service ownership from cloud tags or k8s labels. The remaining path is **runtime
discovery**: Coralogix reads resource attributes off the host's telemetry and its
Infrastructure-Explorer host **entity**.

The collector therefore stamps the names of the services running on the host onto that telemetry
under a set of ownership keys, so **Infrastructure Explorer → Hosts → *host* → Ownership →
Service** is populated. On a host running several applications the value is a multi-item list, so
each application appears as a distinct Service value.

## The keys

The `transform/iis_service_labels` processor stamps seven keys. All seven resolve to the **same**
Service ownership attribute, which Coralogix merges and de-duplicates — the set is intentionally
redundant for robustness, and the minimal equivalent is the single OTel-standard key `service`.

| Key | Resolves to Service ownership | Multi-app array splits |
| --- | --- | --- |
| `service` | yes | yes |
| `tags.service` | yes | yes |
| `tags.cx_svc` | yes | yes |
| `tags.CX_SERVICE_NAME` | yes | yes |
| `cx.infra.labels.service` | yes | yes |
| `cx.infra.labels.cx_svc` | yes | yes |
| `cx.infra.labels.CX_SERVICE_NAME` | yes | yes |

Two keys do **not** work and are deliberately absent:

| Key | Result |
| --- | --- |
| `cx_service` (bare) | Ignored by Service ownership. |
| `CX_SERVICE_NAME` (bare) | Ignored — a cloud-tag-only key (AWS EC2 / Azure VM) that does not resolve via runtime discovery on a bare host. |

`cx_svc` is not a documented Coralogix key, but under the `tags.` and `cx.infra.labels.` prefixes
it does resolve, so it is kept for coverage.

## Value format

The machine variable **`CX_SERVICES`** holds the distinct service names this host claims,
comma-joined. It is the union of the per-workload slices — `CX_IIS_SERVICES` from
`Instrument-IIS.ps1`, `CX_NODE_SERVICES` from the Node instrumenters, `CX_DOTNET_SERVICES` from
the .NET service instrumenter — published by `Install-Agent.ps1`.

**Every writer of a slice must republish the union.** `CX_IIS_SERVICES` / `CX_NODE_SERVICES` /
`CX_DOTNET_SERVICES` are *inputs*; `CX_SERVICES` is the only one the collector reads.
`Install-Agent.ps1` recomputes it at the end of a full install, so the gap appears when an
instrumenter runs **on its own** — the slice gains a name, `CX_SERVICES` keeps the old value, and
the new service has spans in APM while the host claims no ownership for it, with every variable
looking correct. `Instrument-IIS.ps1` and `Instrument-NodePM2.ps1` therefore call the shared
`Update-CxServicesUnion` (`Write-DeployLog.ps1`), and restart the collector when they are not
running under the orchestrator — **the collector reads its environment at process start**, so a
changed value does nothing until it restarts.

> **Setting the variable is not the same as the collector using it.** A host whose **effective**
> config predates `CX_SERVICES` support stamps ownership from `CX_IIS_SERVICES` alone, so every
> non-IIS service is published and claimed by nobody. The effective config is the staged base merged
> with what Fleet Management sends, and it is what `otelcol` actually runs — a newer base config on
> disk does not override it. `Test-Agent.ps1` reports this as `CX_SERVICES_NOT_CONSUMED`, decided
> from the effective config, and says when the fix belongs in the remote config.

> **iisnode apps land in `CX_NODE_SERVICES`, not `CX_IIS_SERVICES`** — even though
> `Instrument-IIS.ps1` is what writes them. `CX_IIS_SERVICES` is the set instrumented by the .NET
> profiler, and `Test-Agent.ps1` rebuilds it with that same .NET-only filter, so a Node service in
> there would report `CX_IIS_SERVICES_DRIFT` permanently. The Node variable is written as a **union**
> with whatever PM2 already published, for the same reason: overwriting would strip the ownership
> label off services that are reporting fine, which reads in Coralogix as those services having
> gone away.

The processor sets each key to an **OpenTelemetry array**, by splitting that value on the comma:

```yaml
set(resource.attributes["service"], Split("${env:CX_SERVICES:-}", ","))
```

A two-application host therefore ends up with:

```json
["Default Web Site", "Orders"]
```

and a single-application host with a one-element array.

**Why an array, not a comma-string.** A single comma-joined string resolves to **one** Service
value that matches no individual service, so APM and service correlation cannot select a single
service. An array resolves to **multiple discrete** Service values, one per application.

Per-signal rendering, for when you go looking in a query:

- **Logs and the host entity** — where ownership is resolved — keep a genuine array under
  `$d.resource.attributes`.
- **Metrics** collapse a resource-attribute array to a single comma-separated label, because
  Prometheus label values are single strings. This does not affect ownership, which is resolved
  from the entity rather than from metric labels.

## Alignment with APM service names

A host's Service-ownership items are **exactly the per-app `OTEL_SERVICE_NAME` values** — the APM
service names. That is guaranteed by construction, not coincidence:

- `Instrument-IIS.ps1` builds the application list **once** with `Get-IISServiceMap`. Each
  record's `.ServiceName` is assigned as that app's `OTEL_SERVICE_NAME`, on the pool or in its
  `web.config`.
- Only the records whose assignment **succeeded** are passed to `Get-IISServiceLabelValue`, which
  produces `CX_IIS_SERVICES`. `Install-Agent.ps1` folds that into `CX_SERVICES`, and the collector
  splits it into the ownership array.

So the ownership set equals the set of service names actually assigned. Two exclusions follow from
"succeeded", and both are deliberate:

- **Nameable, not merely present.** A shared-pool app with no `web.config`, or a classic ASP.NET
  Framework app with no `<aspNetCore>` element to write into, cannot be given a name of our
  choosing. Including it would advertise ownership of a name nothing reports under, and would make
  the doctor report `CX_IIS_SERVICES_DRIFT` **permanently**, because re-running reproduces the same
  value.
- **Instrumentable, not merely nameable.** An app is only named if its runtime classifies as
  ASP.NET Core or ASP.NET Framework. A static site, a native or ISAPI handler, PHP or Node behind
  IIS, a URL-Rewrite reverse proxy, or an app whose runtime cannot be determined is skipped
  outright — .NET auto-instrumentation emits nothing for it. The membership rule is **named AND
  .NET**, and `Test-Agent.ps1` applies the identical filter when it rebuilds the expected set; the
  two must change together.

**The ownership list can therefore be a subset of what the host emits.** An excluded Framework app
still reports, under the auto-detected `SiteName\VirtualPath`, so it appears in APM while the host
does not claim it. The asymmetry is intentional and one-directional: under-claiming costs one
missing ownership item, over-claiming costs permanent drift. To bring such an app under
management, give it a dedicated application pool so the pool variable can carry a chosen name.

See the shared-pool constraints in [single-host.md](single-host.md#known-limitations).

## Where the processor lives

```yaml
transform/iis_service_labels:
  error_mode: silent
  log_statements:
  - context: resource
    conditions:
    - '"${env:CX_SERVICES:-}" != ""'
    statements:
    - set(resource.attributes["service"], Split("${env:CX_SERVICES:-}", ","))
    - set(resource.attributes["tags.service"], Split("${env:CX_SERVICES:-}", ","))
    - set(resource.attributes["tags.cx_svc"], Split("${env:CX_SERVICES:-}", ","))
    - set(resource.attributes["tags.CX_SERVICE_NAME"], Split("${env:CX_SERVICES:-}", ","))
    - set(resource.attributes["cx.infra.labels.service"], Split("${env:CX_SERVICES:-}", ","))
    - set(resource.attributes["cx.infra.labels.cx_svc"], Split("${env:CX_SERVICES:-}", ","))
    - set(resource.attributes["cx.infra.labels.CX_SERVICE_NAME"], Split("${env:CX_SERVICES:-}", ","))
  # second block: same body keyed on CX_IIS_SERVICES, applied only when CX_SERVICES is empty,
  # so a host installed before the union variable existed keeps its IIS ownership.
```

Wired into the two logs-signal pipelines, immediately after `resource/environment`:

```yaml
logs:
  processors: [ …, resource/environment, transform/iis_service_labels, transform/reduce, transform/iis, batch ]
logs/resource_catalog:
  processors: [ …, resource/environment, transform/iis_service_labels, resourcedetection/entity, resourcedetection/region, transform/entity-event ]
```

- `logs` carries Windows Event Log and IIS access logs.
- `logs/resource_catalog` carries the Infrastructure-Explorer host **entity** — the pipeline that
  actually drives ownership.

It is **not** in `traces` or `metrics`. Because both target pipelines carry the logs signal, the
processor defines only `log_statements`, and it is condition-guarded so a host with no services is
left untouched. A transform processor applies **per-signal** statement blocks: if the label is ever
wanted on spans or metrics, add `trace_statements` / `metric_statements` with the same body **and**
wire the processor into those pipelines. Adding the processor to a pipeline without the matching
statement block silently does nothing for that signal.

The authoritative copy is `deploy/config.supervisor.yaml`.
[`iis-service-ownership.collector.yaml`](iis-service-ownership.collector.yaml) is a standalone
snapshot of an earlier base config, kept as a paste source for a remote config; where the two
differ, the file in `deploy/` is current.

## Config is owned remotely

- In supervisor mode the processor reaches production through the **Coralogix Fleet Management
  remote config** (OpAMP), which the supervisor merges on top of the local base.
- The deploy scripts set **only the environment variables**. They never push collector config.
- A remote config that redefines the `logs` or `logs/resource_catalog` pipelines **replaces** the
  base's processor list. The processor must therefore be present in the **remote** config to take
  effect; the base copy only applies when no remote config is assigned to the agent.

> **Checking this on a host.** `CX_DOCTOR_ONLY=effectiveConfig doctor.bat` reads the supervisor's
> merged effective config — what the collector is really running — and reports
> `EFFECTIVE_PROCESSOR_MISSING` when the processor is absent, or `EFFECTIVE_PROCESSOR_NOT_WIRED`
> when it is defined but not listed in a required pipeline. From Coralogix this failure is
> **indistinguishable** from "the variable was never set": both produce blank ownership. The check
> is a text match with comment lines excluded (there is no YAML parser in PowerShell 5.1), so it
> confirms the name is present and inside the pipeline block, not that the processor is semantically
> correct.

## Verify on your host

Three things can break independently, and each has its own check:

| Question | Check |
| --- | --- |
| Is the variable set, and does it match the applications? | `set CX_DOCTOR_ONLY=env,iisServiceName && doctor.bat` |
| Does a processor in the running config actually consume it? | `set CX_DOCTOR_ONLY=effectiveConfig && doctor.bat` |
| Did Coralogix resolve ownership from the stamped keys? | `scripts\Verify-CoralogixInfraLabels.ps1`, then Infrastructure Explorer after ingestion lag |

Only the last needs a query key and tolerates server-side lag; the first two are read-only and
instant on the host.

## Operational notes

- Set the variables **before** the collector starts. A Windows service reads the machine
  environment at start, so restart the collector after changing one — and note that a per-service
  environment block overrides the machine value entirely
  (see [reference/env-vars.md](reference/env-vars.md)).
- The doctor's `env` check reports `CX_IIS_SERVICES_MISSING` when the variable is unset,
  `CX_IIS_SERVICES_STALE` when it holds a value on a host with no IIS applications (a leftover
  still being stamped onto that host's telemetry), and `CX_IIS_SERVICES_DRIFT` when the value no
  longer matches the applications present.
- Point each app's `OTEL_EXPORTER_OTLP_ENDPOINT` at `http://127.0.0.1:4318`, never `localhost` —
  it resolves to `::1` first and OTLP export is dropped silently. Reported per pool as
  `OTLP_ENDPOINT_LOCALHOST`.
- The alignment guarantee is a **construction-time** property. To confirm it on a live host run
  `CX_DOCTOR_ONLY=iisServiceName doctor.bat`: it reads each app's `OTEL_SERVICE_NAME` back from the
  pool or its `web.config` and compares the variable as a **set**. That is the only check that
  catches sites added or renamed *after* the deploy ran.
- Pass the doctor the same `-ServiceNameOverrides` / `-OverridesJson` the install used, or every
  app reports false drift. Pass the same `-RuntimeOverrides` / `-RuntimeOverridesJson` too, with a
  sharper failure mode: they decide which apps are eligible for the list at all, so an install that
  saw an override and a doctor that did not will disagree about membership and report drift no
  re-run can clear. All three scripts default that parameter to `CX_RUNTIME_OVERRIDES_JSON`, so
  setting the variable machine-wide keeps them in step.

## Related

- [reference/env-vars.md](reference/env-vars.md) — `CX_SERVICES` and its per-workload slices
- [reference/exit-codes.md](reference/exit-codes.md) — the ownership and drift findings
- [diagnostics.md](diagnostics.md) — which applications reach the ownership list, and why
- [fleet.md](fleet.md) — assigning the remote config that carries the processor
