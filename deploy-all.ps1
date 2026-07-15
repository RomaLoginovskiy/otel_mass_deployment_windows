#Requires -RunAsAdministrator
#Requires -PSEdition Desktop
<#
    Consolidated, idempotent deploy + verify for the v5 OTel/Coralogix setup.
    Runs the whole remaining chain in one elevated pass and transcripts to deploy-all.log:
      1. Restage collector config.yaml -> C:\otel and restart otelcol-contrib (a clean
         restart also validates the v5 config: an unknown component or bad key would stop it).
      2. Deploy the app to IIS      (reuses deploy-iis.ps1).
      3. Zero-code auto-instrument  (reuses instrument-otel.ps1 + fix-otlp-endpoint.ps1).
      4. Point the app's DB endpoint at the SQL Server container (ConnectionStrings__Sql pool env).
      5. Generate traffic to /, /health, /db.
      6. Verify collector + site + self-metrics and print a RESULT summary.
    Non-fatal phases (SQL/db) never abort the run; all HTTP/host/log signals still ship.
#>
param(
    # Default points at the local SQL Server container (otel-mssql). 127.0.0.1 (not localhost):
    # localhost resolves to ::1 first and Docker's IPv6 publish does not forward to the container.
    # Defaulted (not passed) so the ';'/space-laden value never crosses Start-Process -Verb RunAs,
    # which would split it across params.
    [string]$SqlConn = "Server=127.0.0.1,1433;Database=master;User Id=sa;Password=Otel!Passw0rd2026;Encrypt=False;TrustServerCertificate=True",
    [switch]$SkipDeploy,                          # site already deployed => skip deploy-iis.ps1
    [switch]$SkipInstrument,                      # already auto-instrumented => skip instrument-otel.ps1
    [string]$Pool    = "SimpleWebAppPool",
    [string]$Site    = "SimpleWebApp",
    [int]   $Port    = 8080
)

$ErrorActionPreference = "Stop"
$root   = $PSScriptRoot
$appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
$log    = Join-Path $root "deploy-all.log"
Start-Transcript -Path $log -Force | Out-Null
$summary = [ordered]@{}

function Phase($name, [scriptblock]$body, [bool]$fatal = $true) {
    Write-Host "`n===== $name =====" -ForegroundColor Cyan
    try { & $body; $script:summary[$name] = "OK"; Write-Host "[OK] $name" -ForegroundColor Green }
    catch {
        $script:summary[$name] = "FAIL: $($_.Exception.Message)"
        Write-Warning "[FAIL] $name -> $($_.Exception.Message)"
        if ($fatal) { throw }
    }
}

try {
    Phase "1. Restage config + restart collector" {
        New-Item -ItemType Directory -Force -Path C:\otel | Out-Null
        Copy-Item (Join-Path $root "SimpleWebApp\coralogix\config.yaml") C:\otel\config.yaml -Force
        # Re-assert the Coralogix key as a machine env var so the restarted service has it.
        $keyPath = Join-Path $root "SimpleWebApp\coralogix\SendDataKey.txt"
        $key = (Get-Content $keyPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { throw "SendDataKey.txt empty" }
        [Environment]::SetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', $key, 'Machine')
        $env:CORALOGIX_PRIVATE_KEY = $key
        Restart-Service otelcol-contrib -Force
        Start-Sleep -Seconds 6
        $svc = Get-Service otelcol-contrib
        Write-Host ("  otelcol-contrib: " + $svc.Status)
        if ($svc.Status -ne 'Running') { throw "collector not Running after restart (likely a config error) - see Event Viewer / collector log" }
        Write-Host "  config accepted (service Running => all v5 components loaded, no removed 'address' key)."
    }

    if ($SkipDeploy) {
        Write-Host "`n===== 2. Deploy app to IIS ===== (skipped: -SkipDeploy)" -ForegroundColor Cyan
        $summary["2. Deploy app to IIS"] = "SKIPPED (already deployed)"
    } else {
        # Non-fatal: deploy-iis.ps1's own verify probe can time out on first cold start
        # even though the site deployed fine; the traffic/verify phases below confirm health.
        Phase "2. Deploy app to IIS" {
            & (Join-Path $root "deploy-iis.ps1")
        } $false
    }

    if ($SkipInstrument) {
        Write-Host "`n===== 3. Auto-instrument for IIS ===== (skipped: -SkipInstrument)" -ForegroundColor Cyan
        $summary["3. Auto-instrument for IIS"] = "SKIPPED (already instrumented)"
    } else {
        Phase "3. Auto-instrument for IIS" {
            # A running w3wp holds the auto-instrumentation DLLs open, so
            # Install-OpenTelemetryCore's clean reinstall fails with "Access denied".
            # Stop IIS first to release the locks; instrument-otel.ps1 restarts it (iisreset).
            Write-Host "  stopping IIS to release instrumentation DLL locks..."
            iisreset /stop | Out-Null
            Start-Sleep -Seconds 2
            & (Join-Path $root "instrument-otel.ps1")
            & (Join-Path $root "fix-otlp-endpoint.ps1")
        }
    }

    Phase "4. Wire DB connection string" {
        if ([string]::IsNullOrWhiteSpace($SqlConn)) {
            Write-Host "  no -SqlConn passed; /db uses appsettings default (may 500 if no local SQL). Skipping."
        } else {
            & $appcmd set config -section:system.applicationHost/applicationPools `
                "/-[name='$Pool'].environmentVariables.[name='ConnectionStrings__Sql']" /commit:apphost 2>$null | Out-Null
            & $appcmd set config -section:system.applicationHost/applicationPools `
                "/+[name='$Pool'].environmentVariables.[name='ConnectionStrings__Sql',value='$SqlConn']" /commit:apphost | Out-Null
            Restart-WebAppPool -Name $Pool
            Write-Host "  ConnectionStrings__Sql set on pool '$Pool' and pool recycled."
        }
    } $false

    Phase "5. Generate traffic" {
        $base = "http://localhost:$Port"
        1..40 | ForEach-Object {
            foreach ($u in @("/", "/health", "/db")) {
                try { Invoke-WebRequest "$base$u" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch {}
            }
            Start-Sleep -Milliseconds 200
        }
        Write-Host "  sent ~120 requests (40 x /, /health, /db)."
    } $false

    Phase "6. Verify" {
        function Probe($u, $sec = 10) { try { $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec $sec; return "HTTP $($r.StatusCode)|$([string]$r.Content)" } catch { return "ERR $($_.Exception.Message)" } }
        Write-Host ("  collector service : " + (Get-Service otelcol-contrib).Status)
        Write-Host ("  health_check 13133: " + (Probe "http://127.0.0.1:13133" 8).Split('|')[0])
        try {
            $m = (Invoke-WebRequest "http://127.0.0.1:8888/metrics" -UseBasicParsing -TimeoutSec 8).Content
            $c = ([regex]::Matches($m, '(?m)^otelcol_')).Count
            Write-Host ("  self-metrics 8888 : otelcol_ series = " + $c)
        } catch { Write-Host ("  self-metrics 8888 : ERR " + $_.Exception.Message) }
        $rootResp = Probe "http://localhost:$Port/" 15
        Write-Host ("  GET /            : " + $rootResp.Split('|')[0])
        $health = Probe "http://localhost:$Port/health" 15
        Write-Host ("  GET /health      : " + $health)
        $db = Probe "http://localhost:$Port/db" 20
        Write-Host ("  GET /db          : " + $db)
    } $false

    Write-Host "`n===== RESULT ====="
    foreach ($k in $summary.Keys) { Write-Host ("  {0,-38} {1}" -f $k, $summary[$k]) }
    Write-Host "`nData should now be arriving in Coralogix (app 'iis-instrumentation-test', subsystem 'SimpleWebApp')."
}
finally {
    Stop-Transcript | Out-Null
}
