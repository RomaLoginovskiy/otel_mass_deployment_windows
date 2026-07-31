# Exception: a host running Dynatrace OneAgent cannot take our .NET instrumentation

**Status:** known, measured, not fixable from this deployment. Node.js on such a host **is** covered.

This is the one host shape this deployment does not support, stated precisely so it is recognised
before a rollout rather than diagnosed afterwards from missing data.

## The rule

> On a Windows host where **Dynatrace OneAgent is installed with .NET deep monitoring active**, our
> .NET auto-instrumentation attaches to **nothing**. Only one CLR profiler can attach to a process,
> OneAgent injects at process creation, and it wins. Our **Node.js** instrumentation is unaffected.

## What was measured

`cx-e2e-c1`, Windows Server 2025, OneAgent **1.341.56**, our agent installed **after** it
(2026-07-30). Module scan of every worker and child process, under load:

| Process | Loaded profiler |
| --- | --- |
| `w3wp.exe` (net8, fw48, mixed pool) | `oneagentproc.dll`, `oneagentiis.dll`, `oneagentdotnet.dll` |
| `coreweb.exe` (out-of-process child of the mixed pool) | `oneagentdotnet.dll` |
| any process | `OpenTelemetry.AutoInstrumentation.Native.dll` — **absent everywhere** |

Our registration was **perfect** throughout: `W3SVC`/`WAS` carried our CLSID
`{918728DD-259F-4A6A-AC2B-B85E1B658318}` and all four bitness path variants pointing at our payload.
Registration is not attachment.

Coralogix, same window: the mixed pool's .NET app (`mixedpool`) returned **0 spans**, while its Node
co-tenant (`mixedpool/node`, 6 spans) and the PM2 app (`cx-pm2-fork`, 6 spans) reported normally.

### Three configurations tried, all with the same result

| OneAgent configuration | Our profiler attaches? |
| --- | --- |
| fullstack (default) | no |
| `oneagentctl --set-monitoring-mode=infra-only --restart-service` | no |
| `infra-only` **after a full host reboot** | no |

`infra-only` is **not** a workaround: `oneagentdotnet.dll` stayed injected into recycled and
post-reboot workers alike.

## Partial coverage without the profiler — MEASURED, and it works

**Measured on `cx-e2e-c1`, 2026-07-31, query-confirmed.** OTel .NET auto-instrumentation is only
*partly* native. Its managed half loads through `DOTNET_STARTUP_HOOKS` and, for ASP.NET Core,
`ASPNETCORE_HOSTINGSTARTUPASSEMBLIES` — neither of which needs the CLR profiler slot. So on a host
where another agent owns that slot, ASP.NET Core traces can still be produced.

The experiment, on the `coreweb-net8` pool (in-process ASP.NET Core, net8):

| Step | Result |
| --- | --- |
| Set `CORECLR_ENABLE_PROFILING=0` + `COR_ENABLE_PROFILING=0` on the pool, leave `DOTNET_STARTUP_HOOKS` / `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES` / `OTEL_DOTNET_AUTO_HOME` inherited from W3SVC | — |
| **Negative control** — is our profiler really gone? | worker pid 8272: **229 modules, `OpenTelemetry.AutoInstrumentation.Native` absent, `coreclr.dll` present** |
| Does the app still serve? | **HTTP 200 × 25** — the startup hook did not break it |
| Do spans arrive? (DataPrime, `api.eu1`) | **31 spans**, `serviceName=p21-hooks-only`, `GET /ping` |
| **Positive control** — same app with the profiler restored | `ourNative=True`, spans resume under `coreweb-net8` |

So the answer to "does anything work without the profiler" is **yes, for ASP.NET Core**. That turns the
total loss below into a partial one for **.NET Core apps only** — .NET Framework has no startup hooks,
so `fw48app`-shaped apps stay dark no matter what.

### The coverage delta, measured with a purpose-built probe

A console probe (`C:\cx\probe`, net8) that makes one outbound `HttpClient` GET and one `SqlClient`
connect was run twice against the same collector, identical environment except
`CORECLR_ENABLE_PROFILING`:

| Instrumentation | profiler ON | profiler OFF (startup hook only) |
| --- | --- | --- |
| `System.Net.Http` (HttpClient) | span produced | **span produced** |
| `SqlClient` | **no span** | **no span** |

So **HttpClient survives without the profiler** — measured, not inferred. The SqlClient row proves
nothing either way: the probe's connect failed (no SQL Server on the host) and the instrumentation traces
*commands*, not failed connects, so it produced no span even with the profiler. **Whether SqlClient /
Redis / MongoDB go dark in this mode is still unmeasured** and must not be claimed. Measuring it needs a
reachable database.

> **Correction to the recipe.** Earlier text here (and the plan) listed `DOTNET_ADDITIONAL_DEPS` and
> `DOTNET_SHARED_STORE` as part of the startup-hooks-only variable set. **Measured on v1.16.0-beta.1:
> neither `AdditionalDeps` nor `store` exists in the install**, and pointing those variables at the
> missing directories broke assembly resolution in the first probe run (0 spans). The vendor's own
> `Register-OpenTelemetryForIIS` sets only `DOTNET_STARTUP_HOOKS` and
> `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES` — match that, and set nothing else.

**Now automated:** `Instrument-IIS.ps1 -NoProfiler` (applies at `applicationPoolDefaults`, since the
profiler slot is owned host-wide) and `Instrument-DotNetService.ps1 -NoProfiler` (per service, .NET Core
only — Framework is refused with the reason, because it has no startup hooks).

Upstream does not document or support a startup-hooks-only deployment, so treat this as a degraded
mode with a known-good floor (ASP.NET Core server spans) and an unknown ceiling.

## How to resolve it — pick one

1. **Exclude the IIS process groups in Dynatrace** (keeps both agents installed). In the Dynatrace
   tenant, turn off .NET deep monitoring for that host's IIS process groups — *Settings > Monitoring
   > Monitored technologies > .NET*, or a process-group override. Then reboot the host and confirm
   `OpenTelemetry.AutoInstrumentation.Native.dll` appears in `w3wp.exe`. **Untested here** — it needs
   tenant access, and it is the only route that keeps OneAgent monitoring the host while we own .NET.
2. **Uninstall OneAgent** (`…\dynatrace\oneagent\agent\uninstall.exe --quiet`, then reboot). Our
   .NET instrumentation then works normally. This is what was done on `cx-e2e-c1`.
3. **Accept the split**: leave OneAgent owning .NET and let us instrument only Node.js. Nothing to
   configure — it is the steady state — but the host's `CX_IIS_SERVICES` will claim .NET service
   names that never report, so pass `-RuntimeOverrides` marking those apps `NonDotNet` to stop the
   host advertising ownership it cannot honour.
4. **Run degraded on .NET Core** (see the measurements above). Leave OneAgent owning the profiler slot
   and pass **`-NoProfiler`**: `Instrument-IIS.ps1 -NoProfiler` for pools, or
   `Instrument-DotNetService.ps1 -Services <name> -NoProfiler` for services. That sets
   `CORECLR_ENABLE_PROFILING=0` while keeping `DOTNET_STARTUP_HOOKS`,
   `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES` and `OTEL_DOTNET_AUTO_HOME`, so ASP.NET Core request spans and
   HttpClient spans flow to our collector alongside OneAgent's own tracing. **Framework gains nothing**
   (no startup hooks) — the service path refuses it outright with the reason; for Framework use option
   1, 2 or 3. The bytecode-instrumented libraries (SqlClient, Redis, Mongo, WCF, System.Web) are
   expected not to report and are **unmeasured** — treat them as unknown, not proven absent.

## How to detect it on a host

```powershell
Get-CimInstance Win32_Process -Filter "Name='w3wp.exe' OR Name='dotnet.exe'" | ForEach-Object {
  $procId = $_.ProcessId
  $m = (Get-Process -Id $procId -EA 0).Modules |
         Where-Object { $_.ModuleName -match 'AutoInstrumentation.Native|oneagentdotnet' } |
         Select-Object -Expand ModuleName -Unique
  "{0} {1} -> {2}" -f $_.Name, $procId, ($m -join ',')
}
```

`oneagentdotnet.dll` with no `AutoInstrumentation.Native.dll` **is** this exception.

`Test-IISInstrumentation.ps1` reports it as `PROFILER_NOT_LOADED_IN_PROCESS`.

> **The silence measured on `cx-e2e-c1` has been closed, but not yet re-measured on that host.**
> In that run the doctor completed (`27 pass, 6 warn, 0 fail`) and emitted **no** `profiler` load
> finding at all. Three swallowed failures could each produce that, and which one did was never
> established, so all three now report:
>
> | Was | Now |
> | --- | --- |
> | `Win32_Process` enumeration threw → empty worker list → reported as "no worker is running" | `PROFILER_WORKER_ENUM_FAILED` (warn) — a WMI failure and an idle host are different states |
> | reading one process's modules threw → that process silently dropped from both tallies | `PROFILER_MODULE_SCAN_FAILED` (warn), naming each pid and reason |
> | nothing scanned at all → still fell through to `NOT_LOADED`, i.e. accused on no evidence | `PROFILER_LOAD_UNVERIFIED_SCAN_FAILED` (warn) — absence of evidence is not evidence |
> | a delegated validator crashed → `unknown`, which does not move the exit code → **exit 0** | `CHECK_ERRORED` is now `warn` |
>
> The worker set is also scoped by **parentage** rather than by the name `dotnet.exe`, because the
> process carrying the evidence here was `coreweb.exe` — the app's own ANCM apphost.
>
> `Run-DoctorTest.ps1` D9 asserts that one load verdict is always emitted, so the silent path cannot
> come back unnoticed.
>
> **Re-measured on `cx-e2e-c1` (2026-07-31).** The check now reports, and fixing it surfaced two
> further defects that were both *false reds* — the mirror image of the original problem:
>
> | Defect | Symptom before | Now |
> | --- | --- | --- |
> | `$home` is a PowerShell automatic variable with options **ReadOnly + AllScope**, so `$home = <auto home>` inside a function silently keeps the **user profile path** | every `*_PROFILER_PATH_*` compared against `C:\Users\Administrator` → **8 × `PROFILER_PATH_FOREIGN`, exit=1** on a correctly instrumented host | renamed `$autoHome`; 0 findings, exit 2 |
> | 32-bit PowerShell reading a 64-bit worker's modules returns **count=0 with no exception** (measured: 0 vs 241 from a 64-bit shell) | empty list treated as evidence → `PROFILER_NOT_LOADED_IN_PROCESS`, **exit=1**, on a host where the 64-bit run proved the profiler loaded | empty/ntdll-less list is a failed read → `PROFILER_MODULE_SCAN_FAILED` + `PROFILER_LOAD_UNVERIFIED_SCAN_FAILED` (warn), and the message names Sysnative |
> | scoping the worker set by parentage also caught `conhost.exe` | "1 of 2 scanned" on a fully loaded host | processes with no CLR mapped count in neither tally: "2 of 2 CLR-hosting worker process(es); 1 non-CLR child ignored" |
>
> Note the first defect is **why the original run showed `0 fail`**: `PROFILER_PATH_FOREIGN` only runs
> when the CLSID is ours, and with OneAgent owning the slot `PROFILER_FOREIGN_OWNER` fired instead and
> that block never executed. Uninstalling OneAgent is what exposed it.
>
> Still **not** re-measured: the foreign-profiler-*loaded* case itself. OneAgent has been uninstalled
> from `cx-e2e-c1`, so that shape no longer exists there, and the container can only reproduce the
> foreign *registration* (D7/D8). For a host that genuinely runs another agent, the snippet above
> remains the authority.

## Why it matters beyond this VM

The failure is **silent and reads as healthy**: every environment variable is correct, the collector
is up, the apps serve, and the host simply produces no .NET spans. Without the module check the only
symptom is absence of data, which presents as a Coralogix-side problem. At least one customer
engagement (SGA) runs OneAgent on IIS hosts, so this shape is live, not hypothetical.

## Related

- [iis-service-ownership.md](iis-service-ownership.md) — why a claimed name that never reports is
  worse than no name; the same principle drives `ASPNETCORE_RUNTIME_BELOW_MINIMUM` and
  `FRAMEWORK_CLR2_NOT_INSTRUMENTABLE`.
- [reference/exit-codes.md](reference/exit-codes.md) — `PROFILER_FOREIGN_OWNER`,
  `PROFILER_PATH_FOREIGN`, `PROFILER_NOT_LOADED_IN_PROCESS`.
- [nodejs-pm2.md](nodejs-pm2.md#a-pool-holding-both-a-net-application-and-a-node-application) — the
  Node half, which keeps working with OneAgent present.
