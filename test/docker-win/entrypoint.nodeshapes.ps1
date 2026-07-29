<#
.SYNOPSIS
  Boot half of the Node-shape matrix container: start the collector, then idle.

.DESCRIPTION
  Deliberately does NOT set up any Node shape. Run-NodeShapesTest.ps1 drives every shape through
  `docker exec setup-nodeshape.ps1`, because the harness has to control ordering (shapes are
  additive in places and mutually exclusive in others) and has to observe the state BEFORE and
  AFTER each step. An entrypoint that helpfully pre-arranged PM2 would destroy the P1 baseline -
  "PM2 absent" is itself one of the cases under test.

  So this only provides what every shape needs: a running collector on 127.0.0.1:4318 with its
  telemetry endpoint on :8888, which is the harness's immediate per-shape gate.

.NOTES
  Windows PowerShell 5.1, ContainerAdministrator. CORALOGIX_PRIVATE_KEY / CORALOGIX_DOMAIN arrive
  via `docker run -e`; the container is useful without them (every shape except the final Coralogix
  sweep asserts on local state), so a missing key is a warning, not a failure.
#>
$ErrorActionPreference = 'Continue'

Write-Host "=== cx node-shape matrix container ===" -ForegroundColor Cyan
Write-Host "[boot] host=$env:COMPUTERNAME  node=$((& node --version 2>$null))  pm2=$((& pm2 --version 2>$null))"

# IIS is in the base image and starts on its own; the iisnode/ARR shapes need it up.
try { Start-Service W3SVC -ErrorAction Stop; Write-Host '[boot] W3SVC started' } catch { Write-Host "[boot] W3SVC: $($_.Exception.Message)" }

New-Item -ItemType Directory -Force -Path C:\cx\state | Out-Null

if (-not $env:CORALOGIX_PRIVATE_KEY) {
    Write-Warning "[boot] CORALOGIX_PRIVATE_KEY is not set - the collector will start but export will fail. Local per-shape gates still work; the final Coralogix sweep will not."
}

# ---- collector ---------------------------------------------------------------
# Run as a plain background process, not a Windows service: this matrix asserts with
# Test-NodeInstrumentation.ps1 (which never looks at the collector service), and a process is
# faster to restart and to read logs from. The service-mode path is what Run-DoctorTest.ps1 and
# Run-E2ELoop.ps1 already cover.
$colLog = 'C:\cx\state\collector.out.log'
$colErr = 'C:\cx\state\collector.err.log'
Write-Host "[boot] starting collector (domain=$env:CORALOGIX_DOMAIN) ..."
$col = Start-Process 'C:\cx\otelcol-contrib.exe' `
    -ArgumentList '--config', 'C:\cx\nodeshapes\collector.nodeshapes.yaml' `
    -PassThru -RedirectStandardOutput $colLog -RedirectStandardError $colErr
Write-Host "[boot] collector pid=$($col.Id)"

# Wait for health rather than sleeping a guessed interval: a shape asserting on :8888 counters
# immediately after container start would otherwise race the collector's own startup.
$healthy = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $healthy = $true; break }
    } catch { }
}
if ($healthy) {
    Write-Host "[boot] collector healthy on 127.0.0.1:13133" -ForegroundColor Green
} else {
    Write-Warning "[boot] collector did not report healthy in 40s - see $colErr"
    try { Get-Content -LiteralPath $colErr -Tail 20 | ForEach-Object { Write-Host "  $_" } } catch { }
}

'ready' | Set-Content -LiteralPath C:\cx\state\boot.done -Encoding ascii
Write-Host "[boot] READY - shapes are applied by the harness via 'docker exec setup-nodeshape.ps1'" -ForegroundColor Green

# Hold the container open. The harness does all the work through docker exec.
while ($true) { Start-Sleep -Seconds 3600 }
