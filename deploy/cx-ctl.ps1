<#
.SYNOPSIS
  X-7: one operator surface for reading and setting this host's instrumentation state.

.DESCRIPTION
  The reference agent ships a host control CLI with 56 verbs, and the notable property is not the count - it is that
  every one is a symmetric GET and SET. An operator on the host can ask what the state is and change it
  without knowing which file, registry key or environment variable holds it.

  Ours was scripts plus machine environment variables plus flags, with no single command that answers
  "what is this host's instrumentation state?". This is that command. It writes nothing that the
  instrumenters do not already write - it is a front door onto the same state, not a second source of
  truth.

.PARAMETER Action
  get                      print everything below as one report
  get-monitoring-mode      full | infra-only  (derived from the rule file's hostDisabled)
  set-monitoring-mode      full | infra-only  -Value <mode>
  get-auto-injection       true | false       (the same host kill switch, named as the reference agent names it)
  set-auto-injection       -Value true|false
  get-host-tags            the machine OTEL_RESOURCE_ATTRIBUTES this host advertises
  get-services             CX_IIS_SERVICES / CX_NODE_SERVICES / CX_IISNODE_SERVICES / CX_DOTNET_SERVICES
  get-state                the installer's recorded decisions (X-1)
  get-latches              targets disabled after a failed sanity check (X-5)
  clear-latch              -Value <target>  re-enable one latched target
  get-rules                the active instrumentation rules (X-3)
  get-uncovered            processes no injection point of ours can reach (X-4)

.EXAMPLE
  powershell -File deploy\cx-ctl.ps1 get
  powershell -File deploy\cx-ctl.ps1 set-auto-injection -Value false
  powershell -File deploy\cx-ctl.ps1 clear-latch -Value shop-api

.NOTES
  Read actions need no elevation. Set actions write the rule file and therefore do.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('get','get-monitoring-mode','set-monitoring-mode','get-auto-injection','set-auto-injection',
                 'get-host-tags','get-services','get-state','get-latches','clear-latch','get-rules','get-uncovered')]
    [string] $Action = 'get',
    [string] $Value,
    [string] $RulesJson
)

$ErrorActionPreference = 'Continue'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
foreach ($lib in @('Write-DeployLog.ps1','Backup-Config.ps1','Resolve-NodeServiceNames.ps1')) {
    $p = Join-Path $here $lib
    if (Test-Path -LiteralPath $p) { . $p }
}
if (-not $RulesJson) { $RulesJson = Join-Path $here 'cx-instrument-rules.json' }

function Get-Rules {
    if (Get-Command Get-CxInstrumentRules -ErrorAction SilentlyContinue) {
        try { return Get-CxInstrumentRules -Path $RulesJson }
        catch { Write-Warning "[ctl] $($_.Exception.Message)"; return $null }
    }
    return $null
}

function Set-HostDisabled {
    <#
      Flip the host kill switch by rewriting the rule file, PRESERVING every rule already in it. Rewriting
      the file from scratch would silently drop an operator's exclusions, which is the kind of quiet data
      loss a convenience command must never do.
    #>
    param([bool] $Disabled)
    $existing = Get-Rules
    $rules = if ($existing) { @($existing.Rules) } else { @() }
    $doc = [pscustomobject]@{ hostDisabled = $Disabled; rules = $rules }
    $dir = Split-Path -Parent $RulesJson
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $RulesJson -Encoding utf8
    Write-Host "[ctl] hostDisabled=$Disabled written to $RulesJson (preserved $(@($rules).Count) rule(s))"
    Write-Host '[ctl] this takes effect on the NEXT instrumenter run; it does not remove environment already written. Run the instrumenter (or Uninstall-Agent.ps1) to apply.'
}

function Show-MonitoringMode {
    $r = Get-Rules
    $mode = if ($r -and $r.HostDisabled) { 'infra-only' } else { 'full' }
    Write-Host "monitoring-mode : $mode$(if (-not $r) { '  (no rule file; full is the default)' })"
    return $mode
}

function Show-HostTags {
    $v = [Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES','Machine')
    Write-Host "host-tags       : $(if ($v) { $v } else { '<none>' })"
}

function Show-Services {
    foreach ($n in 'CX_IIS_SERVICES','CX_NODE_SERVICES','CX_IISNODE_SERVICES','CX_DOTNET_SERVICES','CX_SERVICES') {
        $v = [Environment]::GetEnvironmentVariable($n,'Machine')
        Write-Host ("{0,-20}: {1}" -f $n, $(if ($v) { $v } else { '<unset>' }))
    }
}

function Show-State {
    if (-not (Get-Command Get-CxInstrumentationState -ErrorAction SilentlyContinue)) { Write-Host 'state           : (helper unavailable)'; return }
    $s = Get-CxInstrumentationState
    if (-not $s) { Write-Host 'state           : no decision record - the installer has not run here, or predates it'; return }
    Write-Host "state           : $(@($s.targets).Count) target(s) recorded $($s.whenUtc) by installer $($s.installerVersion)"
    $ex = @($s.targets | Where-Object { $_.excluded })
    if (@($ex).Count -gt 0) { Write-Host "                  $(@($ex).Count) excluded by rule: $((@($ex | ForEach-Object { $_.target }) -join ', '))" }
}

function Show-Latches {
    if (-not (Get-Command Get-CxInstrumentationLatch -ErrorAction SilentlyContinue)) { Write-Host 'latches         : (helper unavailable)'; return }
    $l = Get-CxInstrumentationLatch
    if (-not $l -or @($l.disabled).Count -eq 0) { Write-Host 'latches         : none'; return }
    Write-Host "latches         : $(@($l.disabled).Count) target(s) disabled after a failed check"
    foreach ($e in @($l.disabled)) { Write-Host "                  $($e.target)  reason=$($e.reason)  since=$($e.whenUtc)" }
}

switch ($Action) {
    'get' {
        Write-Host ''
        Write-Host "== instrumentation state: $env:COMPUTERNAME ==" -ForegroundColor Cyan
        $null = Show-MonitoringMode
        $r = Get-Rules
        Write-Host "auto-injection  : $(if ($r -and $r.HostDisabled) { 'false' } else { 'true' })"
        Write-Host "rules           : $(if ($r -and $r.Source) { "$(@($r.Rules).Count) rule(s) from $($r.Source)" } else { 'none' })"
        Show-HostTags
        Show-State
        Show-Latches
        Write-Host ''
        Show-Services
        Write-Host ''
        Write-Host 'For per-process reachability run:  cx-ctl.ps1 get-uncovered'
        Write-Host 'For a full health verdict run:      doctor.bat  (Test-Agent.ps1)'
    }
    'get-monitoring-mode' { $null = Show-MonitoringMode }
    'set-monitoring-mode' {
        if ($Value -notin @('full','infra-only')) { throw "-Value must be 'full' or 'infra-only'" }
        Set-HostDisabled -Disabled ($Value -eq 'infra-only')
    }
    'get-auto-injection' { $r = Get-Rules; Write-Host "auto-injection  : $(if ($r -and $r.HostDisabled) { 'false' } else { 'true' })" }
    'set-auto-injection' {
        if ($Value -notin @('true','false')) { throw "-Value must be 'true' or 'false'" }
        Set-HostDisabled -Disabled ($Value -eq 'false')
    }
    'get-host-tags' { Show-HostTags }
    'get-services'  { Show-Services }
    'get-state'     { Show-State }
    'get-latches'   { Show-Latches }
    'clear-latch' {
        if (-not $Value) { throw '-Value <target> is required' }
        if (-not (Get-Command Clear-CxTargetLatch -ErrorAction SilentlyContinue)) { throw 'Backup-Config.ps1 is not present next to this script' }
        if (Clear-CxTargetLatch -Target $Value) { Write-Host "[ctl] latch cleared for '$Value'. The next instrumenter run will treat it normally." }
        else { Write-Host "[ctl] '$Value' was not latched - nothing to clear." }
    }
    'get-rules' {
        $r = Get-Rules
        if (-not $r -or -not $r.Source) { Write-Host 'rules           : none (no rule file)'; break }
        Write-Host "rules           : $(@($r.Rules).Count) from $($r.Source); hostDisabled=$($r.HostDisabled)"
        $i = 0
        foreach ($rule in @($r.Rules)) {
            $i++
            Write-Host ("  {0}. {1,-8} {2} {3} '{4}'{5}" -f $i, $rule.type, $rule.field, $rule.op, $rule.value,
                $(if ($rule.serviceName) { " -> serviceName=$($rule.serviceName)" } elseif ($rule.runtime) { " -> runtime=$($rule.runtime)" } else { '' }))
            if ($rule.reason) { Write-Host "     $($rule.reason)" -ForegroundColor DarkGray }
        }
    }
    'get-uncovered' {
        $u = Join-Path $here 'Resolve-UncoveredProcesses.ps1'
        if (-not (Test-Path -LiteralPath $u)) { throw "not found: $u" }
        & $u
    }
}
