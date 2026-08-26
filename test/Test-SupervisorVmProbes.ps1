<#
.SYNOPSIS
  Offline agreement check between the supervisor config WRITER and the VM loop's guest-side
  READERS - Set-SupervisorAgentSettings in deploy\Install-CoralogixSupervisor.ps1 against the
  $ProbeConfig / $ProbeLogs scriptblocks in poc\Run-SupervisorAgentSettingsVmLoop.ps1.

.DESCRIPTION
  WHY THIS EXISTS. The VM loop's probes are written with their OWN regexes on purpose, so that a
  bug in the writer cannot be mirrored in the harness and cancel itself out. The cost of that
  independence is that the two can also disagree about CORRECT output - and every such disagreement
  is a red assertion discovered forty minutes into a VM run, on a guest that then has to be rebuilt.

  This file closes that gap offline: the real writer writes a real fixture, the real probe reads it,
  and the assertions are the ones the loop's S3 block makes. It found one genuine defect on its
  first run - $ProbeLogs read the whole Application event log, and this dev host still carries an
  'opampsupervisor' source from an install that no longer exists, so 90 KB of events from before the
  fix would have failed the loop's S8. The probe now bounds that read by the config's mtime, and the
  last section here proves the bound both works and is not simply discarding everything.

  Both halves are lifted by AST from the shipping files, so this cannot drift from what runs. It
  fails loudly if a function or a probe variable is renamed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-SupervisorVmProbes.ps1

.NOTES
  Fixture-only: no VM, no service, no network, no elevation. Exit code = failed assertions.
#>
[CmdletBinding()]
param([switch] $KeepFixtures)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty while a param default is evaluated under -File, so resolve here.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repo = Split-Path -Parent $here

# ---- lift the writer ------------------------------------------------------
$installer = Join-Path $repo 'deploy\Install-CoralogixSupervisor.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw "not found: $installer" }
$wantedFns = @('ConvertTo-SupervisorAttrScalar','Expand-CxBackslashEscapes','Get-SupervisorAttrValue',
               'Get-SupervisorAttrFirstPass','Test-SupervisorAttrScalarCanonical',
               'Test-SupervisorAttrScalarNeedsFix','Set-SupervisorDescriptionAttributes',
               'Set-SupervisorAgentSettings')
$instAst = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
$foundFns = @()
foreach ($f in $instAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wantedFns -contains $f.Name) { Invoke-Expression $f.Extent.Text; $foundFns += $f.Name }
}
$missingFns = @($wantedFns | Where-Object { $foundFns -notcontains $_ })
if ($missingFns.Count) { throw "not found in ${installer}: $($missingFns -join ', ') (renamed?)" }

# ---- lift the probes -----------------------------------------------------
$loop = Join-Path $repo 'poc\Run-SupervisorAgentSettingsVmLoop.ps1'
if (-not (Test-Path -LiteralPath $loop)) { throw "not found: $loop" }
$loopAst = [System.Management.Automation.Language.Parser]::ParseFile($loop, [ref]$null, [ref]$null)
$probes = @{}
foreach ($a in $loopAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $lhs = $a.Left -as [System.Management.Automation.Language.VariableExpressionAst]
    if (-not $lhs) { continue }
    if (@('ProbeConfig','ProbeRuntime','ProbeLogs') -contains $lhs.VariablePath.UserPath) {
        # Trim the braces off the scriptblock literal and rebuild it, so the probe body under test
        # is byte-identical to the one the loop ships to the guest.
        $probes[$lhs.VariablePath.UserPath] = [scriptblock]::Create($a.Right.Extent.Text.Trim('{', '}'))
    }
}
foreach ($n in @('ProbeConfig','ProbeLogs')) {
    if (-not $probes.ContainsKey($n)) { throw "could not lift `$$n from $loop (renamed?)" }
}

$script:Pass = 0; $script:Fail = 0
function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { $script:Fail++; Write-Host "  FAIL $Name$(if ($Detail) { " -> $Detail" })" -ForegroundColor Red }
}
function Assert-Equal {
    param([string] $Name, $Expected, $Actual)
    Assert-True $Name ($Expected -eq $Actual) "expected [$Expected], got [$Actual]"
}
function Note {
    param([string] $Name, [string] $Message)
    Write-Host "  NOTE $Name -> $Message" -ForegroundColor Yellow
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-vmprobe-fx-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null

# The vendor's shape, same fixture the writer's own unit test uses.
$vendorBlock = @'
server:
  endpoint: wss://ingress.eu2.coralogix.com/opamp/v1
agent:
  executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
      cx.agent.type: "standalone"
'@

# Exactly what the installer's supervisor branch passes.
$agentSettings = [ordered]@{ 'passthrough_logs' = 'true'; 'config_apply_timeout' = '30s' }
$attrs = 'cx.host.role=iis,workload.pm2.home=C:\ProgramData\pm2,workload.pm2.owner=NT AUTHORITY\LocalService'

function New-Fixture {
    param([string] $Name, [string] $Content = $vendorBlock)
    $p = Join-Path $root "$Name.yaml"
    Set-Content -LiteralPath $p -Value $Content -Encoding utf8
    return $p
}

Write-Host "`n== S3: what the loop asserts, against what the installer actually wrote ==" -ForegroundColor Cyan
$fx = New-Fixture 'vendor'
Set-SupervisorDescriptionAttributes -ConfigPath $fx -Attributes $attrs 3>$null 6>$null
Set-SupervisorAgentSettings -ConfigPath $fx -Settings $agentSettings 3>$null 6>$null
$c = & $probes['ProbeConfig'] $fx | ConvertFrom-Json

Assert-True  'probe reports the file exists' ([bool]$c.exists)
Assert-True  'probe found the agent: block' ([int]$c.agentIdx -ge 0) "agentIdx=$($c.agentIdx)"
Assert-Equal 'passthrough_logs appears exactly once' 1 ([int]$c.passthrough_logs_count)
Assert-Equal 'config_apply_timeout appears exactly once' 1 ([int]$c.config_apply_timeout_count)
Assert-Equal 'config_apply_timeout value' '30s' ([string]$c.config_apply_timeout_value)
Assert-Equal 'passthrough_logs value' 'true' ([string]$c.passthrough_logs_value)
Assert-True  'config_apply_timeout read as UNQUOTED' (-not [bool]$c.config_apply_timeout_quoted) ([string]$c.config_apply_timeout_raw)
Assert-True  'passthrough_logs read as UNQUOTED' (-not [bool]$c.passthrough_logs_quoted) ([string]$c.passthrough_logs_raw)
Assert-Equal 'timeout indent equals executable indent' ([int]$c.exeIndentLen) ([int]$c.config_apply_timeout_indent)
Assert-Equal 'passthrough indent equals executable indent' ([int]$c.exeIndentLen) ([int]$c.passthrough_logs_indent)
Assert-True  'child indent is deeper than agent: itself' `
    ([int]$c.config_apply_timeout_indent -gt [int]$c.agentIndentLen) `
    "child=$($c.config_apply_timeout_indent) agent=$($c.agentIndentLen)"
Assert-Equal 'agent.executable is still one line' 1 ([int]$c.exeCount)
Assert-Equal 'vendor service.name line, verbatim' 'service.name: "coralogix-collector"' ([string]$c.serviceNameLine)
Assert-True  'non_identifying_attributes anchor intact' ([bool]$c.descAnchor)
Assert-Equal 'no rollback copy beside a clean fixture' $false ([bool]$c.preEdit)

Write-Host "`n== the probe's quoting check is not vacuous ==" -ForegroundColor Cyan
# If the writer ever regressed to quoting these, S3 has to go red. Prove the probe would notice.
$q = New-Fixture 'quoted' @'
agent:
  executable: C:\x\otelcol.exe
  config_apply_timeout: "30s"
  passthrough_logs: 'true'
'@
$cq = & $probes['ProbeConfig'] $q | ConvertFrom-Json
Assert-True 'a double-quoted duration is reported as quoted' ([bool]$cq.config_apply_timeout_quoted) ([string]$cq.config_apply_timeout_raw)
Assert-True 'a single-quoted bool is reported as quoted' ([bool]$cq.passthrough_logs_quoted) ([string]$cq.passthrough_logs_raw)

Write-Host "`n== S9: the 5s repair path, as the probe sees it ==" -ForegroundColor Cyan
$fx5 = New-Fixture 'five' @'
agent:
  executable: C:\x\otelcol.exe
  config_apply_timeout: 5s
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
'@
$b5 = & $probes['ProbeConfig'] $fx5 | ConvertFrom-Json
Assert-Equal 'probe sees the broken 5s value first' '5s' ([string]$b5.config_apply_timeout_value)
Set-SupervisorAgentSettings -ConfigPath $fx5 -Settings $agentSettings 3>$null 6>$null
$a5 = & $probes['ProbeConfig'] $fx5 | ConvertFrom-Json
Assert-Equal 'after the re-deploy the probe sees 30s' '30s' ([string]$a5.config_apply_timeout_value)
Assert-Equal 'and still exactly one of it' 1 ([int]$a5.config_apply_timeout_count)

Write-Host "`n== the nested decoy: the two DISAGREE, deliberately ==" -ForegroundColor Cyan
# The probe counts a key anywhere (^\s*key:); the writer only matches the direct-child indent. On a
# host carrying a same-named key under description: the probe therefore reports 2 - which means the
# loop's "exactly once" assertion would go red there. That is the intended behaviour, not a bug:
# such a config is not one this deployment produced, and the operator should be told.
$nest = New-Fixture 'nested' @'
agent:
  executable: C:\x\otelcol.exe
  description:
    non_identifying_attributes:
      config_apply_timeout: 5s
'@
Set-SupervisorAgentSettings -ConfigPath $nest -Settings $agentSettings 3>$null 6>$null
$cn = & $probes['ProbeConfig'] $nest | ConvertFrom-Json
Assert-Equal 'probe counts both levels' 2 ([int]$cn.config_apply_timeout_count)
Assert-Equal 'and reports the FIRST, agent-level value' '30s' ([string]$cn.config_apply_timeout_value)
Assert-Equal 'at the agent-level indent' ([int]$cn.exeIndentLen) ([int]$cn.config_apply_timeout_indent)

Write-Host "`n== the probe survives a config it cannot recognise ==" -ForegroundColor Cyan
$flow = New-Fixture 'flow' "agent: {}`n"
$cf = & $probes['ProbeConfig'] $flow | ConvertFrom-Json
Assert-Equal 'agent: {} -> no agent block found' -1 ([int]$cf.agentIdx)
Assert-Equal 'and no keys reported' 0 ([int]$cf.config_apply_timeout_count)
$cm = & $probes['ProbeConfig'] (Join-Path $root 'nope.yaml') | ConvertFrom-Json
Assert-Equal 'a missing file reports exists=false' $false ([bool]$cm.exists)

Write-Host "`n== ProbeLogs: detection in both directions ==" -ForegroundColor Cyan
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Path (Join-Path $state 'state') -Force | Out-Null
$log = Join-Path $state 'supervisor.log'
Set-Content -LiteralPath $log -Encoding utf8 -Value @(
    '2026-08-26T10:00:00Z info Supervisor starting',
    '2026-08-26T10:00:07Z info Everything is ready. Begin running and processing data.'
)
$l1 = & $probes['ProbeLogs'] $state $log | ConvertFrom-Json
Assert-True 'the log file was discovered' ([bool]($l1.files -match 'supervisor\.log')) ([string]$l1.files)
Assert-True 'a collector-emitted line is detected' ([bool]$l1.hasCollector) ([string]$l1.collectorLines)
Assert-True 'no apply failure in a healthy log' (-not [bool]$l1.hasApplyFail) ([string]$l1.applyFailLines)
$charsBefore = [int]$l1.chars

Add-Content -LiteralPath $log -Value '2026-08-26T10:05:00Z error Config apply timeout exceeded, reporting FAILED'
$l2 = & $probes['ProbeLogs'] $state $log | ConvertFrom-Json
Assert-True 'growth is detected (this is what S7 keys on)' ([int]$l2.chars -gt $charsBefore) "before=$charsBefore after=$($l2.chars)"
Assert-True 'the apply-failure phrase IS detected' ([bool]$l2.hasApplyFail) ([string]$l2.applyFailLines)

Write-Host "`n== ProbeLogs: the event-log read is bounded by the config's mtime ==" -ForegroundColor Cyan
# The defect this file was written to catch. An 'opampsupervisor' event-log source outlives the
# install that created it, so an unbounded read hands S8 apply-failure lines written before the fix
# existed. Only meaningful on a host that HAS such a source - otherwise it is reported as
# inconclusive rather than passing on no data.
$emptyState = Join-Path $root 'emptystate'
New-Item -ItemType Directory -Path $emptyState -Force | Out-Null
$freshCfg = Join-Path $root 'fresh-config.yaml'
Set-Content -LiteralPath $freshCfg -Value 'agent:' -Encoding utf8

$backdated = Join-Path $root 'backdated-config.yaml'
Set-Content -LiteralPath $backdated -Value 'agent:' -Encoding utf8
(Get-Item -LiteralPath $backdated).LastWriteTime = (Get-Date).AddYears(-5)
$old = & $probes['ProbeLogs'] $emptyState $backdated | ConvertFrom-Json

if ([int]$old.events -le 0) {
    Note 'event-log bound not exercised' 'this host has no opampsupervisor event source, so there is nothing for the filter to exclude'
} else {
    Write-Host "  host carries $($old.events) pre-existing opampsupervisor events ($($old.chars) chars)"
    $new = & $probes['ProbeLogs'] $emptyState $freshCfg | ConvertFrom-Json
    Assert-Equal 'a config written now excludes every pre-existing event' 0 ([int]$new.events)
    Assert-Equal 'so an empty state dir yields zero chars' 0 ([int]$new.chars)
    Assert-True  'and claims no collector line' (-not [bool]$new.hasCollector)
    # Without this the assertion above would also pass on a probe that read nothing at all.
    Assert-True  'NOT VACUOUS: a back-dated config lets those same events through' ([int]$old.events -gt 0) `
        "old=$($old.events) new=$($new.events)"
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepFixtures) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "fixtures kept: $root" }
exit $script:Fail
