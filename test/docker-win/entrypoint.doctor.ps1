<#
  Entrypoint for the diagnostics test container (Dockerfile.doctor).

  Builds a realistic IIS layout using the REAL automation library
  (Resolve-IISServiceNames.ps1), so the doctor is validated against the same
  naming/scope logic the fleet deploy uses - not a hand-rolled imitation:

    * three dedicated-pool sites (Scope='pool'  -> OTEL_SERVICE_NAME on the pool)
    * one shared pool hosting two apps (Scope='webconfig' -> name in web.config),
      which is the only way to exercise the web.config readback
    * applicationPoolDefaults carrying the OTLP endpoint, with 'localhost'
      hand-planted so the OTLP_ENDPOINT_LOCALHOST finding fires. This USED to be
      the shipped default; the instrumenters now default to 127.0.0.1 and rewrite
      a `localhost` value, so the fault has to be injected deliberately - which is
      why it is written straight through appcmd below and not via Instrument-IIS.ps1

  It does NOT install a collector. Checks 3-7 are therefore expected to report
  FAIL/WARN - that is intentional: those are the failure branches, and this
  container is how they get exercised.

  Then it idles so the host can `docker exec` the doctor repeatedly, mutate
  state for negative cases, and re-run.
#>
$ErrorActionPreference = 'Continue'
Import-Module WebAdministration

Write-Host "===== Coralogix diagnostics test container =====" -ForegroundColor Cyan
Write-Host "[env] user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'

# --- 1. dedicated-pool sites (pool scope) ----------------------------------
$sites = ($env:CX_TEST_SITES -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$port = 8081
foreach ($s in $sites) {
    $phys = "C:\inetpub\$s"
    New-Item -ItemType Directory -Force -Path $phys | Out-Null
    Set-Content -Path "$phys\index.html" -Value "<h1>$s</h1>" -Encoding utf8
    # ASP.NET Core-shaped web.config so the poolRuntime check has something to assert.
    Set-Content -Path "$phys\web.config" -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
    </system.webServer>
  </location>
</configuration>
'@
    if (-not (Test-Path "IIS:\AppPools\$s")) { New-WebAppPool -Name $s | Out-Null }
    # ASP.NET Core requires "No Managed Code".
    Set-ItemProperty "IIS:\AppPools\$s" -Name managedRuntimeVersion -Value ''
    if (-not (Get-Website -Name $s -ErrorAction SilentlyContinue)) {
        New-Website -Name $s -Port $port -PhysicalPath $phys -ApplicationPool $s | Out-Null
    }
    $port++
}

# --- 2. a SHARED pool with two apps -> Scope='webconfig' --------------------
# Two apps in one pool is the condition that forces per-app names into web.config,
# which is the only path that exercises the new web.config readback.
if (-not (Test-Path 'IIS:\AppPools\SharedPool')) { New-WebAppPool -Name 'SharedPool' | Out-Null }
Set-ItemProperty 'IIS:\AppPools\SharedPool' -Name managedRuntimeVersion -Value ''
$sharedRoot = 'C:\inetpub\shared'
New-Item -ItemType Directory -Force -Path $sharedRoot | Out-Null
Set-Content -Path "$sharedRoot\index.html" -Value '<h1>shared</h1>' -Encoding utf8
if (-not (Get-Website -Name 'shared' -ErrorAction SilentlyContinue)) {
    New-Website -Name 'shared' -Port 8090 -PhysicalPath $sharedRoot -ApplicationPool 'SharedPool' | Out-Null
}
foreach ($sub in 'api','admin') {
    $p = Join-Path $sharedRoot $sub
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Set-Content -Path "$p\web.config" -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
    </system.webServer>
  </location>
</configuration>
'@
    if (-not (Get-WebApplication -Site 'shared' -Name $sub -ErrorAction SilentlyContinue)) {
        New-WebApplication -Site 'shared' -Name $sub -PhysicalPath $p -ApplicationPool 'SharedPool' | Out-Null
    }
}

Write-Host "[iis] sites: $((Get-Website | ForEach-Object Name) -join ', ')"

# --- 3. OTLP defaults, with a hand-planted 'localhost' fault -----------------
# localhost -> ::1 first on a dual-stack host, the collector listens on IPv4 only,
# and the export is dropped with no exporter error - a real documented silent-failure
# mode, so the container reproduces it on purpose and the doctor must warn about it.
#
# Written straight through appcmd rather than via Instrument-IIS.ps1: that script now
# defaults to 127.0.0.1 AND rewrites a `localhost` value it is handed
# (Resolve-CxOtlpEndpoint), so it can no longer produce this state. Keeping the raw
# write is what preserves OTLP_ENDPOINT_LOCALHOST detector coverage.
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/-applicationPoolDefaults.environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT']" /commit:apphost 2>$null | Out-Null
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/+applicationPoolDefaults.environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT',value='http://localhost:4318']" /commit:apphost | Out-Null
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/-applicationPoolDefaults.environmentVariables.[name='OTEL_EXPORTER_OTLP_PROTOCOL']" /commit:apphost 2>$null | Out-Null
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/+applicationPoolDefaults.environmentVariables.[name='OTEL_EXPORTER_OTLP_PROTOCOL',value='http/protobuf']" /commit:apphost | Out-Null

# --- 4. per-app OTEL_SERVICE_NAME + CX_IIS_SERVICES via the REAL library ----
. C:\cx\deploy\Resolve-IISServiceNames.ps1
$svcMap = Get-IISServiceMap
foreach ($r in $svcMap) {
    if ($r.Scope -eq 'pool') {
        & $appcmd set config -section:system.applicationHost/applicationPools "/-[name='$($r.Pool)'].environmentVariables.[name='OTEL_SERVICE_NAME']" /commit:apphost 2>$null | Out-Null
        & $appcmd set config -section:system.applicationHost/applicationPools "/+[name='$($r.Pool)'].environmentVariables.[name='OTEL_SERVICE_NAME',value='$($r.ServiceName)']" /commit:apphost | Out-Null
    } else {
        [void](Set-WebConfigServiceName -PhysicalPath $r.PhysicalPath -ServiceName $r.ServiceName)
    }
}
$cxiis = Get-IISServiceLabelValue -Map $svcMap
[Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $cxiis, 'Machine')
$env:CX_IIS_SERVICES = $cxiis

$perApp = @($svcMap | ForEach-Object { $_.ServiceName } | Select-Object -Unique)
Write-Host "[names] scopes: $((@($svcMap | ForEach-Object { "$($_.ServiceName)=$($_.Scope)" })) -join ', ')"
Write-Host "[names] CX_IIS_SERVICES: $cxiis"

# --- 5. other machine env the doctor reads ---------------------------------
[Environment]::SetEnvironmentVariable('CX_ENVIRONMENT', 'docker-test', 'Machine')
if ($env:CORALOGIX_PRIVATE_KEY) {
    [Environment]::SetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', $env:CORALOGIX_PRIVATE_KEY, 'Machine')
}
[Environment]::SetEnvironmentVariable('CORALOGIX_DOMAIN', 'eu1.coralogix.com', 'Machine')

Write-Host "[ready] container configured - run the doctor with: docker exec <c> powershell -File C:\cx\deploy\Test-Agent.ps1"
Write-Host "[alive] idling for docker exec"

while ($true) {
    Start-Sleep -Seconds 3600
}
