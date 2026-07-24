# Windows Docker E2E — IIS + Coralogix supervisor, Service-ownership tags

End-to-end test that proves the deploy automation's **`CX_IIS_SERVICES`** env var populates the
Coralogix **Service ownership** tags through the real **OpAMP supervisor + IIS** path, with the
values **aligned to the per-app `OTEL_SERVICE_NAME`**.

## What it does

- Builds a Windows image (`servercore/iis`) containing the real `deploy/` automation + the base
  collector config (`deploy/config.supervisor.yaml`, which carries the
  `transform/iis_service_labels` processor).
- On start (`entrypoint.ps1`):
  1. Creates several distinctly-named IIS sites (`CX_TEST_SITES`, default `shop,wallet,blog`),
     each on its own dedicated pool → multiple service names.
  2. Assigns each app's `OTEL_SERVICE_NAME` and sets `CX_IIS_SERVICES` from **one**
     `Get-IISServiceMap` result (`Get-IISServiceLabelValue -Map $svcMap`) → the ownership set
     equals the per-app APM service names (alignment guarantee).
  3. Runs the Coralogix collector against the base config in **hybrid mode**: the local base
     config (`config.supervisor.yaml`, which carries the `transform/iis_service_labels`
     processor) is authoritative — exactly what the supervisor treats as effective when no Fleet
     remote config is assigned. The collector binary is **baked into the image**
     (`otelcol-contrib.exe`) and run directly, because the vendor supervisor installer's GitHub
     MSI download fails inside a minimal Server Core container (TLS/cert artifact — real hosts
     and the POC VM install the full supervisor fine).
- Validation (`Run-DockerWinTest.ps1`): waits for the container to configure + start, prints the
  name-alignment result, queries Coralogix host logs for the tags, and points you at
  Infrastructure Explorer for the final Service-ownership confirmation.

## Prerequisites

- **Docker Desktop in Windows-container mode** (Hyper-V isolation on Win11 clients).
  Enable + switch:
  ```powershell
  & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine
  ```
  > If this returns *"windows containers have been disabled for this installation"* (as on the
  > dev box used to author this), re-run the Docker Desktop installer / enable Windows containers
  > first, or use a Windows host/VM with them enabled. The base image is a multi-GB first pull.
- Coralogix **send key** at `SimpleWebApp/coralogix/SendDataKey.txt` and **query key** at
  `querydata_key.txt` (both gitignored).

## Run

```powershell
# from the repo root (build context must be the repo root)
./test/docker-win/Run-DockerWinTest.ps1
# options: -Sites 'a,b,c'  -HostName cx-owner-test
```

## Pass criteria

- Container log shows `[names] aligned: True` and `CX_IIS_SERVICES` = the site set.
- `opampsupervisor` reaches Running and connects to Coralogix OpAMP.
- Coralogix host logs / entity for the container host carry the 7 keys
  (`service`, `tags.{service,cx_svc,CX_SERVICE_NAME}`, `cx.infra.labels.{service,cx_svc,CX_SERVICE_NAME}`)
  as arrays.
- **Infrastructure Explorer → Hosts → `<hostname>` → Ownership → Service** lists one item per IIS
  app (`shop`, `wallet`, `blog`, `Default Web Site`) — server-side, ~15 min.

## Validation status — PASSED

Ran here on 2026-07-23 (Windows containers enabled, Hyper-V isolation):

- `[names] aligned: True` — `CX_IIS_SERVICES = Default Web Site,shop,wallet,blog` == the set of
  per-app `OTEL_SERVICE_NAME`.
- Collector healthy (`:13133` = 200), exporting to Coralogix eu1: `sent_log_records{coralogix}`
  climbing + `{coralogix/resource_catalog}` (host entity), `send_failed` = 0.
- **Coralogix host logs (`host.name = cx-owner-test.lan`) carry all 7 keys as 4-element arrays**
  = `["Default Web Site","shop","wallet","blog"]` (`service`, `tags.{service,cx_svc,CX_SERVICE_NAME}`,
  `cx.infra.labels.{service,cx_svc,CX_SERVICE_NAME}`), confirmed by DataPrime query.
- Final Service-ownership (multi-item) resolves in Infrastructure Explorer server-side (~15 min).

Two container-only notes (not product issues; the `cx-fleet-test` VM ran the true supervisor path):
the vendor supervisor installer's GitHub MSI download fails in Server Core (so the collector is
baked in and run directly — hybrid base config), and the `resourcedetection/region` cloud detectors
time out (~13s) before the collector reaches ready.
