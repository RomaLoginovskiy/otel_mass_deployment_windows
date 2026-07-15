#Requires -RunAsAdministrator
<#
    Fix: the OTel .NET auto-instrumentation OTLP exporter defaults to http/protobuf, which must
    target the collector's HTTP port 4318 (not the gRPC port 4317). Repoint the app-pool env var
    and recycle the pool so w3wp picks it up.
#>
$ErrorActionPreference = "Stop"
$pool = "SimpleWebAppPool"
$appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"

# Remove existing endpoint var, then add the corrected one.
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/-[name='$pool'].environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT']" /commit:apphost 2>$null | Out-Null
& $appcmd set config -section:system.applicationHost/applicationPools `
    "/+[name='$pool'].environmentVariables.[name='OTEL_EXPORTER_OTLP_ENDPOINT',value='http://localhost:4318']" /commit:apphost

Restart-WebAppPool -Name $pool
Write-Host "OTLP endpoint set to http://localhost:4318 and pool '$pool' recycled." -ForegroundColor Green
& $appcmd list config -section:system.applicationHost/applicationPools | Select-String "OTEL_"
