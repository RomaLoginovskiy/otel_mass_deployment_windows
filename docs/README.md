# Documentation

Which document answers which question.

## Runbooks

| Document | Use it when |
| --- | --- |
| [single-host.md](single-host.md) | Installing the collector and zero-code .NET/IIS instrumentation on **one** host, by hand. Also the deepest IIS background: pool scope, shared pools, known limitations. |
| [fleet.md](fleet.md) | Rolling the same thing out across **many** Windows hosts: build a package, push it, register agents with Fleet Management, assign a remote config, uninstall. |
| [linux.md](linux.md) | The Linux database-host path — supervisor plus collector, config owned remotely. |
| [nodejs-pm2.md](nodejs-pm2.md) | Instrumenting Node.js apps, under PM2 or as a Windows service, including the PM2-as-a-service case that silently instruments nothing. |

## Concepts

| Document | Covers |
| --- | --- |
| [diagnostics.md](diagnostics.md) | Reading a `doctor.bat` result: what each check proves, which applications reach the ownership list, "No Managed Code" versus runtime, and confusing-but-correct findings. |
| [iis-service-ownership.md](iis-service-ownership.md) | How a host gets its Infrastructure-Explorer **Service** ownership: the keys, the array value format, and why it matches the APM service names. |

## Reference

| Document | Covers |
| --- | --- |
| [reference/cli.md](reference/cli.md) | Every command and every argument: build, deploy, instrument, diagnose, uninstall, plus the helper libraries and the operator-side verification scripts. |
| [reference/env-vars.md](reference/env-vars.md) | Every `CX_*`, `CORALOGIX_*` and `OTEL_*` variable — what you set, what the installer publishes, and which copy wins when two disagree. |
| [reference/exit-codes.md](reference/exit-codes.md) | The graded exit-code contract and all 76 finding codes, each with a meaning and a fix. |

## Common starting points

- **Nothing is arriving in Coralogix.** [diagnostics.md](diagnostics.md), then
  [reference/exit-codes.md](reference/exit-codes.md) for the finding the doctor reports.
- **A host is missing from Fleet Management.** [fleet.md](fleet.md) → Troubleshooting. An HTTP 403
  from the OpAMP endpoint is a key or region problem, not a network one.
- **Service ownership is blank.** [iis-service-ownership.md](iis-service-ownership.md) — the
  variable and the processor fail independently, and look identical from Coralogix.
- **An IIS app reports nothing while others work.**
  [diagnostics.md](diagnostics.md) → runtime classification.
- **What does this flag do?** [reference/cli.md](reference/cli.md).
