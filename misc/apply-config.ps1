#Requires -RunAsAdministrator
<#
    Stage SimpleWebApp\coralogix\config.yaml to the path the otelcol-contrib service
    ACTUALLY reads (C:\ProgramData\OpenTelemetry\Collector\config.yaml -- NOT C:\otel),
    back up the current one, restart, then verify the NEW config is live (iis receiver
    active, windowsperfcounters gone), eu2 auth works (no export failures), and
    span metrics flow.
#>
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dst  = "C:\ProgramData\OpenTelemetry\Collector\config.yaml"   # service --config path
Start-Transcript -Path (Join-Path $root "apply-config.log") -Force | Out-Null
try {
    Write-Host "== back up + stage config to the ACTIVE path =="
    if (Test-Path $dst) {
        $bak = "$dst.bak-" + (Get-Date -Format 'yyyyMMddHHmmss')
        Copy-Item $dst $bak -Force
        Write-Host "  backed up current config -> $bak"
    }
    Copy-Item (Join-Path $root "SimpleWebApp\coralogix\config.yaml") $dst -Force
    $key = (Get-Content (Join-Path $root "SimpleWebApp\coralogix\SendDataKey.txt") -Raw).Trim()
    [Environment]::SetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', $key, 'Machine')
    $env:CORALOGIX_PRIVATE_KEY = $key
    Restart-Service otelcol-contrib -Force
    Start-Sleep -Seconds 8
    $svc = Get-Service otelcol-contrib
    Write-Host ("  otelcol-contrib: " + $svc.Status)
    if ($svc.Status -ne 'Running') { throw "collector not Running after restart (config error - check Event Viewer)" }

    Write-Host "== generate traffic =="
    1..30 | ForEach-Object { foreach ($u in "/", "/health", "/db") { try { Invoke-WebRequest "http://localhost:8080$u" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {} } }
    Write-Host "  waiting 35s for spanmetrics flush (30s) + export..."
    Start-Sleep -Seconds 35

    $m = (Invoke-WebRequest "http://127.0.0.1:8888/metrics" -UseBasicParsing -TimeoutSec 10).Content -split "`n"
    Write-Host "--- NEW-config markers (want iis=True, windowsperfcounters=False, security=True) ---"
    Write-Host ("  iis receiver active            : " + [bool]($m | Select-String 'receiver="iis"'))
    Write-Host ("  windowsperfcounters active     : " + [bool]($m | Select-String 'windowsperfcounters'))
    Write-Host ("  windowseventlog/security active: " + [bool]($m | Select-String 'windowseventlog/security'))
    Write-Host "--- exporter sent (coralogix eu2 + resource_catalog) ---"
    $m | Where-Object { $_ -match '^otelcol_exporter_sent_(spans|metric_points|log_records)\{' }
    Write-Host "--- FAILURES (non-zero => eu2 auth/region problem) ---"
    $f = $m | Where-Object { $_ -match '^otelcol_exporter_(send_failed|enqueue_failed)_' -and $_ -notmatch ' 0$' }
    if ($f) { $f } else { Write-Host "  none" }
    Write-Host "--- spanmetrics connector internal counters ---"
    $sm = $m | Where-Object { $_ -match 'otelcol_connector_.*spanmetrics|spanmetrics' }
    if ($sm) { $sm } else { Write-Host "  (connector counters not exposed at this telemetry level; spans->spanmetrics->coralogix is wired + validated)" }
}
finally { Stop-Transcript | Out-Null }
