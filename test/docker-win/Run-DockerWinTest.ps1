<#
.SYNOPSIS
  Build + run the Windows IIS + Coralogix-supervisor E2E image and check that the automation's
  CX_IIS_SERVICES populated the Service-ownership tags (aligned with per-app OTEL_SERVICE_NAME).

.DESCRIPTION
  Requires Docker Desktop in WINDOWS-container mode. Builds from the repo root, runs the
  container with a fixed --hostname (so it can be found in Coralogix), waits for the entrypoint
  to report name alignment + supervisor start, then queries Coralogix host logs for the tags.
  Final Service-ownership confirmation is in Infrastructure Explorer (server-side, ~15 min).

.NOTES
  Send key + query key are read from the repo (gitignored), never printed.
#>
[CmdletBinding()]
param(
    [string] $Image          = 'cx-iis-owner-test',
    [string] $Container      = 'cx-owner-test',
    [string] $HostName       = 'cx-owner-test',
    [string] $Sites          = 'shop,wallet,blog',
    [string] $RepoRoot       = 'C:\Users\roman\Documents\projects\iis_instrumentation_test',
    [string] $PrivateKeyFile,
    [string] $QueryKeyFile
)
# NOTE: keep this 'Continue'. Native docker commands write to stderr (e.g. `docker rm -f` on a
# missing container), which under 'Stop' becomes a terminating NativeCommandError in Windows
# PowerShell 5.1 and aborts the script. We gate real failures on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

# Resolve repo root robustly (do NOT rely on $PSScriptRoot - empty under some -File launches).
if ($PSCommandPath) { $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) }
if (-not $PrivateKeyFile) { $PrivateKeyFile = Join-Path $RepoRoot 'SimpleWebApp\coralogix\SendDataKey.txt' }
if (-not $QueryKeyFile)   { $QueryKeyFile   = Join-Path $RepoRoot 'querydata_key.txt' }

if ((docker version --format '{{.Server.Os}}') -ne 'windows') {
    throw "Docker is not in Windows-container mode. Switch: & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine"
}

$repo = $RepoRoot
Write-Host "== build ($Image) from $repo ==" -ForegroundColor Cyan
Push-Location $repo
try { docker build -f test/docker-win/Dockerfile -t $Image . }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)" }

$key = (Get-Content $PrivateKeyFile -Raw).Trim()
docker rm -f $Container 2>$null | Out-Null
Write-Host "== run ($Container, host=$HostName, sites=$Sites) ==" -ForegroundColor Cyan
docker run -d --name $Container --hostname $HostName `
    -e CORALOGIX_PRIVATE_KEY=$key -e "CX_TEST_SITES=$Sites" $Image | Out-Null

# Wait for the entrypoint to reach the [alive] heartbeat (IIS configured, names set, supervisor started).
$deadline = (Get-Date).AddMinutes(4)
do {
    Start-Sleep -Seconds 10
    $logs = docker logs $Container 2>&1 | Out-String
    $alive = $logs -match '\[alive\]'
} until ($alive -or (Get-Date) -gt $deadline)

Write-Host "== container log (names + supervisor) ==" -ForegroundColor Cyan
($logs -split "`n" | Select-String 'names|aligned|alive|export|collector|health|EXITED' | Select-Object -First 25) | ForEach-Object { Write-Host $_.Line }

# Coralogix host-log query: the processor is logs-only, so the 7 tags ride the host logs +
# the Infra-Explorer entity. Check host logs (subsystem 'windows') for this container host.
Write-Host "== Coralogix host-log check (host=$HostName) ==" -ForegroundColor Cyan
$qkey = (Get-Content $QueryKeyFile -Raw).Trim()
$api = 'https://ng-api-http.coralogix.com/api/v1/dataprime/query'
$end = (Get-Date).ToUniversalTime(); $start = $end.AddMinutes(-20)
$body = @{ query = "source logs | filter `$m.computername == '$HostName' || `$d.resource.attributes['host.name'] == '$HostName' | limit 3"
           metadata = @{ tier = 'TIER_ARCHIVE'; startDate = $start.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); endDate = $end.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } } | ConvertTo-Json -Depth 6 -Compress
try {
    $r = Invoke-WebRequest -Uri $api -Method Post -UseBasicParsing -Headers @{ Authorization = "Bearer $qkey" } -ContentType 'application/json' -Body $body
    $t = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    $rows = @($t -split "`n" | Where-Object { $_ -match '"userData"' })
    if ($rows.Count) {
        foreach ($k in 'service','cx_service','CX_SERVICE_NAME','tags.service','cx.infra.labels.service') {
            Write-Host ("   {0,-30} present={1}" -f $k, [bool]($rows[0].Contains('"' + $k + '"')))
        }
    } else { Write-Host "   no host logs yet (archive lag / low volume) - check again shortly" }
} catch { Write-Warning "   query failed: $($_.Exception.Message)" }

Write-Host ""
Write-Host "FINAL CHECK (manual, ~15 min): Coralogix Infrastructure Explorer -> Hosts -> '$HostName'" -ForegroundColor Yellow
Write-Host "  -> Ownership -> Service should list: $Sites + 'Default Web Site' (one item per IIS app)." -ForegroundColor Yellow
Write-Host "Teardown: docker rm -f $Container" -ForegroundColor DarkGray
