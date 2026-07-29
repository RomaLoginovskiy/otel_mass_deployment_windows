<#
.SYNOPSIS
  Ask Coralogix which PM2 apps a host runs, and which of them are actually reporting Node.js
  telemetry. Prints a per-app PASS/GAP table. No host access required.

.DESCRIPTION
  The gap this closes: Verify-CoralogixNodeSpans.ps1 checks service names you already know. On a
  real fleet host you do not know them - the app list lives in a PM2 daemon you may not be able
  to query, on a machine you may not be able to log into. But both halves of the answer are
  already in Coralogix:

    EXPECTED  the pm2 prometheus exporter publishes one `pm2_up` series per managed app, labelled
              with the app name. That IS the authoritative app list, straight off the host.
    OBSERVED  spans carry process.serviceName plus telemetry.sdk.language, so the set of app
              names actually emitting Node traces is one query away.

  Expected minus observed is the coverage gap - the list of apps whose instrumentation never took
  effect. That is exactly the report you want after a staged
  `Instrument-NodePM2.ps1 -Apps <app>` rollout, and the one that told us a host running 26 PM2
  apps was emitting no Node telemetry at all.

  Metrics come from the PromQL endpoint (/metrics/api/v1), spans from DataPrime
  (/api/v1/dataprime/query). Read-only: two GETs and a POST.

.PARAMETER HostName
  host.name / host_name as Coralogix knows it. Matched case-insensitively - the same host often
  appears in both cases (the collector's resourcedetection reports the Windows spelling, an SDK
  may report it lower-cased).

.PARAMETER ApiHost
  Coralogix API host for the account's region. eu1: ng-api-http.coralogix.com (default),
  eu2: ng-api-http.eu2.coralogix.com, us1: ng-api-http.coralogix.us. Both endpoints are derived
  from it.

.PARAMETER QueryKeyFile
  File holding a Coralogix QUERY key (cxup_...), NOT a send/ingest key. Default:
  querydata_key.txt at the repo root (gitignored). Two layouts are accepted: the whole file is
  the key, or one `label - key` per line, in which case -KeyLabel selects one.

.PARAMETER KeyLabel
  Substring of the label to select from a multi-key file (e.g. 'sga'). First cxup_ key wins when
  omitted.

.PARAMETER ExpectedApps
  Skip the pm2_up lookup and use this app list instead. For hosts with no pm2 exporter.

.PARAMETER ExcludeApps
  App names to ignore. Defaults to PM2's own utility apps, which are not instrumented and must
  not count as gaps.

.NOTES
  Windows PowerShell 5.1. Exit 0 = every expected app is reporting, 1 = at least one gap,
  2 = the expected set could not be established (nothing was proven either way).

  Three things that cost real time to find out, all encoded below:

  * Attribute keypaths need BRACKET syntax. The OTel attribute key is literally 'host.name', so
    $d.resource.attributes['host.name'] is right, while $d.resource.attributes.'host.name' and
    the backtick form are compile errors, and the dotted $d.resource.attributes.host.name
    silently compiles to a keypath that does not exist and aggregates everything as null.
  * Send a normal User-Agent. Cloudflare answers 403 'error code: 1010' to some default agents,
    on every region host, which reads exactly like a bad key.
  * Some accounts keep nothing in the frequent-search tier (archive-only retention), so both
    tiers are tried and the first with rows wins.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [string]   $ApiHost          = 'ng-api-http.coralogix.com',
    [string]   $QueryKeyFile,
    [string]   $KeyLabel,
    [int]      $LookbackMinutes  = 60,
    [string[]] $ExpectedApps,
    [string[]] $ExcludeApps      = @('pm2-logrotate','pm2-prometheus-exporter','pm2-server-monit','pm2-auto-pull'),
    [string[]] $Tiers            = @('TIER_FREQUENT_SEARCH','TIER_ARCHIVE'),
    [string]   $UserAgent        = 'curl/8.4.0'
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when invoked via `powershell -File <relative-path>`; fall back to the
# invocation path so the default query-key location resolves from scripts\..\querydata_key.txt.
if (-not $QueryKeyFile) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $QueryKeyFile = Join-Path $here '..\querydata_key.txt'
}
if (-not (Test-Path -LiteralPath $QueryKeyFile)) { throw "Query key file not found: $QueryKeyFile (pass -QueryKeyFile)" }

# Accept both a bare key and a `label - key` list. Nothing is echoed: a key printed into a
# BatchPatch transcript is a leaked credential.
$key = $null
foreach ($line in (Get-Content -LiteralPath $QueryKeyFile)) {
    $text = $line.Trim()
    if (-not $text) { continue }
    $label = ''
    $value = $text
    if ($text -match '^(.*?)\s+-\s+(\S+)$') { $label = $matches[1]; $value = $matches[2] }
    if ($value -notmatch '^cx[a-z]p_') { continue }
    if ($KeyLabel -and $label -notmatch [regex]::Escape($KeyLabel)) { continue }
    $key = $value; break
}
if (-not $key) {
    $hint = if ($KeyLabel) { " matching label '$KeyLabel'" } else { '' }
    throw "No Coralogix query key$hint found in $QueryKeyFile (expected a cxup_ value)."
}

$dpUrl   = "https://$ApiHost/api/v1/dataprime/query"
$promUrl = "https://$ApiHost/metrics/api/v1/query"

$endUtc   = (Get-Date).ToUniversalTime()
$startUtc = $endUtc.AddMinutes(-1 * $LookbackMinutes)
$startISO = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$endISO   = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

function Invoke-CxPromQuery {
    param([Parameter(Mandatory)][string] $Query)
    # No `time` parameter: the query below carries its own [<lookback>m] window, and pinning an
    # instant makes the result depend on scrape freshness (see the last_over_time note).
    $uri = "{0}?query={1}" -f $promUrl, [uri]::EscapeDataString($Query)
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -UserAgent $UserAgent `
                    -Headers @{ Authorization = "Bearer $key" }
    } catch { Write-Warning "  PromQL query failed: $($_.Exception.Message)"; return $null }
    $text = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    try { return ($text | ConvertFrom-Json) } catch { Write-Warning "  PromQL response was not JSON"; return $null }
}

function Invoke-CxDpQuery {
    param([Parameter(Mandatory)][string] $Query, [Parameter(Mandatory)][string] $Tier)
    # metadata.syntax is deliberately OMITTED (sending the enum returns HTTP 400).
    $body = @{ query = $Query; metadata = @{ tier = $Tier; startDate = $startISO; endDate = $endISO } } |
                ConvertTo-Json -Depth 8 -Compress
    try {
        $resp = Invoke-WebRequest -Uri $dpUrl -Method Post -UseBasicParsing -UserAgent $UserAgent `
                    -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body
    } catch { Write-Warning "  DataPrime query failed ($Tier): $($_.Exception.Message)"; return '' }
    if ($resp.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($resp.Content) }
    return [string]$resp.Content
}

function Get-CxDpRows {
    <#
      Rows out of a DataPrime response.

      The body is a run of concatenated JSON objects, each row arriving as an ESCAPED JSON string
      inside "userData". So the payloads are pulled out by regex, unescaped, and parsed one at a
      time - an aggregation row is small and has unique keys, unlike a raw log or span document
      (whose captured environment carries case-colliding keys that make 5.1's ConvertFrom-Json
      throw outright).
    #>
    param([string] $Ndjson)

    if (-not $Ndjson) { return @() }
    $out = foreach ($m in [regex]::Matches($Ndjson, '"userData"\s*:\s*"((?:[^"\\]|\\.)*)"')) {
        $payload = $m.Groups[1].Value
        $payload = $payload.Replace('\"','"').Replace('\/','/').Replace('\n',"`n").Replace('\r',"`r").Replace('\t',"`t")
        $payload = $payload.Replace('\\','\')
        try { $payload | ConvertFrom-Json } catch { continue }
    }
    return @($out)
}

function Get-CxDpRowsFirstTier {
    # First tier with rows wins; see the archive-only note in .NOTES.
    param([Parameter(Mandatory)][string] $Query)
    foreach ($tier in $Tiers) {
        $rows = Get-CxDpRows -Ndjson (Invoke-CxDpQuery -Query $Query -Tier $tier)
        if (@($rows).Count -gt 0) { return [pscustomobject]@{ Rows = @($rows); Tier = $tier } }
    }
    return [pscustomobject]@{ Rows = @(); Tier = $null }
}

# Case variants as an explicit equality OR, rather than trusting a regex operator's semantics.
$hostVariants = @($HostName, $HostName.ToUpperInvariant(), $HostName.ToLowerInvariant()) | Select-Object -Unique
$hostFilter   = ($hostVariants | ForEach-Object { "`$d.process.tags['host.name'] == '$_'" }) -join ' || '

Write-Host "Coralogix PM2 coverage check" -ForegroundColor Cyan
Write-Host ("  host   : {0}" -f $HostName)
Write-Host ("  window : {0} -> {1} ({2} min)" -f $startISO, $endISO, $LookbackMinutes)
Write-Host ("  api    : {0}" -f $ApiHost)
Write-Host ""

# ---- EXPECTED: the PM2 app list, from the pm2 exporter's own series ------------
$expected = @()
$expectedSource = 'pm2_up'
if ($ExpectedApps) {
    $expected = @($ExpectedApps)
    $expectedSource = '-ExpectedApps'
} else {
    # last_over_time over the lookback window, NOT a bare instant query. `pm2_up` is scraped
    # periodically, so an instant query at `now` routinely returns an empty result while
    # reporting seriesFetched: 28 - the series exist, the newest sample is just older than the
    # 5-minute instant-query lookback. That empty result reads exactly like "this host runs no
    # PM2 apps", which is the opposite of the truth.
    $prom = Invoke-CxPromQuery -Query ("last_over_time(pm2_up{{host_name=~`"(?i){0}`"}}[{1}m])" -f `
                                        [regex]::Escape($HostName), $LookbackMinutes)
    if ($prom -and $prom.status -eq 'success') {
        $expected = @($prom.data.result | ForEach-Object { [string]$_.metric.name } | Where-Object { $_ } | Select-Object -Unique)
    }
}
$expected = @($expected | Where-Object { $ExcludeApps -notcontains $_ } | Sort-Object)

if ($expected.Count -eq 0) {
    Write-Host "Could not establish the expected app set." -ForegroundColor Yellow
    Write-Host "  No pm2_up series for this host. Either the pm2 prometheus exporter is not running/scraped" -ForegroundColor Yellow
    Write-Host "  there, or the host name does not match. Pass -ExpectedApps to check a known list." -ForegroundColor Yellow
    exit 2
}
Write-Host ("expected apps ({0}, via {1}): {2}" -f $expected.Count, $expectedSource, ($expected -join ', '))

# ---- OBSERVED: which service names emit spans from this host -------------------
$svcQuery = "source spans | filter $hostFilter | groupby " +
            "`$d.process.serviceName as svc, `$d.process.tags['telemetry.sdk.language'] as lang " +
            "aggregate count() as c | sortby c desc | limit 500"
$observedResult = Get-CxDpRowsFirstTier -Query $svcQuery
$observed = @{}
foreach ($r in $observedResult.Rows) {
    $svc = [string]$r.svc
    if (-not $svc) { continue }
    if (-not $observed.ContainsKey($svc)) { $observed[$svc] = [pscustomobject]@{ Spans = 0; Lang = [string]$r.lang } }
    $observed[$svc].Spans += [int]$r.c
    if (-not $observed[$svc].Lang) { $observed[$svc].Lang = [string]$r.lang }
}
# Precomputed, not inlined: an `if` expression is legal on the right of an assignment but not as
# an argument inside a -f list, where PowerShell tries to run `if` as a command.
$observedCountText = if ($observed.Count -gt 0) { [string]$observed.Count } else { 'none' }
$observedTierText  = if ($observedResult.Tier) { " (tier $($observedResult.Tier))" } else { '' }
Write-Host ("observed services on this host: {0}{1}" -f $observedCountText, $observedTierText)
Write-Host ""

# ---- The table -----------------------------------------------------------------
$gaps = @()
$rows = foreach ($app in $expected) {
    $hit   = $observed[$app]
    $spans = if ($hit) { [int]$hit.Spans } else { 0 }
    $lang  = if ($hit) { [string]$hit.Lang } else { '' }
    # A .NET service answering to a PM2 app's name would be a naming collision, not coverage,
    # so the language has to agree before this counts as instrumented.
    $ok = ($spans -gt 0 -and ($lang -eq 'nodejs' -or -not $lang))
    if (-not $ok) { $gaps += $app }
    [pscustomobject]@{
        App    = $app
        Spans  = $spans
        Lang   = if ($lang) { $lang } else { '-' }
        Result = if ($ok) { 'PASS' } else { 'GAP' }
    }
}
$rows | Format-Table App, Spans, Lang, Result -AutoSize | Out-String | Write-Host

# Node services reporting from this host that PM2 does not list: a renamed app, an override, or
# something instrumented outside PM2. Informational, never a gap.
$extra = @($observed.Keys | Where-Object { $expected -notcontains $_ -and $observed[$_].Lang -eq 'nodejs' })
if ($extra.Count -gt 0) {
    Write-Host ("NOTE: Node services reporting from this host but not in the PM2 list: {0}" -f ($extra -join ', ')) -ForegroundColor DarkCyan
    Write-Host  "      (a service-name override, a renamed app, or Node instrumented outside PM2)" -ForegroundColor DarkCyan
}

if ($gaps.Count -eq 0) {
    Write-Host ("RESULT: PASS - all {0} PM2 app(s) report Node telemetry from {1}." -f $expected.Count, $HostName) -ForegroundColor Green
    exit 0
}
Write-Host ("RESULT: FAIL - {0} of {1} PM2 app(s) emit no Node telemetry: {2}" -f `
    $gaps.Count, $expected.Count, ($gaps -join ', ')) -ForegroundColor Yellow
Write-Host "  Allow a few minutes after a restart for ingestion, then re-run. If a gap persists, run" -ForegroundColor Yellow
Write-Host "  doctor.bat -Only nodeInstrumentation on the host - NODE_PM2_DAEMON_OWNER_MISMATCH and" -ForegroundColor Yellow
Write-Host "  NODE_OPTIONS_MISSING are the two findings that explain a silent app." -ForegroundColor Yellow
exit 1
