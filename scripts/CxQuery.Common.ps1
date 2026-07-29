<#
.SYNOPSIS
  Shared Coralogix query-API helpers: key extraction and a DataPrime call that FAILS LOUDLY.
  Dot-source it.

.DESCRIPTION
  Both of these exist because of the same class of bug, found while wiring per-application telemetry
  gates into the VM matrix:

  1. KEY EXTRACTION. The verifiers did `(Get-Content $QueryKeyFile -Raw).Trim()` - the whole file as
     the Bearer token. A real key file in this repo holds several LABELLED lines:

         watcher - cxup_XXXX
         sga coralogix - cxup_YYYY
         sga the reference agent - dt0c01.ZZZZ

     so the token sent was the entire multi-line blob, the API answered 403, and every query came
     back empty. Nothing said "unauthorised" anywhere.

  2. AN HTTP FAILURE IS NOT AN EMPTY RESULT. The callers caught every exception and returned '',
     which a row-counting gate reads as "no data". For a positive gate that is a confusing false
     failure; for a NEGATIVE gate ("this service must be silent") it is worse - an unauthenticated
     query makes every forbidden service look correctly silent, and the run passes while proving
     nothing. A gate that cannot tell "no telemetry" from "no answer" is not a gate.

  So: keys are extracted by token pattern with an optional label filter, and a non-200 raises,
  with 401/403 named explicitly.
#>

function Get-CxQueryKey {
    <#
      Pull a Coralogix API key out of a key file.

      Accepts a bare token per line, or 'label - token' lines. -Label picks among several
      (substring, case-insensitive); without it the first Coralogix (cxup_) token wins - never a
      the reference agent dt0c01 token, which is a different vendor's key that happens to share the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "query key file not found: $Path" }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = "$raw".Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        # Coralogix personal/API keys start cxup_; also accept a bare long token with no label.
        $m = [regex]::Match($line, '(cxup_[A-Za-z0-9_\-]{8,})')
        if (-not $m.Success) {
            if ($line -match '^[A-Za-z0-9_\-]{24,}$') { $candidates.Add([pscustomobject]@{ Label = ''; Token = $line }) }
            continue
        }
        # $parsedLabel, NOT $label: PowerShell variable names are case-INSENSITIVE, so a local
        # `$label` IS the `$Label` parameter. Assigning it here overwrote the caller's requested
        # label with the last line's label, so -Label 'watcher' selected 'sga coralogix' - and with
        # no -Label at all the now-non-empty $Label made the filter branch run anyway. Same class of
        # bug as the dot-sourced helper that clobbered $VmName.
        $parsedLabel = ($line.Substring(0, $m.Index) -replace '[-:\s]+$', '').Trim()
        $candidates.Add([pscustomobject]@{ Label = $parsedLabel; Token = $m.Groups[1].Value })
    }

    if (-not $candidates.Count) {
        throw "no Coralogix (cxup_) key found in $Path. Lines look like 'label - cxup_...' or a bare token; a the reference agent dt0c01 key is not usable here."
    }

    if ($Label) {
        $hit = @($candidates | Where-Object { $_.Label -and $_.Label -like "*$Label*" }) | Select-Object -First 1
        if (-not $hit) {
            throw "no key labelled '*$Label*' in $Path (labels present: $(@($candidates | ForEach-Object { if ($_.Label) { $_.Label } else { '<unlabelled>' } }) -join ', '))"
        }
        return $hit
    }

    return $candidates[0]
}

function Invoke-CxDataPrime {
    <#
      One DataPrime query. Returns the NDJSON body on success and THROWS on a non-200, so an
      authorisation problem can never be mistaken for an absence of data.

      metadata.syntax is deliberately omitted: sending the enum returns HTTP 400 on this account.
      The response body arrives as Byte[] from Invoke-WebRequest, so it is decoded as UTF-8.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] [string] $Key,
        [string] $ApiUrl = 'https://ng-api-http.coralogix.com/api/v1/dataprime/query',
        [string] $Tier   = 'TIER_FREQUENT_SEARCH',
        [string] $StartIso,
        [string] $EndIso,
        [int]    $TimeoutSec = 90
    )

    if (-not $EndIso)   { $EndIso   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    if (-not $StartIso) { $StartIso = (Get-Date).ToUniversalTime().AddMinutes(-60).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }

    $body = @{ query = $Query; metadata = @{ tier = $Tier; startDate = $StartIso; endDate = $EndIso } } |
                ConvertTo-Json -Depth 8 -Compress

    # 429 is retried with backoff. A gate that asks about a dozen services makes a dozen queries per
    # tier, and the API rate-limits well before that is unreasonable - without a retry the run fails
    # for a reason that has nothing to do with the telemetry under test. Retries are bounded and an
    # exhausted retry is still a hard error, never silence.
    $attempt = 0
    $delays  = @(8, 20, 45)
    while ($true) {
        try {
            $resp = Invoke-WebRequest -Uri $ApiUrl -Method Post -UseBasicParsing `
                        -Headers @{ Authorization = "Bearer $Key"; 'Content-Type' = 'application/json' } `
                        -Body $body -TimeoutSec $TimeoutSec
            break
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { }
            if ($code -eq 401 -or $code -eq 403) {
                throw "Coralogix query API returned $code (unauthorised). The key was rejected - check that the key file holds a Coralogix QUERY key for THIS account AND region (a US-cluster URL answers 403 for an eu1 account), and that the token was extracted without its label prefix. This is NOT 'no data'."
            }
            if ($code -eq 429 -and $attempt -lt $delays.Count) {
                $wait = $delays[$attempt]; $attempt++
                Write-Host "  [query] rate-limited (429); retrying in ${wait}s (attempt $attempt of $($delays.Count))" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            if ($code -eq 429) {
                throw "Coralogix query API kept returning 429 after $($delays.Count) retries. Slow down or narrow the query set - this is a rate limit, NOT an absence of telemetry."
            }
            throw "Coralogix query API call failed$(if ($code) { " (HTTP $code)" }): $($_.Exception.Message)"
        }
    }

    if ($resp.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($resp.Content) }
    return [string]$resp.Content
}

function Get-CxRowCount {
    <#
      Rows in an NDJSON response. The API packs results into one JSON object on a single line, so
      rows are counted by occurrences of the userData marker rather than by newlines.
    #>
    param([string] $Ndjson)
    if (-not $Ndjson) { return 0 }
    return ([regex]::Matches($Ndjson, '"userData"')).Count
}
