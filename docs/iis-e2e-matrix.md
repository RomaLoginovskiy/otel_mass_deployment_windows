# IIS shapes, log layouts, and what needs a fix

What the end-to-end deploy loop covers, what each case proved, and — the reason this
file exists — **every IIS layout that needs a fix or a non-default setting before
telemetry works**.

Run it with:

```powershell
./test/docker-win/Run-E2ELoop.ps1
# one phase or one failure case:  -Case P2   -Case F6
# no Coralogix keys / fast loop:  -SkipTelemetry
```

Unlike `Run-DoctorTest.ps1` (offline, asserts what the diagnostics *say*), this loop
drives the real operator entry points — `deploy.bat`, `doctor.bat` — inside a
disposable Windows container and then confirms the data in Coralogix. Nothing in the
harness re-implements what the deploy scripts do; if that were allowed, the harness
would be testing itself.

## Phases

| | What it does |
| --- | --- |
| **P0** premises | Can the vendor installer fetch the collector **MSI** here? Answering this first turns one environmental limitation into one clear line instead of a cascade of misleading failures. See [below](#the-container-cannot-install-a-collector) — in a Server Core container it cannot, so collector-dependent assertions are **skipped**, not failed. |
| **P1** install | `deploy.bat` with `CX_NO_SUPERVISOR=1`; asserts the installer got `-Config` and **not** `-Supervisor`, that `config.recommended.yaml` was produced into the script folder, and that `otelcol-contrib` is running with no supervisor alongside it. |
| **P2** shapes | Every IIS shape below gets the service name its layout implies. |
| **P3** failures | F1–F7: break → the doctor names the cause → fix → green again. The round trip is the deliverable. |
| **P4** telemetry | Real load, then `:8888` counters on the host, then Coralogix via `querydata_key.txt`. |
| **P5** idempotency | A second `deploy.bat` changes nothing and adds no duplicate pool entries. |

Each run uses a unique `host.name` (`cx-e2e-<stamp>`). Without that, P4 would happily
pass on the previous run's telemetry after a regression broke this one.

## IIS shape matrix

Provisioned by `test/docker-win/entrypoint.e2e.ps1`. Every shape is here because the
deploy code handles it somewhere and nothing exercised it end to end.

| # | Shape | Where the name lands | Why it is in the matrix |
| --- | --- | --- | --- |
| 1 | `Default Web Site`, stock | **nowhere, by design** | Static content: `C:\inetpub\wwwroot` ships `iisstart.htm` and no `web.config`, so .NET auto-instrumentation produces nothing for it. It used to be named purely because it had a pool to itself, which made the host claim ownership of a service that emits nothing. Now `NON_DOTNET_APP_NOT_INSTRUMENTED` (info) and absent from `CX_IIS_SERVICES`. |
| 2 | `shop` — dedicated pool, ASP.NET Core | pool | The ordinary case. |
| 3 | `shop/api` — nested app, own pool | pool | Name must be `shop/api`, not `shop`. |
| 4 | `shared` + `/api` + `/admin` on one pool | **web.config** | One pool cannot carry three different names, so the per-app name has to go in each app's `web.config`. |
| 5 | `legacy` — ASP.NET **Framework**, dedicated `v4.0` pool | pool | Fully supported: classified `AspNetFramework` from `<system.web>`, named on its pool, and **claimed** in `CX_IIS_SERVICES`. The shared-pool limitation below does not apply to it. |
| 6 | `wrapped` — `<aspNetCore>` inside `<location path=".">` | pool | The shape `dotnet publish` actually emits. A reader looking for a direct child of `<system.webServer>` finds nothing; the code matches `//aspNetCore`. |
| 7 | `nocfg` — shared pool, **no** `web.config` | nowhere | ⚠️ See below. |
| 8 | `shop/assets` — a virtual **directory** | nowhere, by design | It is not an application: no pool of its own, shares the parent's process. Naming it would invent an app that does not exist. |
| 9 | `brownfield` + `/admin` — shared pool that already owned an `<environmentVariables>` block | **web.config** | The pool never sees `applicationPoolDefaults`, so the OTLP vars must be stamped on it directly (`POOL_LOST_INHERITANCE`). |
| 10 | `defaults-core` — ASP.NET Core, `applicationPool` attribute **omitted** | pool/web.config | Carries the `<sites><applicationDefaults>` resolution pin that shape 1 can no longer hold. Also the Core-on-a-managed-CLR case: `DefaultAppPool` has no `managedRuntimeVersion` attribute, which IIS reads as `v4.0`, so this app is named and claimed **and** warned about (`POOL_NOT_NO_MANAGED_CODE`). |
| 11 | `staticwc` — a `web.config` with only `<staticContent>` | nowhere, by design | Kills the "it has a `web.config`, so it is .NET" heuristic. Very common on asset origins. |
| 12 | `arrproxy` — URL-Rewrite reverse proxy to `localhost:5000` | nowhere, by design | The pool's environment never reaches a separate backend process, so instrumenting the IIS pool achieves nothing — the backend has to be instrumented where it runs. |
| 13 | `oop-core` — ASP.NET Core, `hostingModel="outofprocess"` | pool | Looks like shape 12 from outside and is the **opposite** verdict: the ASP.NET Core Module launches `dotnet.exe` as a *child* of `w3wp`, which does inherit the pool environment. |
| 14 | `binonly` — `bin\*.dll`, no `web.config` | nowhere, pending an override | Deliberately ambiguous: static sites carry stray `bin` folders and an out-of-process publish puts DLLs in the app root. Reports `RUNTIME_UNKNOWN_NEEDS_OVERRIDE` rather than guessing, because a wrong guess puts a non-reporting name into `CX_IIS_SERVICES`. Resolved with `-RuntimeOverrides`. |

## Log layout matrix

The collector's `filelog/iis` receiver ships one include:
`C:\inetpub\logs\LogFiles\W3SVC*\*.log`. Anything outside it shipped **nothing**,
silently, with no finding anywhere — that was the gap this work closed.

| | Layout | Before | Now |
| --- | --- | --- | --- |
| L1 | IIS default | logs arrive | unchanged |
| L2 | site with a custom `logFile.directory` | **silent data loss** | `IIS_LOGDIR_NOT_COVERED` (warn); `Instrument-IIS.ps1` publishes `CX_IIS_LOG_DIR_n` and the logs arrive |
| L3 | `centralLogFileMode=CentralW3C` | silent data loss | `IIS_CENTRAL_LOGGING` (info) + the directory is published |
| L4 | site logging disabled | nothing, indistinguishable from a fault | `IIS_LOGGING_DISABLED` (info); does not move the exit code |
| L5 | `logFormat` = IIS / NCSA / Custom | lines arrive unparsed, looking like a collector bug | `IIS_LOG_FORMAT_UNSUPPORTED` (warn) |

## The container cannot install a collector

Measured, not assumed. Inside `mcr.microsoft.com/windows/servercore/iis:windowsservercore-ltsc2022`:

| Transport | Result fetching `otelcol-contrib_0.155.0_windows_x64.msi` |
| --- | --- |
| `curl.exe` | **HTTP 200**, 22,608,519 bytes |
| .NET `Invoke-WebRequest` | **`The decryption operation failed, see inner exception.`** |

The Coralogix vendor installer downloads exclusively with `Invoke-WebRequest`
(`Invoke-Download`), and it has **no local-MSI option for the collector** —
`-SupervisorMsi` exists but is supervisor-mode only, and the work directory it
downloads into is timestamp+PID suffixed, so it cannot be pre-seeded either.

Consequences, stated precisely so this is not mistaken for a defect in this repo:

- **No collector can be installed in this image, by any flag or mode.** This is why
  the older E2E image (`Dockerfile`) bakes `otelcol-contrib.exe` and runs it
  directly instead of using the installer at all.
- `deploy.bat` still runs correctly right up to that point: the loop asserts the
  run reached the vendor installer's own download step, which is what separates
  "the image cannot fetch an MSI" from "our script failed earlier".
- Everything that does not need a collector — the whole shape matrix, all the
  instrumentation failure cases, every doctor finding — **does** run in the
  container and is asserted normally.
- Real Server SKUs and the VirtualBox POC install normally. It is the same class of
  Schannel limitation already documented for the Node.js zip and the collector
  binary in `test/docker-win/README.md`.

**To exercise a real collector install** (P1 service assertions, P4 telemetry, F7),
run the loop's phases on the VirtualBox POC VM or a real host rather than the
container.

### The instrumentation half had the same problem — and a real fix

`Instrument-IIS.ps1` hit the identical wall one layer down: the vendor module's
`Install-OpenTelemetryCore` downloads a ~19 MB archive with .NET and failed the same
way, aborting the script at that line — so **no app got named, no pool got its OTLP
env, and `CX_IIS_SERVICES` was never set**, all as collateral from one failed
download.

Unlike the collector MSI, this one has a supported offline path:
`Install-OpenTelemetryCore -LocalPath <archive>`. `Instrument-IIS.ps1` now exposes it:

| | |
| --- | --- |
| `-LocalArchive` / `CX_OTEL_DOTNET_ARCHIVE` | pre-staged `opentelemetry-dotnet-instrumentation-windows.zip` |
| `-LocalModule` / `CX_OTEL_DOTNET_MODULE` | pre-staged `OpenTelemetry.DotNet.Auto.psm1` |

This is a **real feature, not a test hook** — proxied and air-gapped fleet hosts hit
the same download wall. Stage the files once, set the machine env vars, and
`deploy.bat` needs no extra flags. The E2E image bakes the archive and sets
`CX_OTEL_DOTNET_ARCHIVE`, so the container drives the genuine instrumentation path.

While fixing this, one more trap surfaced: an interrupted earlier run leaves the
temp `.psm1` **locked**, and the next run fails with *"the process cannot access the
file"* — which reads like a permissions problem and is not. The download path now
clears that file first.

## Cases that need a fix or non-default configuration

The point of the exercise. Each of these is a layout that does **not** work out of
the box.

### ⚠️ ASP.NET Framework app on a *shared* pool cannot be named

`Set-WebConfigServiceName` writes `OTEL_SERVICE_NAME` into the `<aspNetCore>`
element's `<environmentVariables>`. A classic ASP.NET Framework app has no
`<aspNetCore>` node at all, so there is nowhere to put it and the function declines
with a warning.

On a **dedicated** pool this does not matter — the name goes on the pool. It only
bites when a Framework app **shares** a pool with another app.

**`appSettings` does not fix the shared-pool case.** On .NET Framework the `OTEL_*`
values in `Web.config` are promoted to *process-level* environment variables at
startup and the SDK initialises once per worker process, so in a shared pool the
first application to start decides the service name for every app in it. Writing
`appSettings` would hand you a name chosen by a startup race — which is also why the
writer must keep returning `$false` here: counting the app as named would put that
race result into `CX_IIS_SERVICES` and reintroduce permanent
`CX_IIS_SERVICES_DRIFT`.

**Not silent, though.** With nothing configured the instrumentation auto-detects
`SiteName\VirtualPath`, so the app *does* report — it is simply named by the SDK
rather than by us, and excluded from `CX_IIS_SERVICES`.

**Remediation:** give the app its own pool (then the pool carries the name), or set
`OTEL_SERVICE_NAME` from application code. `appSettings` is valid only when the app
already has a **dedicated** pool, where the pool variable is the simpler route anyway.

### ⚠️ App with no `web.config` on a shared pool cannot be named

Same shape, different cause: the pool is shared so it cannot disambiguate, and there
is no file to write the name into.

**Remediation:** add a `web.config`, or move the app to its own pool.

### ⚠️ An app whose runtime cannot be determined is left alone

`binonly` (shape 14) has managed assemblies in `bin\` and no `web.config`. That is genuinely
ambiguous — static sites carry stray `bin` folders, and an out-of-process `dotnet publish`
puts DLLs in the app root — so the installer reports `RUNTIME_UNKNOWN_NEEDS_OVERRIDE` and
writes nothing at all.

Not writing is deliberate rather than cautious. Writing `OTEL_SERVICE_NAME` while declining to
claim the app would leave a name readable on the host that `Test-Agent.ps1` then counts as
present and missing from `CX_IIS_SERVICES` — permanent `CX_IIS_SERVICES_DRIFT`, the exact
failure the "subset wins" rule exists to avoid.

**Remediation:** decide it explicitly and give the same answer to the install and the doctor:

```
set CX_RUNTIME_OVERRIDES_JSON=C:\cx\runtimes.json && deploy.bat
```

Keys are app identity (`Site/`, `Site/api`) — the string the doctor prints in its `Target`
column — which is a *different* key space from `-ServiceNameOverrides`. A key matching no app
is reported as `RUNTIME_OVERRIDE_UNMATCHED` rather than ignored.

### ✅ Non-.NET apps no longer claimed as Services — FIXED

Shapes 1, 11 and 12 (static content, a `<staticContent>`-only `web.config`, and a URL-Rewrite
reverse proxy) were each named and added to `CX_IIS_SERVICES` whenever they happened to have a
pool to themselves, because the installer decided naming from **pool arity** alone and never
looked at what the application was. The host then advertised Service ownership for names no
APM telemetry ever arrives under.

Fixed by classifying the runtime of every application before deciding anything. A pre-existing
name left on such a pool by an older installer is actively **removed** on the next run, not
merely skipped — skipping would leave the stale value on disk forever.

### ✅ "cannot read web.config" on a host where nothing was wrong — FIXED

Reported from a real host, on the app every host has:

```
[UNKNOWN] poolRuntime[Default Web Site/]  cannot read web.config, so it is unknown
                                          whether this is an ASP.NET Core app
                                          needing 'No Managed Code'  (WEBCONFIG_UNREADABLE)
```

Nothing was wrong. Stock IIS ships `C:\inetpub\wwwroot` with `iisstart.htm` and
`iisstart.png` and **no `web.config` at all**, and the reader returned the same
"unknown" for a file that is missing as for one it could not open:

```powershell
if (-not (Test-Path -LiteralPath $wc -ErrorAction SilentlyContinue)) { return $null }
[xml]$x = Get-Content -LiteralPath $wc -Raw -ErrorAction Stop
```

So the default site read as a permissions problem on essentially every host in the
fleet — noise that trains people to ignore the check, right next to the codes that
do matter.

Those are different answers. ANCM is wired *by* `web.config`, so no `web.config`
means the app is not ASP.NET Core and the pool's `managedRuntimeVersion` is
irrelevant — determinate, not unknown.

| State | Code | Severity |
| --- | --- | --- |
| no `web.config` (or the physical directory is gone) | `WEBCONFIG_ABSENT` | info |
| present but unopenable/unparsable, or the app has no `physicalPath` | `WEBCONFIG_UNREADABLE` | unknown, message carries the reason |

Two details the fix depends on:

- **Read through `[System.IO.File]`, not `Test-Path`.** Under
  `-ErrorAction SilentlyContinue` a `Test-Path` returns `$false` for an
  access-denied path exactly as it does for a missing one, so keeping it would
  have inverted the confusion instead of removing it. The .NET exceptions
  (`FileNotFoundException` / `DirectoryNotFoundException` / everything else)
  separate the cases cleanly.
- **Absent does not always mean "not Core".** `<system.webServer>` inherits into
  child applications, so an app with no `web.config` under a parent that declares
  `<aspNetCore>` *is* ANCM-hosted. `dotnet publish` emits
  `<location path="." inheritInChildApplications="false">` precisely to stop this,
  but hand-written configs often omit it. The check now walks the URL hierarchy —
  not the filesystem, which is not what IIS inherits along — to the nearest
  ancestor application that has a `web.config`, and if that one is inheritable
  Core the child is treated as Core and its pool runtime is still checked. The
  finding then says `(<aspNetCore> inherited from 'shop/')`.

Pinned by five cases in group C2 of `Run-DoctorTest.ps1`, including the same site
flipped between `absent` and `unreadable`, and the same child app flipping to Core
when only the parent's `<location>` wrapper is removed.

### ⚠️ Re-running the deploy fails while IIS is up — profiler DLLs are locked

`Install-OpenTelemetryCore` replaces the assemblies under
`C:\Program Files\OpenTelemetry .NET AutoInstrumentation\`. Once IIS has loaded
them, a second run dies:

```
Cannot remove item ...\Microsoft.Extensions.DependencyInjection.Abstractions.dll:
Access to the path '...' is denied.
```

`Instrument-IIS.ps1` calls `iisreset` only at the **end**, so the first install on
a clean host succeeds and every subsequent one fails at the very first step —
before any naming, any pool variable, and `CX_IIS_SERVICES`. A re-deploy therefore
looks like a total instrumentation failure.

**Remediation today:** stop `W3SVC` and `WAS` before re-running, start them after.
The E2E loop does exactly this (`Invoke-Instrument`).

**Not fixed in the script on purpose** — stopping IIS means deliberate downtime
during a fleet deploy, which is a product decision, not a bug fix to slip in.

### ✅ `CX_IIS_SERVICES` advertised apps that were never named — FIXED

Found by this loop, and the reason F3 ("re-running clears the drift") could never
pass.

`CX_IIS_SERVICES` was built from the **whole** service map, including apps whose
`OTEL_SERVICE_NAME` assignment had been **skipped** — a shared-pool app with no
`web.config`, or an ASP.NET Framework app with no `<aspNetCore>` node. The host
then advertised Service ownership for a service that emits nothing, breaking the
`set(CX_IIS_SERVICES) == set(OTEL_SERVICE_NAME across apps)` guarantee in
[`iis-service-ownership.md`](iis-service-ownership.md).

The consequence was worse than a cosmetic mismatch: the doctor compares the
variable against the names actually present, so such a host reported
**`CX_IIS_SERVICES_DRIFT` permanently** — re-running the instrumenter could never
clear it, because the re-run reproduced the same bad value. An operator following
the documented remediation would loop forever.

`Instrument-IIS.ps1` now collects only the apps whose assignment returned success
(`Set-WebConfigServiceName` returns `$false` when it declines) and builds the label
from those, warning about the count it excluded. Pinned by the loop's
"CX_IIS_SERVICES excludes apps that could not be named" case.

### ✅ `applicationPoolDefaults` could only be written once — FIXED

Found by F5. `Set-PoolDefaultEnv` does remove-then-add, because appcmd has no
"update" for a collection element. The **remove** addressed the target as

```
/-[name='applicationPoolDefaults'].environmentVariables.[name='OTEL_...']
```

but `[name=…]` selects an element of the `add` collection — a *named pool*.
`applicationPoolDefaults` is not one, so the remove silently matched nothing, and
the following add then found the element already present and left the **old** value
in place. (The add line right beneath it always used the correct form, and a
comment even said so — the two lines had drifted apart.)

Effect: the defaults could be written exactly once. Changing `-OtlpEndpoint` and
re-running did nothing, so the remediation the doctor itself prints for
`POOL_ENV_STALE` — *"re-run `Instrument-IIS.ps1`"* — could not work for the defaults
side. Measured directly in the container: after a break set the defaults to
`127.0.0.1` and the instrumenter was re-run, defaults were still `127.0.0.1` while
every pool had moved to `localhost`.

Both lines now use the predicate-free form.

### ⚠️ More than three distinct log directories

`${env:VAR}` expands to a **single scalar** and an OTel `include:` is a **list**, so
one environment variable cannot become N entries. The config template therefore
declares a fixed number of slots (`CX_IIS_LOG_DIR_1..3`). A host needing more is
reported as `IIS_LOGDIR_SLOTS_EXCEEDED` rather than silently truncated.

**Remediation:** consolidate the log directories, or add slots — to the template
`include:` list **and** `$CxLogDirSlotCount` in `deploy/Resolve-IISLogPaths.ps1`. The
two must agree.

### ⚠️ Log directory changes need a collector restart

The `filelog` receiver reads its include list at start. Publishing
`CX_IIS_LOG_DIR_n` is not enough on its own — restart the collector (or the
supervisor) afterwards.

### ⚠️ Non-W3C log formats arrive unparsed

The receiver's `csv_parser` gets its field names from the W3C `#Fields:` header line.
IIS, NCSA and Custom formats have no such header, so the lines tail fine and arrive
as unsplit text.

**Remediation:** switch the site to W3C, which is the IIS default.

### ⚠️ Central W3C logging loses per-site attribution

One file for the whole host, written directly into the directory with no
`W3SVC<id>` subfolder. The logs arrive once the directory is published, but nothing
in them distinguishes which site a line came from.

### Two traps that are already handled, and must stay handled

- **Do not publish a directory the default glob already covers.** Two `include`
  entries matching the same files means every access-log line is ingested **twice**.
  `Get-IISLogDirValue` tests coverage against where files actually land
  (`…\LogFiles\W3SVC1`) while publishing the configured directory (`…\LogFiles`),
  because the slot glob is `<dir>\**\*.log`. Pinned by the "default directory is not
  published into a slot" case.
- **Empty env-var defaults break the receiver.** confmap resolves a whole-string
  `${env:X:-}` with an empty default to nil, and the receiver then fails to start.
  The slots default to non-existent sentinel paths, which are inert.

## Failure-injection cases

| | Injected | Doctor says | Fix |
| --- | --- | --- | --- |
| F1 | no key | `PRIVATE_KEY_MISSING`, exit 1 | supply the key |
| F2 | instrumentation never ran (`CX_SKIP_INSTRUMENT=1`) | `PROFILER_NOT_REGISTERED` + `CX_IIS_SERVICES_MISSING` | re-run `deploy.bat` |
| F3 | site added after the deploy | `IIS_SERVICE_NAME_MISSING` on the new app | re-run, restart the collector |
| F4 | Core app's pool back on `v4.0` | `POOL_NOT_NO_MANAGED_CODE` | revert, recycle |
| F5 | defaults changed, pool snapshot stale | `POOL_ENV_STALE` | re-run `Instrument-IIS.ps1` |
| F6 | logs in a custom directory | `IIS_LOGDIR_NOT_COVERED` | re-run to publish the slot, restart the collector |
| F7 | collector stopped | `COLLECTOR_SERVICE_STOPPED`, exit 1 | start it |

F4 and F5 are the two that produce **no telemetry at all** while every other signal
looks healthy — which is what makes them worth a dedicated finding.

**`_DRIFT` vs `_MISSING`, since F3 makes the distinction concrete.** A site *added*
after the deploy has no name yet, so the per-app check reports
`IIS_SERVICE_NAME_MISSING` while `CX_IIS_SERVICES` remains accurate for everything
it does list. `CX_IIS_SERVICES_DRIFT` means the **variable itself** disagrees with
the host — a site was removed or renamed and the variable still advertises it.
Expecting DRIFT for an added site looks right and is wrong.

## Collector modes

`deploy.bat` installs with the OpAMP Supervisor by default. `CX_NO_SUPERVISOR=1`
switches to the plain `otelcol-contrib` service.

The flag changes **only** the arguments handed to the Coralogix vendor installer:

```
supervisor      -Supervisor -SupervisorCollectorBaseConfig <cfg> -EnableDynamicIISParsing
no-supervisor   -Config <cfg> -EnableDynamicIISParsing
```

Instrumentation, the env vars that get set, and the diagnostics are identical in both.
One recommended config (`config.recommended.yaml`, produced into the script folder)
serves both modes; it must stay free of an `opamp` extension, which is mandatory in
supervisor mode and is what makes no-supervisor mode deterministic.

The diagnostics do not take a mode flag — they report whichever collector is actually
on the host, and search the supervisor's effective config, then its base config, then
the plain service's `%ProgramData%\OpenTelemetry\Collector\config.yaml`.

## Status — 2026-07-28, 60 passed / 0 failed

`Run-E2ELoop.ps1 -SkipTelemetry`, container `cx-e2e-<stamp>`, Windows containers under
Hyper-V isolation.

| Phase | Result |
| --- | --- |
| P0 premises | curl.exe HTTP 200 / `Invoke-WebRequest` intermittent — informational |
| P1 install | flag contract PASS; collector service assertions **skipped** (image cannot fetch the MSI) |
| P2 shapes | **14/14**, plus the exact-set `CX_IIS_SERVICES` pin and the "no name on an unsupported pool" probes |
| P3 failures | F2–F6 and F8–F10 break→diagnose→fix→green all PASS; F7 skipped (needs a collector) |
| P4 telemetry | not run (`-SkipTelemetry`; needs a collector — run on the POC VM) |
| P5 idempotency | PASS — value stable, no duplicate pool entries, **no drift**, and the same classification twice |

Alongside it: `Run-DoctorTest.ps1` 54/54 and `test/Test-ResolveIISAppRuntime.ps1` 54/54 (the
latter includes 16 cases asserting `misc/Test-CxInstrumentation.ps1`'s inlined copy of the
classifier still agrees with the shared one).

**Four defects in shipped scripts were found by this loop.** Three are fixed and pinned by
regression cases (`CX_IIS_SERVICES` including un-nameable apps; `applicationPoolDefaults`
being write-once; and non-.NET apps being named and claimed purely for having a dedicated
pool). The fourth — profiler DLLs locked on re-deploy — is **open**, because the only fix
stops IIS and that is a downtime decision.

> The harness now pins `CX_OTEL_DOTNET_MODULE` at the module the first run installs. The
> container's `Invoke-WebRequest` fails intermittently with *"The decryption operation
> failed"* (same TLS-stack problem P0 records for the collector MSI), and when it landed on a
> re-instrument case the script died before reaching anything under test. The first run still
> exercises the real download; every run after it is deterministic.

Every one of them was invisible to the offline diagnostics matrix: each needs the real
`Instrument-IIS.ps1` to run twice against a real `applicationHost.config`, which is
exactly what this loop adds.

### Still to verify on a VM or real host

The container cannot install a collector, so these remain unexercised here:

- P1's service assertions (`otelcol-contrib` Running, no supervisor alongside it)
- P4 end to end: spans per app, IIS access logs per site, host + IIS metrics,
  the 7 ownership keys, `send_failed = 0`
- F7 (`COLLECTOR_SERVICE_STOPPED` as a hard fail)
- A supervisor-mode run, to confirm `CX_NO_SUPERVISOR` changed nothing beyond the
  installer arguments
