# Host diagnostics

Read-only checks that run **on a deployed Windows host** and report what is actually configured
versus what should be. They ship in the deployment package, change nothing, and grade themselves
into a single exit code a fleet tool can triage.

They exist because the same symptom has many causes. "`CX_IIS_SERVICES` was never set" has at
least six distinct explanations, and an empty variable is identical evidence for all of them.
These scripts tell them apart.

- **Which command to run, and every flag:** [reference/cli.md](reference/cli.md)
- **What an exit code and each finding code mean:** [reference/exit-codes.md](reference/exit-codes.md)

## Start here

```powershell
REM everything, from the package directory, elevated
doctor.bat
```

```powershell
# a subset, when you already know what you are chasing
powershell -NoProfile -ExecutionPolicy Bypass -File Test-Agent.ps1 -Only env,iisServiceName

# one validator on its own
powershell -NoProfile -ExecutionPolicy Bypass -File Test-IISInstrumentation.ps1
```

> **Run elevated.** `applicationHost.config` is readable by Administrators only. A non-elevated run
> would report every IIS app as unconfigured — it would confidently report the exact symptom you
> are investigating. The scripts refuse rather than lie.

Exit codes in one line: `0` pass, `1` hard fail (not elevated, no key, collector down, malformed
profiler registry), `2` degraded (collector up, something misconfigured). `info`, `skip` and
`unknown` never move the code — in particular **`unknown` is not a failure**, it means the script
could not determine the answer.

## The checks

| Check | What it proves |
| --- | --- |
| `env` | Machine-scope `CORALOGIX_PRIVATE_KEY` / `CORALOGIX_DOMAIN` / `CX_ENVIRONMENT` / `OTEL_RESOURCE_ATTRIBUTES` / `CX_IIS_SERVICES` |
| `iisServiceName` | Each app's `OTEL_SERVICE_NAME` read back from the pool **or** its `web.config`, and `CX_IIS_SERVICES` compared as a **set** against them |
| `services` | `opampsupervisor` / `otelcol-contrib` running, plus `StartType` |
| `health` | The collector health endpoint answers |
| `exportCounters` | The internal metrics endpoint — is anything actually being exported, and are the failure counters non-zero |
| `ports` | OTLP receivers listening on 4318 (HTTP) and 4317 (gRPC) |
| `effectiveConfig` | The required processors are present **and wired into** the required pipelines |
| `iisInstrumentation` | The CLR profiler and pool configuration — see below |
| `nodeInstrumentation` | `NODE_OPTIONS`, the register bootstrap, and per-app service names on PM2 apps |

### Why `iisInstrumentation` is separate from `iisServiceName`

`iisServiceName` proves a *name* landed. It says nothing about whether the profiler is attached —
and without the profiler there are no spans at all, however correct the name is. The two are
graded independently for that reason.

## Two traps worth knowing

**`localhost` silently drops OTLP.** On a dual-stack host `localhost` resolves to `::1` first, and
export is dropped with no error. `127.0.0.1` is required. The instrumenters default
`-OtlpEndpoint` to `http://127.0.0.1:4318` **and** rewrite a `localhost` value passed explicitly,
so a stock deploy no longer trips this. Seeing `OTLP_ENDPOINT_LOCALHOST` now means the value came
from somewhere else — a hand edit, a pre-existing pool block, or an older install — and it is a
genuine finding, not a false positive.

**A pool's environment block is a snapshot.** A pool that has its own `<environmentVariables>`
**replaces** `applicationPoolDefaults` rather than merging with it. IIS materialises the defaults
into that block the first time `appcmd` writes any variable to the pool — and that copy never
refreshes. Changing `applicationPoolDefaults` afterwards therefore leaves every
already-instrumented pool on the old value. This is the mechanism behind "I fixed the endpoint
centrally and half the fleet still exports nowhere", and it surfaces as `POOL_ENV_STALE`.

The corollary bites earlier. A pool can acquire its own block *before* the agent is installed —
any prior `appcmd` write of any variable creates one, a connection string being the usual culprit.
That block was materialised from defaults that had no OTLP entries, so the pool never sees the ones
the installer sets later, while the defaults still read as correct. `Instrument-IIS.ps1` therefore
writes the OTLP variables directly onto every pool that owns a block — including *shared* pools,
which are otherwise left inheriting. `POOL_LOST_INHERITANCE` is what an un-repaired pool looks
like, and re-running the instrumenter is a real fix for it.

## "No Managed Code" does not mean unsupported

The IIS application pool setting **No Managed Code** (`managedRuntimeVersion=""`) means IIS does
not load the .NET **Framework** CLR into the worker process. It does *not* mean the application is
unmanaged. ASP.NET Core applications are managed; they run on CoreCLR, booted by the ASP.NET Core
Module, not on the IIS-managed .NET Framework pipeline.

So the pool setting on its own decides nothing, and neither `managedRuntimeVersion="" ⇒ supported`
nor `managedRuntimeVersion="" ⇒ unsupported` is a sound rule. Every application is classified
first, then the pairing is judged:

| Pool setting | Application | Instrumentable? | What the installer does |
| --- | --- | --- | --- |
| `No Managed Code` | ASP.NET Core | Yes | Instrument, claim in `CX_IIS_SERVICES` |
| `No Managed Code` | ASP.NET Framework | No — the app cannot run at all | Report `FRAMEWORK_POOL_NO_MANAGED_CLR`; still named, so ownership does not drift |
| `No Managed Code` | static / native / ISAPI | No | Skip; report `NON_DOTNET_APP_NOT_INSTRUMENTED` |
| `No Managed Code` | PHP / Node / Java behind IIS | No | Skip; instrument that runtime with its own agent |
| `No Managed Code` | reverse proxy to a backend | Depends — see below | Skip the IIS pool; instrument the backend process |
| `v4.0` / `v2.0` | ASP.NET Framework | Yes | Instrument, claim in `CX_IIS_SERVICES` |
| `v4.0` / `v2.0` | ASP.NET Core | Yes, but wasteful | Instrument anyway; report `POOL_NOT_NO_MANAGED_CODE` |

An **absent** `managedRuntimeVersion` attribute is *not* No Managed Code — IIS defaults it to
`v4.0`. That distinction is why the pool version is never used as evidence of what an application
is: inferring "Framework" from a `v4.0` pool would classify every static site on the default pool
as a .NET app.

**Reverse proxies split two ways.** An IIS site that URL-Rewrites to a backend on another port is
not instrumentable from IIS: the pool's environment never reaches that separate process, so the
backend must be instrumented where it runs. ASP.NET Core's **out-of-process hosting model** looks
the same from outside and is the opposite case — the ASP.NET Core Module launches `dotnet.exe` as a
*child* of `w3wp`, which does inherit the pool environment, so it is instrumented normally.

Detection uses positive evidence only: `<aspNetCore>` (including inherited from a parent
application whose `<location>` does not set `inheritInChildApplications="false"`) for Core;
`<system.web>` with real content, managed `type=` handlers or modules, `.aspx`/`.asmx`/`.ashx`
mappings, or `Global.asax` for Framework. Where it cannot tell, it reports
`RUNTIME_UNKNOWN_NEEDS_OVERRIDE` and writes nothing rather than guessing — a wrong guess puts a
name into `CX_IIS_SERVICES` that no telemetry ever arrives for.

## Which apps reach `CX_IIS_SERVICES`

An application is claimed only if **both** hold: the `OTEL_SERVICE_NAME` write succeeded, and it
classified as ASP.NET Core or ASP.NET Framework. Two distinct exclusions follow.

**Non-.NET and undeterminable apps** are never named and never claimed. Nothing reports under them,
so claiming one would point host Service ownership at telemetry that does not exist.

**A classic Framework app that shares a pool** cannot be given a name of our choosing: it has no
`<aspNetCore>` element, and `appSettings` on a shared pool is promoted process-wide, so the first
app to start would decide for all of them. Such apps are excluded — but they still **report**,
under the auto-detected `SiteName\VirtualPath`. Note the scope: this is specific to a *shared*
pool. A Framework app on its own **dedicated** pool is named from the pool and *is* claimed,
exactly like a Core app.

So a host's Service-ownership list is a legitimate subset of what it emits, and
`IIS_SERVICE_NAME_MISSING` for a shared-pool Framework app means "not named by us", not "not
instrumented". Give the app a dedicated pool to bring it under management.

## Forcing a runtime with `-RuntimeOverrides`

`Instrument-IIS.ps1`, `Test-IISInstrumentation.ps1` and `Test-Agent.ps1` all accept
`-RuntimeOverrides` / `-RuntimeOverridesJson`, and all three read `CX_RUNTIME_OVERRIDES_JSON` by
default, so a fleet can stage one file and have the install and the checks agree:

```bat
set CX_RUNTIME_OVERRIDES_JSON=C:\cx\runtimes.json && deploy.bat
```

```json
{ "Wallet/api": "AspNetCore", "Legacy/": "AspNetFramework", "Static/": "NonDotNet" }
```

**Mind the key space — there are two, and they differ by one character for root apps.**

| Parameter | Keyed by | Root app | Nested app |
| --- | --- | --- | --- |
| `-ServiceNameOverrides` | derived **service name** (the label) | `Wallet` | `Wallet/api` |
| `-RuntimeOverrides` | **application identity** | `Wallet/` | `Wallet/api` |

The runtime key is exactly the string the doctor prints in its `Target` column, so it can be copied
off the diagnostic output. The slash-less form is accepted as an alias for a root app, and a key
matching no application is reported as `RUNTIME_OVERRIDE_UNMATCHED` (warn) rather than silently
ignored — that is nearly always a key pasted from the other key space, a typo, or a decommissioned
site. An invalid *value* fails the run outright.

Pass the same overrides to the install and to the doctor. If only one side sees them, the two
disagree about which apps belong in `CX_IIS_SERVICES` and `CX_IIS_SERVICES_DRIFT` is reported
permanently.

## `CX_NODE_SERVICES` has no consumer

`Instrument-NodePM2.ps1` sets the machine variable `CX_NODE_SERVICES`, but **no collector config
reads `${env:CX_NODE_SERVICES}`** — unlike `CX_IIS_SERVICES`, there is no transform consuming it,
so Node host Service ownership stays blank. The doctor reports this as
`NODE_SERVICES_NOT_CONSUMED` (info, does not affect the exit code), and it decides that by
*looking* at the effective config, so the finding disappears on its own if a processor is ever
added. Node services do reach host ownership through the union variable `CX_SERVICES`.

## `APPHOST_UNREADABLE` when the deployment clearly worked

The confusing shape of this one is worth spelling out: **the doctor says the config cannot be read,
yet the installer set the pool environment variables just fine.** That is not a contradiction,
because the two use different mechanisms.

| | How it reaches the config |
| --- | --- |
| `Instrument-IIS.ps1` | `appcmd.exe` → the IIS configuration COM API (`ahadmin`) |
| the diagnostics | a plain file read of `…\inetsrv\config\applicationHost.config` |

Same data on a healthy host. Four things break the file read while leaving `appcmd` working:

| Cause | Message you see | Why `appcmd` survives |
| --- | --- | --- |
| **WOW64** — a 32-bit host process | `applicationHost.config not found at …` | `SysWOW64\inetsrv` has `appcmd.exe` but **no** `config\applicationHost.config`, while the COM API is bitness-agnostic |
| **IIS Shared Configuration** | `not found`, or silently stale results | `redirection.config` points `appcmd` at the UNC store; a file read still hits the local copy |
| Install ran as **SYSTEM**, doctor as an admin *user*, config ACL hardened | `access denied … (run elevated)` → `APPHOST_ACCESS_DENIED` | SYSTEM retained access |
| Transient — WAS rewriting the file mid-read | `could not read/parse …` | `appcmd` writes temp-then-replace; a raw reader can catch it half-written. Passes on re-run |

The first row should no longer occur: `deploy.bat` / `uninstall.bat` / `doctor.bat` re-launch
themselves through `%SystemRoot%\Sysnative\…\powershell.exe` when `PROCESSOR_ARCHITEW6432` is
defined, and the scripts resolve the IIS directory themselves for the case where a `.ps1` is
invoked directly from a 32-bit shell. If you see it anyway, confirm the bitness from an
**elevated** prompt on that host:

```powershell
[pscustomobject]@{
  Is64Proc  = [Environment]::Is64BitProcess
  Native    = Test-Path "$env:windir\System32\inetsrv\config\applicationHost.config"
  Sysnative = Test-Path "$env:windir\Sysnative\inetsrv\config\applicationHost.config"
  Shared    = Test-Path "$env:windir\System32\inetsrv\config\redirection.config"
} | Format-List
```

`Is64Proc=False` with `Sysnative=True` and `Native=False` is WOW64, conclusively — `Sysnative`
exists *only* when observed from a 32-bit process. `Shared=True` means IIS Shared Configuration.
Run it elevated or the result is meaningless: `Test-Path` returns `$false` on a permission-denied
path, so a non-elevated `Native=False` proves nothing.

> **Why this matters beyond the diagnostics.** A 32-bit host process also breaks the *install*: it
> writes pool variables through `appcmd` successfully, while the backup snapshots a path that does
> not exist and the "was this variable already set?" test answers `$false` for every variable. The
> run then mutates `applicationHost.config` with **no backup** and records pre-existing `OTEL_*`
> values as its own, which uninstall would later delete. Hence the `Sysnative` re-launch.

## Output

Console output is the surface a fleet tool harvests and is designed to stand alone. A
machine-readable report is also written to `agent-doctor.json` next to the scripts — the same
convention as `install-agent-status.json` and `detect-workloads.json`. Suppress it with
`-NoFileOutput`.

## Read-only guarantee

The diagnostics never set an environment variable, never run `appcmd` or `iisreset`, never start or
stop a service, and never download anything. The only writes are the report files. The guarantee is
enforced by test, by hashing `applicationHost.config` and the full machine environment before and
after a run.

## Related

- [reference/cli.md](reference/cli.md) — every diagnostic flag and default
- [reference/exit-codes.md](reference/exit-codes.md) — all 76 finding codes
- [reference/env-vars.md](reference/env-vars.md) — the variables the checks read back
- [single-host.md](single-host.md) — installing and instrumenting one host
- [nodejs-pm2.md](nodejs-pm2.md) — the Node/PM2 specifics behind the Node findings
