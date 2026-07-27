<#
.SYNOPSIS
  Query Coralogix (DataPrime + PromQL) to confirm the collector's APPLICATION name resolved to the
  host's own name (host.name fallback) on all four signal paths, and that the old hard-coded
  application name is gone for that host.

.DESCRIPTION
  Companion to Verify-CoralogixNodeSpans.ps1 / Verify-CoralogixInfraLabels.ps1, for the
  application-name fallback added to the coralogix exporter:

      application_name_attributes: [cx.application.name, service.namespace, host.name]

  service.namespace now comes from the machine env var CX_APPLICATION and is EMPTY when that var is
  unset, so the exporter falls through to host.name and each host names its own application.

  Checks (all scoped to one host by host.name):
    1. LOGS        - log records from this host under the expected app                     [gate]
    2. HOST STREAM - subsystem 'windows' (windowseventlog) count            [informational]
    3. SPANS       - IIS + Node auto-instrumentation spans under the expected app          [gate]
    4. METRICS     - PromQL series carrying label cx_application_name="<app>"              [gate]
    5. NEGATIVE    - zero rows for the legacy application name on this host                [gate]
    6. EXCLUSIVITY - the expected app is the ONLY application on this host (logs + spans)  [gate]

  PASS (exit 0) when every [gate] row passes. Check 2 never fails the run: the Windows event
  channels can be silent for an hour in a Server Core container, so an empty host stream says
  nothing about the application name - it is printed so that emptiness stays visible.

  Signal-specific keypaths, learned the hard way against this account (2026-07-27):
    * logs   - application label is LOWERCASE `$l.applicationname`; resource attributes are at
               `$d.resource.attributes['...']`.
    * spans  - application label is CAMELCASE `$l.applicationName`; resource attributes are NOT at
               `$d.resource.attributes` (that keypath does not exist) but at `$d.process.tags['...']`.
    * metrics- NOT reachable through the DataPrime endpoint (`source metrics` returns HTTP 400).
               Use the PromQL endpoint `https://api.<domain>/metrics/api/v1/query`; the paths
               `.../prometheus/api/v1/query` and `ng-api-http.<domain>/prometheus/...` all 404.
               The probe is `count by (__name__) (...)` rather than a named series, because which
               metric names a host produces varies (host `system_*` series were absent here while
               app/spanmetrics series were present) - the claim under test is the label, not the metric.

.PARAMETER ExpectedApplication
  The application name the data must carry. For the container harness this is the container
  hostname (Run-DockerWinTest.ps1 -HostName, default cx-owner-test).

.PARAMETER HostName
  Host to scope the queries to (resource attribute host.name). Defaults to -ExpectedApplication,
  which is the whole point of the fallback; pass it explicitly when testing the CX_APPLICATION
  override branch (application != hostname).

.PARAMETER LegacyApplication
  Application name that must NOT appear for this host any more. Default: iis-instrumentation-test.

.NOTES
  - Uses a Coralogix QUERY key (Bearer), NOT the send/ingest key. Default reads querydata_key.txt
    at the repo root (gitignored).
  - metadata.syntax is deliberately OMITTED (sending the enum returns HTTP 400).
  - Response is NDJSON; Invoke-WebRequest .Content is a Byte[] -> decode UTF-8 before use.
  - Host logs route to TIER_ARCHIVE on this account, so both tiers are tried.
  - Windows PowerShell 5.1 compatible. Allow ~10-15 min after the container starts before the
    archive tier and the metrics backend have the data.
#>
[CmdletBinding()]
param(
    [string]   $ExpectedApplication = 'cx-owner-test',
    [string]   $HostName            = $null,
    [string]   $LegacyApplication   = 'iis-instrumentation-test',
    [string]   $ApiUrl              = 'https://ng-api-http.coralogix.com/api/v1/dataprime/query',
    [string]   $PromUrl             = 'https://api.eu1.coralogix.com/metrics/api/v1/query',
    [string]   $QueryKeyFile        = $null,
    [int]      $LookbackMinutes     = 60,
    [string[]] $Tiers               = @('TIER_FREQUENT_SEARCH','TIER_ARCHIVE')
)

$ErrorActionPreference = 'Stop'
if (-not $HostName) { $HostName = $ExpectedApplication }

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

# A DataPrime result packs many rows into one JSON object on a single line, so count the
# "userData" substring rather than lines. First (query, tier) combination with hits wins; the
# matching keypath is reported because span fields are camelCase while log labels are lowercase.
function Get-RowCount {
    param([string[]]$Queries)
    foreach ($q in $Queries) {
        foreach ($tier in $Tiers) {
            $nd = Invoke-DpQuery -Query $q -Tier $tier
            if (-not $nd) { continue }
            $c = ([regex]::Matches($nd, '"userData"')).Count
            if ($c -gt 0) { return [pscustomobject]@{ Count = $c; Tier = $tier; Query = $q; Ndjson = $nd } }
        }
    }
    return [pscustomobject]@{ Count = 0; Tier = $null; Query = $Queries[0]; Ndjson = '' }
}

$app  = $ExpectedApplication
$hn   = $HostName
$results = New-Object System.Collections.Generic.List[object]

Write-Host "Coralogix application-name verification" -ForegroundColor Cyan
Write-Host ("  window      : {0} -> {1} ({2} min)" -f $startISO, $endISO, $LookbackMinutes)
Write-Host ("  application : {0}" -f $app)
Write-Host ("  host.name   : {0}" -f $hn)
Write-Host ""

# 1. LOGS from this host - the gate. Scoped by host.name so another host's data cannot satisfy it.
$logs = Get-RowCount -Queries @(
    "source logs | filter `$l.applicationname == '$app' && `$d.resource.attributes['host.name'] == '$hn' | limit 50"
)
$results.Add([pscustomobject]@{ Check = 'logs (this host)'; Rows = $logs.Count; Tier = $logs.Tier; Pass = ($logs.Count -gt 0); Gate = $true })

# 2. HOST STREAM (informational, NOT a gate). The windowseventlog receivers can be completely
#    silent for an hour in a Server Core container - Application/System/Security simply have no
#    new events - so an empty result here says nothing about the application name. Reported so an
#    empty host stream is visible rather than silently papered over by the check above.
$hostLogs = Get-RowCount -Queries @(
    "source logs | filter `$l.applicationname == '$app' && `$l.subsystemname == 'windows' | limit 50"
)
$results.Add([pscustomobject]@{ Check = "host stream (subsystem 'windows')"; Rows = $hostLogs.Count; Tier = $hostLogs.Tier; Pass = $true; Gate = $false })

# 3. SPANS - span labels are camelCase, and span resource attributes live under $d.process.tags.
$spans = Get-RowCount -Queries @(
    "source spans | filter `$l.applicationName == '$app' | limit 50",
    "source spans | filter `$l.applicationName == '$app' && `$d.process.tags['host.name'] == '$hn' | limit 50"
)
$results.Add([pscustomobject]@{ Check = 'spans (this host)'; Rows = $spans.Count; Tier = $spans.Tier; Pass = ($spans.Count -gt 0); Gate = $true })

# 4. METRICS - the exporter's application name becomes the cx_application_name metric label.
#    Count series by name rather than naming one: which metrics a host emits varies, the label does not.
$metricRows = 0
$metricNames = @()
$promQuery = "count by (__name__) ({cx_application_name=`"$app`"})"
try {
    $uri = $PromUrl + '?query=' + [uri]::EscapeDataString($promQuery)
    $pr  = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 40
    $pt  = if ($pr.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($pr.Content) } else { [string]$pr.Content }
    $metricNames = @([regex]::Matches($pt, '"__name__":"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $metricRows  = $metricNames.Count
} catch { Write-Warning "  PromQL query failed: $($_.Exception.Message)" }
$results.Add([pscustomobject]@{ Check = 'metrics'; Rows = $metricRows; Tier = 'promql'; Pass = ($metricRows -gt 0); Gate = $true })
if ($metricRows -gt 0) {
    Write-Host ("  metric names under this application: {0}{1}" -f (($metricNames | Select-Object -First 6) -join ', '), $(if ($metricRows -gt 6) { " (+$($metricRows - 6) more)" } else { '' })) -ForegroundColor DarkCyan
}

# 5. NEGATIVE CONTROL - the legacy hard-coded application must no longer appear FOR THIS HOST.
#    (Other hosts still on the old config legitimately keep reporting under it, so scope by host.)
$legacy = Get-RowCount -Queries @(
    "source logs | filter `$l.applicationname == '$LegacyApplication' && `$d.resource.attributes['host.name'] == '$hn' | limit 5"
)
$results.Add([pscustomobject]@{ Check = "no '$LegacyApplication'"; Rows = $legacy.Count; Tier = $legacy.Tier; Pass = ($legacy.Count -eq 0); Gate = $true })

# 6. EXCLUSIVITY - stronger than the named negative control: group this host's telemetry BY
#    application and require the expected name to be the only one. Catches a pipeline that still
#    routes some signal under 'otel' or any other bucket, without having to name it in advance.
function Get-AppNames {
    param([string]$Query)
    foreach ($tier in $Tiers) {
        $nd = Invoke-DpQuery -Query $Query -Tier $tier
        if (-not $nd) { continue }
        $names = @([regex]::Matches($nd, '\\"app\\":\\"([^\\"]*)\\"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($names.Count) { return $names }
    }
    return @()
}
$logApps  = Get-AppNames "source logs | filter `$d.resource.attributes['host.name'] == '$hn' | groupby `$l.applicationname as app aggregate count() as c"
$spanApps = Get-AppNames "source spans | filter `$d.process.tags['host.name'] == '$hn' | groupby `$l.applicationName as app aggregate count() as c"
# @(...) on BOTH operands is required: `return $names` unrolls a one-element array to a scalar
# string, and "a" + "b" is string concatenation, not a two-element array.
$seenApps  = @(@($logApps) + @($spanApps) | Where-Object { $_ } | Select-Object -Unique)
$otherApps = @($seenApps | Where-Object { $_ -ne $app })
$results.Add([pscustomobject]@{ Check = 'no other application for this host'; Rows = $otherApps.Count; Tier = 'logs+spans'; Pass = ($otherApps.Count -eq 0); Gate = $true })
if ($otherApps.Count) { Write-Host ("  unexpected application names on this host: {0}" -f ($otherApps -join ', ')) -ForegroundColor Yellow }
elseif ($seenApps.Count) { Write-Host ("  applications seen on this host: {0}" -f ($seenApps -join ', ')) -ForegroundColor DarkCyan }

$results | Format-Table Check, Rows, Tier, Pass, Gate -AutoSize | Out-String | Write-Host

# Only rows marked Gate decide the exit code; informational rows are printed, never fatal.
$pass = -not ($results | Where-Object { $_.Gate -and -not $_.Pass })
if ($pass) {
    Write-Host ("RESULT: PASS - all four signals report application '{0}' and the legacy name is gone for this host." -f $app) -ForegroundColor Green
} else {
    Write-Host "RESULT: FAIL - see the table above." -ForegroundColor Yellow
    Write-Host "  Ingestion lag: host logs land in TIER_ARCHIVE and metrics take a few minutes; re-run after ~15 min before digging." -ForegroundColor DarkCyan
    Write-Host "  If only 'app logs' or 'spans' are empty, check the workload actually produced traffic in the window." -ForegroundColor DarkCyan
}
if (-not $pass) { exit 1 } else { exit 0 }
