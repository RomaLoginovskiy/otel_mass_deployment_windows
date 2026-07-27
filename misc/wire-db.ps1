#Requires -RunAsAdministrator
<#
    Wires the SimpleWebApp /db endpoint to the local SQL Server container (otel-mssql)
    by setting ConnectionStrings__Sql on the app pool, recycles the pool, then drives
    /db traffic so the OTel .NET auto-instrumentation emits db.system=mssql spans
    (which populate the DB span-metrics pipeline shipped to Coralogix).

    The connection string is hardcoded here on purpose: passing a value containing
    spaces and semicolons through Start-Process -Verb RunAs splits it across params.
#>
$ErrorActionPreference = "Stop"
$pool = "SimpleWebAppPool"
$port = 8080
$appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
# 127.0.0.1 (not localhost): localhost resolves to ::1 first, and Docker's IPv6
# port publish does not forward to the container, so localhost hangs/times out.
$conn = 'Server=127.0.0.1,1433;Database=master;User Id=sa;Password=Otel!Passw0rd2026;Encrypt=False;TrustServerCertificate=True'
Start-Transcript -Path (Join-Path $PSScriptRoot "wire-db.log") -Force | Out-Null
try {
    Write-Host "== set ConnectionStrings__Sql on pool =="
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/-[name='$pool'].environmentVariables.[name='ConnectionStrings__Sql']" /commit:apphost 2>$null | Out-Null
    & $appcmd set config -section:system.applicationHost/applicationPools `
        "/+[name='$pool'].environmentVariables.[name='ConnectionStrings__Sql',value='$conn']" /commit:apphost | Out-Null
    Restart-WebAppPool -Name $pool
    Start-Sleep -Seconds 3
    & $appcmd list config -section:system.applicationHost/applicationPools | Select-String "ConnectionStrings__Sql"

    Write-Host "== drive /db traffic =="
    $ok = 0; $fail = 0
    1..30 | ForEach-Object {
        try { $r = Invoke-WebRequest "http://localhost:$port/db" -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop; if ($r.StatusCode -eq 200) { $ok++ } else { $fail++ } }
        catch { $fail++ }
        Start-Sleep -Milliseconds 150
    }
    Write-Host "RESULT /db ok=$ok fail=$fail"
    try { $r = Invoke-WebRequest "http://localhost:$port/db" -UseBasicParsing -TimeoutSec 25; Write-Host ("SAMPLE /db -> HTTP " + $r.StatusCode + " " + $r.Content) }
    catch { Write-Host ("SAMPLE /db -> " + $_.Exception.Message) }
}
finally { Stop-Transcript | Out-Null }
