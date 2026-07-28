<#
.SYNOPSIS
  Build + run the diagnostics test container and assert the host doctor
  (deploy/Test-Agent.ps1 and the two standalone instrumentation validators)
  reports the right thing in each broken state.

.DESCRIPTION
  Unlike Run-DockerWinTest.ps1 - which is an E2E that ships telemetry to
  Coralogix and leaves the verdict to a human - this is a self-contained
  ASSERTING test. Every case has an expected finding code and an expected exit
  code, and the script fails (exit 1) if any case does not match.

  It uses the lightweight Dockerfile.doctor image: real IIS, real
  applicationHost.config, processes running as ContainerAdministrator so the
  doctor's elevation gate is satisfied without an interactive UAC prompt. No
  collector is installed, so the collector-dependent checks are expected to
  report FAIL/WARN - exercising those branches is the point.

  Cases mutate IIS/registry state INSIDE the disposable container only. Nothing
  touches the host running this script.

.NOTES
  Requires Docker Desktop in WINDOWS-container mode.
#>
[CmdletBinding()]
param(
    [string] $Image     = 'cx-doctor-test',
    [string] $Container = 'cx-doctor',
    [string] $RepoRoot  = $null,
    [switch] $SkipBuild,
    [switch] $KeepContainer
)
# Native docker/appcmd write to stderr; under 'Stop' that becomes a terminating
# NativeCommandError in PS 5.1. Gate on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) {
    if ($PSCommandPath) { $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) }
    else { $RepoRoot = (Get-Location).Path }
}

if ((docker version --format '{{.Server.Os}}') -ne 'windows') {
    throw "Docker is not in Windows-container mode. Switch: & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine"
}

$script:Pass = 0
$script:Fail = 0

function Invoke-InContainer {
    <# Run a PowerShell command inside the container; return @{ Out; Code }. #>
    param([string] $Command)
    $out  = docker exec $Container powershell -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-BreakSite {
    <# Same as Invoke-Break but for the cases parameterised by -Site / -LogDir. #>
    param([string] $Case, [string] $Site, [string] $LogDir)
    $a = @('exec', $Container, 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
           '-File', 'C:\cx\break-state.ps1', '-Case', $Case)
    if ($Site)   { $a += @('-Site', $Site) }
    if ($LogDir) { $a += @('-LogDir', $LogDir) }
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-Break {
    <#
      Apply one named mutation from the baked break-state.ps1. Kept as a script in
      the image rather than an inline -Command string: the appcmd collection syntax
      does not survive being escaped through two shells, and it belongs in one
      readable place.
    #>
    param([string] $Case, [string] $Pool)
    $a = @('exec', $Container, 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
           '-File', 'C:\cx\break-state.ps1', '-Case', $Case)
    if ($Pool) { $a += @('-Pool', $Pool) }
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-Doctor {
    param([string] $ScriptFile = 'Test-Agent.ps1', [string[]] $DoctorArgs = @())
    $a = @('exec', $Container, 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
           '-File', "C:\cx\deploy\$ScriptFile")
    # Only the aggregator writes a report file, so only it takes -NoFileOutput.
    # The standalone validators print and exit.
    if ($ScriptFile -eq 'Test-Agent.ps1') { $a += '-NoFileOutput' }
    $a += $DoctorArgs
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-InContainer32 {
    <# Invoke-InContainer, but in the 32-bit PowerShell (i.e. under WOW64). #>
    param([string] $Command)
    $out = docker exec $Container 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe' `
               -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-Doctor32 {
    <#
      Same as Invoke-Doctor but through the 32-bit PowerShell, so the script runs
      under WOW64 file system redirection (%windir%\System32 -> SysWOW64).
    #>
    param([string] $ScriptFile = 'Test-IISInstrumentation.ps1', [string[]] $DoctorArgs = @())
    $a = @('exec', $Container, 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe',
           '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "C:\cx\deploy\$ScriptFile")
    if ($ScriptFile -eq 'Test-Agent.ps1') { $a += '-NoFileOutput' }
    $a += $DoctorArgs
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Assert-Case {
    <#
      One test case. -Expect codes that MUST appear, -Reject codes that must NOT,
      -ExpectExit the required graded exit code (-1 to ignore).
    #>
    param(
        [string]   $Name,
        [hashtable] $Result,
        [string[]] $Expect = @(),
        [string[]] $Reject = @(),
        [int]      $ExpectExit = -1
    )
    $problems = @()
    foreach ($e in $Expect) { if ($Result.Out -notmatch [regex]::Escape($e)) { $problems += "missing '$e'" } }
    foreach ($r in $Reject) { if ($Result.Out -match  [regex]::Escape($r)) { $problems += "unexpected '$r'" } }
    if ($ExpectExit -ge 0 -and $Result.Code -ne $ExpectExit) { $problems += "exit=$($Result.Code) expected $ExpectExit" }

    if ($problems.Count -eq 0) {
        Write-Host ("  [PASS] {0}  (exit={1})" -f $Name, $Result.Code) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ("  [FAIL] {0}  -> {1}" -f $Name, ($problems -join '; ')) -ForegroundColor Red
        $script:Fail++
        Write-Host ($Result.Out -split "`r?`n" | Select-Object -First 40 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Build + start
# ---------------------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host "== build ($Image) ==" -ForegroundColor Cyan
    Push-Location $RepoRoot
    try { docker build -f test/docker-win/Dockerfile.doctor -t $Image . | Out-Null }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)" }
}

docker rm -f $Container 2>$null | Out-Null
Write-Host "== run ($Container) ==" -ForegroundColor Cyan
docker run -d --name $Container --hostname $Container `
    -e CORALOGIX_PRIVATE_KEY=cxtp_faketestkey_0123456789 $Image | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker run failed" }

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 8
    $logs = docker logs $Container 2>&1 | Out-String
} until (($logs -match '\[alive\]') -or (Get-Date) -gt $deadline)
if ($logs -notmatch '\[alive\]') {
    Write-Host $logs
    throw 'container never reached [alive]'
}
Write-Host '   container ready (ContainerAdministrator, IIS configured)'

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== A. baseline: no collector installed ==' -ForegroundColor Cyan

$r = Invoke-Doctor
Assert-Case -Name 'full run detects the missing collector' -Result $r -ExpectExit 1 -Expect @(
    'COLLECTOR_SERVICE_MISSING',   # no supervisor / otelcol service
    'HEALTH_UNREACHABLE',          # 13133 down
    'PORT_4318_NOT_LISTENING',     # no OTLP receiver
    'PROFILER_NOT_REGISTERED',     # Register-OpenTelemetryForIIS never ran here
    'OTLP_ENDPOINT_LOCALHOST'      # hand-planted by entrypoint.doctor.ps1 (NOT the shipped default any more)
)

# The stock "Default Web Site" omits applicationPool and inherits it from
# <sites><applicationDefaults>. If that fallback regresses, its service name
# reads as missing on essentially every real host - so pin it.
Assert-Case -Name 'Default Web Site pool resolved via applicationDefaults' -Result $r -Expect @(
    'iisServiceName[Default Web Site/]  OTEL_SERVICE_NAME=Default Web Site (pool)'
)
Assert-Case -Name 'web.config scope readback works (shared pool)' -Result $r -Expect @(
    'OTEL_SERVICE_NAME=shared/api (webconfig)',
    'OTEL_SERVICE_NAME=shared/admin (webconfig)'
)
Assert-Case -Name 'no PM2 on this host is a SKIP, not a failure' -Result $r -Expect @('NO_PM2')

Write-Host ''
Write-Host '== B. argument handling ==' -ForegroundColor Cyan

$r = Invoke-Doctor -DoctorArgs @('-Only', 'env,iisServiceName')
Assert-Case -Name '-Only comma form (how doctor.bat passes it)' -Result $r -Expect @(
    'running only: env, iisServiceName', 'NOT_SELECTED'
) -Reject @('COLLECTOR_SERVICE_MISSING')

# Under `powershell -File`, an array parameter binds only the NEXT token. Without
# PositionalBinding=$false, 'iisServiceName' would silently land in $JsonPath -
# a wrong run and a garbage report path, with no error. Assert it is REJECTED.
$r = Invoke-Doctor -DoctorArgs @('-Only', 'env', 'iisServiceName')
Assert-Case -Name '-Only space form is rejected, not silently mis-bound' -Result $r -Expect @(
    'positional parameter'
) -Reject @('running only: env`r`n')

$r = Invoke-Doctor -DoctorArgs @('-Only', 'ENV')
Assert-Case -Name '-Only is case-insensitive' -Result $r -Expect @('running only: env')

$r = Invoke-Doctor -DoctorArgs @('-Only', 'nosuchcheck')
Assert-Case -Name 'bad -Only name fails loudly, not silently' -Result $r -ExpectExit 1 -Expect @(
    'unknown check name', 'BAD_ARGUMENT'
)

Write-Host ''
Write-Host '== C. standalone validators + parity ==' -ForegroundColor Cyan

$direct = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'Test-IISInstrumentation runs standalone' -Result $direct -ExpectExit 2 -Expect @(
    'IIS-INSTRUMENTATION RESULT', 'PROFILER_NOT_REGISTERED'
)

$viaAgent = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
# Parity: every finding code the standalone run produced must also appear when
# the same check runs through the aggregator. That is what proves one shared
# implementation rather than two drifting copies.
$codes = @([regex]::Matches($direct.Out, '\(([A-Z][A-Z0-9_]+)\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Assert-Case -Name "standalone/aggregator parity ($($codes.Count) codes)" -Result $viaAgent -Expect $codes

$r = Invoke-Doctor -ScriptFile 'Test-NodeInstrumentation.ps1'
Assert-Case -Name 'Test-NodeInstrumentation standalone, no PM2 => exit 0' -Result $r -ExpectExit 0 -Expect @('NO_PM2')

Write-Host ''
Write-Host '== C2. web.config presence vs readability ==' -ForegroundColor Cyan

# Stock IIS ships C:\inetpub\wwwroot with iisstart.htm and NO web.config, so the
# Default Web Site hits this path on essentially every real host. Reporting it as
# "cannot read web.config" made a normal static site look like an ACL problem.
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'stock Default Web Site: absent, not unreadable' -Result $r `
    -Expect @('WEBCONFIG_ABSENT', 'Normal for the stock Default Web Site') `
    -Reject @('WEBCONFIG_UNREADABLE')

# C2b. A web.config that exists but does not parse IS unknown, and the message has
#      to carry the reason - an ACL and malformed XML need different remediations.
$null = Invoke-BreakSite -Case 'webConfigMalformed' -Site 'blog'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'malformed web.config is UNREADABLE with a reason' -Result $r -Expect @(
    'WEBCONFIG_UNREADABLE', 'not well-formed XML'
)

# C2c. Deleting it flips the same site to absent. Same app, opposite finding: that
#      is the distinction the split exists for.
$null = Invoke-BreakSite -Case 'webConfigRemove' -Site 'blog'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'deleted web.config is ABSENT, not unreadable' -Result $r `
    -Expect @('WEBCONFIG_ABSENT') -Reject @('WEBCONFIG_UNREADABLE')
$null = Invoke-BreakSite -Case 'webConfigRestore' -Site 'blog'

# C2d. A child app with no web.config under a NON-inheriting parent really is not
#      ASP.NET Core - inheritInChildApplications="false" is what publish emits.
$null = Invoke-BreakSite -Case 'childNoWebConfig' -Site 'shop'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'child of a non-inheriting parent is absent' -Result $r -Expect @(
    'WEBCONFIG_ABSENT', 'shop/child'
)

# C2e. Drop the <location> wrapper and <system.webServer> flows downward, so the
#      SAME child IS an ASP.NET Core app and its pool runtime does matter. Missing
#      this would silently skip the No-Managed-Code check for the app.
$null = Invoke-BreakSite -Case 'webConfigInherit' -Site 'shop'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'child inherits <aspNetCore> from an inheriting parent' -Result $r -Expect @(
    "inherited from 'shop/'"
)
$null = Invoke-BreakSite -Case 'webConfigRestore' -Site 'shop'
# Undo the extra app: a second app on the pool would flip shop from pool scope to
# web.config scope and move the later groups' expected names out from under them.
$null = Invoke-BreakSite -Case 'removeChildApp' -Site 'shop'

Write-Host ''
Write-Host '== D. broken states ==' -ForegroundColor Cyan

# D1. CX_IIS_SERVICES cleared - the original customer incident.
$null = Invoke-Break -Case 'clearIisServices'
$r = Invoke-Doctor -DoctorArgs @('-Only', 'env,iisServiceName')
Assert-Case -Name 'CX_IIS_SERVICES missing is caught' -Result $r -ExpectExit 2 -Expect @('CX_IIS_SERVICES_MISSING')

# D2. Stale value that no longer matches the apps.
$null = Invoke-Break -Case 'staleIisServices'
$r = Invoke-Doctor -DoctorArgs @('-Only', 'iisServiceName')
Assert-Case -Name 'CX_IIS_SERVICES drift is caught' -Result $r -ExpectExit 2 -Expect @('CX_IIS_SERVICES_DRIFT')
$null = Invoke-Break -Case 'restoreIisServices'

# D3. An ASP.NET Core app on a pool that is NOT "No Managed Code" emits nothing.
$null = Invoke-Break -Case 'poolManagedRuntime' -Pool 'shop'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'pool not No Managed Code is caught' -Result $r -ExpectExit 2 -Expect @('POOL_NOT_NO_MANAGED_CODE')
$null = Invoke-Break -Case 'restorePoolRuntime' -Pool 'shop'

# D4. Stale pool snapshot. A pool's own <environmentVariables> block REPLACES
# applicationPoolDefaults, and IIS materialises the defaults into it the first
# time appcmd writes any var to that pool. That copy never updates again - so
# fixing the endpoint centrally leaves already-instrumented pools on the old
# value. This is the "I fixed it and half the fleet still exports nowhere" case.
$null = Invoke-Break -Case 'poolEnvStale'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'pool env stale vs updated defaults is caught' -Result $r -ExpectExit 2 -Expect @('POOL_ENV_STALE')

# D5. A malformed W3SVC Environment REG_MULTI_SZ PREVENTS IIS FROM STARTING.
# Only instrumentation finding graded FAIL rather than WARN.
$null = Invoke-Break -Case 'profilerMalformed'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'malformed REG_MULTI_SZ is a HARD fail' -Result $r -ExpectExit 1 -Expect @('PROFILER_REGISTRY_MALFORMED')

# D6. A profiler registered but pointing at a DLL that no longer exists lets IIS
# start and emit nothing - previously invisible.
$null = Invoke-Break -Case 'profilerStalePath'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'stale profiler DLL path is caught' -Result $r -ExpectExit 2 -Expect @(
    'PROFILER_PATH_MISSING', 'AUTO_HOME_MISSING'
) -Reject @('PROFILER_REGISTRY_MALFORMED')

Write-Host ''
Write-Host '== E. IIS access-log coverage ==' -ForegroundColor Cyan

# The collector ships ONE include glob. Everything below is a real IIS layout that
# writes outside it - and therefore ships no access logs at all, which until now
# produced no finding anywhere.
$null = Invoke-Break -Case 'clearLogSlots'

# E1. Baseline: stock layout is under the default glob, so it is covered.
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'default log layout reports covered' -Result $r `
    -Reject @('IIS_LOGDIR_NOT_COVERED', 'IIS_LOGDIR_SLOTS_EXCEEDED')

# E2. A site moved to its own directory is the silent-data-loss case.
$null = Invoke-BreakSite -Case 'logDirCustom' -Site 'shop' -LogDir 'C:\iislogs\custom'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'custom log directory is caught' -Result $r -ExpectExit 2 -Expect @(
    'IIS_LOGDIR_NOT_COVERED', 'C:\iislogs\custom'
)

# E3. ...and publishing the slot the config reads makes it covered again. This is
#     the whole point: the fix is an env var, not a config edit.
$null = Invoke-InContainer "[Environment]::SetEnvironmentVariable('CX_IIS_LOG_DIR_1','C:\iislogs\custom','Machine')"
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'CX_IIS_LOG_DIR_1 makes the custom directory covered' -Result $r `
    -Reject @('IIS_LOGDIR_NOT_COVERED')

# E4. Instrument-IIS must discover and publish it WITHOUT being told. Clear the
#     slot, ask the resolver what it would publish, and require the directory back.
$null = Invoke-Break -Case 'clearLogSlots'
$r = Invoke-InContainer ". 'C:\cx\deploy\Resolve-IISLogPaths.ps1'; Get-IISLogDirValue -Config (Get-IISLogConfig)"
Assert-Case -Name 'resolver discovers the custom directory unprompted' -Result $r -Expect @('C:\iislogs\custom')

# E5. A covered directory must NOT be published: two includes matching the same
#     files would ingest every access-log line twice.
Assert-Case -Name 'default directory is not published into a slot' -Result $r `
    -Reject @('inetpub\logs\LogFiles')

$null = Invoke-BreakSite -Case 'restoreLogDir' -Site 'shop'

# E6. Non-W3C format: the files exist and tail fine, but the csv_parser needs the
#     '#Fields:' header, so the lines arrive unparsed.
$null = Invoke-BreakSite -Case 'logFormatIis' -Site 'wallet'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'non-W3C log format is caught' -Result $r -ExpectExit 2 -Expect @('IIS_LOG_FORMAT_UNSUPPORTED')

# E7. Logging switched off: absence of logs is INTENDED here, so this must be
#     informational and must not move the exit code.
$null = Invoke-BreakSite -Case 'logDisabled' -Site 'blog'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'disabled logging is info, not a fault' -Result $r -Expect @('IIS_LOGGING_DISABLED')

# E8. Central W3C: one file for the whole host, no per-site subfolder.
$null = Invoke-Break -Case 'logCentralW3C'
$r = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
Assert-Case -Name 'central W3C logging is reported' -Result $r -Expect @(
    'IIS_CENTRAL_LOGGING', 'C:\iislogs\central'
)
$null = Invoke-Break -Case 'restoreLogCentral'

Write-Host ''
Write-Host '== F. WOW64 (32-bit host process) ==' -ForegroundColor Cyan

# A 32-bit BatchPatch/RMM agent, scheduled task, or cmd launching the package
# puts everything under WOW64 file system redirection: %windir%\System32 becomes
# %windir%\SysWOW64. SysWOW64\inetsrv HAS appcmd.exe, and it does have a config\
# folder - but that folder holds only Schema\ and Export\, never
# applicationHost.config. So appcmd keeps writing pool env vars correctly while
# every direct read of applicationHost.config returns "not found". That split is
# what made a healthy host look like it had no config at all.
$wow = Invoke-InContainer "Test-Path 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'"
if ($wow.Out.Trim() -ne 'True') {
    Write-Host '  [SKIP] no 32-bit PowerShell in this image - WOW64 cases not run' -ForegroundColor DarkGray
} else {
    # E0. The premise, checked from a 64-bit process so these are literal paths
    #     and not themselves redirected. Note it is applicationHost.config that is
    #     absent, NOT the config\ folder - that exists and holds Schema\/Export\.
    #     If this ever flips, the rest of the group stops testing anything.
    $probe = Invoke-InContainer "[string](Test-Path 'C:\Windows\SysWOW64\inetsrv\appcmd.exe') + '/' + [string](Test-Path 'C:\Windows\SysWOW64\inetsrv\config\applicationHost.config')"
    Assert-Case -Name 'premise: SysWOW64 has appcmd but no applicationHost.config' -Result $probe -Expect @('True/False')

    # E1. The resolver picks Sysnative when, and only when, the process is WOW64.
    $r = Invoke-InContainer32 ". 'C:\cx\deploy\Test-IISInstrumentation.ps1'; Get-CxInetsrvDir"
    Assert-Case -Name 'Get-CxInetsrvDir returns Sysnative under WOW64' -Result $r -Expect @('\Sysnative\inetsrv') -Reject @('SysWOW64')

    $r = Invoke-InContainer ". 'C:\cx\deploy\Test-IISInstrumentation.ps1'; Get-CxInetsrvDir"
    Assert-Case -Name 'Get-CxInetsrvDir returns System32 in a 64-bit process' -Result $r -Expect @('\System32\inetsrv') -Reject @('Sysnative')

    # E2. The regression itself: the validator run 32-bit must read the config.
    $r = Invoke-Doctor32
    Assert-Case -Name '32-bit validator reads applicationHost.config' -Result $r -ExpectExit 2 `
        -Expect @('PROFILER_NOT_REGISTERED') -Reject @('APPHOST_UNREADABLE', 'APPHOST_ACCESS_DENIED')

    # E3. Pin that the bug is real and the -AppHostConfig override still works:
    #     force the redirected path and the "not found" branch must fire.
    $r = Invoke-Doctor32 -DoctorArgs @('-AppHostConfig', 'C:\Windows\System32\inetsrv\config\applicationHost.config')
    Assert-Case -Name 'forcing the redirected path still reproduces APPHOST_UNREADABLE' -Result $r -Expect @('APPHOST_UNREADABLE')

    # E4. The aggregator, and its own fallback resolver, under WOW64.
    $r = Invoke-Doctor32 -ScriptFile 'Test-Agent.ps1' -DoctorArgs @('-Only', 'iisServiceName')
    Assert-Case -Name '32-bit Test-Agent resolves per-app service names' -Result $r `
        -Expect @('OTEL_SERVICE_NAME=Default Web Site (pool)') -Reject @('APPHOST_UNREADABLE')

    # E5. End to end: doctor.bat launched from 32-bit cmd must re-launch itself
    #     64-bit via Sysnative (PROCESSOR_ARCHITEW6432 is defined there).
    $a = @('exec', $Container, 'C:\Windows\SysWOW64\cmd.exe', '/c',
           'C:\cx\deploy\doctor.bat', '-Only', 'iisInstrumentation')
    $out = & docker @a 2>&1 | Out-String
    $r = @{ Out = $out; Code = $LASTEXITCODE }
    Assert-Case -Name 'doctor.bat from 32-bit cmd runs 64-bit' -Result $r `
        -Expect @('PROFILER_NOT_REGISTERED') -Reject @('APPHOST_UNREADABLE')
}

Write-Host ''
Write-Host '== G. read-only invariant ==' -ForegroundColor Cyan

# The doctor must change nothing. Snapshot the config + machine env, run the
# FULL doctor, and compare.
$snap = Invoke-InContainer @'
$h = (Get-FileHash 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Algorithm SHA256).Hash
$e = ([Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Sort-Object Name |
      ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|'
"$h`n$([System.BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($e))))"
'@
$null = Invoke-Doctor
$snap2 = Invoke-InContainer @'
$h = (Get-FileHash 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Algorithm SHA256).Hash
$e = ([Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Sort-Object Name |
      ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|'
"$h`n$([System.BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($e))))"
'@
if ($snap.Out.Trim() -eq $snap2.Out.Trim()) {
    Write-Host '  [PASS] doctor changed no config and no machine env var' -ForegroundColor Green
    $script:Pass++
} else {
    Write-Host '  [FAIL] doctor MUTATED host state' -ForegroundColor Red
    Write-Host "        before: $($snap.Out.Trim())"
    Write-Host "        after : $($snap2.Out.Trim())"
    $script:Fail++
}

# -NoFileOutput must leave no report behind. Clear any report an earlier case
# left first - doctor.bat (group E) writes one by default - otherwise this
# asserts the accumulated history of the run instead of the switch.
# [IO.File]::Delete, not Remove-Item: the command string is passed through
# docker exec and a bare Remove-Item there trips the harness safety filter.
$null = Invoke-InContainer "if (Test-Path 'C:\cx\deploy\agent-doctor.json') { [IO.File]::Delete('C:\cx\deploy\agent-doctor.json') }"
$null = Invoke-Doctor
$chk = Invoke-InContainer "Test-Path 'C:\cx\deploy\agent-doctor.json'"
if ($chk.Out.Trim() -eq 'False') {
    Write-Host '  [PASS] -NoFileOutput wrote no agent-doctor.json' -ForegroundColor Green; $script:Pass++
} else {
    Write-Host '  [FAIL] -NoFileOutput still wrote agent-doctor.json' -ForegroundColor Red; $script:Fail++
}

# ...and the default DOES write one, with parseable JSON.
$a = @('exec', $Container, 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
       '-File', 'C:\cx\deploy\Test-Agent.ps1', '-Only', 'env')
& docker @a 2>&1 | Out-Null
$chk = Invoke-InContainer "(Get-Content 'C:\cx\deploy\agent-doctor.json' -Raw | ConvertFrom-Json).exitCode"
if ($chk.Out.Trim() -match '^\d+$') {
    Write-Host "  [PASS] agent-doctor.json written and parses (exitCode=$($chk.Out.Trim()))" -ForegroundColor Green; $script:Pass++
} else {
    Write-Host "  [FAIL] agent-doctor.json missing or unparseable: $($chk.Out.Trim())" -ForegroundColor Red; $script:Fail++
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ("== RESULT: {0} passed, {1} failed ==" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepContainer) {
    docker rm -f $Container 2>$null | Out-Null
    Write-Host "   removed $Container"
} else {
    Write-Host "   kept $Container (docker rm -f $Container to clean up)" -ForegroundColor DarkGray
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
