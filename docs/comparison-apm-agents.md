# How this deployment compares to a full-stack APM agent

Written from a reverse-engineering study of **the reference agent** — a commercial full-stack
.NET + Node APM agent for Windows, build 1.341.56. The study corpus is kept **outside this repo**
(notably its `11-INVOCATION-GRAPH.md` and `12-GUARDRAILS-AND-CONFIG.md` notes). The point is not
feature parity — it is knowing precisely where a zero-code OpenTelemetry deployment differs, so a
customer conversation and a rollout plan can both be honest.

## The one structural difference

| | The reference agent | This deployment |
| --- | --- | --- |
| How environment reaches the target | injects its process-wide injector DLL into **every** process and hooks `CreateProcessA`, writing `COR_*`/`CORECLR_*`/`NODE_OPTIONS` into each child **before it starts** | deploy scripts write environment to the **spawner** in advance: IIS pool env, service `Environment` REG_MULTI_SZ, nssm `AppEnvironmentExtra`, winsw XML, pm2 env |
| Reach | any child of any parent, no prior knowledge required | only *known* spawners |
| Restart | needed only for processes that pre-date the agent, and reported per process (`RESTART_REQUIRED`) | always needed; now reported as `PENDING_RESTART` |
| Identity | PGI computed by the host agent **and** recomputed in-process, reconciled through a shared-memory "inproc store" | decided once by the installer and recorded to `instrumentation-state.json` for the doctor to compare |

Everything below follows from that row. **Windows offers no post-start environment injection** — a
child's environment is frozen at `CreateProcess` and the CRT caches it — so the model is not a shortcut,
it is the only option available to a script-only deployment. What it costs is reach, and the work has
been to make the edges visible rather than to pretend they are not there.

## What we now do that the reference agent also does

| Behaviour | The reference agent's version | Ours |
| --- | --- | --- |
| Refuse unsupported runtimes | `Node.js version %d.%d.%d not supported`; extensionless gated ≥18.19/≥20.10 | `NODE_RUNTIME_BELOW_MINIMUM`, `NODE_ESM_RUNTIME_UNSUPPORTED`, `NODE_EXTENSIONLESS_UNSUPPORTED`, per target |
| Skip tool processes | a `[blocklist]` section in its process-agent config file, app + exe filters | `deploy/cx-node-blocklist.txt`, anchored patterns, plus built-in defaults |
| Skip debugged processes | `Nodejs has a debug option set` | `--inspect`/`--inspect-brk`/`--inspect-port` → skipped, rule named |
| Skip REPL/eval shapes | argv table gates `-e`, `--eval`, `--print`, `--interactive` | same set; "no entry script" is an answer, not a failure |
| Resolve the entry script properly | argv walk skipping `-r`/`--require` and their values | `Get-CxNodeEntryScript`, same approach, incl. extensionless |
| Classify runtime from loaded modules | reads `\MSCOREE.DLL`/`\CLR.DLL`/`\CORECLR.DLL` from outside the process | `Get-CxClrFlavorFromModules`, used to settle `Unknown` verdicts |
| Detect other APM agents up front | 45 `OTHER_AGENT_*`, partly by module name | pre-flight probe in `Detect-Workloads`, published as `workload.foreign_apm`; signatures in `deploy/cx-foreign-apm.json` (one table, read by both the probe and the doctor's in-process module scan) |
| Restart-required detection | process creation time vs install time | `PENDING_RESTART`, with the per-shape remedy |
| Refuse another tenant's pipeline | `DIFFERENT_TENANT` | refuses to overwrite an off-box OTLP endpoint without `-ForceEndpoint` |
| Disable itself after a failed check | `GLOBAL_HOOKING_STATUS_DISABLED_{SANITYCHECK,RECOVERY}` and refuses silent re-enable | post-write sanity check → revert from manifest → per-target latch honoured on the next run |
| Rule-based inclusion and naming | `INJECTION_RULE_TYPE_{INCLUDE,EXCLUDE}` × 10 match operators, evaluated per agent type and group | `cx-instrument-rules.json`: ordered rules, first match wins, 9 operators, plus a host kill switch |
| Per-process decision reporting | `AGENT_INJECTION_STATUS_*` / `SUPPRESSION_REASON_*` | `processStatus` rows: `INJECTED` / `FOREIGN_PROFILER` / `NOT_INJECTED` / `NO_CLR` / `SCAN_FAILED` |

## What the reference agent does that we deliberately do not

**Rejected, with reasons** — so these are not re-proposed:

- **IFEO `Debugger` launcher for `node.exe`** — the only script-only way to reach a process whose parent
  we cannot write to. Rejected: it is global per image name (every `node.exe` on the host), lives in a
  separate WOW64 registry hive, is skipped for images on network shares, breaks real debugging, and needs
  a launcher executable we do not ship.
- **`AppInit_DLLs` / `AppCertDlls` / any hooking DLL** — `AppInit_DLLs` never loads in `node.exe` (it has
  no user32 import), and the others mean shipping and signing an injector. That is rebuilding the
  reference agent's process-wide injector, which is a different product.
- **WMI `Win32_ProcessStartTrace`, ETW, scheduled task on process start** — all fire *after* the child's
  environment block exists. Observation only; they can never inject.
- **Post-start environment injection** — no supported mechanism on Windows. This is why `PENDING_RESTART`
  is a first-class finding rather than something we work around.
- **Notification profilers for coexistence** — `CORECLR_ENABLE_NOTIFICATION_PROFILERS` exists but forbids
  IL rewriting, and the OTel native profiler needs `SetILFunctionBody`. Not a path.

**Out of scope by design:** Azure App Service, Windows containers, AWS Lambda, RUM / browser
instrumentation (the reference agent's IIS native module injects a JS agent into HTML responses; we do
not), method-level sensors, live debugging, and cluster-pushed per-sensor configuration.

## Signal coverage: the honest delta

The reference agent ships ~130 `Introspection.*` sensor assemblies. The naive comparison ("they have WCF,
MSMQ, Remoting, IBM MQ, MassTransit, Cosmos…") **overstates the gap**, because several of those sensors
ship **disabled** — measured in its `any/dotnet/runtimeConfiguration`:

| Sensor | Shipped default |
| --- | --- |
| `dotnet.logging`, `dotnet.remoting`, `dotnet.messaging.amqp`, `dotnet.messaging.amqpreceiveentrypoint`, `dotnet.nosql.mongodb` | **`enabled=false`** |
| `dotnet.agentcore`, `default`, `httptagging`, `threadtagging`, `wcf`, `wcftagging`, `method.detection`, `aspnet`, `exception`, `adonet`, `servicefabric` | enabled |

So the real headline differences are **WCF as first-class**, **exceptions as first-class**, **automatic
method detection**, **live debugging** and **RUM**. Against that, OTel gives vendor-neutral OTLP, per-app
control, and no IL-rewriting risk.

On the Node side the reference agent covers log enrichment for pino/winston/bunyan/log4js,
`undici`/`fetch`, HTTP/2, route naming for express/fastify/koa/restify/connect, and per-channel
propagation switches. Our coverage is whatever `@opentelemetry/auto-instrumentations-node` bundles, which
overlaps heavily but is not identical.

## Coexistence: the case that matters most

Only **one** `ICorProfilerCallback` can attach to a process. On a host where the reference agent has .NET
deep monitoring active, our .NET auto-instrumentation attaches to **nothing** — measured, three
configurations tried, its infra-only mode included. Full detail and the four ways out are in
[exception-foreign-profiler.md](exception-foreign-profiler.md).

The measured good news: **startup-hooks-only works**. With `CORECLR_ENABLE_PROFILING=0` and
`DOTNET_STARTUP_HOOKS` + `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES` left in place, ASP.NET Core request spans
still flow (31 spans, query-confirmed, profiler provably absent from the worker). That converts a total
.NET loss into a partial one for .NET **Core**; Framework has no startup hooks and stays dark. The
coverage delta beyond ASP.NET Core is **not yet measured** — the probe app used serves only `/ping`, so
nothing exercised HttpClient or SqlClient.

Worth knowing: the reference agent is *built* to tolerate an OTel SDK in-process. It ships
`FOREIGN_TRACER_SYSTEM_OPENTELEMETRY`, an `OpenTelemetryInventory` config class,
`Introspection.OpenTelemetry.Api-OpenTelemetry.Api.dll`, and a flag literally named
`optionSuppressOtelDoubleTracedSpansDotnet`. The conflict is over the profiler slot, not over
OpenTelemetry existing.

## Operational surface

The reference agent ships a control CLI with **56 verbs**, every one a symmetric get *and* set —
monitoring mode, auto-injection, host tags/group, network zone, deployment metadata, version management.
Ours is scripts plus machine environment variables plus flags, with the decision record and rule file as
the durable state. A single operator get/set surface is the remaining gap (plan item X-7).

One detail worth copying that we have not: its watchdog distinguishes a **suspended VM** from a hung
agent (*"Potential suspension detected, resetting heartbeat timeout counter"*). Collector failure actions
here should not treat a VM resume as a failure — see [fleet.md](fleet.md).

## Related

- [exception-foreign-profiler.md](exception-foreign-profiler.md) — the profiler-slot conflict, measured
- [reference/exit-codes.md](reference/exit-codes.md) — every finding code, including the ones added from
  this comparison
- the study corpus's `11-INVOCATION-GRAPH.md` and `12-GUARDRAILS-AND-CONFIG.md` notes — the evidence
  base, kept outside this repo
