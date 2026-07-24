<#
  Container entrypoint: configure IIS with several distinctly-named sites, run the real
  service-name automation (per-app OTEL_SERVICE_NAME + CX_IIS_SERVICES from ONE Get-IISServiceMap),
  install + start the Coralogix OpAMP supervisor in HYBRID mode (local base config
  config.supervisor.yaml carries the processor; no Fleet remote assigned to this agent), then
  keep the container alive. Validation is done from the host against Coralogix.
#>
$ErrorActionPreference = 'Continue'
Import-Module WebAdministration

# Server Core defaults to legacy TLS; force TLS 1.2 so the vendor collector MSI download
# from GitHub succeeds (otherwise: "The decryption operation failed").
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "===== Coralogix IIS ownership E2E (container) =====" -ForegroundColor Cyan

# --- 0. keys / domain (from container env -> machine scope so the supervised collector inherits) ---
if (-not $env:CORALOGIX_PRIVATE_KEY) { Write-Warning "CORALOGIX_PRIVATE_KEY not set - supervisor will not export. Pass 'docker run -e CORALOGIX_PRIVATE_KEY=...'." }
else { [Environment]::SetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', $env:CORALOGIX_PRIVATE_KEY, 'Machine') }
if (-not $env:CORALOGIX_DOMAIN) { $env:CORALOGIX_DOMAIN = 'eu1.coralogix.com' }
[Environment]::SetEnvironmentVariable('CORALOGIX_DOMAIN', $env:CORALOGIX_DOMAIN, 'Machine')

# --- 1. configure IIS: N distinctly-named sites, each its own (dedicated) pool ---
$sites = ($env:CX_TEST_SITES -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$port = 8081
foreach ($s in $sites) {
    $phys = "C:\inetpub\$s"
    New-Item -ItemType Directory -Force -Path $phys | Out-Null
    Set-Content -Path "$phys\index.html" -Value "<h1>$s</h1>" -Encoding utf8
    if (-not (Test-Path "IIS:\AppPools\$s"))  { New-WebAppPool -Name $s | Out-Null }
    if (-not (Get-Website -Name $s -ErrorAction SilentlyContinue)) {
        New-Website -Name $s -Port $port -PhysicalPath $phys -ApplicationPool $s | Out-Null
    }
    $port++
}
Write-Host "[iis] sites: $((Get-Website | ForEach-Object Name) -join ', ')"

# --- 2. per-app OTEL_SERVICE_NAME + CX_IIS_SERVICES from ONE map (single source = aligned) ---
. C:\cx\deploy\Resolve-IISServiceNames.ps1
$svcMap = Get-IISServiceMap
$appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
foreach ($r in $svcMap) {
    if ($r.Scope -eq 'pool') {
        & $appcmd set config -section:system.applicationHost/applicationPools "/-[name='$($r.Pool)'].environmentVariables.[name='OTEL_SERVICE_NAME']" /commit:apphost 2>$null | Out-Null
        & $appcmd set config -section:system.applicationHost/applicationPools "/+[name='$($r.Pool)'].environmentVariables.[name='OTEL_SERVICE_NAME',value='$($r.ServiceName)']" /commit:apphost | Out-Null
    } else {
        [void](Set-WebConfigServiceName -PhysicalPath $r.PhysicalPath -ServiceName $r.ServiceName)
    }
}
# SAME map -> CX_IIS_SERVICES == set of per-app OTEL_SERVICE_NAME (alignment guarantee).
$cxiis = Get-IISServiceLabelValue -Map $svcMap
[Environment]::SetEnvironmentVariable('CX_IIS_SERVICES', $cxiis, 'Machine')
$env:CX_IIS_SERVICES = $cxiis
$perApp = @($svcMap | ForEach-Object { $_.ServiceName } | Select-Object -Unique)
Write-Host "[names] per-app OTEL_SERVICE_NAME: $($perApp -join ', ')"
Write-Host "[names] CX_IIS_SERVICES        : $cxiis"
Write-Host "[names] aligned: $([bool](-not (Compare-Object ($cxiis -split ',') $perApp)))"

# --- 3. stage the base config (carries transform/iis_service_labels) + env ---
# HYBRID semantics: run the collector directly against the base config, which is exactly what
# the supervisor treats as authoritative when no Fleet remote config is assigned. (The vendor
# supervisor installer is skipped here: its GitHub MSI download fails in a minimal Server Core
# container; on real hosts / the POC VM the full supervisor path works.)
if (-not $env:CORALOGIX_PRIVATE_KEY) { Write-Warning "[collector] no CORALOGIX_PRIVATE_KEY - collector will not export (names were still set)" }
if (-not $env:CX_ENVIRONMENT) { $env:CX_ENVIRONMENT = 'staging' }
[Environment]::SetEnvironmentVariable('CX_ENVIRONMENT', $env:CX_ENVIRONMENT, 'Machine')
New-Item -ItemType Directory -Force -Path C:\otel | Out-Null
Copy-Item C:\cx\deploy\config.supervisor.yaml C:\otel\config.supervisor.yaml -Force

# --- 4. start IIS + run the collector (foreground child; inherits CX_IIS_SERVICES etc.) ---
Start-Service W3SVC -ErrorAction SilentlyContinue
$col = Start-Process 'C:\cx\otelcol-contrib.exe' `
    -ArgumentList '--config', 'C:\otel\config.supervisor.yaml', '--feature-gates=filelog.allowHeaderMetadataParsing' `
    -PassThru -RedirectStandardOutput C:\cx\collector.out.log -RedirectStandardError C:\cx\collector.err.log
Start-Sleep -Seconds 12

# --- 5. keep the container alive; report collector health + export counters ---
while ($true) {
    $health = try { (Invoke-WebRequest 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 5).StatusCode } catch { 'ERR' }
    $m = try { (Invoke-WebRequest 'http://127.0.0.1:8888/metrics' -UseBasicParsing -TimeoutSec 5).Content } catch { '' }
    $sent   = (($m -split "`n" | Select-String 'otelcol_exporter_sent_log_records_total.*coralogix' | Select-Object -First 2) -join ' | ')
    $failed = (($m -split "`n" | Select-String 'otelcol_exporter_send_failed') -join ' | ')
    Write-Host ("[alive] collector_running={0} health={1} w3svc={2} CX_IIS_SERVICES={3}" -f (-not $col.HasExited), $health, (Get-Service W3SVC -ErrorAction SilentlyContinue).Status, $cxiis)
    Write-Host ("[export] sent_logs={0} send_failed={1}" -f $sent, $failed)
    if ($col.HasExited) { Write-Host "[collector] EXITED - stderr tail:"; Get-Content C:\cx\collector.err.log -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ } }
    Start-Sleep -Seconds 60
}
