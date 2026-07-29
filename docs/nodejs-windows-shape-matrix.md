# Node.js on Windows — the deployment shapes, and which ones this tooling covers

Sibling of [`iis-e2e-matrix.md`](./iis-e2e-matrix.md), for Node instead of IIS. Every way Node
realistically runs on a Windows fleet host, what the deploy scripts make of each, and **which ones
get zero-code telemetry** — because the expensive failure here was not a wrong answer, it was a
confident silence: a host running 26 PM2 apps, every script reporting success, and no Node
telemetry anywhere.

Executable form: [`test/docker-win/Run-NodeShapesTest.ps1`](../test/docker-win/Run-NodeShapesTest.ps1),
which builds each shape in a Windows container and asserts the rows below. That harness, not this
table, is the source of truth — if they disagree, the table is stale.

```powershell
.\test\docker-win\Run-NodeShapesTest.ps1 -SkipCoralogix              # the matrix, local gates only
.\test\docker-win\Run-NodeShapesTest.ps1 -Only p3-service            # one phase
.\test\docker-win\Run-NodeShapesTest.ps1 -Region eu1                 # + the Coralogix sweep
```

## Supported

| Shape | How it is recognised | Instrumented by |
| --- | --- | --- |
| **PM2, per-user daemon, fork** | `pm2 jlist` answers for the caller; `workload.pm2.hosting=user` | `Instrument-NodePM2.ps1` in-process: per-app `NODE_OPTIONS` + `pm2 restart --update-env` |
| **PM2, per-user daemon, cluster** | same; workers share one app name | ⚠️ **not working — see below.** The env is applied and the app runs, but no telemetry is produced |
| **PM2 as a Windows service** (`pm2-installer` / `pm2-windows-service` / node-windows) | `Win32_Service` whose image path is under `PM2_HOME`, + `<PM2_HOME>\service\index.js` in the process tree. `workload.pm2.hosting=service`, `workload.pm2.owner`, `workload.pm2.home` | same, but `pm2` is invoked **as the daemon's owner** (`Invoke-CxPm2AsOwner`) |
| — owned by `LOCAL SERVICE` / `NETWORK SERVICE` / `SYSTEM` / a gMSA | `Win32_Service.StartName` (`LocalSystem` is the SCM's spelling of SYSTEM) | passwordless logon: scheduled task, else transient service |
| — owned by an **ordinary account** | same | needs `-Pm2OwnerCredential`. Without it the run **refuses with that reason** rather than failing with a logon error |
| **PM2 daemon stopped**, `dump.pm2` on disk | app set read from `dump.pm2`, `Source='dump'`, finding `NODE_PM2_APPS_FROM_DUMP` | naming and reporting work; applying env needs the daemon up |
| **ESM apps** (`"type": "module"`, `.mjs`) | nearest `package.json`, else the extension | `--import` instead of `--require` (Node ≥ 20) |

## Out of scope — reported, never silently assumed

These are real ways to run Node on Windows that this tooling does **not** instrument. The matrix
asserts that each is *reported as such*: no false pass, no crash, no claim of coverage.

| Shape | What the tooling says | Why not covered |
| --- | --- | --- |
| **bare `node.exe`** (scheduled task, startup script, hand-started) | `workload.nodejs` without `workload.pm2`; doctor `skip`/`unknown` | no supervisor to inject env into and restart through. Instrumenting means editing whatever starts it |
| **Node as a Windows service** (node-windows / nssm / winsw, no PM2) | not claimed as PM2 | the env lives in the service definition; changing it is a service reconfigure + restart, not a `pm2 restart` |
| **iisnode** | `Resolve-IISAppRuntime` → Unsupported, `NON_DOTNET_APP_NOT_INSTRUMENTED`, kept out of `CX_IIS_SERVICES` | IIS runs no managed code (nothing for .NET auto-instrumentation) and there is no PM2 (nothing for the Node path). iisnode is also effectively EOL |
| **IIS ARR → PM2 app** | IIS site Unsupported; the **Node** side carries the telemetry | correct division of labour, and SGA's actual architecture. See the trace-continuity note below |

### Two things that look like gaps and are not

**An ARR/rewrite site produces no IIS spans.** It has no managed code, so the .NET profiler has
nothing to attach to. `NON_DOTNET_APP_NOT_INSTRUMENTED` on such a site is the right answer, and the
site is deliberately excluded from `CX_IIS_SERVICES` so host Service-ownership does not claim it.

**ARR does not propagate `traceparent`.** It is a native module, so the backend Node span arrives as
a trace **root** — there is no IIS→Node parent/child link to go looking for unless something
upstream already propagates context.

## What the matrix found

Building it was not a formality. Eleven defects surfaced in code that the fixture unit tests passed,
every one of them the same shape as the original incident — the tooling reporting success while
doing nothing:

| Defect | What it did on a real host |
| --- | --- |
| `Get-CxPm2CommandPath` returned `pm2.ps1` | `CreateProcess` cannot launch a `.ps1`, so every pm2 call returned empty and the tooling said "PM2 manages no apps" on a host running them |
| `Invoke-CxPm2` unbounded (and the doctor's own `pm2 jlist`) | a pm2 call that spawns the God daemon leaves it holding the caller's stdout, so `doctor.bat` prints its whole report and **never returns** — under BatchPatch as much as Docker |
| JSON unescaping by chained `.Replace()` | `\n` inside `…\\node_modules\…` became a newline: paths silently stopped existing, which faked `NODE_REGISTER_PATH_STALE` and disabled the ESM check |
| `NODE_OPTIONS` replaced, not merged | an app's own `--max-old-space-size` disappeared on instrumentation, unreported |
| `Get-CxPm2Apps` returned bare `@()` | PowerShell unrolls it to `$null`, so "answered, no apps" and "could not be read" collapsed into one wrong finding |
| "any node process is running" heuristic | PM2's own idle daemon counted as evidence of apps, so the doctor reported the wrong-daemon finding about the daemon it had just queried |
| service probe required `pm2` **and** `node` in `PathName` | missed `…\pm2\service\pm2.exe` — the exact pm2-installer layout it was written for |
| `sc create binPath=` with embedded quotes | `sc.exe` prints its usage and creates nothing, silently disabling the transient-service fallback |
| run-as-owner working files in `C:\Windows\Temp` | `LOCAL SERVICE` is in none of that ACL, so the task ran, could not write its sentinel, and the wait timed out with nothing to explain it — the run-as-owner path would have failed on SGA's own account |
| `.\name` owner from `Win32_Service.StartName` | not resolvable by `LookupAccountName`, so `icacls` / `New-ScheduledTaskPrincipal` / `sc obj=` fail with Win32 1332 for any ordinary-account daemon |
| `Set-Item Env:\X -Value ''` to clear env | Set-Item refuses an empty value and, silenced, invisibly: uninstall reported success while leaving every app instrumented |

Each is now pinned by an assertion in `test/Test-Pm2Topology.ps1` as well as by a shape here, so a
regression fails in about a second rather than on a customer host.

## Open: PM2 cluster mode produces no telemetry

Confirmed by the matrix, and narrowed by a direct probe. A cluster app is instrumented as far as
every check can see — `NODE_OPTIONS` is on the app, the doctor passes it, the workers are online and
serving — and **no spans exist at all**.

The narrowing that matters: run a cluster app with `OTEL_TRACES_EXPORTER=console`, where the SDK
prints spans to the worker's own stdout and no collector or network is involved. Result: the worker
log carries the app's ordinary `pino` output (so the app is genuinely handling requests) and **zero
`traceId` occurrences**. The same app in **fork** mode, same flags, emits spans immediately.

So this is *not* an exporter, batching or flush problem, which is how it had been assumed: **the OTel
bootstrap never takes effect inside a PM2 cluster worker.** The likely mechanism is how pm2 creates
cluster workers — `cluster.fork()` out of the God daemon, rather than a fresh `node` process that
re-reads `NODE_OPTIONS` — in which case the fix is to deliver the bootstrap through pm2's own
`node_args` / `interpreter_args` (which become the worker's `execArgv`) for cluster apps specifically,
instead of `NODE_OPTIONS`. That is not yet implemented or verified.

Until it is: **treat cluster-mode apps as uninstrumented**, whatever the doctor says about them. A
fork-mode app is the only PM2 exec mode this tooling has actually been shown to instrument
end-to-end. `Run-NodeShapesTest.ps1`'s Coralogix sweep is what keeps this honest — it reports
`shape-user-cluster` as a GAP rather than letting a green doctor imply coverage.

## What a container cannot prove

Stated rather than skipped quietly:

- **Node < 20** (no `--import`, so an ESM app cannot be zero-code instrumented at all). One Node is
  baked per image; the flag-selection rule is pinned by `test/Test-Pm2Topology.ps1` instead.
- **A gMSA-owned daemon** — needs a domain. `Test-CxIsServiceAccount` treats a trailing `$` as
  passwordless, which is the only decision that differs from `LOCAL SERVICE`.

Both mechanisms behind `Invoke-CxPm2AsOwner` *are* exercised in-container: P0 confirms Task
Scheduler and a transient service can each run as `LOCAL SERVICE` there, and prints which one the
run used.

- **The unreachable-daemon condition itself.** In this container an administrator CAN read another
  account's PM2 daemon — pm2's RPC pipe is keyed on `PM2_HOME`, and the container's ACLs are more
  permissive than the SGA host's, where the same query came back empty. So P3 asserts the honest
  weaker property (the service hosting is reported, and an uninstrumented host does not pass) and
  prints whether the daemon was `READABLE` or `UNREACHABLE`; the `NODE_PM2_DAEMON_OWNER_MISMATCH`
  grading is pinned by the unit test, which can stub a provably-unreachable daemon. Claiming the
  matrix reproduces SGA's exact condition would be wrong.
- **iisnode actually serving.** The module installs, but the fixture site returns 500 in this image.
  That is the site's own configuration, not anything under test, so it is reported as a loud
  KNOWN-issue line; the assertions that matter — the site is classified not-instrumentable and stays
  out of `CX_IIS_SERVICES` — do pass.

## Why PM2-as-a-service needed its own support

Everything about that layout defeats a deploy that assumes a per-user daemon, and **none of it
errors** — the failure mode is silence:

| The deploy assumed | What actually happens |
| --- | --- |
| `pm2` is on the deploying account's PATH | `pm2-installer` puts it in `C:\ProgramData\npm`, frequently absent from a fleet tool's PATH |
| `~\.pm2` or `$env:PM2_HOME` resolves for us | the home is `C:\ProgramData\pm2` and belongs to the service account |
| `pm2 jlist` lists the apps | the daemon's IPC pipe belongs to that account; pm2 answers for an empty daemon of **our** own and exits 0 |
| `pm2 restart --update-env` applies the env | it restarts nothing, and reports success |

Detection therefore probes machine-wide (`Win32_Process` command lines, `Win32_Service.StartName`,
`dump.pm2` on disk) instead of asking the caller's own daemon, and the doctor separates the two
cases that used to look identical:

| Finding | Meaning |
| --- | --- |
| `NODE_PM2_DAEMON_NOT_VISIBLE` (unknown) | we could not look. Never a failure |
| `NODE_PM2_DAEMON_OWNER_MISMATCH` (**fail**) | we looked, the apps are **proven** to exist, and this identity cannot reach them |

Full code list: [`agent-diagnostics.md`](./agent-diagnostics.md). Mechanism and rollout guidance:
[`nodejs-pm2-instrumentation.md`](./nodejs-pm2-instrumentation.md).
