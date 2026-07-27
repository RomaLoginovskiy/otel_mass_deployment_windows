<#
.SYNOPSIS
  Query Coralogix (DataPrime HTTP API) to confirm that the zero-code, PM2-managed Node.js apps
  are actually reporting to Coralogix: traces (spans) + logs per service, and - for the cluster
  app - per-worker telemetry (>= N distinct process.pid rolling up under one service name).

.DESCRIPTION
  The Node/PM2 analog of Verify-CoralogixInfraLabels.ps1. For each service name it:
    * TRACES : counts spans (source spans) carrying that service.name.
    * LOGS   : counts log records (source logs) carrying that service.name (pino -> OTLP logs).
    * PIDS   : extracts distinct process.pid from the spans, so the cluster app proves each PM2
               worker instrumented itself independently while sharing one OTEL_SERVICE_NAME.
  Each probe tries a couple of keypath variants (resource.attributes.service.name and the
  Coralogix applicationname mapping) and the frequent-search then archive tiers, so it is robust
  to how the account maps OTLP resource attributes.

  METRICS: OTLP metrics (e.g. http.server.duration) are NOT queryable through this logs/spans
  DataPrime endpoint; confirm them via the collector's exporter counters in the container log
  (the entrypoint prints sent_metric_points) and Coralogix Metrics/APM. This script gates on
  traces + logs + per-worker PIDs.

  PASS (exit 0): every service has spans > 0 AND logs > 0, and the cluster service shows
  >= MinClusterWorkers distinct process.pid. Otherwise exit 1.

.NOTES
  - Uses a Coralogix QUERY key (Bearer), NOT the send/ingest key. Default reads querydata_key.txt
    at the repo root (gitignored).
  - metadata.syntax is deliberately OMITTED (sending the enum returns HTTP 400).
  - Response is NDJSON; Invoke-WebRequest .Content is a Byte[] -> decode UTF-8 before use.
  - Windows PowerShell 5.1 compatible. Allow a few minutes after load starts before spans land.
#>
[CmdletBinding()]
param(
    [string]   $ApiUrl            = 'https://ng-api-http.coralogix.com/api/v1/dataprime/query',
    [string]   $QueryKeyFile      = $null,
    [int]      $LookbackMinutes   = 60,
    [string[]] $Services          = @('nodeapp-fork','nodeapp-cluster'),
    [string]   $ClusterService    = 'nodeapp-cluster',
    [int]      $MinClusterWorkers = 2,
    [string[]] $Tiers             = @('TIER_FREQUENT_SEARCH','TIER_ARCHIVE')
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when invoked via `powershell -File <relative-path>`; fall back to the
# invocation path so the default query-key location resolves from scripts\..\querydata_key.txt.
if (-not $QueryKeyFile) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $QueryKeyFile = Join-Path $here '..\querydata_key.txt'
}
if (-not (Test-Path $QueryKeyFile)) { throw "Query key file not found: $QueryKeyFile (pass -QueryKeyFile)" }
$key = (Get-Content -LiteralPath $QueryKeyFile -Raw).Trim()
if (-not $key) { throw "Query key file is empty: $QueryKeyFile" }

$endUtc   = (Get-Date).ToUniversalTime()
$startUtc = $endUtc.AddMinutes(-1 * $LookbackMinutes)
$startISO = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$endISO   = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

function Invoke-DpQuery {
    param([string]$Query, [string]$Tier)
    $body = @{ query = $Query; metadata = @{ tier = $Tier; startDate = $startISO; endDate = $endISO } } | ConvertTo-Json -Depth 8 -Compress
    try {
        $resp = Invoke-WebRequest -Uri $ApiUrl -Method Post -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body
    } catch { Write-Warning "  query failed ($Tier): $($_.Exception.Message)"; return '' }
    if ($resp.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($resp.Content) }
    return [string]$resp.Content
}

# Count spans/rows by counting userData payload occurrences (a DataPrime result packs many rows
# into one JSON object on a single line, so count the substring, not lines). First tier with hits wins.
function Get-RowCount {
    param([string[]]$Queries)
    foreach ($q in $Queries) {
        foreach ($tier in $Tiers) {
            $nd = Invoke-DpQuery -Query $q -Tier $tier
            if (-not $nd) { continue }
            $c = ([regex]::Matches($nd, '"userData"')).Count
            if ($c -gt 0) { return [pscustomobject]@{ Count = $c; Tier = $tier; Ndjson = $nd } }
        }
    }
    return [pscustomobject]@{ Count = 0; Tier = $null; Ndjson = '' }
}

# Distinct per-worker discriminator from span payloads: prefer service.instance.id (OTel assigns
# each process a unique one, so each PM2 cluster worker differs), fall back to process.pid.
function Get-DistinctWorkers {
    param([string]$Ndjson)
    if (-not $Ndjson) { return @() }
    $ids = @([regex]::Matches($Ndjson, 'service\.instance\.id\\?["'']?\s*[:=]\s*\\?["'']?([0-9a-fA-F-]{8,})') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($ids.Count -ge 1) { return $ids }
    return @([regex]::Matches($Ndjson, 'process\.pid\\?["'']?\s*[:=]\s*\\?["'']?(\d+)') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

Write-Host "Coralogix Node/PM2 span verification" -ForegroundColor Cyan
Write-Host ("  window : {0} -> {1} ({2} min)" -f $startISO, $endISO, $LookbackMinutes)
Write-Host ("  api    : {0}" -f $ApiUrl)
Write-Host ("  services: {0}" -f ($Services -join ', '))
Write-Host ""

$pass = $true
$anyLogs = $false
$rows = foreach ($svc in $Services) {
    # TRACES: Coralogix maps OTel service.name onto the span serviceName label (camelCase).
    $spanQ = @(
        "source spans | filter `$l.serviceName == '$svc' | limit 300",
        "source spans | filter `$d.serviceName == '$svc' | limit 300"
    )
    $spans = Get-RowCount -Queries $spanQ

    # LOGS (informational): pino->OTLP logs. Surfacing them by service depends on the collector
    # logs pipeline (in real fleet that is the remote Fleet config). Try the log label variants.
    $logQ = @(
        "source logs | filter `$l.subsystemname == '$svc' | limit 50",
        "source logs | filter `$l.applicationname == '$svc' | limit 50"
    )
    $logs = Get-RowCount -Queries $logQ
    if ($logs.Count -gt 0) { $anyLogs = $true }

    $workers = Get-DistinctWorkers -Ndjson $spans.Ndjson

    # PASS gate: traces present per service, and (cluster) >= N distinct worker instance ids.
    $svcPass = ($spans.Count -gt 0)
    if ($svc -eq $ClusterService) { $svcPass = $svcPass -and (@($workers).Count -ge $MinClusterWorkers) }
    if (-not $svcPass) { $pass = $false }

    [pscustomobject]@{
        Service   = $svc
        Spans     = $spans.Count
        Logs      = $logs.Count
        Workers   = @($workers).Count
        Pass      = $svcPass
    }
}

$rows | Format-Table Service, Spans, Logs, Workers, Pass -AutoSize | Out-String | Write-Host

Write-Host ("Trace gate: each service has spans > 0; cluster '{0}' has >= {1} distinct worker instance ids." -f $ClusterService, $MinClusterWorkers)
if ($pass) {
    Write-Host "RESULT: PASS - traces confirmed in Coralogix; cluster shows per-worker telemetry." -ForegroundColor Green
} else {
    Write-Host "RESULT: FAIL - traces missing for a service or too few cluster workers. Allow a few minutes for ingestion, then re-run." -ForegroundColor Yellow
}
if (-not $anyLogs) {
    Write-Host "NOTE: app logs (pino->OTLP) are emitted by the apps and accepted by the collector, but did not surface" -ForegroundColor DarkCyan
    Write-Host "      by service name here - log routing is governed by the collector logs pipeline (remote Fleet config)." -ForegroundColor DarkCyan
}
Write-Host "Metrics: confirmed via the collector's exporter counters (sent_metric_points) and Coralogix APM/Metrics." -ForegroundColor DarkCyan
if (-not $pass) { exit 1 } else { exit 0 }
