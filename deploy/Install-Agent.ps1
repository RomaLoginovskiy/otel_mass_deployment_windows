<#
.SYNOPSIS
  Fleet agent orchestrator: detect workloads -> install Coralogix collector in
  Supervisor mode -> conditionally configure IIS zero-code instrumentation.

.DESCRIPTION
  This is the single entry point BatchPatch invokes on each target server (via
  deploy.bat). It is idempotent and transcript-logged. Steps:
    1. Detect workloads (Detect-Workloads.ps1) and publish agent-selector
       attributes to machine-level OTEL_RESOURCE_ATTRIBUTES.
    2. Install the collector in Supervisor mode (Install-CoralogixSupervisor.ps1),
       so Coralogix Fleet Management can push remote config.
    3. If IIS is present, run zero-code .NET auto-instrumentation
       (Instrument-IIS.ps1) unless -SkipInstrument.
    4. Restart the collector so it re-reads OTEL_RESOURCE_ATTRIBUTES, then verify
       and write a JSON status summary.

.PARAMETER Domain
  Coralogix domain. Default: eu1.coralogix.com

.PARAMETER KeyFile
  File containing the Send-Your-Data key. Default: .\SendDataKey.txt

.PARAMETER PrivateKey
  Key value (overrides KeyFile). Prefer passing via a secured file / BatchPatch.

.PARAMETER Environment
  Optional deployment.environment.name resource attribute (e.g. production).

.PARAMETER SkipInstrument
  Skip IIS zero-code instrumentation even if IIS is detected.

.PARAMETER InstrumentVersion
  Auto-instrumentation release tag forwarded to Instrument-IIS.ps1.

.NOTES
  Run elevated. Exit code 0 = success (BatchPatch treats non-zero as failure).
#>
[CmdletBinding()]
param(
    [string] $Domain            = 'eu1.coralogix.com',
    [string] $KeyFile           = $null,
    [string] $PrivateKey        = $null,
    [string] $Environment       = $null,
    [switch] $SkipInstrument,
    [string] $InstrumentVersion = 'v1.16.0-beta.1'
)

$ErrorActionPreference = 'Stop'
# Resolve script dir robustly - $PSScriptRoot can be empty when invoked via
# `powershell -File <relative-path>`, so fall back to the invocation path.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $KeyFile) { $KeyFile = Join-Path $here 'SendDataKey.txt' }
$logDir = $here
$transcript = Join-Path $logDir 'install-agent.log'
try { Start-Transcript -Path $transcript -Append | Out-Null } catch {}

$status = [ordered]@{
    host          = $env:COMPUTERNAME
    started       = (Get-Date).ToString('s')
    primaryRole   = $null
    workloads     = @()
    supervisor    = $false
    iisInstrumented = $false
    healthOk      = $false
    result        = 'unknown'
    error         = $null
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Install-Agent must run elevated (Administrator)."
    }
}

try {
    Assert-Admin
    Write-Host "=== Coralogix fleet agent install on $($env:COMPUTERNAME) ==="

    # -- 1. Detect workloads ----------------------------------------------------
    $extra = @{}
    if ($Environment) { $extra['deployment.environment.name'] = $Environment }
    $roles = & (Join-Path $here 'Detect-Workloads.ps1') -SetEnv $true -ExtraAttributes $extra
    $status.primaryRole = $roles.PrimaryRole
    $status.workloads = @('iis','dotnet','nodejs','rabbitmq','redis','valkey','sqlserver','db2','elasticsearch' |
        Where-Object {
            switch ($_) {
                'iis'           { $roles.IIS }
                'dotnet'        { $roles.DotNet }
                'nodejs'        { $roles.NodeJs }
                'rabbitmq'      { $roles.RabbitMQ }
                'redis'         { $roles.Redis }
                'valkey'        { $roles.Valkey }
                'sqlserver'     { $roles.SqlServer }
                'db2'           { $roles.Db2 }
                'elasticsearch' { $roles.Elasticsearch }
            }
        })

    # -- 2. Install collector in Supervisor mode --------------------------------
    $supArgs = @{ Domain = $Domain; BaseConfig = (Join-Path $here 'config.supervisor.yaml') }
    if ($PrivateKey) { $supArgs['PrivateKey'] = $PrivateKey } else { $supArgs['KeyFile'] = $KeyFile }
    & (Join-Path $here 'Install-CoralogixSupervisor.ps1') @supArgs
    $status.supervisor = $true

    # -- 3. Conditional IIS zero-code instrumentation ---------------------------
    if ($roles.IIS -and -not $SkipInstrument) {
        Write-Host "[agent] IIS detected -> configuring zero-code .NET instrumentation"
        & (Join-Path $here 'Instrument-IIS.ps1') -Version $InstrumentVersion
        $status.iisInstrumented = $true
    } elseif ($roles.IIS) {
        Write-Host "[agent] IIS detected but -SkipInstrument set; skipping instrumentation"
    } else {
        Write-Host "[agent] IIS not detected; skipping zero-code instrumentation"
    }

    # -- 4. Restart collector to pick up OTEL_RESOURCE_ATTRIBUTES ----------------
    $svc = Get-Service -Name 'otelcol-contrib' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "[agent] restarting otelcol-contrib to apply resource attributes"
        Restart-Service -Name 'otelcol-contrib' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }

    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 10
        $status.healthOk = ($r.StatusCode -eq 200)
    } catch { $status.healthOk = $false }

    $status.result = if ($status.supervisor) { 'success' } else { 'partial' }
    Write-Host "=== done: role=$($status.primaryRole) workloads=[$($status.workloads -join ',')] iisInstrumented=$($status.iisInstrumented) health=$($status.healthOk) ==="
}
catch {
    $status.result = 'error'
    $status.error  = $_.Exception.Message
    Write-Error $_
}
finally {
    $status.finished = (Get-Date).ToString('s')
    try { $status | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $logDir 'install-agent-status.json') -Encoding utf8 } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

if ($status.result -eq 'error') { exit 1 } else { exit 0 }
