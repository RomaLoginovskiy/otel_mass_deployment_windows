<#
.SYNOPSIS
  Detect which workloads a Windows host runs and publish them as Coralogix Fleet
  Management agent-selector attributes via the machine-level OTEL_RESOURCE_ATTRIBUTES
  environment variable.

.DESCRIPTION
  Probes for each workload using several independent signals (Windows services,
  running processes, listening TCP ports, install directories / registry). Every
  probe is non-fatal: a failing probe simply reports that workload as absent.

  Targets:
    IIS, .NET (Framework + Core/5+), Node.js (v9 -> latest), RabbitMQ, Redis,
    Valkey, SQL Server, DB2, Elasticsearch.

  Output attribute schema (the agent-selector contract):
    cx.host.role=<primary>        single coarse role, by priority
    workload.<name>=true          one per detected workload (multi-role hosts)
    workload.nodejs.version=<v>    when Node.js present
    workload.dotnet.version=<v>    when .NET present

  These land on the OpAMP AgentDescription (the Supervisor reports the collector's
  resource attributes; resourcedetection/env in the base config promotes
  OTEL_RESOURCE_ATTRIBUTES into the resource), so Coralogix Fleet Management can
  build agent groups / config assignments that select on them.

.PARAMETER SetEnv
  Persist the built attribute string to the machine-level OTEL_RESOURCE_ATTRIBUTES
  environment variable. Default: $true. Requires an elevated session.

.PARAMETER LogPath
  Path to write a JSON detection summary for verification. Default: .\detect-workloads.json

.PARAMETER ExtraAttributes
  Hashtable of additional resource attributes to merge (e.g. deployment.environment).

.OUTPUTS
  A [ordered] hashtable of detection results (booleans + versions + role +
  OtelResourceAttributes string). Suitable for dot-sourcing / consumption by
  Install-Agent.ps1:  $roles = & .\Detect-Workloads.ps1 -SetEnv:$false

.NOTES
  Detection is best-effort. Redis and Valkey both listen on 6379; they are told
  apart by service/process/binary name. Where only the port is seen, the host is
  tagged as the more generic 'redis' unless a Valkey process/service is found.
#>
[CmdletBinding()]
param(
    [bool]   $SetEnv = $true,
    [string] $LogPath = (Join-Path $PSScriptRoot 'detect-workloads.json'),
    [hashtable] $ExtraAttributes = @{},
    # Optional backup/manifest session (from Backup-Config.ps1). When supplied, the
    # prior OTEL_RESOURCE_ATTRIBUTES value is recorded so uninstall can restore or
    # remove it correctly.
    $Session = $null
)

$ErrorActionPreference = 'Continue'

# Optional backup/manifest recording (shared session from the orchestrator).
$backupHelper = Join-Path $PSScriptRoot 'Backup-Config.ps1'
if (Test-Path $backupHelper) { . $backupHelper }

# ---------------------------------------------------------------------------
# Signal helpers (all safe / non-throwing)
# ---------------------------------------------------------------------------
function Test-ServiceLike {
    param([string[]] $Patterns)
    foreach ($p in $Patterns) {
        try {
            $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $p -or $_.DisplayName -like $p }
            if ($svc) { return $true }
        } catch {}
    }
    return $false
}

function Test-ProcessLike {
    param([string[]] $Names)
    foreach ($n in $Names) {
        try {
            if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
        } catch {}
    }
    return $false
}

function Test-PortListening {
    param([int[]] $Ports)
    foreach ($port in $Ports) {
        try {
            $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
            if ($c) { return $true }
        } catch {
            # Get-NetTCPConnection missing (older hosts) -> fall back to netstat
            try {
                $ns = netstat -an | Select-String -Pattern (":$port\s") -SimpleMatch:$false
                if ($ns -match 'LISTENING') { return $true }
            } catch {}
        }
    }
    return $false
}

function Test-PathAny {
    param([string[]] $Paths)
    foreach ($p in $Paths) {
        try { if ($p -and (Test-Path $p)) { return $true } } catch {}
    }
    return $false
}

# ---------------------------------------------------------------------------
# Per-workload detection
# ---------------------------------------------------------------------------
function Get-IisPresent {
    if (Test-ServiceLike @('W3SVC','WAS'))            { return $true }
    if (Test-ProcessLike @('w3wp','iisexpress'))       { return $true }
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName IIS-WebServer -ErrorAction SilentlyContinue
        if ($f -and $f.State -eq 'Enabled') { return $true }
    } catch {}
    try {
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            $wf = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
            if ($wf -and $wf.Installed) { return $true }
        }
    } catch {}
    return (Test-PathAny @("$env:windir\System32\inetsrv\appcmd.exe"))
}

function Get-DotNetInfo {
    $info = [ordered]@{ present = $false; version = $null }
    # .NET (Core / 5+) via dotnet CLI or install dir
    $ver = $null
    try {
        $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($cmd) {
            $ver = (& dotnet --version) 2>$null
            if ($ver) { $info.present = $true }
        }
    } catch {}
    if (-not $info.present -and (Test-PathAny @("$env:ProgramFiles\dotnet\dotnet.exe","${env:ProgramFiles(x86)}\dotnet\dotnet.exe"))) {
        $info.present = $true
    }
    # .NET Framework via registry (NDP v4 Full release)
    if (-not $info.present -or -not $ver) {
        try {
            $ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
            if ($ndp) {
                $info.present = $true
                if (-not $ver -and $ndp.Version) { $ver = $ndp.Version }
            }
        } catch {}
    }
    $info.version = $ver
    return $info
}

function Get-NodeInfo {
    $info = [ordered]@{ present = $false; version = $null }
    try {
        $cmd = Get-Command node -ErrorAction SilentlyContinue
        if ($cmd) {
            $v = (& node --version) 2>$null   # e.g. v20.11.0
            if ($v) { $info.present = $true; $info.version = ($v -replace '^v','') }
        }
    } catch {}
    if (-not $info.present -and (Test-PathAny @("$env:ProgramFiles\nodejs\node.exe","${env:ProgramFiles(x86)}\nodejs\node.exe"))) {
        $info.present = $true
        try {
            $exe = @("$env:ProgramFiles\nodejs\node.exe","${env:ProgramFiles(x86)}\nodejs\node.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($exe) { $info.version = ((& $exe --version) 2>$null) -replace '^v','' }
        } catch {}
    }
    return $info
}

function Get-RedisPresent {
    if (Test-ServiceLike @('Redis*','*Redis*'))  { return $true }
    if (Test-ProcessLike @('redis-server','redis')) { return $true }
    if (Test-PathAny @("$env:ProgramFiles\Redis","$env:ProgramFiles\Redis\redis-server.exe")) { return $true }
    return $false
}

function Get-ValkeyPresent {
    if (Test-ServiceLike @('Valkey*','*Valkey*'))    { return $true }
    if (Test-ProcessLike @('valkey-server','valkey')) { return $true }
    if (Test-PathAny @("$env:ProgramFiles\Valkey")) { return $true }
    return $false
}

function Get-RabbitPresent {
    if (Test-ServiceLike @('RabbitMQ*'))              { return $true }
    if (Test-ProcessLike @('rabbitmq-server','erl','beam','beam.smp')) {
        # erlang is generic; require the port too
        if (Test-PortListening @(5672,15672)) { return $true }
    }
    if (Test-PortListening @(5672,15672))              { return $true }
    if (Test-PathAny @("$env:ProgramFiles\RabbitMQ Server")) { return $true }
    return $false
}

function Get-SqlServerPresent {
    if (Test-ServiceLike @('MSSQL*','SQLSERVERAGENT','MSSQLSERVER')) { return $true }
    if (Test-ProcessLike @('sqlservr'))                { return $true }
    if (Test-PortListening @(1433))                    { return $true }
    return $false
}

function Get-Db2Present {
    if (Test-ServiceLike @('DB2*'))                    { return $true }
    if (Test-ProcessLike @('db2sysc','db2syscs'))      { return $true }
    if (Test-PortListening @(50000,25000))             { return $true }
    return $false
}

function Get-ElasticPresent {
    if (Test-ServiceLike @('elasticsearch*','Elastic*')) { return $true }
    if (Test-PortListening @(9200,9300))               { return $true }
    if (Test-PathAny @("$env:ProgramFiles\Elastic\Elasticsearch")) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Run detection
# ---------------------------------------------------------------------------
Write-Host "[detect] scanning host for known workloads..."

$dotnet = Get-DotNetInfo
$node   = Get-NodeInfo

$roles = [ordered]@{
    IIS           = [bool](Get-IisPresent)
    DotNet        = [bool]$dotnet.present
    DotNetVersion = $dotnet.version
    NodeJs        = [bool]$node.present
    NodeJsVersion = $node.version
    RabbitMQ      = [bool](Get-RabbitPresent)
    Redis         = [bool](Get-RedisPresent)
    Valkey        = [bool](Get-ValkeyPresent)
    SqlServer     = [bool](Get-SqlServerPresent)
    Db2           = [bool](Get-Db2Present)
    Elasticsearch = [bool](Get-ElasticPresent)
}

# If a Valkey service/process is found, don't also claim redis from a shared 6379.
if ($roles.Valkey -and $roles.Redis) {
    if (-not (Test-ServiceLike @('Redis*')) -and -not (Test-ProcessLike @('redis-server'))) {
        $roles.Redis = $false
    }
}

# ---------------------------------------------------------------------------
# Primary role (coarse selector) by priority
# ---------------------------------------------------------------------------
$priority = @(
    @{ key = 'IIS';           role = 'iis' },
    @{ key = 'SqlServer';     role = 'sqlserver' },
    @{ key = 'Db2';           role = 'db2' },
    @{ key = 'Elasticsearch'; role = 'elasticsearch' },
    @{ key = 'RabbitMQ';      role = 'rabbitmq' },
    @{ key = 'Redis';         role = 'redis' },
    @{ key = 'Valkey';        role = 'valkey' },
    @{ key = 'NodeJs';        role = 'nodejs' },
    @{ key = 'DotNet';        role = 'dotnet' }
)
$primary = 'unknown'
foreach ($p in $priority) { if ($roles[$p.key]) { $primary = $p.role; break } }
$roles['PrimaryRole'] = $primary

# ---------------------------------------------------------------------------
# Build OTEL_RESOURCE_ATTRIBUTES
# ---------------------------------------------------------------------------
$attrMap = [ordered]@{ 'cx.host.role' = $primary }

$workloadKeys = [ordered]@{
    'workload.iis'           = $roles.IIS
    'workload.dotnet'        = $roles.DotNet
    'workload.nodejs'        = $roles.NodeJs
    'workload.rabbitmq'      = $roles.RabbitMQ
    'workload.redis'         = $roles.Redis
    'workload.valkey'        = $roles.Valkey
    'workload.sqlserver'     = $roles.SqlServer
    'workload.db2'           = $roles.Db2
    'workload.elasticsearch' = $roles.Elasticsearch
}
foreach ($k in $workloadKeys.Keys) {
    if ($workloadKeys[$k]) { $attrMap[$k] = 'true' }
}
if ($roles.NodeJs -and $roles.NodeJsVersion) { $attrMap['workload.nodejs.version'] = $roles.NodeJsVersion }
if ($roles.DotNet -and $roles.DotNetVersion) { $attrMap['workload.dotnet.version'] = $roles.DotNetVersion }

foreach ($k in $ExtraAttributes.Keys) { $attrMap[$k] = $ExtraAttributes[$k] }

# OTEL_RESOURCE_ATTRIBUTES is comma-separated key=value; values must not contain
# commas or '='. Detected values here are safe (roles, 'true', dotted versions).
$otelAttrs = ($attrMap.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
$roles['OtelResourceAttributes'] = $otelAttrs

# ---------------------------------------------------------------------------
# Report + persist
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[detect] primary role : $primary"
Write-Host "[detect] detected      : $(($workloadKeys.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key -replace '^workload\.','' }) -join ', ')"
Write-Host "[detect] OTEL_RESOURCE_ATTRIBUTES = $otelAttrs"

try {
    $summary = [ordered]@{
        host      = $env:COMPUTERNAME
        primary   = $primary
        workloads = ($workloadKeys.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key -replace '^workload\.','' })
        versions  = @{ nodejs = $roles.NodeJsVersion; dotnet = $roles.DotNetVersion }
        otel_resource_attributes = $otelAttrs
    }
    $summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $LogPath -Encoding utf8
    Write-Host "[detect] summary written to $LogPath"
} catch {
    Write-Warning "[detect] could not write summary: $_"
}

if ($SetEnv) {
    try {
        if ($Session) {
            $priorAttrs = [Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES', 'Machine')
            Record-EnvChange -Session $Session -Name 'OTEL_RESOURCE_ATTRIBUTES' -PriorValue $priorAttrs
        }
        [Environment]::SetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES', $otelAttrs, 'Machine')
        # Also set in the current process so a same-session install picks it up.
        $env:OTEL_RESOURCE_ATTRIBUTES = $otelAttrs
        Write-Host "[detect] set machine OTEL_RESOURCE_ATTRIBUTES (restart the collector service to apply)"
    } catch {
        Write-Warning "[detect] failed to set machine env var (need elevation?): $_"
    }
}

return $roles
