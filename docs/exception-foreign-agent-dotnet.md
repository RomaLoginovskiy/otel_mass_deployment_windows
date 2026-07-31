# Exception: a host running the reference agent cannot take our .NET instrumentation

**Status:** known, measured, not fixable from this deployment. Node.js on such a host **is** covered.

This is the one host shape this deployment does not support, stated precisely so it is recognised
before a rollout rather than diagnosed afterwards from missing data.

## The rule

> On a Windows host where **the reference agent is installed with .NET deep monitoring active**, our
> .NET auto-instrumentation attaches to **nothing**. Only one CLR profiler can attach to a process,
> the reference agent injects at process creation, and it wins. Our **Node.js** instrumentation is unaffected.

## What was measured

`cx-e2e-c1`, Windows Server 2025, the reference agent **1.341.56**, our agent installed **after** it
(2026-07-30). Module scan of every worker and child process, under load:

| Process | Loaded profiler |
| --- | --- |
| `w3wp.exe` (net8, fw48, mixed pool) | `agent-injector.dll`, `agent-iis-module.dll`, `agent-dotnet-profiler.dll` |
| `coreweb.exe` (out-of-process child of the mixed pool) | `agent-dotnet-profiler.dll` |
| any process | `OpenTelemetry.AutoInstrumentation.Native.dll` — **absent everywhere** |

Our registration was **perfect** throughout: `W3SVC`/`WAS` carried our CLSID
`{918728DD-259F-4A6A-AC2B-B85E1B658318}` and all four bitness path variants pointing at our payload.
Registration is not attachment.

Coralogix, same window: the mixed pool's .NET app (`mixedpool`) returned **0 spans**, while its Node
co-tenant (`mixedpool/node`, 6 spans) and the PM2 app (`cx-pm2-fork`, 6 spans) reported normally.

### Three configurations tried, all with the same result

| the reference agent configuration | Our profiler attaches? |
| --- | --- |
| fullstack (default) | no |
| `agentctl --set-monitoring-mode=infra-only --restart-service` | no |
| `infra-only` **after a full host reboot** | no |

`infra-only` is **not** a workaround: `agent-dotnet-profiler.dll` stayed injected into recycled and
post-reboot workers alike.

## How to resolve it — pick one

1. **Exclude the IIS process groups in the reference agent** (keeps both agents installed). In the the reference agent
   tenant, turn off .NET deep monitoring for that host's IIS process groups — *Settings > Monitoring
   > Monitored technologies > .NET*, or a process-group override. Then reboot the host and confirm
   `OpenTelemetry.AutoInstrumentation.Native.dll` appears in `w3wp.exe`. **Untested here** — it needs
   tenant access, and it is the only route that keeps the reference agent monitoring the host while we own .NET.
2. **Uninstall the reference agent** (`…\the reference agent\the reference agent\agent\uninstall.exe --quiet`, then reboot). Our
   .NET instrumentation then works normally. This is what was done on `cx-e2e-c1`.
3. **Accept the split**: leave the reference agent owning .NET and let us instrument only Node.js. Nothing to
   configure — it is the steady state — but the host's `CX_IIS_SERVICES` will claim .NET service
   names that never report, so pass `-RuntimeOverrides` marking those apps `NonDotNet` to stop the
   host advertising ownership it cannot honour.

## How to detect it on a host

```powershell
Get-CimInstance Win32_Process -Filter "Name='w3wp.exe' OR Name='dotnet.exe'" | ForEach-Object {
  $procId = $_.ProcessId
  $m = (Get-Process -Id $procId -EA 0).Modules |
         Where-Object { $_.ModuleName -match 'AutoInstrumentation.Native|the reference agentdotnet' } |
         Select-Object -Expand ModuleName -Unique
  "{0} {1} -> {2}" -f $_.Name, $procId, ($m -join ',')
}
```

`agent-dotnet-profiler.dll` with no `AutoInstrumentation.Native.dll` **is** this exception.

`Test-IISInstrumentation.ps1` reports it as `PROFILER_NOT_LOADED_IN_PROCESS`.

> **Verify that finding before relying on it.** In the run on `cx-e2e-c1` the doctor completed
> (`27 pass, 6 warn, 0 fail`) but emitted **no** `profiler` finding at all, so it is unconfirmed
> whether the check fires. Until that is settled, use the snippet above rather than the doctor's
> verdict — a check that stays silent on this shape is the same false green it was written to close.

## Why it matters beyond this VM

The failure is **silent and reads as healthy**: every environment variable is correct, the collector
is up, the apps serve, and the host simply produces no .NET spans. Without the module check the only
symptom is absence of data, which presents as a Coralogix-side problem. At least one customer
engagement (SGA) runs the reference agent on IIS hosts, so this shape is live, not hypothetical.

## Related

- [iis-service-ownership.md](iis-service-ownership.md) — why a claimed name that never reports is
  worse than no name; the same principle drives `ASPNETCORE_RUNTIME_BELOW_MINIMUM` and
  `FRAMEWORK_CLR2_NOT_INSTRUMENTABLE`.
- [reference/exit-codes.md](reference/exit-codes.md) — `PROFILER_FOREIGN_OWNER`,
  `PROFILER_PATH_FOREIGN`, `PROFILER_NOT_LOADED_IN_PROCESS`.
- [nodejs-pm2.md](nodejs-pm2.md#a-pool-holding-both-a-net-application-and-a-node-application) — the
  Node half, which keeps working with the reference agent present.
