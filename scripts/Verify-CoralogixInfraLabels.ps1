<#
.SYNOPSIS
  Query Coralogix (DataPrime HTTP API) to determine which IIS service-label attribute keys
  actually reach ingestion on INFRASTRUCTURE telemetry, and which resolve to a queryable
  label / Infrastructure-Explorer Service ownership.

.DESCRIPTION
  The collector's `transform/iis_service_labels` processor stamps the machine env var
  CX_IIS_SERVICES onto host telemetry under a battery of candidate keys (bare
  service/cx_service/CX_SERVICE_NAME, the tags.* span-tag variants, the cx.infra.labels.*
  probe, and *_list OTel-array variants). This script proves - by querying the ingested
  data, not the UI - which of those keys Coralogix keeps.

  For each candidate key it checks two things in the returned records:
    * KEY present  - the attribute key string appears in the record JSON (it survived
      ingestion under some keypath).
    * VALUE present - the CX_IIS_SERVICES value appears (the stamp carried through).

  It queries the resource-catalog / host-entity stream (application 'resource', which feeds
  Infrastructure Explorer) and the main host stream (subsystem 'windows'), across the
  frequent-search and archive tiers (host telemetry on this account routes to TIER_ARCHIVE).

.NOTES
  - Uses a Coralogix QUERY key (Bearer), NOT the send/ingest key. Default reads
    querydata_key.txt at the repo root (gitignored).
  - DataPrime query API, eu1. metadata.syntax is deliberately OMITTED (sending the enum
    returns HTTP 400 "Could not decode JSON"; DataPrime is the default).
  - Response is NDJSON; Invoke-WebRequest .Content is a Byte[] -> decode UTF-8 before use.
  - Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string]   $ApiUrl        = 'https://ng-api-http.coralogix.com/api/v1/dataprime/query',
    # Which labelled key to use, and which regional endpoint. A US-cluster URL answers 403 for an
    # eu1 account, and that 403 used to read as 'no data'.
    [string]   $KeyLabel      = '',
    [string]   $Region        = 'eu1',
    [string]   $QueryKeyFile  = (Join-Path $PSScriptRoot '..\querydata_key.txt'),
    [int]      $LookbackMinutes = 90,
    [string]   $ExpectedValue = $env:CX_IIS_SERVICES,   # the value the collector stamped
    # Scope every query to one host. Without it a shared Coralogix account happily answers
    # from some OTHER host's telemetry, and the check passes while the host under test sent
    # nothing. Run-E2ELoop.ps1 always passes a unique per-run hostname for exactly this reason
    # (it was already passing -HostName before this parameter existed, which made P4 fail with
    # a parameter-binding error rather than a verdict).
    [string]   $HostName,
    # Names that must NOT appear on this host's infra labels. The point of runtime
    # classification is that a static site, a reverse proxy or an undeterminable app is never
    # claimed as a Service - and the only way to know that held all the way through is to ask
    # the backend, not the installer.
    [string[]] $MustNotContain = @(),
    [string[]] $Tiers         = @('TIER_FREQUENT_SEARCH','TIER_ARCHIVE'),
    [switch]   $DumpSample                              # print a full sample record per stream
)

$ErrorActionPreference = 'Stop'

# Region-aware endpoint: the default host is the US cluster, which is not where an eu1 account's
# data lives.
if ($Region -and $Region -ne 'us' -and $ApiUrl -notmatch [regex]::Escape(".$Region.")) {
    $ApiUrl = "https://ng-api-http.$Region.coralogix.com/api/v1/dataprime/query"
}

# --- keys the final config emits (must match transform/iis_service_labels: 7 winners, arrays).
# Bare cx_service / CX_SERVICE_NAME and the old *_list variants were dropped, so they are not
# probed here.
$allKeys = @(
    'service',
    'tags.service','tags.cx_svc','tags.CX_SERVICE_NAME',
    'cx.infra.labels.service','cx.infra.labels.cx_svc','cx.infra.labels.CX_SERVICE_NAME'
)

# --- query key ---------------------------------------------------------------------------
if (-not (Test-Path $QueryKeyFile)) { throw "Query key file not found: $QueryKeyFile (pass -QueryKeyFile)" }
# Key extraction via the shared helper. Taking the whole file was silently fatal: a real key file
# holds several LABELLED lines ('watcher - cxup_...'), so the Bearer token became a multi-line blob,
# the API answered 403, and every query returned empty - which this script then reported as "no
# telemetry". See scripts\CxQuery.Common.ps1.
. (Join-Path $PSScriptRoot 'CxQuery.Common.ps1')
$__cxKey = Get-CxQueryKey -Path $QueryKeyFile -Label $KeyLabel
$key = $__cxKey.Token
Write-Host ("  key    : {0}" -f $(if ($__cxKey.Label) { "'" + $__cxKey.Label + "'" } else { '<unlabelled>' }))
if (-not $key) { throw "Query key file is empty: $QueryKeyFile" }

$endUtc   = (Get-Date).ToUniversalTime()
$startUtc = $endUtc.AddMinutes(-1 * $LookbackMinutes)
$startISO = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$endISO   = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

function Invoke-DpQuery {
    param([string]$Query, [string]$Tier)
    $body = @{
        query    = $Query
        metadata = @{ tier = $Tier; startDate = $startISO; endDate = $endISO }   # NO syntax key
    } | ConvertTo-Json -Depth 8 -Compress
    try {
        $resp = Invoke-WebRequest -Uri $ApiUrl -Method Post -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body
    } catch {
        Write-Warning "  query failed ($Tier): $($_.Exception.Message)"
        return ''
    }
    if ($resp.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($resp.Content) }
    return [string]$resp.Content
}

# NDJSON -> count data rows (each line with a "userData"/"result" payload is one record).
function Count-Rows { param([string]$Ndjson)
    if (-not $Ndjson) { return 0 }
    return @($Ndjson -split "`n" | Where-Object { $_ -match '"(userData|result|metadata)"' }).Count
}

# Streams to probe. Each is a DataPrime source+filter that isolates infrastructure data.
# When -HostName is given, every stream is additionally pinned to that host so the answer
# cannot come from a different machine reporting into the same account.
$hostFilter = if ($HostName) { " | filter `$d.resource.attributes.host.name == '$HostName' || `$d.host.name == '$HostName'" } else { '' }
$streams = @(
    @{ Name = 'resource-catalog/entity (Infra Explorer)'; Query = "source logs | filter `$l.applicationname == 'resource'$hostFilter | limit 25" },
    @{ Name = 'host stream (subsystem windows)';          Query = "source logs | filter `$l.subsystemname == 'windows'$hostFilter | limit 25" }
)

Write-Host "Coralogix infra-label verification" -ForegroundColor Cyan
Write-Host ("  window : {0}  ->  {1}  ({2} min)" -f $startISO, $endISO, $LookbackMinutes)
Write-Host ("  expect : CX_IIS_SERVICES = '{0}'" -f $ExpectedValue)
Write-Host ("  api    : {0}" -f $ApiUrl)
Write-Host ""

$overall = [ordered]@{}
foreach ($k in $allKeys) { $overall[$k] = @{ KeyHit = $false; ValHit = $false; Where = @() } }
$forbiddenHits = @{}

foreach ($s in $streams) {
    $found = $false
    foreach ($tier in $Tiers) {
        $ndjson = Invoke-DpQuery -Query $s.Query -Tier $tier
        $rows   = Count-Rows $ndjson
        if ($rows -eq 0) { continue }
        $found = $true
        foreach ($bad in $MustNotContain) {
            if ($bad -and $ndjson.Contains($bad)) {
                if (-not $forbiddenHits.ContainsKey($bad)) { $forbiddenHits[$bad] = @() }
                if ($forbiddenHits[$bad] -notcontains $s.Name) { $forbiddenHits[$bad] += $s.Name }
            }
        }
        Write-Host ("[{0}] tier={1} rows={2}" -f $s.Name, $tier, $rows) -ForegroundColor Green
        if ($DumpSample) {
            $first = @($ndjson -split "`n" | Where-Object { $_ -match '"(userData|result)"' })[0]
            if ($first) { Write-Host "   sample: $first" -ForegroundColor DarkGray }
        }
        foreach ($k in $allKeys) {
            # KEY present: the attribute key string appears as a JSON key (robust to the exact
            # keypath Coralogix lands it under - $d.resource.attributes vs merged log attrs).
            if ($ndjson.Contains('"' + $k + '"')) {
                $overall[$k].KeyHit = $true
                if ($overall[$k].Where -notcontains $s.Name) { $overall[$k].Where += $s.Name }
                if ($ExpectedValue -and $ndjson.Contains($ExpectedValue)) { $overall[$k].ValHit = $true }
            }
        }
        break   # first tier with rows wins for this stream
    }
    if (-not $found) { Write-Host ("[{0}] no rows in any tier" -f $s.Name) -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Per-key result (KEY landed / VALUE carried):" -ForegroundColor Cyan
$rowsOut = foreach ($k in $allKeys) {
    [pscustomobject]@{
        Key   = $k
        Kind  = if ($k -like '*_list') { 'array' } else { 'string' }
        Family= if ($k -like 'tags.*') { 'tags.*' } elseif ($k -like 'cx.infra.labels.*') { 'cx.infra.labels.*' } else { 'bare' }
        Key_Landed   = $overall[$k].KeyHit
        Value_Landed = $overall[$k].ValHit
        Seen_In      = ($overall[$k].Where -join '; ')
    }
}
$rowsOut | Format-Table -AutoSize | Out-String | Write-Host

$landed = @($rowsOut | Where-Object { $_.Key_Landed })
Write-Host ("SUMMARY: {0}/{1} candidate keys reached ingestion on infra data." -f $landed.Count, $allKeys.Count) -ForegroundColor Cyan
if ($landed.Count) {
    Write-Host "  landed:" -ForegroundColor Green
    $landed | ForEach-Object { Write-Host ("    {0} [{1}/{2}] value={3}" -f $_.Key, $_.Family, $_.Kind, $_.Value_Landed) }
}
if ($MustNotContain.Count -gt 0) {
    Write-Host ""
    if ($forbiddenHits.Count -eq 0) {
        Write-Host ("OK: none of the excluded names appear on this host's infra telemetry ({0})" -f ($MustNotContain -join ', ')) -ForegroundColor Green
    } else {
        Write-Host "FAIL: names that should never be claimed as Services are present:" -ForegroundColor Red
        foreach ($k in $forbiddenHits.Keys) { Write-Host ("    {0}  in: {1}" -f $k, ($forbiddenHits[$k] -join '; ')) -ForegroundColor Red }
        Write-Host "  These are non-.NET or undeterminable IIS apps. If they reached CX_IIS_SERVICES," -ForegroundColor Red
        Write-Host "  Service ownership points at telemetry that never arrives." -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Next: cross-check Infrastructure Explorer -> Hosts -> Ownership -> Service for the" -ForegroundColor DarkCyan
Write-Host "keys above; bare service/cx_service/CX_SERVICE_NAME are the documented ownership keys." -ForegroundColor DarkCyan

# Non-zero exit when an excluded name was actually carried, so Run-E2ELoop.ps1's
# $LASTEXITCODE check turns it into a failed assertion instead of prose nobody reads.
if ($forbiddenHits.Count -gt 0) { exit 1 }
exit 0
