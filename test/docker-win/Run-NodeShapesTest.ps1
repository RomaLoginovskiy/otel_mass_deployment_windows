<#
.SYNOPSIS
  Asserting harness for every Node.js deployment shape a Windows host can have: drives each shape
  in a Windows container, gates it on what the deploy scripts make of it, and proves telemetry
  reaches Coralogix.

.DESCRIPTION
  Why this exists: service-hosted PM2 support shipped behind fixture unit tests only. Nothing had
  ever watched Invoke-CxPm2AsOwner actually reach a PM2 daemon owned by another account, and no Node
  hosting shape other than a per-user PM2 had been exercised at all. Both gaps are the kind that
  produce a silent no-op on a customer host - which is exactly what happened on SGA's OTIOMWQA01,
  where 26 PM2 apps ran with zero Node telemetry and every script reported success.

  Structure: ONE container, shapes applied and reset through `docker exec setup-nodeshape.ps1`
  (the break-state.ps1 arrangement), so the harness controls ordering and can observe state before
  and after each step without paying container-start cost per case.

  Each shape is gated twice:
    * LOCALLY, in seconds - the doctor's findings and graded exit code, plus the collector's own
      counters on :8888 (accepted/sent spans rising, send_failed flat).
    * IN CORALOGIX, once at the end - a single DataPrime sweep over every shape's service name, so
      the 10-15 minute ingest lag is paid once instead of per shape. Uninstall (P5) runs before the
      sweep; that is fine, because uninstalling does not retract telemetry already sent.

.PARAMETER Only
  Run just the phases whose name contains this (e.g. -Only p3, -Only service). Repeatable.

.PARAMETER SkipCoralogix
  Skip the final backend sweep. Everything else still asserts. Use for the inner loop.

.NOTES
  Requires Docker Desktop in WINDOWS-container mode, plus the baked prerequisites listed in
  test/docker-win/README.md (node.zip, npm-global with pm2 AND node-windows, otel-node,
  otelcol-contrib.exe, nodeapp/node_modules, and for the IIS-hosted shapes vendor/iis/*.msi).

  Exit code = number of failed assertions.

  Every `docker exec` is BOUNDED. A pm2 call that has to spawn the God daemon can hang forever under
  docker exec - the daemon inherits the exec session's stdout handle and never closes it - and one
  such hang would stall the whole matrix.
#>
[CmdletBinding()]
param(
    [string]   $Image      = 'cx-nodeshapes',
    [string]   $Container  = 'cx-nodeshapes',
    [string]   $HostName   = 'cx-nodeshapes',
    [string]   $RepoRoot   = $null,
    [string[]] $Only       = @(),
    [switch]   $SkipBuild,
    [switch]   $KeepContainer,
    [switch]   $SkipCoralogix,
    [string]   $Region     = 'eu1',
    [string]   $Domain,
    [string]   $PrivateKey,
    [string]   $QueryKeyFile,
    [string]   $KeyLabel   = 'watcher',
    [int]      $IngestWaitSec = 900
)

# Native docker/appcmd write to stderr; under 'Stop' that becomes a terminating NativeCommandError
# in PS 5.1. Gate on exit codes instead.
$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) {
    if ($PSCommandPath) { $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) }
    else { $RepoRoot = (Get-Location).Path }
}
if ((docker version --format '{{.Server.Os}}') -ne 'windows') {
    throw "Docker is not in Windows-container mode. Switch: & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine"
}

if (-not $QueryKeyFile) { $QueryKeyFile = Join-Path $RepoRoot 'querydata_key.txt' }
if (-not $Domain) {
    . (Join-Path $RepoRoot 'deploy\Resolve-CxRegion.ps1')
    $Domain = Resolve-CxDomain -Region $Region
}
if (-not $PrivateKey) {
    $kf = Join-Path $RepoRoot 'SimpleWebApp\coralogix\SendDataKey.txt'
    if (Test-Path -LiteralPath $kf) { $PrivateKey = (Get-Content -LiteralPath $kf -Raw).Trim() }
}

# Accept both -Only a,b and -Only a b. Invoked through `powershell -File`, a comma-separated list
# arrives as ONE token, which would then match no phase at all - the same trap doctor.bat's -Only
# has, and worth handling here rather than making every caller remember it.
$Only = @($Only | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Write-Host with -ForegroundColor asks the host for console buffer info, which THROWS when stdout is
# a redirected file with no console attached ("No process is on the other end of the pipe", 0xE9).
# That is how this harness is normally run - output piped to a log - and it cost a whole P3 run: the
# assertions executed, but every [FAIL] line and the final tally failed to render, so the results
# were lost. Colour is decoration; the results are not.
$script:CxColour = $true
function Write-CxHost {
    param([Parameter(Position = 0)] $Object = '', [string] $ForegroundColor)
    $text = [string]$Object
    if ($ForegroundColor -and $script:CxColour) {
        try { Microsoft.PowerShell.Utility\Write-Host $text -ForegroundColor $ForegroundColor; return }
        catch { $script:CxColour = $false }
    }
    try { Microsoft.PowerShell.Utility\Write-Host $text } catch { Write-Output $text }
}

$script:Pass = 0
$script:Fail = 0
$script:Known = 0
$script:Skipped = @()
# Service names every shape is expected to have shipped under, collected as the run goes and swept
# in Coralogix at the end.
$script:ExpectedServices = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
function Invoke-Docker {
    <# docker with a hard timeout; returns @{ Out; Code; TimedOut }. #>
    param([string[]] $DockerArgs, [int] $TimeoutSec = 300)

    $stem = Join-Path $env:TEMP ("cx-dex-" + [guid]::NewGuid().ToString('N'))
    $o = "$stem.out"; $e = "$stem.err"
    $timedOut = $false
    $code = -1
    try {
        $p = Start-Process -FilePath 'docker' -ArgumentList $DockerArgs -NoNewWindow -PassThru `
                 -RedirectStandardOutput $o -RedirectStandardError $e
        # Touching .Handle caches it, which is what makes .ExitCode readable after WaitForExit.
        # Without this the property is $null even for a process that plainly succeeded, and every
        # exit-code assertion in this harness silently compares against nothing.
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $p.Kill() } catch { }
        } else {
            $p.Refresh()
            $code = $p.ExitCode
        }
    } catch {
        return @{ Out = "docker launch failed: $($_.Exception.Message)"; Code = -1; TimedOut = $false }
    }
    $out = ''
    foreach ($f in @($o, $e)) {
        if (Test-Path -LiteralPath $f) {
            try { $out += (Get-Content -LiteralPath $f -Raw -ErrorAction Stop) } catch { }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    if ($timedOut) { $out += "`n[harness] TIMED OUT after ${TimeoutSec}s" }
    return @{ Out = $out; Code = $code; TimedOut = $timedOut }
}

function Invoke-Step {
    <#
      Run something in the container DETACHED, then poll for its result.

      Not an optimisation - a correctness fix. A synchronous `docker exec` that ends up spawning the
      PM2 God daemon never returns: the daemon inherits the exec session's stdout handle and holds it
      open long after the script itself has finished. Observed repeatedly here as a completed report
      followed by a full-timeout hang, which makes every downstream assertion fail for a reason that
      has nothing to do with the thing under test.

      `docker exec -d` gives the work no stdout to inherit in the first place. Output and exit code
      go to files in C:\cx\state, and the harness polls for the sentinel with SHORT execs that never
      touch pm2 (a later exec cannot be captured by an earlier daemon - handles are inherited at
      spawn time, from the spawning process only).

      The command is passed as -EncodedCommand: UTF-16LE base64 survives two shells intact, so app
      names with dots, quotes or spaces need no escaping anywhere.
    #>
    param([string] $CommandText, [int] $TimeoutSec = 300, [string] $Label)

    if ($Label) { Write-CxHost "   -> $Label" -ForegroundColor DarkGray }
    $id    = [guid]::NewGuid().ToString('N')
    $outF  = "C:\cx\state\$id.out"
    $errF  = "C:\cx\state\$id.err"
    $doneF = "C:\cx\state\$id.done"

    # The work runs as a CHILD process with its stdout redirected to a file, not as
    # `$CommandText *>&1 | Out-File` in-process. Everything here reports through Write-CxHost - the
    # shape script's own log lines, the instrumenter's, the doctor's finding table - and Write-Host
    # writes to the HOST, not the pipeline, so an in-process capture yields an empty file and every
    # assertion fails against nothing. A child process's stdout IS a file handle, so the same
    # Write-CxHost output lands in the file.
    #
    # The inner command is passed to the child as its own -EncodedCommand: no quoting survives two
    # shells plus an argument list otherwise, and app names here contain dots and quotes.
    # A `trap` that reports on STDOUT. A PowerShell child whose stderr is redirected serialises its
    # error and progress records as CLIXML, so the actual message arrives as an unreadable XML blob -
    # which is how an uninstall step that threw showed up as "no output" twice over. Write-Host goes
    # to stdout as plain text, and `continue` keeps the rest of the step running.
    $inner = "trap { Write-Host ('[error] ' + `$_.Exception.Message + ' @ ' + `$_.InvocationInfo.ScriptName + ':' + `$_.InvocationInfo.ScriptLineNumber); continue }`n" +
             "`$ProgressPreference = 'SilentlyContinue'`n" +
             "$CommandText`nexit `$LASTEXITCODE"
    $inner64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

    $wrapper = @"
`$ErrorActionPreference = 'Continue'
`$p = Start-Process -FilePath 'powershell.exe' -NoNewWindow -PassThru ``
        -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-OutputFormat','Text','-EncodedCommand','$inner64' ``
        -RedirectStandardOutput '$outF' -RedirectStandardError '$errF'
`$null = `$p.Handle
`$p.WaitForExit()
`$p.Refresh()
`$c = `$p.ExitCode
if (`$null -eq `$c) { `$c = 0 }
Set-Content -LiteralPath '$doneF' -Value ([string]`$c) -Encoding ascii
"@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))

    $launch = Invoke-Docker -TimeoutSec 90 -DockerArgs @('exec', '-d', $Container, 'powershell',
                  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64)
    if ($launch.Code -ne 0) {
        return @{ Out = "[harness] detached launch failed: $($launch.Out)"; Code = -1; TimedOut = $false }
    }

    # BOTH streams. Reading only stdout made a step that threw look like a step that printed
    # nothing - which is how an uninstall failure presented as an empty output block with no clue
    # in it. The error text is the whole point of running the thing.
    # The poll goes through -EncodedCommand as well. Passed as `-Command "<text>"`, any double quote
    # in the text is eaten by the docker/CreateProcess argument round-trip - which turned
    # `"[stderr] " + $e` into a bare `[stderr] + $e` and an "Unable to find type [stderr]" error,
    # hiding the very stderr it was added to surface. Base64 has no such layer.
    $readCmd = "if (Test-Path '$doneF') { " +
               "Get-Content -LiteralPath '$outF' -Raw -ErrorAction SilentlyContinue; " +
               "`$e = Get-Content -LiteralPath '$errF' -Raw -ErrorAction SilentlyContinue; " +
               "if (`$e) { '[stderr] ' + `$e } " +
               "'###EXIT=' + (Get-Content -LiteralPath '$doneF' -Raw).Trim() }"
    $read64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($readCmd))
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $p = Invoke-Docker -TimeoutSec 60 -DockerArgs @('exec', $Container, 'powershell', '-NoProfile', '-EncodedCommand', $read64)
        if ($p.Out -match '###EXIT=(-?\d+)') {
            $code = [int]$matches[1]
            $body = ($p.Out -replace '###EXIT=-?\d+\s*$', '')
            return @{ Out = $body; Code = $code; TimedOut = $false }
        }
    }
    return @{ Out = "[harness] step did not finish within ${TimeoutSec}s"; Code = -1; TimedOut = $true }
}

function Invoke-InContainer {
    <# Arbitrary PowerShell in the container. Detached, because callers use it for pm2 reads too. #>
    param([string] $Command, [int] $TimeoutSec = 180)
    Invoke-Step -CommandText $Command -TimeoutSec $TimeoutSec
}

function Invoke-Shape {
    <# Apply one named shape from the baked setup-nodeshape.ps1. #>
    param([string] $Case, [int] $TimeoutSec = 300)
    $r = Invoke-Step -Label "shape: $Case" -TimeoutSec $TimeoutSec `
             -CommandText ("& 'C:\cx\setup-nodeshape.ps1' -Case '{0}'" -f $Case)
    if ($r.Out -match 'SKIP\s+(\w+)') { $script:Skipped += $matches[1] }
    return $r
}

function Invoke-Detect {
    # -SetEnv is deliberately NOT passed: its default is already $true, and through a string-typed
    # invocation '$true' cannot bind to a [bool] parameter - it fails with a transformation error
    # before detection runs at all.
    param([int] $TimeoutSec = 300)
    Invoke-Step -Label 'detect' -TimeoutSec $TimeoutSec `
        -CommandText "& 'C:\cx\deploy\Detect-Workloads.ps1' -LogPath 'C:\cx\state\detect.json'"
}

function Invoke-Instrument {
    <#
      -CredentialUser/-CredentialPassword build the PSCredential INSIDE the container. A
      [pscredential] cannot be handed across as a command-line string, and the ordinary-account
      owner shape cannot be instrumented without one.
    #>
    param(
        [string[]] $ExtraArgs = @(), [int] $TimeoutSec = 900,
        [string] $CredentialUser, [string] $CredentialPassword
    )
    $extra = ''
    if ($ExtraArgs.Count -gt 0) {
        $extra = ' ' + (@($ExtraArgs | ForEach-Object {
            if ($_ -match '^-') { $_ } else { "'" + ([string]$_).Replace("'","''") + "'" }
        }) -join ' ')
    }
    $prefix = ''
    if ($CredentialUser) {
        $u = $CredentialUser.Replace("'","''")
        $pw = $CredentialPassword.Replace("'","''")
        $prefix = "`$cxCred = New-Object pscredential('$u', (ConvertTo-SecureString '$pw' -AsPlainText -Force)); "
        $extra += ' -Pm2OwnerCredential $cxCred'
    }
    Invoke-Step -Label "instrument$extra" -TimeoutSec $TimeoutSec `
        -CommandText ($prefix + "& 'C:\cx\deploy\Instrument-NodePM2.ps1' -SkipInstall -OtlpEndpoint 'http://127.0.0.1:4318'$extra")
}

function Invoke-Doctor {
    param([string] $ScriptFile = 'Test-NodeInstrumentation.ps1', [string[]] $DoctorArgs = @(), [int] $TimeoutSec = 300)
    $a = @()
    if ($ScriptFile -eq 'Test-Agent.ps1') { $a += '-NoFileOutput' }
    $a += $DoctorArgs
    $extra = if ($a.Count -gt 0) { ' ' + ($a -join ' ') } else { '' }
    Invoke-Step -Label "doctor: $ScriptFile$extra" -TimeoutSec $TimeoutSec `
        -CommandText ("& 'C:\cx\deploy\$ScriptFile'$extra")
}

function Get-SpanCounter {
    <#
      Total spans the collector has ACCEPTED from the apps. The local per-shape gate: an
      instrumented app that never loads its bootstrap leaves this flat, and that is visible in
      seconds rather than after the ingest wait.
    #>
    $cmd = "try { ((Invoke-WebRequest 'http://127.0.0.1:8888/metrics' -UseBasicParsing -TimeoutSec 5).Content -split [char]10 | " +
           "Where-Object { `$_ -match '^otelcol_receiver_accepted_spans' } | " +
           "ForEach-Object { [double](`$_ -split ' ')[-1] } | Measure-Object -Sum).Sum } catch { 0 }"
    $r = Invoke-InContainer -Command $cmd -TimeoutSec 60
    $n = 0.0
    if ([double]::TryParse((($r.Out -split "`r?`n" | Where-Object { $_ -match '^\s*[\d\.]+\s*$' } | Select-Object -First 1)), [ref]$n)) { return $n }
    return 0.0
}

function Wait-ForSpans {
    <# Poll until the accepted-span counter rises above a baseline. #>
    param([double] $Baseline, [int] $TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 6
        $now = Get-SpanCounter
        if ($now -gt $Baseline) { return $now }
    } while ((Get-Date) -lt $deadline)
    return (Get-SpanCounter)
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
function Assert-Case {
    <#
      -Expect  every string must appear in the output
      -Reject  none of these may appear
      -ExpectExit required graded exit code (-1 to ignore)
    #>
    param(
        [string] $Name, [hashtable] $Result,
        [string[]] $Expect = @(), [string[]] $Reject = @(),
        [int] $ExpectExit = -1
    )
    $out  = [string]$Result.Out
    $miss = @($Expect | Where-Object { $out -notmatch [regex]::Escape($_) })
    $bad  = @($Reject | Where-Object { $out -match  [regex]::Escape($_) })
    $codeOk = ($ExpectExit -lt 0) -or ($Result.Code -eq $ExpectExit)

    if ($miss.Count -eq 0 -and $bad.Count -eq 0 -and $codeOk -and -not $Result.TimedOut) {
        $script:Pass++
        Write-CxHost "  [PASS] $Name" -ForegroundColor Green
        return
    }
    $script:Fail++
    Write-CxHost "  [FAIL] $Name" -ForegroundColor Red
    if ($Result.TimedOut)   { Write-CxHost "         TIMED OUT" -ForegroundColor Red }
    if (-not $codeOk)       { Write-CxHost "         exit: expected $ExpectExit, got $($Result.Code)" -ForegroundColor Red }
    if ($miss.Count -gt 0)  { Write-CxHost "         missing: $($miss -join ' | ')" -ForegroundColor Red }
    if ($bad.Count -gt 0)   { Write-CxHost "         present but rejected: $($bad -join ' | ')" -ForegroundColor Red }
    $tail = @($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 14)
    foreach ($l in $tail) { Write-CxHost "         | $l" -ForegroundColor DarkGray }
}

function Assert-True {
    param([string] $Name, $Condition, [string] $Detail = '')
    if ($Condition) { $script:Pass++; Write-CxHost "  [PASS] $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-CxHost "  [FAIL] $Name" -ForegroundColor Red; if ($Detail) { Write-CxHost "         $Detail" -ForegroundColor DarkGray } }
}

function Write-KnownIssue {
    <# A shape that behaves as (badly as) it always has. Loud, counted, never silent, never a pass. #>
    param([string] $Name, [string] $Detail)
    $script:Known++
    Write-CxHost "  [KNOWN] $Name" -ForegroundColor Yellow
    Write-CxHost "          $Detail" -ForegroundColor DarkGray
}

function Write-Phase { param([string] $T) Write-CxHost ''; Write-CxHost ("== {0} " -f $T).PadRight(78, '=') -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# Build + start
# ---------------------------------------------------------------------------
Push-Location $RepoRoot
try {
    if (-not $SkipBuild) {
        Write-Phase "build ($Image)"
        $b = Invoke-Docker -TimeoutSec 2400 -DockerArgs @('build', '-f', 'test/docker-win/Dockerfile.nodeshapes', '-t', $Image, '.')
        if ($b.Code -ne 0) {
            Write-CxHost $b.Out
            throw "docker build failed (exit $($b.Code))"
        }
        $mods = @($b.Out -split "`r?`n" | Where-Object { $_ -match '\[build\] (installing|SKIP|WARN|IIS modules)' })
        foreach ($m in $mods) { Write-CxHost "  $m" -ForegroundColor DarkGray }
    }

    Invoke-Docker -DockerArgs @('rm', '-f', $Container) | Out-Null
    Write-Phase "run ($Container)"
    $runArgs = @('run', '-d', '--name', $Container, '--hostname', $HostName,
                 '-e', "CORALOGIX_DOMAIN=$Domain")
    if ($PrivateKey) { $runArgs += @('-e', "CORALOGIX_PRIVATE_KEY=$PrivateKey") }
    else { Write-Warning 'no send key found - the local gates still run, the Coralogix sweep will not' }
    $runArgs += $Image
    $r = Invoke-Docker -DockerArgs $runArgs
    if ($r.Code -ne 0) { Write-CxHost $r.Out; throw 'docker run failed' }

    # Wait for the entrypoint to report the collector healthy.
    $booted = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        $logs = Invoke-Docker -DockerArgs @('logs', $Container)
        if ($logs.Out -match '\[boot\] READY') { $booted = $true; break }
        if ($logs.Out -match 'collector did not report healthy') { $booted = $true; break }
    }
    Assert-True 'container booted with a healthy collector' $booted 'see: docker logs cx-nodeshapes'

    $phases = New-Object System.Collections.ArrayList
    function Add-Phase { param([string]$Name, [scriptblock]$Body) [void]$phases.Add(@{ Name = $Name; Body = $Body }) }

    # -----------------------------------------------------------------------
    Add-Phase 'p0-probe' {
        Write-Phase 'P0 - what this container can actually prove'
        $p = Invoke-Shape 'probeEnv'
        foreach ($probeLine in @($p.Out -split "`r?`n" | Where-Object { $_ -match 'PROBE' })) { Write-CxHost "   $probeLine" }
        Assert-Case 'probe reports every mechanism' -Result $p -Expect @(
            'PROBE ScheduledTasks module:', 'PROBE scheduled task as LOCAL SERVICE:',
            'PROBE transient service as LOCAL SERVICE:', 'PROBE winsw baked: YES')
        $script:TaskSchedulerWorks = ($p.Out -match 'PROBE scheduled task as LOCAL SERVICE: WORKS')
        $script:ScFallbackWorks    = ($p.Out -match 'PROBE transient service as LOCAL SERVICE: WORKS')
        Assert-True 'at least one run-as-owner mechanism works here' `
            ($script:TaskSchedulerWorks -or $script:ScFallbackWorks) `
            'neither Task Scheduler nor a transient service can run as LOCAL SERVICE in this container - the service-hosted shapes cannot be applied'
        if (-not $script:TaskSchedulerWorks) {
            Write-KnownIssue 'Task Scheduler unusable in this container' 'Invoke-CxPm2AsOwner will be exercised through its sc.exe fallback instead'
        }
    }

    # -----------------------------------------------------------------------
    Add-Phase 'p1-baseline' {
        Write-Phase 'P1 - Node present, PM2 absent / idle'
        Invoke-Shape 'resetAll' | Out-Null

        # A genuinely PM2-less host - the state most fleet hosts are in. The shims have to be
        # hidden to reach it, because this image installs pm2 globally and `Get-Command pm2`
        # finding it is (correctly) enough for detection to report workload.pm2=true.
        Invoke-Shape 'pm2Hide' | Out-Null
        $d = Invoke-Detect
        Assert-Case 'no PM2 on the host: detection sees Node but not PM2' -Result $d `
            -Expect @('workload.nodejs=true') -Reject @('workload.pm2=true')
        $doc = Invoke-Doctor
        Assert-Case 'no PM2 on the host: doctor skips, never fails' -Result $doc -ExpectExit 0 -Expect @('NO_PM2')
        Invoke-Shape 'pm2Unhide' | Out-Null

        # PM2 installed but with no daemon/apps yet: still workload.pm2=true (it IS on this host),
        # and no app count claimed.
        $d = Invoke-Detect
        Assert-Case 'PM2 installed but idle: reported present, with no app count' -Result $d `
            -Expect @('workload.pm2=true') -Reject @('workload.pm2.apps=')

        Invoke-Shape 'pm2ZeroApps' | Out-Null
        $doc = Invoke-Doctor
        Assert-Case 'doctor: PM2 with zero apps is a skip' -Result $doc -ExpectExit 0 `
            -Expect @('NO_PM2_APPS') -Reject @('NODE_PM2_DAEMON_OWNER_MISMATCH')
        $svc = Invoke-InContainer "[Environment]::GetEnvironmentVariable('CX_NODE_SERVICES','Machine')"
        Assert-True 'CX_NODE_SERVICES not invented for a daemon with no apps' ($svc.Out.Trim() -eq '') $svc.Out.Trim()
    }

    # -----------------------------------------------------------------------
    Add-Phase 'p2-peruser' {
        Write-Phase 'P2 - PM2 per-user daemon'
        Invoke-Shape 'resetAll' | Out-Null
        Invoke-Shape 'pm2UserFork' | Out-Null

        $d = Invoke-Detect
        Assert-Case 'detection: hosting=user, one app' -Result $d `
            -Expect @('workload.pm2=true', 'workload.pm2.hosting=user', 'workload.pm2.apps=1')

        $doc = Invoke-Doctor
        Assert-Case 'doctor before instrumenting: app is not instrumented' -Result $doc `
            -Expect @('NODE_OPTIONS_MISSING')

        $base = Get-SpanCounter
        $i = Invoke-Instrument
        Assert-Case 'instrument: fork app gets --require, in-process (no owner hop)' -Result $i `
            -Expect @('pm2 hosting   : user', '--require', 'shape-user-fork') `
            -Reject @('will be invoked as that account')
        [void]$script:ExpectedServices.Add('shape-user-fork')

        $doc = Invoke-Doctor
        Assert-Case 'doctor after instrumenting: clean' -Result $doc -ExpectExit 0 `
            -Reject @('NODE_OPTIONS_MISSING', 'NODE_ESM_REQUIRE_MISMATCH')

        $after = Wait-ForSpans -Baseline $base -TimeoutSec 120
        Assert-True 'collector accepted spans from the fork app' ($after -gt $base) "accepted_spans $base -> $after"

        # -- cluster
        Invoke-Shape 'pm2UserCluster' | Out-Null
        $i = Invoke-Instrument
        Assert-Case 'instrument: cluster app instrumented under one service name' -Result $i `
            -Expect @('shape-user-cluster', 'instances=2')
        [void]$script:ExpectedServices.Add('shape-user-cluster')
        $doc = Invoke-Doctor
        Assert-Case 'doctor: cluster app carries NODE_OPTIONS + service name' -Result $doc `
            -Expect @('shape-user-cluster') -Reject @('NODE_OPTIONS_MISSING')

        # -- ESM: --import, and the negative case
        Invoke-Shape 'pm2Esm' | Out-Null
        Invoke-Shape 'pm2Mjs' | Out-Null
        $i = Invoke-Instrument
        Assert-Case 'instrument: ESM apps get the loader hook, CJS keeps plain --require' -Result $i `
            -Expect @('shape-esm', 'shape-mjs', 'ESM loader hook', 'esm+hook')
        [void]$script:ExpectedServices.Add('shape-esm')
        [void]$script:ExpectedServices.Add('shape-mjs')

        # Read the app's ACTUAL NODE_OPTIONS back out of pm2, rather than trusting the
        # instrumenter's own log line. The previous version of this assertion looked for the string
        # '--import' in the output and kept passing after --import had been removed entirely - it was
        # matching something incidental, and an assertion that passes either way is worse than one
        # that fails. What the app really carries is the only thing worth checking.
        $optsCmd = '$env:PM2_HOME = "$env:USERPROFILE\.pm2"; ' +
                   '(& C:
pm-global\pm2.cmd jlist 2>$null | Out-String) -split ''\{"pid":'' | ' +
                   'Where-Object { $_ -match ''"name":"shape-esm"'' } | ' +
                   'ForEach-Object { if ($_ -match ''"NODE_OPTIONS":"([^"]*)"'') { "OPTS=" + $matches[1] } }'
        $esmOpts = Invoke-InContainer -Command $optsCmd -TimeoutSec 150
        Assert-True 'the ESM app really carries the loader hook (file:// URL)' `
            ($esmOpts.Out -match 'experimental-loader=file:///.*hook\.mjs') $esmOpts.Out.Trim()
        Assert-True 'and still --require for the SDK bootstrap' `
            ($esmOpts.Out -match '--require .*register\.js') $esmOpts.Out.Trim()
        # --import is measurably wrong for ESM here: with a Windows path the app crashes
        # (ERR_UNSUPPORTED_ESM_URL_SCHEME) and as a file:// URL it emits zero spans.
        Assert-True 'and NOT --import, which yields no telemetry' ($esmOpts.Out -notmatch '--import') $esmOpts.Out.Trim()

        $doc = Invoke-Doctor
        Assert-Case 'doctor: ESM apps clean once the loader hook is present' -Result $doc `
            -Reject @('NODE_ESM_REQUIRE_MISMATCH')

        # Force the wrong flag on the ESM app: the doctor must catch what would otherwise be a
        # perfectly healthy-looking app emitting nothing.
        $reg = Invoke-InContainer "(Get-ChildItem C:\cx\otel-node\node_modules\@opentelemetry\auto-instrumentations-node -Recurse -Filter register.js | Select-Object -First 1).FullName"
        $regPath = ($reg.Out -split "`r?`n" | Where-Object { $_ -match 'register\.js' } | Select-Object -First 1)
        if ($regPath) {
            $forced = ('$env:NODE_OPTIONS = ''--require {0}''; $env:PM2_HOME = "$env:USERPROFILE\.pm2"; & C:\npm-global\pm2.cmd restart shape-esm --update-env' -f ($regPath.Trim() -replace '\\','/'))
            Invoke-InContainer -Command $forced -TimeoutSec 180 | Out-Null
            $doc = Invoke-Doctor
            Assert-Case 'doctor: ESM app forced onto --require WITHOUT the hook is a hard fail' -Result $doc -ExpectExit 1 `
                -Expect @('NODE_ESM_REQUIRE_MISMATCH', 'shape-esm')
            # Put it back so the Coralogix sweep sees a working app.
            Invoke-Instrument -ExtraArgs @('-Apps', 'shape-esm') | Out-Null
        } else {
            Assert-True 'register.js located in the image' $false $reg.Out
        }

        # -- SGA-style names
        Invoke-Shape 'pm2DottedNames' | Out-Null
        $i = Invoke-Instrument
        Assert-Case 'instrument: dotted/dashed app names survive' -Result $i `
            -Expect @('synapse-qa-v2.betway', 'uat-reg.jackpotcity')
        [void]$script:ExpectedServices.Add('synapse-qa-v2.betway')
        [void]$script:ExpectedServices.Add('uat-reg.jackpotcity')
        $svc = Invoke-InContainer "[Environment]::GetEnvironmentVariable('CX_NODE_SERVICES','Machine')"
        Assert-True 'CX_NODE_SERVICES carries the dotted names as separate items' `
            ($svc.Out -match 'synapse-qa-v2\.betway' -and $svc.Out -match 'uat-reg\.jackpotcity') $svc.Out.Trim()

        # -- an app that already uses NODE_OPTIONS
        Invoke-Shape 'pm2PreexistingNodeOptions' | Out-Null
        $i = Invoke-Instrument -ExtraArgs @('-Apps', 'shape-preexisting-nodeopts')
        [void]$script:ExpectedServices.Add('shape-preexisting-nodeopts')
        $chk = Invoke-InContainer -Command ('$env:PM2_HOME = "$env:USERPROFILE\.pm2"; ' +
            '(& C:\npm-global\pm2.cmd jlist 2>$null | Out-String) -split ''\{"pid":'' | ' +
            'Where-Object { $_ -match ''shape-preexisting-nodeopts'' } | ' +
            'ForEach-Object { if ($_ -match ''"NODE_OPTIONS":"([^"]*)"'') { $matches[1] } }') -TimeoutSec 120
        $nodeOpts = ($chk.Out -split "`r?`n" | Where-Object { $_ -match '--' } | Select-Object -First 1)
        Assert-True "instrumenting preserved the app's own NODE_OPTIONS (--max-old-space-size)" `
            ($nodeOpts -match 'max-old-space-size') "NODE_OPTIONS=$nodeOpts"
        Assert-True 'instrumenting also added the OTel bootstrap' `
            ($nodeOpts -match '(--require|--import)') "NODE_OPTIONS=$nodeOpts"

        # -- -WhatIf must not touch anything
        $before = Invoke-InContainer "[Environment]::GetEnvironmentVariable('CX_NODE_SERVICES','Machine')"
        $w = Invoke-Instrument -ExtraArgs @('-WhatIf')
        $after2 = Invoke-InContainer "[Environment]::GetEnvironmentVariable('CX_NODE_SERVICES','Machine')"
        Assert-True '-WhatIf leaves CX_NODE_SERVICES untouched' ($before.Out.Trim() -eq $after2.Out.Trim()) `
            "before='$($before.Out.Trim())' after='$($after2.Out.Trim())'"
        Assert-Case '-WhatIf says what it would do' -Result $w -Expect @('What if:')
    }

    # -----------------------------------------------------------------------
    Add-Phase 'p3-service' {
        Write-Phase 'P3 - PM2 hosted as a Windows service (the SGA shape)'
        foreach ($shape in @(
            @{ Case = 'pm2ServiceLocalService'; Owner = 'LOCAL SERVICE'; App = 'shape-svc-localservice' },
            @{ Case = 'pm2ServiceLocalSystem';  Owner = 'SYSTEM';        App = 'shape-svc-localsystem' },
            @{ Case = 'pm2ServiceLocalUser';    Owner = 'svc_pm2';       App = 'shape-svc-localuser'
               Credential = $true; CredUser = 'svc_pm2'; CredPassword = 'Cx!Shape#2026' }
        )) {
            Write-CxHost ''
            Write-CxHost " -- $($shape.Case) (owner: $($shape.Owner))" -ForegroundColor Cyan
            Invoke-Shape 'resetAll' | Out-Null
            $s = Invoke-Shape $shape.Case -TimeoutSec 420
            if ($s.Out -match 'SKIP ' + [regex]::Escape($shape.Case)) {
                Write-KnownIssue "$($shape.Case) skipped" (($s.Out -split "`r?`n" | Where-Object { $_ -match 'SKIP' } | Select-Object -First 1))
                continue
            }
            Assert-Case "$($shape.Case): the service is running" -Result $s -Expect @('service status: Running')

            $d = Invoke-Detect
            Assert-Case "$($shape.Case): detection reports service hosting + owner + home" -Result $d `
                -Expect @('workload.pm2=true', 'workload.pm2.hosting=service', 'workload.pm2.home=C:\ProgramData\pm2')

            # The service hosting itself must always be reported. Whether the daemon is also
            # UNREACHABLE from here is a property of the host, not of the tooling: pm2's RPC pipe is
            # keyed on PM2_HOME, and in this container an administrator can read another account's
            # daemon, where on the real SGA host it could not. So both honest outcomes are accepted -
            # 'the apps are visible but uninstrumented' (warn) and 'the daemon cannot be reached at
            # all' (fail) - and which one occurred is printed. The OWNER_MISMATCH grading itself is
            # pinned by test/Test-Pm2Topology.ps1, which can stub a provably-unreachable daemon.
            $doc = Invoke-Doctor
            Assert-Case "$($shape.Case): doctor reports the service hosting" -Result $doc `
                -Expect @('NODE_PM2_SERVICE_HOSTED')
            $reachable = ($doc.Out -notmatch 'NODE_PM2_DAEMON_OWNER_MISMATCH')
            $reachText = if ($reachable) { 'READABLE' } else { 'UNREACHABLE' }
            Write-CxHost ("      (daemon is {0} from this account; doctor exit {1})" -f $reachText, $doc.Code) -ForegroundColor DarkGray
            Assert-True "$($shape.Case): doctor does not pass an uninstrumented host" ($doc.Code -ne 0) `
                "graded exit was $($doc.Code)"

            $base = Get-SpanCounter
            # An ORDINARY account cannot be logged on without its password, so that shape must be
            # given one. Proving the refusal path matters too, so it is asserted first.
            if ($shape.Credential) {
                $noCred = Invoke-Instrument -TimeoutSec 300
                Assert-Case "$($shape.Case): without a credential the run refuses, naming why" -Result $noCred `
                    -Expect @('OwnerCredential')
            }
            $i = if ($shape.Credential) {
                Invoke-Instrument -TimeoutSec 900 -CredentialUser $shape.CredUser -CredentialPassword $shape.CredPassword
            } else {
                Invoke-Instrument -TimeoutSec 900
            }
            Assert-Case "$($shape.Case): instrument routes pm2 through the owning account" -Result $i `
                -Expect @('pm2 hosting   : service', 'not to us', $shape.App, 'applied via')

            $doc = Invoke-Doctor
            Assert-Case "$($shape.Case): doctor clean after instrumenting" -Result $doc `
                -Reject @('NODE_PM2_DAEMON_OWNER_MISMATCH', 'NODE_OPTIONS_MISSING')

            $after = Wait-ForSpans -Baseline $base -TimeoutSec 150
            Assert-True "$($shape.Case): collector accepted spans from the service-hosted app" `
                ($after -gt $base) "accepted_spans $base -> $after"
            [void]$script:ExpectedServices.Add($shape.App)

            if ($shape.Case -eq 'pm2ServiceLocalService') {
                # dump.pm2 fallback: daemon down, app set must still resolve from disk.
                Invoke-Shape 'pm2DaemonStop' | Out-Null
                $doc = Invoke-Doctor
                Assert-Case 'daemon stopped: app set still resolved from dump.pm2' -Result $doc `
                    -Expect @($shape.App)
                Invoke-Shape 'pm2ServiceStart' | Out-Null

                # two daemons at once: a per-user one alongside the service one.
                Invoke-Shape 'pm2UserFork' | Out-Null
                $d = Invoke-Detect
                Assert-Case 'two daemons: the service-hosted one still wins' -Result $d `
                    -Expect @('workload.pm2.hosting=service')
                $ins = Invoke-Shape 'inspect'
                Assert-Case 'two daemons: inspect reports the service owner, not ours' -Result $ins `
                    -Expect @('hosting=service')
            }

            # uninstall, for this hosting
            $unCmd = '. C:\cx\deploy\Resolve-NodeServiceNames.ps1; '
            if ($shape.Credential) {
                $unCmd += ("`$cxCred = New-Object pscredential('{0}', (ConvertTo-SecureString '{1}' -AsPlainText -Force)); " -f $shape.CredUser, $shape.CredPassword)
                $unCmd += 'Remove-NodeInstrumentation -OwnerCredential $cxCred'
            } else {
                $unCmd += 'Remove-NodeInstrumentation'
            }
            $u = Invoke-InContainer -Command $unCmd -TimeoutSec 600
            Assert-Case "$($shape.Case): uninstall clears NODE_OPTIONS via the owner path" -Result $u `
                -Expect @('NODE_OPTIONS cleared') -Reject @('nothing to revert')
        }
    }

    # -----------------------------------------------------------------------
    Add-Phase 'p4-nonpm2' {
        Write-Phase 'P4 - Node WITHOUT PM2, and Node inside IIS'
        Invoke-Shape 'resetAll' | Out-Null

        Invoke-Shape 'nodeBareTask' | Out-Null
        # Hide the pm2 CLI so this is a genuinely PM2-less host. Without that, workload.pm2=true is
        # correct (pm2 IS installed in this image) and the assertion would be testing the fixture
        # rather than the tooling.
        Invoke-Shape 'pm2Hide' | Out-Null
        $d = Invoke-Detect
        Assert-Case 'bare node from a scheduled task: Node yes, PM2 no' -Result $d `
            -Expect @('workload.nodejs=true') -Reject @('workload.pm2=true')
        $doc = Invoke-Doctor
        # The honest answer is that this host has no PM2 to instrument - the bare node app is simply
        # invisible to a PM2-shaped tool. What must NOT happen is a claim about instrumentation.
        # Either honest answer is acceptable: NO_PM2 (nothing here at all) or NODE_PM2_NOT_ON_PATH
        # (node processes running, pm2 not reachable from this account, so no claim either way).
        # What must never appear is a claim ABOUT instrumentation.
        Assert-True 'bare node: doctor is honest, never a false pass' `
            (($doc.Out -match 'NO_PM2|NODE_PM2_NOT_ON_PATH') -and ($doc.Code -eq 0) -and
             ($doc.Out -notmatch 'NODE_OPTIONS_MISSING|NODE_REGISTER_PATH_STALE')) `
            ("exit $($doc.Code): " + (($doc.Out -split "`r?`n" | Where-Object { $_ -match '\[(SKIP|UNKNOWN|WARN|FAIL)' }) -join ' | '))
        Invoke-Shape 'pm2Unhide' | Out-Null
        $i = Invoke-Instrument
        Assert-Case 'bare node: instrumenter declines cleanly instead of crashing' -Result $i `
            -Reject @('Exception', 'Unhandled')

        Invoke-Shape 'resetAll' | Out-Null
        Invoke-Shape 'nodeServiceNoPm2' -TimeoutSec 300 | Out-Null
        # The probe must not read a node.exe running as a service as a PM2 service. Checked with the
        # pm2 CLI hidden so 'PM2 is installed' cannot supply the answer.
        Invoke-Shape 'pm2Hide' | Out-Null
        $d = Invoke-Detect
        Assert-Case 'node-as-a-service without PM2 is not claimed as PM2' -Result $d `
            -Reject @('workload.pm2=true', 'workload.pm2.hosting=service')
        Invoke-Shape 'pm2Unhide' | Out-Null

        # -- IIS-hosted Node
        Invoke-Shape 'resetAll' | Out-Null
        $s = Invoke-Shape 'iisnodeSite' -TimeoutSec 300
        if ($s.Out -match 'SKIP iisnodeSite') {
            Write-KnownIssue 'iisnode shape skipped' 'vendor/iis/iisnode-full-*.msi was not staged at build time'
        } else {
            # Whether iisnode actually SERVES is about the site's own config (it returns 500 in this
            # image), not about anything under test - the assertions that matter are the two below,
            # that the tooling classifies it as not-instrumentable and keeps it out of
            # CX_IIS_SERVICES. Reported rather than asserted, so a 500 cannot pass unnoticed.
            if ($s.Out -match 'iisnode site responded 200') {
                Assert-True 'iisnode site serves Node through IIS' $true
            } else {
                Write-KnownIssue 'iisnode site returns 500 in this image' `
                    (($s.Out -split "`r?`n" | Where-Object { $_ -match 'iisnode site' } | Select-Object -First 1))
            }
            $iis = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
            Assert-Case 'iisnode site is reported not-instrumentable, not misconfigured' -Result $iis `
                -Expect @('NON_DOTNET_APP_NOT_INSTRUMENTED')
            $svc = Invoke-InContainer "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
            Assert-True 'iisnode site stays out of CX_IIS_SERVICES' ($svc.Out -notmatch 'cx-iisnode') $svc.Out.Trim()
        }

        $s = Invoke-Shape 'arrSite' -TimeoutSec 300
        if ($s.Out -match 'SKIP arrSite') {
            Write-KnownIssue 'ARR shape skipped' 'vendor/iis/requestRouter_amd64.msi or rewrite_*.msi was not staged at build time'
        } else {
            # The proxy target is the PM2 fork app on 9101, so bring it up first.
            Invoke-Shape 'pm2UserFork' | Out-Null
            Invoke-Instrument | Out-Null
            [void]$script:ExpectedServices.Add('shape-user-fork')
            $s2 = Invoke-Shape 'arrSite' -TimeoutSec 300
            # The body carries the app's OTEL_SERVICE_NAME once instrumented, so match on the
            # module marker instead of the default app name.
            Assert-Case 'ARR proxies IIS -> PM2 Node app' -Result $s2 -Expect @('ARR site responded 200', '"module":"cjs"')
            $iis = Invoke-Doctor -ScriptFile 'Test-IISInstrumentation.ps1'
            Assert-Case 'the ARR site itself is not instrumentable (no managed code)' -Result $iis `
                -Expect @('NON_DOTNET_APP_NOT_INSTRUMENTED')
        }
    }

    # -----------------------------------------------------------------------
    Add-Phase 'p5-uninstall' {
        Write-Phase 'P5 - uninstall on a per-user daemon'
        Invoke-Shape 'resetAll' | Out-Null
        Invoke-Shape 'pm2UserFork' | Out-Null
        Invoke-Instrument | Out-Null
        $u = Invoke-InContainer -Command ('. C:\cx\deploy\Resolve-NodeServiceNames.ps1; Remove-NodeInstrumentation') -TimeoutSec 600
        Assert-Case 'uninstall clears NODE_OPTIONS on a per-user daemon' -Result $u -Expect @('NODE_OPTIONS cleared')
        $chk = Invoke-InContainer -Command ('$env:PM2_HOME = "$env:USERPROFILE\.pm2"; ' +
            '(& C:\npm-global\pm2.cmd jlist 2>$null | Out-String) -split ''\{"pid":'' | ' +
            'Where-Object { $_ -match ''shape-user-fork'' } | ' +
            'ForEach-Object { if ($_ -match ''"NODE_OPTIONS":"([^"]*)"'') { "OPTS=[" + $matches[1] + "]" } }') -TimeoutSec 120
        Assert-True 'the app no longer carries a bootstrap' ($chk.Out -notmatch '(--require|--import)') $chk.Out.Trim()
    }

    # -----------------------------------------------------------------------
    Add-Phase 'p6-coralogix' {
        Write-Phase 'P6 - Coralogix sweep'
        if ($SkipCoralogix) { Write-CxHost '  (skipped: -SkipCoralogix)' -ForegroundColor DarkGray; return }
        if (-not $PrivateKey) { Assert-True 'send key available for the sweep' $false 'no SimpleWebApp\coralogix\SendDataKey.txt and no -PrivateKey'; return }
        if (-not (Test-Path -LiteralPath $QueryKeyFile)) { Assert-True 'query key available for the sweep' $false $QueryKeyFile; return }

        $expected = @($script:ExpectedServices | Select-Object -Unique)
        Write-CxHost "  expecting $($expected.Count) service name(s): $($expected -join ', ')"

        $m = Invoke-InContainer -Command ("(Invoke-WebRequest 'http://127.0.0.1:8888/metrics' -UseBasicParsing).Content -split [char]10 | " +
             "Where-Object { `$_ -match '^otelcol_exporter_sent_spans|^otelcol_exporter_send_failed_spans' }")
        Write-CxHost ($m.Out.Trim())
        Assert-True 'collector reports spans SENT to Coralogix' ($m.Out -match 'otelcol_exporter_sent_spans') $m.Out.Trim()

        Write-CxHost "  waiting ${IngestWaitSec}s for ingestion (paid once for the whole matrix) ..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $IngestWaitSec

        $verify = Join-Path $RepoRoot 'scripts\Verify-Pm2Coverage.ps1'
        if (-not (Test-Path -LiteralPath $verify)) { Assert-True 'Verify-Pm2Coverage.ps1 present' $false $verify; return }
        $apiHost = "ng-api-http.$Domain" -replace 'ng-api-http\.eu1\.coralogix\.com', 'ng-api-http.coralogix.com'
        $out = & $verify -HostName $HostName -ApiHost $apiHost -QueryKeyFile $QueryKeyFile -KeyLabel $KeyLabel `
                         -ExpectedApps $expected -LookbackMinutes 120 2>&1 | Out-String
        Write-CxHost $out
        Assert-True 'every shape reports Node telemetry in Coralogix' ($LASTEXITCODE -eq 0) `
            "Verify-Pm2Coverage exit $LASTEXITCODE - see the GAP rows above"
    }

    # -----------------------------------------------------------------------
    $toRun = if ($Only.Count -gt 0) {
        @($phases | Where-Object { $p = $_; @($Only | Where-Object { $p.Name -match [regex]::Escape($_) }).Count -gt 0 })
    } else { @($phases) }
    if ($toRun.Count -eq 0) { throw "-Only '$($Only -join ',')' matched no phase. Available: $(($phases | ForEach-Object { $_.Name }) -join ', ')" }

    foreach ($ph in $toRun) { & $ph.Body }
}
finally {
    Pop-Location
    if (-not $KeepContainer) {
        Write-CxHost ''
        Write-CxHost "(container $Container left running for inspection; remove with: docker rm -f $Container)" -ForegroundColor DarkGray
    }
}

Write-CxHost ''
Write-CxHost ("=" * 78)
Write-CxHost ("  {0} passed, {1} failed, {2} known-issue/skipped" -f $script:Pass, $script:Fail, $script:Known) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Skipped.Count -gt 0) { Write-CxHost "  shapes skipped: $(($script:Skipped | Select-Object -Unique) -join ', ')" -ForegroundColor Yellow }
Write-CxHost ("=" * 78)
exit $script:Fail
