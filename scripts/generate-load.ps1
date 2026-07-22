<#
    Continuous load generator for the IIS instrumentation test site.

    Sends steady, single-threaded HTTP traffic to the deployed SimpleWebApp so telemetry
    (HTTP spans, SqlClient DB spans from /db, span metrics) keeps flowing to the collector
    and on to Coralogix. Unlike the one-shot burst in deploy-all.ps1, this runs until stopped
    (Ctrl-C) or until -DurationMinutes elapses.

    Only makes HTTP calls, so it does NOT need to run elevated (no #Requires -RunAsAdministrator).

    Examples:
      .\generate-load.ps1                                  # run forever, Ctrl-C to stop
      .\generate-load.ps1 -DurationMinutes 30              # stop after 30 minutes
      .\generate-load.ps1 -DelayMs 1000 -Paths /health     # slow cadence, single endpoint
#>
param(
    [int]     $Port            = 8080,                    # site port
    [string[]]$Paths           = @("/", "/health", "/db"),# endpoints hit each sweep
    [int]     $DelayMs         = 200,                     # pause between each full sweep
    [int]     $DurationMinutes = 0,                       # 0 = run forever until Ctrl-C
    [int]     $StatsEverySec   = 10                       # rolling-stats print interval
)

$ErrorActionPreference = "Stop"

$base      = "http://localhost:$Port"
$deadline  = if ($DurationMinutes -gt 0) { (Get-Date).AddMinutes($DurationMinutes) } else { $null }
$stats     = [ordered]@{ total = 0; ok = 0; fail = 0; totalMs = 0 }
$perPath   = [ordered]@{}; $Paths | ForEach-Object { $perPath[$_] = 0 }
$startedAt = Get-Date
$lastPrint = Get-Date

$durText = if ($deadline) { "$DurationMinutes min" } else { "infinite (Ctrl-C to stop)" }
Write-Host "Load -> $base  paths=$($Paths -join ',')  delay=${DelayMs}ms  duration=$durText" -ForegroundColor Cyan

try {
    while ($true) {
        foreach ($p in $Paths) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $r = Invoke-WebRequest "$base$p" -UseBasicParsing -TimeoutSec 15
                if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { $stats.ok++ } else { $stats.fail++ }
            } catch { $stats.fail++ }
            $sw.Stop()
            $stats.total++; $stats.totalMs += $sw.ElapsedMilliseconds; $perPath[$p]++
        }

        if (((Get-Date) - $lastPrint) -ge [TimeSpan]::FromSeconds($StatsEverySec)) {
            $elapsed = (Get-Date) - $startedAt
            $rps = [math]::Round($stats.total / [math]::Max($elapsed.TotalSeconds, 1), 1)
            $avg = if ($stats.total) { [math]::Round($stats.totalMs / $stats.total) } else { 0 }
            Write-Host ("  [{0:hh\:mm\:ss}] total={1} ok={2} fail={3} rps={4} avg={5}ms" -f `
                $elapsed, $stats.total, $stats.ok, $stats.fail, $rps, $avg) `
                -ForegroundColor $(if ($stats.fail) { "Yellow" } else { "Green" })
            $lastPrint = Get-Date
        }

        if ($deadline -and (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds $DelayMs
    }
}
finally {
    $elapsed = (Get-Date) - $startedAt
    Write-Host "`n===== RESULT =====" -ForegroundColor Cyan
    Write-Host ("  ran {0:hh\:mm\:ss}  total={1}  ok={2}  fail={3}" -f $elapsed, $stats.total, $stats.ok, $stats.fail)
    foreach ($k in $perPath.Keys) { Write-Host ("  {0,-10} {1}" -f $k, $perPath[$k]) }
}
