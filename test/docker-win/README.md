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
  > If this returns *"windows containers have been disabled for this installation"*,
  > re-run the Docker Desktop installer / enable Windows containers
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

## Known limitations (container only)

- The vendor supervisor installer's GitHub MSI download fails inside a minimal Server Core
  container, so the collector binary is baked into the image and run directly against the
  base config. Real hosts install the full supervisor.
- The `resourcedetection/region` cloud detectors time out (~13s) before the collector
  reaches ready.
