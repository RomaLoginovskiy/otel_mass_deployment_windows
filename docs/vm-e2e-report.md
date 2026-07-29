# Full-matrix VM E2E — test report

Branch `vm-full-matrix-e2e` (21 commits off `update_iis_instrumentation` @ `bbb0fbb`).
Guests: `cx-e2e-c1` (supervisor mode) and `cx-e2e-c2` (`CX_NO_SUPERVISOR=1`), Windows Server 2025,
region **eu1**. Findings log: [`vm-e2e-findings.md`](vm-e2e-findings.md) (23 entries). Matrix
definition: [`vm-e2e-matrix.md`](vm-e2e-matrix.md).

## Verdict

The matrix is built, runs end to end, and has already paid for itself: **six product defects** that
no existing test could reach, five fixed and one still open. It is **not** a green run, and the
sections below say exactly which claims are evidence-backed and which are not.

The single most important result is methodological: the telemetry gates in this repo were never
authenticating (F17). Every "0 spans" verdict any of them ever produced was a false negative, and
every "this service is correctly silent" check was a **vacuous pass**. That is fixed, and the gates
now fail loudly instead.

## What is verified, and by what evidence

| Claim | Evidence |
| --- | --- |
| Pure string/classification rules hold | **208 unit assertions**, all passing (`Test-SupervisorConfigWriter` 36, `Test-ServiceInstrumenters` 36, `Test-ResolveIISAppRuntime` 60, `Test-Pm2Topology` 76) |
| Guest transport carries hostile values verbatim | P0 asserts a value with backslashes, quotes and an apostrophe round-trips unchanged, both guests |
| Prerequisites really present | P1: IIS, ANCM, **ASP.NET Core 8 *and* 6**, .NET 3.5 + ASP.NET 2.0 handler mapping, URL Rewrite/ARR, node v20.11.0, pm2, otel-dotnet payload, 5 app fixtures |
| Every workload shape provisions and serves | P2 **15/15**: 14 IIS classification shapes, net8 in-proc, net8 out-of-proc, net6, Framework 4.8, CLR 2.0, node-as-a-service, .NET worker service, PM2 fork — each answering HTTP 200 locally *before* the agent is installed |
| The guest runs **this** checkout's payload | P3 writes a marker holding the git HEAD next to the scripts and reads it back from the guest (added after F15 showed the deploy had been running the guest's old payload) |
| A real collector installs in **both** modes | P3: supervisor took the `-Supervisor` path with `opampsupervisor` Running; regular took `-Config`, `otelcol-contrib` Running, **no supervisor service present** |
| Collector health | P4: `:13133` = 200, OTLP 4317+4318 listening, `:8888` exports > 0 with **zero** `send_failed`, StartType automatic |
| **The supervising contract** | P4: killed the `otelcol` child → `supervisor restarted the collector child` … `and it is a NEW process`. Nothing in this repo tested that before |
| Naming and refusals | P5: net8 / net8-oop / net6 / fw48app claimed; `clr2app`, `arrproxy`, `staticwc`, `nocfg`, `binonly` all correctly **not** claimed |
| **Telemetry in Coralogix** (queried, not read off a UI) | spans: `coreweb-net8` 372, `shape-user-fork` 283, `coreweb-net8-oop` 73, **`fw48app` 72**; app logs present in TIER_ARCHIVE; `clr2app` **absent** ✔ |

Two of those deserve calling out. **ASP.NET Framework 4.8 reports** (72 spans through the desktop
CLR) and **out-of-process ASP.NET Core reports** (73 spans) — both were untested runtime paths. And
the CLR-2 refusal is now a *meaningful* negative: `aspnet_regiis` was registered, so that app really
executes managed code and still, correctly, produces nothing and claims nothing.

## What is NOT verified

Stated plainly, because a matrix that overclaims is worse than no matrix.

| Not proven | Why |
| --- | --- |
`cxnodesvc` / `cxworkersvc` spans | The two new instrumenters were only wired into `Install-Agent.ps1` after the last full cycle (F19). Their telemetry has never been observed |
`coreweb-net6` spans | 0 rows in the sampled window while net8 had 372. Unexplained — could be sampling, could be real |
`CX_SERVICES` host ownership end to end | The fix (F20) validates against the real collector binary (`otelcol validate` exit 0) but has not run on a guest, and cannot show ownership until F21 is resolved |
P7 gates *inside a run* | The Coralogix gates were exercised by hand after being fixed; no full cycle has run with them working |
P9 reboot survival | Both cycles produced **false** failures (F13 fixed the fixed-sleep assertion; the wedged-transport hazard is still unhandled). Resilience settings themselves were verified directly: `AUTO_START (DELAYED)` + restart 30/60/120s + `RESET_PERIOD 86400` |
P10 uninstall | Its substance passed (`services=[]`, IIS Running, `iisDeinstrumented=True`) but the exit-code assertion was wrong (F14/F16 fixed after) |

## Product defects found

Six, all reachable only because the matrix runs a real collector and queries the backend.

1. **F2 — `NODE_OPTIONS` double-loads the SDK.** The prior-hook check matched only paths containing
   `opentelemetry`/`auto-instrumentations-node`, true of the default prefix by coincidence. With any
   other `-InstallPrefix`, every re-deploy appended another `--require`. *Fixed*, 8 regression
   assertions.
2. **F10 — a CLR-2 app was claimed as a Service.** `Get-IISAppInstrumentability` keyed on *whether*
   a pool loads a CLR, which is true for v2.0 and v4.0 alike, so a Framework app on CLR 2 was
   `Supported`, named, and advertised — while the profiler needs 4.6.2+. A permanently silent
   Service reads as an outage. *Fixed* + new finding code `FRAMEWORK_CLR2_NOT_INSTRUMENTABLE`;
   verified on the VM with the payload-identity assertion proving it was this code.
3. **F19 — the new instrumenters were never called.** `Instrument-NodeService.ps1` and
   `Instrument-DotNetService.ps1` existed but nothing invoked them. *Fixed*: orchestrated as step 3c
   (Node discovered; .NET opt-in via `-DotNetServices` / `CX_DOTNET_SERVICE_NAMES`).
4. **F20 — host ownership covered IIS only.** The collector's transform read `CX_IIS_SERVICES` and
   nothing else, so `CX_NODE_SERVICES`/`CX_DOTNET_SERVICES` were write-only: an APM service had 283
   spans and no host correlation, and a Node-only host got no ownership labels at all. *Fixed*:
   `CX_SERVICES` union published by the deploy and stamped by the transform, with the old variable
   as fallback.
5. **F23 — re-deploy fails on a live host.** `Install-OpenTelemetryCore` replaces DLLs that `w3wp`
   holds open, and `Install-Agent` treats it as fatal, so re-running `deploy.bat` against a host
   whose apps are up fails the whole install. *Fixed*: skip when the requested version is already
   installed (read from the vendor's `VERSION` marker), otherwise stop W3SVC/WAS + lingering
   `dotnet.exe`, install, and restart in a `finally`.
6. **F21 — no host telemetry reaches Coralogix. OPEN.** `cx-e2e-c2` sends only application
   telemetry: no host metrics (`system_cpu_utilization` → **0 series**), no `windows` event-log
   stream, no resource-catalog entity. So the host is invisible in Infrastructure Explorer and the
   ownership labels of F20 have nothing to attach to. The collector is healthy and exporting, so it
   is evidently not running this repo's config — which would also explain an empty APM *service*
   view alongside stored spans, since that view is driven by the spanmetrics connector our config
   defines. **Root cause not yet confirmed**; the read of the collector's effective config was
   blocked by the guest's own reboot.

## Harness defects found (17)

Recorded in full in the findings log. The ones worth carrying as lessons:

* **F17** — key extraction sent an entire labelled key file as the Bearer token, and the default
  endpoint was the US cluster for an eu1 account. Both produced 403, both were swallowed as "no
  data". A gate that cannot distinguish *no telemetry* from *no answer* is not a gate.
* **F15** — `deploy.bat` resolves `%~dp0Install-Agent.ps1`, so staging it beside an inherited
  payload silently tested last month's code.
* **F3 / F18** — PowerShell variable names are case-insensitive: a dot-sourced helper's
  `$script:VmName` clobbered the caller's parameter, and a local `$label` clobbered a `$Label`
  parameter. Same bug twice.
* **F5** — `snapshot take --live` wedged both guests and corrupted their registration. P0 no longer
  snapshots unless asked.
* **F16** — `$LASTEXITCODE` is not a PowerShell script's exit code; it is the last *native*
  command's. A healthy provisioning step reported 13 from an internal `appcmd`.
* **F13** — a *delayed*-auto service starts ~2 min after boot, so a fixed 90 s wait reported a
  reboot-survival failure that was not one.

## Environment notes

* The two unattended VMs (`cx-e2e-sup`, `cx-e2e-nosup`) never produced working Guest Additions
  after ~75 minutes and were deleted; the matrix runs on linked clones of the reference VM instead.
  VirtualBox unattended install is not a usable path on this host.
* `cx-fleet-test` was left alone apart from an added `e2e-base` snapshot the clones link from — do
  not delete that snapshot while the clones exist.
* `OTIOMWQA01` and `cx-fleet-test` are excluded from every gate **by construction** (F22):
  `-HostName` is mandatory and the unscoped fallback query is gone.
* A guest can report `running` with a dead `guestcontrol` service; `controlvm reset` clears it. Any
  post-reboot phase should treat "no answer" as reset-and-retry, not as a product failure.

## Reproducing

```powershell
# unit gates (anywhere, ~2s, no elevation, no keys)
powershell -File test\Test-SupervisorConfigWriter.ps1
powershell -File test\Test-ServiceInstrumenters.ps1
powershell -File test\Test-ResolveIISAppRuntime.ps1
powershell -File test\Test-Pm2Topology.ps1

# full matrix, one VM per mode
.\poc\Run-FullMatrixVmLoop.ps1 -Mode supervisor   -VmName cx-e2e-c1 -Region eu1 -AssetRoot <checkout>\test\docker-win
.\poc\Run-FullMatrixVmLoop.ps1 -Mode nosupervisor -VmName cx-e2e-c2 -Region eu1 -AssetRoot <checkout>\test\docker-win

# a single Coralogix gate by hand
.\scripts\Verify-CoralogixServiceTelemetry.ps1 -KeyLabel watcher -Region eu1 -HostName CX-E2E-C2 `
    -Services coreweb-net8,coreweb-net8-oop,fw48app,shape-user-fork `
    -MustBeSilent clr2app,arrproxy,staticwc,nocfg,binonly
```

## Next steps, in priority order

1. **Confirm F21**: read the collector's effective config on the guest and find why hostmetrics /
   windowseventlog / resource_catalog are not running. Until that is fixed, Infra Explorer and
   host↔APM correlation cannot work regardless of the ownership fix.
2. Run one full cycle with the working gates and the wired-in service instrumenters, to close
   `cxnodesvc` / `cxworkersvc` / `CX_SERVICES` / P7 / P9 / P10.
3. Explain `coreweb-net6`'s zero spans.
4. Add reset-and-retry to `Restart-Guest` so a wedged transport self-heals rather than failing P9.
