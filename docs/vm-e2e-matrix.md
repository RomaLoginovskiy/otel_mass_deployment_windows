# Full-matrix VM end-to-end validation

What `poc\Run-FullMatrixVmLoop.ps1` proves, against a real Windows guest, in **both** install modes.

## Why this exists

Every harness under `test/docker-win/` installs with `CX_NO_SUPERVISOR=1`, because the vendor
installer cannot fetch the collector MSI inside a Server Core container. The consequence is easy to
miss and was true for a long time: **no automated test ran a collector at all** — not in supervisor
mode, not in regular mode. The container matrix proves the deploy scripts *decide* correctly; it
cannot prove a host ends up *reporting*.

That gap is how an AgentDescription value whose backslashes did not survive the supervisor's second
YAML parse reached a production host with the install reporting success, and it is why
[`docs/fleet-deployment.md`](fleet-deployment.md#backslashes-in-agentdescription-values-measured)
now carries a measured quoting table instead of an assumption.

Coverage is deliberately split three ways:

| Layer | Runs | Proves |
| --- | --- | --- |
| Unit (`test/Test-*.ps1`) | anywhere, ~1s, no elevation | the pure functions: classification rules, YAML scalar rules, launcher-XML and REG_MULTI_SZ writers, `NODE_OPTIONS` merging |
| Container (`test/docker-win/`) | Docker, Windows containers | the real `deploy.bat` path over 14 IIS shapes and 21 Node shapes — decisions, naming, doctor findings |
| **VM (this document)** | VirtualBox guest | a collector actually running, supervising, surviving a reboot, and **telemetry arriving in Coralogix** |

## What it runs

```powershell
# supervisor mode (the fleet default)
.\poc\Run-FullMatrixVmLoop.ps1 -Mode supervisor   -VmName cx-e2e-c1 -Region eu1

# regular mode - the path no container can install
.\poc\Run-FullMatrixVmLoop.ps1 -Mode nosupervisor -VmName cx-e2e-c2 -Region eu1

# one phase at a time while fixing something
.\poc\Run-FullMatrixVmLoop.ps1 -Mode supervisor -VmName cx-e2e-c1 -Phase P4,P5
```

Exit code = number of failed assertions. Phases skipped for a missing key or asset are counted as
**notes**, never as passes, so a run that proved nothing cannot look green.

`-AssetRoot` points at the baked guest binaries (`node.zip`, `npm-global`, `otel-node`,
`otel-dotnet.zip`). They are gitignored, so a fresh clone does not have them and the machine holding
the branch is not necessarily the one that baked them — see
[`test/docker-win/README.md`](../test/docker-win/README.md) for how they are produced.

## Phases

| Phase | Gate |
| --- | --- |
| **P0** transport | `guestcontrol` answers; the guest session is elevated; a value carrying backslashes, quotes and an apostrophe round-trips **verbatim**; the guest is renamed (`host.name` is the join key for every telemetry query, and two clones of one image collide); any pre-existing agent is uninstalled so P3 is a real install |
| **P1** prerequisites | IIS running, **ANCM** present (without it every Core shape 500s and it looks like an instrumentation failure), ASP.NET Core **8 and 6** both present, Node + pm2 answer, `otel-dotnet` staged, app fixtures staged. Missing URL Rewrite/ARR or .NET 3.5 downgrade the shapes that need them to notes |
| **P2** shapes | the 14 IIS classification shapes (from the container harness's own `entrypoint.e2e.ps1 -NoWait`, so the two matrices cannot drift), the four runtime apps, PM2 fork, Node-as-a-service, the .NET worker service — and every one answers HTTP 200 **locally, before the agent is installed** |
| **P3** deploy | `deploy.bat` in the mode under test. Supervisor: took the `-Supervisor` path, `opampsupervisor` Running. Regular: took `-Config`, `otelcol-contrib` Running, **no supervisor service anywhere** |
| **P4** health | `:13133` returns 200; OTLP 4317+4318 listening; `:8888` shows exports > 0 and **zero** `send_failed`. Supervisor mode also: automatic start type, a live collector **child**, and — kill that child and the supervisor must bring back a *new* one. That supervising contract is the whole reason to run supervisor mode and nothing else tested it |
| **P5** naming | `CX_IIS_SERVICES` contains net8, net8-oop, net6 and fw48; and **does not** contain the CLR-2 pool, the ARR proxy, the static site, the `web.config`-less app or the ambiguous `bin`-only app. A claimed name that never reports reads as an outage, so the negative half matters as much as the positive |
| **P6** load | real requests against every shape, including an always-throwing route, then a wait for ingestion |
| **P7** telemetry | Coralogix, **queried** — never a UI. Host/IIS service labels via `Verify-CoralogixInfraLabels.ps1` with the value the *guest* stamped and `-MustNotContain` for the refusal cases; Node spans and logs via `Verify-CoralogixNodeSpans.ps1` |
| **P9** reboot | the guest reboots and the agent comes back with **no intervention**. `StartType=Automatic` alone was measured not to be enough — see the resilience notes in `Install-CoralogixSupervisor.ps1` |
| **P10** uninstall | services gone, IIS still running, no profiler entries and **no empty element** left in the W3SVC `Environment` (an empty element there stops IIS from starting) |

## Runtime / CLR combinations

One source (`test/fixtures/apps/coreweb`) published twice, plus two runtime-compiled ASP.NET apps —
so Framework coverage needs no MSBuild web targets on the build machine.

| Fixture | Pool | Expected |
| --- | --- | --- |
| `coreweb-net8` | No Managed Code, in-process | named, claimed, reports |
| `coreweb-net8-oop` | No Managed Code, `hostingModel="outofprocess"` | named, claimed, reports — ANCM launches `dotnet.exe` as a **child** of `w3wp`, which inherits the pool environment. The opposite verdict to an ARR proxy that looks the same from outside |
| `coreweb-net6` | No Managed Code, in-process | named, claimed, reports — proves the profiler attaches across two Core majors on one host |
| `fw48` | `v4.0` | named, claimed, reports through the **desktop CLR** (`COR_*`, not `CORECLR_*`) |
| `clr2` | `v2.0` | **refusal**: classified, NOT claimed, no telemetry. The profiler supports 4.x; a silent claim here would put a never-reporting service name into Coralogix |

## Windows services outside IIS

Both were documented as out of scope and are now covered, because a fleet host runs them and they
were silent on a host that reported a fully successful install:

- **Node as a Windows service, no PM2** — `deploy\Instrument-NodeService.ps1`. Four launcher shapes
  (winsw/node-windows XML, nssm, the service's registry `Environment`, and *unknown* → refused with
  a reason). `NODE_OPTIONS` is merged, never replaced.
- **.NET service outside IIS** — `deploy\Instrument-DotNetService.ps1`. Profiler variables are
  **copied from W3SVC** (i.e. from whatever the vendor module actually wrote) rather than
  hard-coded, so they cannot rot at the next version bump; Core vs Framework is decided per service
  because the wrong variable pair attaches nothing at all.

Ownership is published as `CX_NODE_SERVICES` / `CX_DOTNET_SERVICES`, merged rather than overwritten
so two instrumenters cannot erase each other's names.

## Known-opens

- **PM2 cluster export** — the environment is applied and the app runs, but no telemetry is
  produced. Fork mode is the gate; cluster is informational until the root cause is found.
- **iisnode** is Unsupported by design (IIS runs no managed code, and there is no PM2 to inject
  into); it is asserted absent from the claim list rather than instrumented.
- Screenshots of a headless VirtualBox guest on this host render as a blank framebuffer, so they are
  useless as a diagnostic — use `guestcontrol` exit codes, which is what the harness does.
