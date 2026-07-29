# Full-matrix VM E2E — findings log

Running log for the two-VM matrix run (`cx-e2e-sup` supervisor mode, `cx-e2e-nosup` regular mode).
One row per defect found while the matrix runs: what failed, the evidence, where the fix landed.
Harness bugs and product bugs are labelled, because only one of the two ships to the fleet.

| # | Gate | Symptom (verbatim where possible) | Root cause | Kind | Fix / status |
| --- | --- | --- | --- | --- | --- |
| F2 | pre-flight unit | `Merge-CxNodeOptions` returned `--require C:/cx/otel-node/register.js` **twice** when merging a value it had already written | The prior-hook check recognised our bootstrap only if its path matched `auto-instrumentations-node\|opentelemetry`. The default install prefix contains both by coincidence, so the bug is invisible there — but a vendored or differently-prefixed install (`-InstallPrefix C:\otel`) is not recognised, and every re-deploy appends another `--require`, loading the SDK twice. The function's own docstring promised this could not happen. | **product** | Fixed — recognition is now by exact normalised target (`file:///C:/x` = `C:\x` = `C:/x`), with the marker rule kept for values written by older versions, plus a new `-OwnedTargets` parameter so a caller can declare artifacts absent from the current bootstrap (an ESM→CommonJS switch would otherwise leave our stale `--experimental-loader` forever). Both callers updated. Pinned by 8 new assertions in `test/Test-ServiceInstrumenters.ps1`, incl. the app-keeps-its-own-`--require` false-positive case. |
| F1 | P0 provision | `Run-TestVM.ps1 -Action Unattended` died before doing anything: `Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string` at line 35 (`$IsoPath` default) | `$PSScriptRoot` is **not populated while param-block defaults are evaluated**, so every default built from it (`$IsoPath`, `$PackagePath`, `$AdditionsIso`) collapsed to an empty path. The documented invocation `-Action Unattended` could never have worked without passing `-IsoPath` explicitly. The repo's other scripts already repair this after the param block; this one did not. | harness | Fixed — paths repaired after the param block, same `$here` pattern as `Install-CoralogixSupervisor.ps1` / `Run-SupervisorVmLoop.ps1`. |

## Notes on method

- A gate that passes after a fix but was never observed failing is not evidence: each row above
  records the failing observation first.
- Assertions are only loosened when the assertion itself was wrong, and then the reason is written
  in this table rather than left in the diff.
- Anything that turns out to be a genuine product limitation stays here as a known-open with its
  evidence instead of being quietly dropped from the matrix.
