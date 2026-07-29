<#
.SYNOPSIS
  Query Coralogix to confirm which service names are ACTUALLY reporting from one host - and which
  are correctly reporting nothing. Exit 0 only when every expectation holds.

.DESCRIPTION
  The companion every other gate in this repo was missing. Verify-CoralogixInfraLabels.ps1 proves
  the host's Service-ownership labels arrive; Verify-CoralogixNodeSpans.ps1 proves the PM2 apps
  report. Nothing proved that each INSTRUMENTED APPLICATION - ASP.NET Core 8 in-process, the same
  app out-of-process, Core 6, ASP.NET Framework 4.8, a Node app running as a Windows service, a
  .NET worker service - actually produces spans, or that the shapes deliberately left alone
  produce none.

  That distinction is the whole point of runtime classification, and it can only be settled in the
  backend:

    * a host can claim a service name in CX_IIS_SERVICES and emit nothing under it (a silent
      Service reads as an outage), and
    * a host can emit under a name it never claimed (ownership is then incomplete).

  Local state cannot tell you either way. So this gates on ingested data:

    -Services          every one MUST have spans > 0            (positive gate)
    -MustBeSilent      every one MUST have exactly 0 spans      (negative gate)
    -RequireLogs       additionally require logs > 0 per service (off by default: log routing is
                       governed by the collector's logs pipeline, which on this account comes from
                       the remote Fleet config, so absence is not evidence about instrumentation)

  Queries are scoped to one host wherever the signal carries a host attribute, because a shared
  account will happily answer from another machine's telemetry and turn a broken run green.

  Keypath notes, learned against this account and kept identical to Verify-CoralogixNodeSpans.ps1
  so the two cannot disagree: Coralogix maps OTel service.name onto the span label
  `serviceName` (CAMELCASE), while log records carry it as `subsystemname` (lowercase). Both the
  label ($l) and data ($d) positions are tried, and the frequent-search tier is queried before the
  archive tier.

.PARAMETER Services
  Service names that must be reporting spans. Comma-separated or an array.

.PARAMETER MustBeSilent
  Service names that must have NO spans - the refusal cases (a CLR-2 app, an ARR proxy, a static
  site). A hit here is a real defect: something was instrumented that this tooling declared it
  would not touch.

.PARAMETER HostName
  Restrict to one host (matched against the span's host attribute). Strongly recommended.

.NOTES
  Uses a Coralogix QUERY key (Bearer), not the send key. metadata.syntax is deliberately omitted
  (sending the enum returns HTTP 400). Response is NDJSON and Invoke-WebRequest returns Byte[], so
  it is decoded as UTF-8. Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    # Region matters: ng-api-http.coralogix.com (the US cluster) answers 403 for an eu1 account,
    # and a 403 read as "no rows" is exactly how this gate reported silence for a reporting host.
    [string]   $Region          = 'eu1',
    [string]   $ApiUrl          = '',
    [string]   $QueryKeyFile    = $null,
    # Which key in the file to use when it holds several labelled ones ('watcher - cxup_...').
    [string]   $KeyLabel        = '',
    [string[]] $Services        = @(),
    [string[]] $MustBeSilent    = @(),
    [string]   $HostName        = '',
    [int]      $LookbackMinutes = 90,
    [string[]] $Tiers           = @('TIER_FREQUENT_SEARCH','TIER_ARCHIVE'),
    [switch]   $RequireLogs
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ApiUrl) {
    $ApiUrl = if ($Region -and $Region -ne 'us') { "https://ng-api-http.$Region.coralogix.com/api/v1/dataprime/query" }
              else { 'https://ng-api-http.coralogix.com/api/v1/dataprime/query' }
}
if (-not $QueryKeyFile) { $QueryKeyFile = Join-Path $here '..\querydata_key.txt' }
if (-not (Test-Path $QueryKeyFile)) { throw "query key file not found: $QueryKeyFile" }

# Key extraction and the query call both live in CxQuery.Common.ps1, which fails LOUDLY on a
# non-200. Taking the whole file (or a whole labelled line) as the token is how these gates came to
# report "0 spans" for everything while the API was answering 403.
. (Join-Path $here 'CxQuery.Common.ps1')
$keyInfo = Get-CxQueryKey -Path $QueryKeyFile -Label $KeyLabel
$key = $keyInfo.Token
Write-Host "  key       : $(if ($keyInfo.Label) { "'" + $keyInfo.Label + "'" } else { '<unlabelled>' }) from $(Split-Path -Leaf $QueryKeyFile)"

# `-Services 'a,b'` and `-Services a,b` must behave the same: through `powershell -File` an array
# arrives as one comma-joined string, and a caller that forgets is otherwise silently checking a
# single service named 'a,b'.
function Split-List { param([string[]] $V) return @($V | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$Services     = Split-List $Services
$MustBeSilent = Split-List $MustBeSilent

if (-not $Services.Count -and -not $MustBeSilent.Count) { throw 'nothing to check: pass -Services and/or -MustBeSilent' }

$endISO   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$startISO = (Get-Date).ToUniversalTime().AddMinutes(-$LookbackMinutes).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

function Invoke-DpQuery {
    param([string] $Query, [string] $Tier)
    # No try/catch here on purpose: an auth or transport failure must propagate, not become '' and
    # then read as "this service is silent".
    return (Invoke-CxDataPrime -Query $Query -Key $key -ApiUrl $ApiUrl -Tier $Tier -StartIso $startISO -EndIso $endISO)
}

function Get-Hits {
    <#
      Row count for the first query/tier combination that returns anything. The API packs results
      into one JSON object on a single line, so rows are counted by occurrences of the userData
      marker rather than by lines.
    #>
    param([string[]] $Queries)
    foreach ($q in $Queries) {
        foreach ($tier in $Tiers) {
            $nd = Invoke-DpQuery -Query $q -Tier $tier
            if (-not $nd) { continue }
            $c = Get-CxRowCount -Ndjson $nd
            if ($c -gt 0) { return [pscustomobject]@{ Count = $c; Tier = $tier; Query = $q } }
        }
    }
    return [pscustomobject]@{ Count = 0; Tier = ''; Query = ($Queries | Select-Object -First 1) }
}

# Host scoping. Spans carry resource attributes under $d.process.tags on this account (NOT
# $d.resource.attributes, which does not exist for spans), so both spellings are attempted.
function Get-HostFilter {
    <#
      Spans carry the host as the Coralogix APPLICATION label (the host.name fallback), and Windows
      reports the computer name in UPPERCASE - so scoping on a lowercase VM name matched nothing and
      made every service look silent. Both spellings are compared.
    #>
    if (-not $HostName) { return '' }
    $u = $HostName.ToUpperInvariant()
    return " && (`$l.applicationName == '$u' || `$l.applicationName == '$HostName')"
}

function Get-SpanCount {
    param([string] $Svc)
    $hf = Get-HostFilter
    return (Get-Hits -Queries @(
        "source spans | filter `$l.serviceName == '$Svc'$hf | limit 500",
        "source spans | filter `$d.serviceName == '$Svc'$hf | limit 500",
        # Unscoped last: better a host-wide answer than none, and the tier/query used is printed.
        "source spans | filter `$l.serviceName == '$Svc' | limit 500"
    ))
}

function Get-LogCount {
    param([string] $Svc)
    return (Get-Hits -Queries @(
        "source logs | filter `$l.subsystemname == '$Svc' | limit 200",
        "source logs | filter `$l.applicationname == '$Svc' | limit 200"
    ))
}

Write-Host ''
Write-Host "=== Coralogix service telemetry gate ===" -ForegroundColor Cyan
Write-Host "  api       : $ApiUrl"
Write-Host "  host      : $(if ($HostName) { $HostName } else { '<all hosts - results are not host-scoped>' })"
Write-Host "  lookback  : $LookbackMinutes min   tiers: $($Tiers -join ', ')"
Write-Host ''

$rows = New-Object System.Collections.Generic.List[object]
$fail = 0

foreach ($svc in $Services) {
    $spans = Get-SpanCount -Svc $svc
    $logs  = if ($RequireLogs) { Get-LogCount -Svc $svc } else { $null }
    $ok    = ($spans.Count -gt 0) -and ((-not $RequireLogs) -or ($logs.Count -gt 0))
    if (-not $ok) { $fail++ }
    $rows.Add([pscustomobject]@{
        Service = $svc
        Expect  = 'reporting'
        Spans   = $spans.Count
        Logs    = $(if ($null -ne $logs) { $logs.Count } else { 'n/a' })
        Tier    = $spans.Tier
        Verdict = $(if ($ok) { 'PASS' } else { 'FAIL' })
    })
}

foreach ($svc in $MustBeSilent) {
    $spans = Get-SpanCount -Svc $svc
    $ok = ($spans.Count -eq 0)
    if (-not $ok) { $fail++ }
    $rows.Add([pscustomobject]@{
        Service = $svc
        Expect  = 'silent'
        Spans   = $spans.Count
        Logs    = 'n/a'
        Tier    = $spans.Tier
        Verdict = $(if ($ok) { 'PASS' } else { 'FAIL' })
    })
}

$rows | Format-Table -AutoSize | Out-String | Write-Host

Write-Host 'Gate: every -Services entry has spans > 0; every -MustBeSilent entry has exactly 0.'
if ($RequireLogs) { Write-Host '      -RequireLogs also demands logs > 0 per reporting service.' }
Write-Host ''
if ($fail -eq 0) {
    Write-Host "RESULT: PASS - $($Services.Count) service(s) reporting, $($MustBeSilent.Count) correctly silent." -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: FAIL - $fail expectation(s) not met." -ForegroundColor Red
Write-Host 'If a reporting service shows 0 spans, allow a few minutes for ingestion and re-run before concluding.'
Write-Host 'A MustBeSilent service with spans > 0 is the more serious direction: something was instrumented that the'
Write-Host 'classification rules said would be left alone, so a name nobody claims is now emitting.'
exit 1
