<#
.SYNOPSIS
  Unit tests for deploy\Resolve-NodeServiceNames.ps1 - PM2 topology, app enumeration and the
  ESM/CommonJS rule - plus the doctor's ownership grading in deploy\Test-NodeInstrumentation.ps1.

.DESCRIPTION
  Fixture-only. Builds a throwaway PM2_HOME under the user's TEMP and stubs the machine-wide
  probes with the process/service records a real service-hosted host reports. Touches no PM2, no
  services, no Task Scheduler, no machine environment, and needs no elevation - so unlike the
  docker-win harnesses this one is safe to run anywhere and finishes in about a second.

  That is the point: these are pure functions of (process command lines, Win32_Service.StartName,
  dump.pm2, package.json), and the rules are what silently failed on a production host - PM2
  installed as a Windows service under NT AUTHORITY\LOCAL SERVICE, 26 apps running, no Node
  telemetry, and every script reporting success. A container run cannot easily reproduce a
  LOCAL SERVICE-owned daemon; pinning the rules here means it does not have to.

  Covers the cases the deploy scripts get wrong if the rules regress:
    * a node-windows wrapper + ProgramData daemon reads as hosting=service, with the owner and
      PM2_HOME taken from the service and the daemon's own command line
    * an unreachable daemon falls back to dump.pm2 rather than concluding "no apps"
    * dump.pm2's NESTED "name" keys do not invent apps
    * cluster instances come from the entry, fork apps do not
    * PM2's own utility apps are excluded by default and includable on request
    * an ESM entry point is detected from .mjs and from "type":"module"
    * pm2 arguments are quoted so an app name cannot inject PowerShell
    * the doctor grades a PROVEN unreachable daemon as fail, and an unprovable one as unknown

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-Pm2Topology.ps1

.NOTES
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param([switch] $KeepFixtures)

$ErrorActionPreference = 'Stop'

$here    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$lib     = Join-Path $here '..\deploy\Resolve-NodeServiceNames.ps1'
$doctor  = Join-Path $here '..\deploy\Test-NodeInstrumentation.ps1'
foreach ($f in @($lib, $doctor)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "not found: $f" }
}
. $lib
. $doctor

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-pm2-fx-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null

$fakeHome = Join-Path $root 'pm2home'
New-Item -ItemType Directory -Path (Join-Path $fakeHome 'service') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeHome 'logs')    -Force | Out-Null

# A dump with deliberately hostile shapes: nested objects carrying their own "name" key (pm2
# really does write axm_options), case-colliding env keys (which is why ConvertFrom-Json is not
# used anywhere near this file), a cluster entry, and a utility app.
$dump = @'
[{"name":"qa.jackpotcity","namespace":"default","exec_mode":"fork_mode","instances":1,
  "pm_exec_path":"D:\\apps\\qa.jackpotcity\\server.js","cwd":"D:\\apps\\qa.jackpotcity",
  "axm_options":{"name":"NOT-AN-APP","module_conf":{"name":"ALSO-NOT-AN-APP"}},
  "env":{"PATH":"C:\\x","Path":"C:\\y","npm_package_name":"nope"}},
 {"name":"synapse-qa.betway","exec_mode":"cluster_mode","instances":4,
  "pm_exec_path":"D:\\apps\\synapse\\index.mjs","cwd":"D:\\apps\\synapse",
  "env":{"TEMP":"a","Temp":"b"}},
 {"name":"pm2-logrotate","exec_mode":"fork_mode","instances":1,"env":{}}]
'@
Set-Content -LiteralPath (Join-Path $fakeHome 'dump.pm2') -Value $dump -Encoding ASCII
'x' | Set-Content -LiteralPath (Join-Path $fakeHome 'logs\qa.jackpotcity-out.log')
'x' | Set-Content -LiteralPath (Join-Path $fakeHome 'logs\long-gone-app-out.log')

$script:Fail = 0
$script:Pass = 0

function Assert-Equal {
    param([string] $What, $Expected, $Actual)
    if ([string]$Expected -eq [string]$Actual) {
        $script:Pass++
        Write-Host ("  [PASS] {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0}`n         expected: '{1}'`n         actual:   '{2}'" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}

function Assert-True {
    param([string] $What, $Condition)
    Assert-Equal -What $What -Expected 'True' -Actual ([bool]$Condition)
}

# ---------------------------------------------------------------------------
# Stubs: the machine-wide probes, standing in for a service-hosted host.
# ---------------------------------------------------------------------------
function Get-CxPm2Processes {
    $out = @(
        [pscustomobject]@{ Kind='wrapper'; Pid=5268; ParentPid=3320; Owner='NT AUTHORITY\LOCAL SERVICE'
            CommandLine='"C:\Program Files\nodejs\node.exe" --harmony C:\ProgramData\npm\npm\node_modules\node-windows\lib\wrapper.js --file C:\ProgramData\pm2\service\index.js' }
        [pscustomobject]@{ Kind='daemon'; Pid=6616; ParentPid=5268; Owner='NT AUTHORITY\LOCAL SERVICE'
            CommandLine=('"C:\Program Files\nodejs\node.exe" --harmony ' + $fakeHome + '\service\index.js') }
    )
    $out + (1..28 | ForEach-Object {
        [pscustomobject]@{ Kind='worker'; Pid=(7000+$_); ParentPid=6616; Owner='NT AUTHORITY\LOCAL SERVICE'
            CommandLine='node C:\ProgramData\npm\npm\node_modules\pm2\lib\ProcessContainerFork.js' } })
}
function Get-CxPm2Service {
    [pscustomobject]@{ Name='pm2.exe'; DisplayName='PM2'; StartName='NT AUTHORITY\LOCAL SERVICE'
                       State='Running'; PathName='"C:\ProgramData\pm2\service\pm2.exe" node' }
}
function Get-CxPm2CommandPath { 'C:\ProgramData\npm\pm2.cmd' }
# The daemon belongs to someone else, so jlist tells us nothing - the whole point of the fallback.
function Invoke-CxPm2 { param($Pm2Args, $Pm2Home) '' }

Write-Host ''
Write-Host '== topology: node-windows service layout ==' -ForegroundColor Cyan
$topo = Get-CxPm2Topology
Assert-Equal 'hosting is service'                    'service'                     $topo.Hosting
Assert-Equal 'owner comes from Win32_Service'        'NT AUTHORITY\LOCAL SERVICE'  $topo.Owner
Assert-Equal 'PM2_HOME from the daemon command line' $fakeHome                     $topo.Home
Assert-Equal 'daemon pid'                            6616                          $topo.DaemonPid
Assert-Equal 'worker count'                          28                            $topo.WorkerCount
Assert-True  'owner mismatch flagged'                $topo.OwnerMismatch

Write-Host ''
Write-Host '== app enumeration: unreachable daemon falls back to dump.pm2 ==' -ForegroundColor Cyan
$map = Get-PM2ServiceMap -Topology $topo -Pm2Home $fakeHome
Assert-Equal 'utility apps excluded by default'      2            @($map).Count
Assert-Equal 'source is dump'                        'dump'       (@($map)[0].Source)
Assert-Equal 'hosting carried onto each record'      'service'    (@($map)[0].Hosting)
Assert-Equal 'owner carried onto each record'        'NT AUTHORITY\LOCAL SERVICE' (@($map)[0].Owner)

$dumpApps = Get-CxPm2DumpApps -Pm2Home $fakeHome
Assert-Equal 'dump yields exactly 3 apps'            3            @($dumpApps).Count
Assert-True  'nested "name" keys invent no apps'     (@($dumpApps | Where-Object { $_.Name -like '*NOT-AN-APP*' }).Count -eq 0)
$cluster = @($dumpApps | Where-Object { $_.Name -eq 'synapse-qa.betway' })[0]
$fork    = @($dumpApps | Where-Object { $_.Name -eq 'qa.jackpotcity'    })[0]
Assert-Equal 'cluster instances read from the entry' 4            $cluster.Instances
Assert-Equal 'fork app has one instance'             1            $fork.Instances
Assert-Equal 'cluster exec mode'                     'cluster_mode' $cluster.ExecMode
Assert-Equal 'script path unescaped'                 'D:\apps\qa.jackpotcity\server.js' $fork.Script

$withUtils = Get-PM2ServiceMap -Topology $topo -Pm2Home $fakeHome -ExcludeApps @()
Assert-Equal '-ExcludeApps @() includes utilities'   3            @($withUtils).Count

$logApps = Get-CxPm2LogApps -Pm2Home $fakeHome
Assert-True  'log fallback finds app names'          (@($logApps | Where-Object { $_.Name -eq 'qa.jackpotcity' }).Count -eq 1)

Write-Host ''
Write-Host '== JSON unescaping: a Windows path must survive it ==' -ForegroundColor Cyan
# The bug this pins: a chain of .Replace() calls with .Replace('\\','\') last mangles every escaped
# path whose next segment starts with n/r/t/b/f, because `C:\\node_modules` CONTAINS the two
# characters `\n`. It silently defeated the ESM probe and would fake a NODE_REGISTER_PATH_STALE.
Assert-Equal 'escaped \\node_modules stays a path' 'C:\cx\node_modules\x' (Convert-CxJsonEscapes 'C:\\cx\\node_modules\\x')
Assert-Equal 'escaped \\temp stays a path'         'D:\temp\report'       (Convert-CxJsonEscapes 'D:\\temp\\report')
Assert-Equal 'escaped \\bin stays a path'          'E:\bin\fresh'         (Convert-CxJsonEscapes 'E:\\bin\\fresh')
Assert-True  'a REAL \n escape still becomes a newline' ((Convert-CxJsonEscapes 'a\nb') -eq "a`nb")
Assert-Equal 'quotes and slashes unescape'         'say "hi"/ok'          (Convert-CxJsonEscapes 'say \"hi\"/ok')

Write-Host ''
Write-Host '== NODE_OPTIONS is merged, never replaced ==' -ForegroundColor Cyan
$boot = '--require C:/cx/otel-node/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js'
$merged = Merge-CxNodeOptions -Existing '--max-old-space-size=512' -Bootstrap $boot
Assert-True  "the app's own heap limit survives"  ($merged -match '--max-old-space-size=512') $merged
Assert-True  'and the bootstrap is present'       ($merged -match 'register\.js') $merged
# Re-running must not accumulate hooks - two SDK loads is its own failure mode.
$twice = Merge-CxNodeOptions -Existing $merged -Bootstrap $boot
Assert-Equal 'a second run does not duplicate the bootstrap' 1 ([regex]::Matches($twice, 'register\.js').Count)
Assert-True  'and still keeps the heap limit'     ($twice -match '--max-old-space-size=512') $twice
# Switching a CommonJS app to the ESM form replaces the bootstrap rather than stacking both. The ESM
# form is the LOADER HOOK plus --require: measured against a real ESM app, --require alone and
# --import both produce ZERO spans, and only the hook works.
$esmBoot  = '--experimental-loader=file:///C:/cx/otel-node/node_modules/@opentelemetry/instrumentation/hook.mjs ' + $boot
$switched = Merge-CxNodeOptions -Existing $merged -Bootstrap $esmBoot
Assert-Equal 'switching to the ESM form leaves one bootstrap' 1 ([regex]::Matches($switched, 'register\.js').Count)
Assert-True  'and it carries the ESM loader hook' ($switched -match 'experimental-loader.*hook\.mjs') $switched
# Re-running the ESM form must not register the hook twice - two hooks is its own failure mode.
$esmTwice = Merge-CxNodeOptions -Existing $switched -Bootstrap $esmBoot
Assert-Equal 'a second ESM run does not duplicate the loader hook' 1 ([regex]::Matches($esmTwice, 'hook\.mjs').Count)
Assert-True  "and still keeps the app's own heap limit" ($esmTwice -match '--max-old-space-size=512') $esmTwice
# An app's OWN --require of its own module is not ours to remove.
$ownHook = Merge-CxNodeOptions -Existing '--require ./instrument-me.js' -Bootstrap $boot
Assert-True  "an app's own --require is preserved" ($ownHook -match 'instrument-me\.js') $ownHook
Assert-Equal 'nothing to merge yields just the bootstrap' $boot (Merge-CxNodeOptions -Existing '' -Bootstrap $boot)

Write-Host ''
Write-Host '== uninstall must clear with a PRESENT value, not an empty one ==' -ForegroundColor Cyan
# On Windows an empty value DELETES the variable, and `pm2 restart --update-env` merges the caller's
# env OVER the app's - so a deleted variable is an absence, not an override, and the app keeps its
# old NODE_OPTIONS. Uninstall then reports success having changed nothing. Every cleared value must
# therefore be non-empty.
$clearSrc = Get-Content -LiteralPath $lib -Raw
$clearBlock = [regex]::Match($clearSrc, '(?s)\$cleared\s*=\s*\[ordered\]@\{(.*?)\n\s*\}').Groups[1].Value
Assert-True 'uninstall defines a cleared-env set'            ($clearBlock -match 'NODE_OPTIONS')
Assert-True 'and NODE_OPTIONS is not cleared to empty'       ($clearBlock -notmatch "NODE_OPTIONS\s*=\s*''")
Assert-True 'and every cleared value is non-empty'           ($clearBlock -notmatch "=\s*''")
# ...and the per-user branch must APPLY those values rather than hardcoding '' - which is exactly
# how it kept deleting the variable (so --update-env had nothing to override) long after the values
# themselves were fixed.
Assert-True 'and the per-user branch applies $cleared, not a literal empty string' `
    ($clearSrc -match "SetEnvironmentVariable\(\`$k,\s*\[string\]\`$cleared\[\`$k\]")
Assert-True 'and no clearing call passes a literal empty string' `
    ($clearSrc -notmatch "SetEnvironmentVariable\(\`$k,\s*''")

Write-Host ''
Write-Host '== ESM detection ==' -ForegroundColor Cyan
$esmDir = Join-Path $root 'esmapp'; New-Item -ItemType Directory -Path $esmDir -Force | Out-Null
'{ "name":"x", "type":"module" }' | Set-Content -LiteralPath (Join-Path $esmDir 'package.json')
$cjsDir = Join-Path $root 'cjsapp'; New-Item -ItemType Directory -Path $cjsDir -Force | Out-Null
'{ "name":"y" }'                  | Set-Content -LiteralPath (Join-Path $cjsDir 'package.json')
Assert-True  '.mjs entry is ESM'                     (Test-CxNodeAppIsEsm -Script 'D:\a\index.mjs' -Cwd 'D:\a')
Assert-True  '"type":"module" is ESM'                (Test-CxNodeAppIsEsm -Script (Join-Path $esmDir 'index.js') -Cwd $esmDir)
Assert-Equal 'plain package.json is CommonJS'        'False' (Test-CxNodeAppIsEsm -Script (Join-Path $cjsDir 'index.js') -Cwd $cjsDir)
Assert-Equal 'unknown app is treated as CommonJS'    'False' (Test-CxNodeAppIsEsm -Script 'D:\nope\app.js' -Cwd 'D:\nope')

Write-Host ''
Write-Host '== Invoke-CxPm2AsOwner: argument quoting ==' -ForegroundColor Cyan
# Task Scheduler is stubbed; only the script this would have run is inspected. Nothing is
# registered, so this stays runnable unelevated (registering a task under another principal needs
# elevation and would fail with "Access is denied").
#
# The stubs are bound by ALIAS, not by same-named function. The ScheduledTasks module exports its
# CIM commands as FUNCTIONS, and the helper's own New-ScheduledTaskAction call auto-imports that
# module mid-run - which overwrites a stub function of the same name, and the real cmdlet then
# runs for real. Aliases outrank both functions and cmdlets and survive the import.
$script:generated      = $null
$script:principalUser  = $null
$script:principalLogon = $null
$script:sentinel       = $null
function Invoke-CxStubRegisterTask {
    param($TaskName, $Action, $Principal, $Settings, $InputObject, $User, $Password, [switch] $Force, $ErrorAction)
    # -InputObject is what the real code registers (it is the only parameter set that accepts a
    # principal alongside a password), so the action/principal come off the task object.
    $act = if ($InputObject) { @($InputObject.Actions)[0] }   else { $Action }
    $pri = if ($InputObject) { $InputObject.Principal }       else { $Principal }
    if ($act.Arguments -match '-File "([^"]+)"') {
        $script:generated = Get-Content -LiteralPath $matches[1] -Raw
        # The generated script's LAST act is writing a sentinel with pm2's exit code; that file is
        # the only completion signal either mechanism has. Simulate the run by writing it, so the
        # wait succeeds instead of falling through to the sc.exe mechanism and timing out.
        if ($script:generated -match "Set-Content -LiteralPath '([^']+\.done)'") {
            $script:sentinel = $matches[1]
            Set-Content -LiteralPath $script:sentinel -Value '0' -Encoding ASCII
        }
    }
    $script:principalUser  = $pri.UserId
    $script:principalLogon = $pri.LogonType
    $script:registeredUser = $User
    $null
}
function Invoke-CxStubNoop      { param($TaskName, $ErrorAction, [switch] $Confirm) }
function Invoke-CxStubTaskState { param($TaskName, $ErrorAction) [pscustomobject]@{ State = 'Ready' } }
function Invoke-CxStubTaskInfo  { param($TaskName, $ErrorAction) [pscustomobject]@{ LastTaskResult = 0 } }
function Invoke-CxStubNewTask {
    param($Action, $Principal, $Settings, $Trigger, $Description)
    [pscustomobject]@{ Actions = @($Action); Principal = $Principal; Settings = $Settings }
}
Set-Alias Register-ScheduledTask   Invoke-CxStubRegisterTask
Set-Alias New-ScheduledTask        Invoke-CxStubNewTask
Set-Alias Start-ScheduledTask      Invoke-CxStubNoop
Set-Alias Unregister-ScheduledTask Invoke-CxStubNoop
Set-Alias Get-ScheduledTask        Invoke-CxStubTaskState
Set-Alias Get-ScheduledTaskInfo    Invoke-CxStubTaskInfo

$hostile = "weird'; Remove-Item C:\ -Recurse; '"
$argSets = @()
$argSets += ,@('restart', $hostile, '--update-env')
$res = Invoke-CxPm2AsOwner -Owner $topo.Owner -Pm2Home $topo.Home -Pm2ArgSets $argSets `
                           -Env ([ordered]@{ OTEL_SERVICE_NAME = 'qa.jackpotcity' })
Assert-True  'ran as the daemon owner'               ($script:principalUser -match 'LOCAL SERVICE')
Assert-Equal 'ServiceAccount logon (no password)'    'ServiceAccount' $script:principalLogon
Assert-True  'PM2_HOME pinned in the script'         ($script:generated -match [regex]::Escape("`$env:PM2_HOME = '$fakeHome'"))
Assert-True  'env applied in the script'             ($script:generated -match "OTEL_SERVICE_NAME = 'qa\.jackpotcity'")
Assert-True  'pm2 called by absolute path'           ($script:generated -match "& 'C:\\ProgramData\\npm\\pm2\.cmd' @a")
Assert-True  'single quotes doubled, not escaped out' ($script:generated -match "'weird''; Remove-Item C:\\ -Recurse; '''")
Assert-True  'no bare Remove-Item statement'          ($script:generated -notmatch "(?m)^\s*Remove-Item")
Assert-True  'writes a completion sentinel last'      ($script:generated -match "Set-Content -LiteralPath '[^']+\.done'")
Assert-Equal 'the scheduled-task mechanism was used'  'scheduledTask' $res.Mechanism
Assert-True  'succeeded via the first mechanism'      $res.Ok

Write-Host ''
Write-Host '== run-as-owner: which accounts can be logged on without a password ==' -ForegroundColor Cyan
foreach ($a in @('NT AUTHORITY\LOCAL SERVICE','NT AUTHORITY\SYSTEM','LocalSystem','NT AUTHORITY\NETWORK SERVICE','CONTOSO\gmsa-pm2$')) {
    Assert-True "'$a' is a passwordless service account" (Test-CxIsServiceAccount -Account $a)
}
foreach ($a in @('svc_pm2','.\svc_pm2','CONTOSO\alice')) {
    Assert-Equal "'$a' is NOT a passwordless account" 'False' (Test-CxIsServiceAccount -Account $a)
}
# An ordinary owner with no credential must be REFUSED with a reason, not attempted and left to
# fail with a logon error that reads like a bug in the tooling. It must also refuse FAST - not
# after two mechanisms each wait out their timeout.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$noCred = Invoke-CxPm2AsOwner -Owner 'svc_pm2' -Pm2Home $topo.Home -Pm2ArgSets @( ,@('restart','x','--update-env') )
$sw.Stop()
Assert-Equal 'ordinary owner without a credential is refused'  'False' $noCred.Ok
Assert-True  'and the reason names the missing credential'     ($noCred.Reason -match 'OwnerCredential')
Assert-True  'and it refuses immediately, not after a timeout' ($sw.Elapsed.TotalSeconds -lt 10) "took $([int]$sw.Elapsed.TotalSeconds)s"

# With a credential, the task is registered with -User/-Password and a Password logon type.
$cred = New-Object pscredential('svc_pm2', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))
$script:generated = $null
$withCred = Invoke-CxPm2AsOwner -Owner 'svc_pm2' -Pm2Home $topo.Home -OwnerCredential $cred `
                                -Pm2ArgSets @( ,@('restart','x','--update-env') )
Assert-Equal 'ordinary owner WITH a credential uses a Password logon' 'Password' $script:principalLogon
Assert-Equal 'and passes the user to Register-ScheduledTask'           'svc_pm2'  $script:registeredUser
Assert-True  'and succeeds'                                            $withCred.Ok

# The wait must give up on a mechanism that is demonstrably not running, rather than burning the
# whole timeout - with two dozen apps that is the difference between minutes and hours.
$missing = Join-Path $root 'never-written.done'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$w = Wait-CxOwnerDone -DoneFile $missing -TimeoutSec 300 -IsAlive { $false } -GraceSec 1
$sw.Stop()
Assert-Equal 'a dead mechanism is reported dead'      'dead' $w.State
Assert-True  'and reported in seconds, not minutes'   ($sw.Elapsed.TotalSeconds -lt 15) "took $([int]$sw.Elapsed.TotalSeconds)s"

Write-Host ''
Write-Host '== doctor grading: proven-unreachable is fail, unprovable is unknown ==' -ForegroundColor Cyan
# $script:fakeTopo, not $topo: PowerShell variable lookup is dynamic, and the doctor reads its
# result into a local named $topo. A stub body of `$topo` would resolve to the caller's own local
# - $null at the moment of the call - and the stub would silently return nothing.
$script:fakeTopo = $topo
function Get-CxPm2Topology { $script:fakeTopo }
function Test-CxPm2Available { $true }
function Get-CxPm2Apps { ,@() }   # ,@() like the real one: a bare @() unrolls to $null on return
$f1 = Test-NodeInstrumentation
Assert-True 'proven + owner mismatch -> OWNER_MISMATCH fail' `
    (@($f1 | Where-Object { $_.code -eq 'NODE_PM2_DAEMON_OWNER_MISMATCH' -and $_.severity -eq 'fail' }).Count -eq 1)
Assert-True 'service hosting reported as info' `
    (@($f1 | Where-Object { $_.code -eq 'NODE_PM2_SERVICE_HOSTED' -and $_.severity -eq 'info' }).Count -eq 1)
Assert-Equal 'graded exit is 1' 1 (Get-GradedExitCode -Findings $f1)

# A reachable daemon managing nothing, with no worker anywhere: the empty answer is the TRUTH, not
# a blind spot. The daemon is itself a node.exe, so a "are any node processes running" heuristic
# reports NODE_PM2_DAEMON_NOT_VISIBLE about the daemon it just successfully queried.
$script:fakeTopo = [pscustomobject]@{ Hosting='user'; Owner='NT AUTHORITY\SYSTEM'; Home=$fakeHome
    ServiceName=$null; ServiceState=$null; DaemonPid=4242; WorkerCount=0
    Identity='NT AUTHORITY\SYSTEM'; OwnerMismatch=$false }
function Get-CxPm2DumpApps { param($Pm2Home) @() }
function Test-CxNodeWorkloadPresent { $true }   # the daemon itself
$fIdle = Test-NodeInstrumentation
Assert-True 'reachable daemon + zero workers -> NO_PM2_APPS skip' `
    (@($fIdle | Where-Object { $_.code -eq 'NO_PM2_APPS' -and $_.severity -eq 'skip' }).Count -eq 1)
Assert-True 'and NOT reported as the wrong daemon' `
    (@($fIdle | Where-Object { $_.code -eq 'NODE_PM2_DAEMON_NOT_VISIBLE' }).Count -eq 0)
Assert-Equal 'graded exit is 0' 0 (Get-GradedExitCode -Findings $fIdle)

# Nothing provable AND the list could not be READ at all ($null, not an empty array - the two are
# different findings, which is why Get-CxPm2Apps has to return ,@() for the empty case). Here the
# honest answer is "could not look".
function Get-CxPm2Apps { $null }
$script:fakeTopo = [pscustomobject]@{ Hosting='none'; Owner=$null; Home=$null; ServiceName=$null
    ServiceState=$null; DaemonPid=$null; WorkerCount=0; Identity='NT AUTHORITY\SYSTEM'; OwnerMismatch=$false }
function Get-CxPm2DumpApps { param($Pm2Home) @() }
$f2 = Test-NodeInstrumentation
Assert-True 'unprovable -> DAEMON_NOT_VISIBLE unknown' `
    (@($f2 | Where-Object { $_.code -eq 'NODE_PM2_DAEMON_NOT_VISIBLE' -and $_.severity -eq 'unknown' }).Count -eq 1)
Assert-Equal 'graded exit is 0' 0 (Get-GradedExitCode -Findings $f2)

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepFixtures) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "fixtures kept: $root" }
exit $script:Fail
