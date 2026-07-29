<#
.SYNOPSIS
  Put the container into one named Node.js deployment shape, or inspect/reset it, so
  Run-NodeShapesTest.ps1 can assert what the deploy scripts make of it.

.DESCRIPTION
  Baked into the image and invoked via `docker exec`, the same arrangement as break-state.ps1:
  keeping the fixtures as a script in the image (rather than as escaped one-liners in the harness)
  means the winsw XML, the icacls grants and the appcmd quoting live in one readable place and do
  not have to survive being escaped through two shells.

  DESTRUCTIVE BY DESIGN - it creates and deletes Windows services, scheduled tasks, local accounts
  and IIS sites, and kills every node.exe on the box. Only ever safe because the container is
  disposable. Never run this anywhere else.

.PARAMETER Case
  probeEnv                   report whether Task Scheduler / sc.exe / a LOCAL SERVICE service work
                             in this container - decides which Invoke-CxPm2AsOwner path is testable
  resetAll                   back to a clean host: no PM2, no services, no tasks, no shape env
  inspect                    dump the topology the deploy scripts would see

  pm2Hide                    move the pm2 CLI shims aside, so the host looks like one that never
                             had PM2 - the common fleet case, and untestable otherwise because this
                             image installs pm2 globally
  pm2Unhide                  put them back
  pm2ZeroApps                a per-user PM2 daemon managing nothing
  pm2UserFork                per-user PM2, one CommonJS app in fork mode
  pm2UserCluster             per-user PM2, one CommonJS app in cluster mode (2 workers)
  pm2Esm                     per-user PM2, an ESM app ("type": "module")
  pm2Mjs                     per-user PM2, an ESM app by .mjs extension
  pm2DottedNames             per-user PM2, SGA-style names (synapse-qa-v2.betway, ...)
  pm2PreexistingNodeOptions  per-user PM2, app already carrying NODE_OPTIONS of its own

  pm2ServiceLocalService     PM2 as a Windows service owned by NT AUTHORITY\LOCAL SERVICE (the SGA
                             shape: PM2_HOME=C:\ProgramData\pm2, daemon in <home>\service\index.js)
  pm2ServiceLocalSystem      same, owned by LocalSystem
  pm2ServiceLocalUser        same, owned by a local account (needs SeServiceLogonRight)
  pm2DaemonStop              stop the service daemon, leaving only dump.pm2 on disk
  pm2ServiceStart            start it again

  nodeBareTask               bare node.exe launched by a scheduled task (no PM2)
  nodeServiceNoPm2           node.exe run as a Windows service (no PM2)
  iisnodeSite                an IIS site hosting Node via iisnode
  arrSite                    an IIS site reverse-proxying to a PM2 app (ARR + URL Rewrite)

.NOTES
  Windows PowerShell 5.1. Every pm2 invocation goes through Invoke-Pm2, which is BOUNDED: a pm2
  call that has to spawn the God daemon can hang indefinitely under `docker exec` (the daemon
  inherits the exec's stdout pipe and never lets go), and an unbounded hang here stalls the whole
  matrix. `pm2 kill` is never used for the same reason - processes are stopped with Stop-Process.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('probeEnv','resetAll','inspect','pm2Hide','pm2Unhide',
                 'pm2ZeroApps','pm2UserFork','pm2UserCluster','pm2Esm','pm2Mjs',
                 'pm2DottedNames','pm2PreexistingNodeOptions',
                 'pm2ServiceLocalService','pm2ServiceLocalSystem','pm2ServiceLocalUser',
                 'pm2DaemonStop','pm2ServiceStart',
                 'nodeBareTask','nodeServiceNoPm2','iisnodeSite','arrSite')]
    [string] $Case,
    # Service-hosted shapes: where the daemon's PM2_HOME lives. The pm2-installer default.
    [string] $Pm2Home = 'C:\ProgramData\pm2',
    [string] $ServiceName = 'pm2',
    [string] $LocalUser = 'svc_pm2',
    [string] $LocalUserPassword = 'Cx!Shape#2026'
)

$ErrorActionPreference = 'Continue'

$APPS      = 'C:\cx\nodeshapes\apps'
$NODE      = 'C:\nodejs\node.exe'
$PM2CLI    = 'C:\npm-global\pm2.cmd'
$PM2MOD    = 'C:\npm-global\node_modules\pm2'
$NODEWIN   = 'C:\npm-global\node_modules\node-windows'
$WINSW     = Join-Path $NODEWIN 'bin\winsw\winsw.exe'
$STATE     = 'C:\cx\state'
$USERHOME  = Join-Path $env:USERPROFILE '.pm2'
New-Item -ItemType Directory -Force -Path $STATE | Out-Null

function Say { param([string]$m) Write-Host "[shape] $m" }

# ---------------------------------------------------------------------------
# Bounded pm2
# ---------------------------------------------------------------------------
function Invoke-Pm2 {
    <#
      Run the pm2 CLI with PM2_HOME pinned, bounded by a timeout, returning its output.

      Bounded because pm2 spawning its God daemon under `docker exec` can never return: the daemon
      inherits the exec session's stdout handle and holds it open, so the CLI waits on a pipe that
      nothing will close. Observed hanging >5 minutes on `pm2 kill`.
    #>
    # NOT named $Home: that is a READ-ONLY automatic variable, and a parameter of that name
    # makes the call throw "Cannot overwrite variable Home" before the body runs at all - so every
    # pm2 invocation silently did nothing.
    param([string[]] $Pm2Args, [string] $Pm2HomeDir = $USERHOME, [int] $TimeoutSec = 60)

    $outFile = Join-Path $STATE ("pm2-" + [guid]::NewGuid().ToString('N') + ".out")
    $errFile = "$outFile.err"
    $prior   = $env:PM2_HOME
    $env:PM2_HOME = $Pm2HomeDir
    try {
        $p = Start-Process -FilePath $PM2CLI -ArgumentList $Pm2Args -NoNewWindow -PassThru `
                 -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            Say "pm2 $($Pm2Args -join ' ') TIMED OUT after ${TimeoutSec}s (killed)"
        }
    } catch {
        Say "pm2 $($Pm2Args -join ' ') failed to launch: $($_.Exception.Message)"
    } finally {
        $env:PM2_HOME = $prior
    }
    $out = ''
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) {
            try { $out += (Get-Content -LiteralPath $f -Raw -ErrorAction Stop) } catch { }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    return $out
}

function Start-Pm2App {
    <# Start one app under the CALLER's (per-user) daemon. #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Script,
        [Parameter(Mandatory)][string] $Cwd,
        [int] $Instances = 0,          # 0 => fork mode
        [int] $Port,
        [hashtable] $ExtraEnv = @{}
    )
    # pm2 passes ITS OWN environment to the app, so per-app values are set here and read back by
    # the app. Cleared afterwards so they do not leak into the next app.
    $env:PORT = [string]$Port
    foreach ($k in $ExtraEnv.Keys) { Set-Item -Path ("Env:\" + $k) -Value ([string]$ExtraEnv[$k]) -ErrorAction SilentlyContinue }
    $a = @('start', $Script, '--name', $Name, '--cwd', $Cwd)
    if ($Instances -gt 0) { $a += @('-i', [string]$Instances) }
    $out = Invoke-Pm2 -Pm2Args $a -Pm2HomeDir $USERHOME -TimeoutSec 120
    Say "pm2 start $Name -> $(($out -split "`n" | Where-Object { $_ -match 'online|error|Error' } | Select-Object -First 2) -join ' | ')"
    Remove-Item Env:\PORT -ErrorAction SilentlyContinue
    foreach ($k in $ExtraEnv.Keys) { Remove-Item -Path ("Env:\" + $k) -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Windows plumbing
# ---------------------------------------------------------------------------
function Grant-CxPath {
    <# Grant an account rights on a path. LOCAL SERVICE has no useful rights by default, and
       pm2-installer does exactly this to PM2_HOME. #>
    param([string] $Account, [string] $Path, [string] $Rights = '(OI)(CI)F')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $null = & icacls.exe $Path /grant "${Account}:$Rights" /T /C /Q 2>&1
}

function Remove-CxService {
    param([string] $Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    if ($svc.Status -ne 'Stopped') {
        try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { }
        # SCM can report Stopped while the hosted process lingers; give it a moment either way.
        for ($i = 0; $i -lt 15; $i++) {
            if ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
            Start-Sleep -Seconds 1
        }
    }
    $null = & sc.exe delete $Name 2>&1
    Say "service '$Name' removed"
}

function Stop-AllNode {
    <# Stop every node.exe. NOT `pm2 kill`: see .NOTES. #>
    $procs = @(Get-Process -Name node -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Seconds 2
    Say "stopped $($procs.Count) node process(es)"
}

function Write-Pm2Dump {
    <#
      Write <PM2_HOME>\dump.pm2 by hand - the file `pm2 save` writes and `pm2 resurrect` replays.

      Hand-written rather than produced by running the apps under a temporary daemon and calling
      `pm2 save`: that would need a second daemon owning the same PM2_HOME, and the pipe ownership
      it would leave behind is the very thing under test. The fields below are the ones resurrect
      actually consumes.
    #>
    param([string] $Pm2HomeDir, [object[]] $Apps)   # $Home is read-only - see Invoke-Pm2

    New-Item -ItemType Directory -Force -Path $Pm2HomeDir | Out-Null
    $entries = foreach ($a in $Apps) {
        $envObj = @{ PORT = [string]$a.Port }
        if ($a.Env) { foreach ($k in $a.Env.Keys) { $envObj[$k] = [string]$a.Env[$k] } }
        [ordered]@{
            name         = $a.Name
            script       = $a.Script
            pm_exec_path = $a.Script
            cwd          = $a.Cwd
            exec_mode    = if ($a.Instances -gt 1) { 'cluster_mode' } else { 'fork_mode' }
            instances    = if ($a.Instances -gt 1) { $a.Instances } else { 1 }
            env          = $envObj
        }
    }
    # -Depth matters: the nested env object is dropped at the default depth of 2 in some builds.
    $json = ConvertTo-Json -InputObject @($entries) -Depth 8
    Set-Content -LiteralPath (Join-Path $Pm2HomeDir 'dump.pm2') -Value $json -Encoding ascii

    # The same list as apps.json, which the service's index.js starts explicitly. dump.pm2 alone is
    # not enough: pm2.resurrect() replays it and a hand-written dump does not reliably satisfy the
    # full pm2_env schema, so the daemon came up owning nothing. Both files are written - the dump is
    # what the stopped-daemon shape reads from disk.
    $svcDir = Join-Path $Pm2HomeDir 'service'
    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
    Set-Content -LiteralPath (Join-Path $svcDir 'apps.json') -Value $json -Encoding ascii
    Say "wrote dump.pm2 + service\apps.json with $(@($Apps).Count) app(s) -> $Pm2HomeDir"
}

function New-Pm2Service {
    <#
      Install PM2 as a Windows service with the properties that matter for detection:

        <PM2_HOME>\service\pm2-daemon.cmd   the service's image path - note NO 'node' in it, the
                                            same property pm2-installer's renamed-winsw pm2.exe has
        <PM2_HOME>\service\index.js         runs the God in-process (see the file's own comment)
        Win32_Service.StartName             the owning account, which is what decides whether this
                                            identity can reach the daemon at all

      That missing 'node' is the point: a service probe requiring both 'pm2' AND 'node' in the image
      path misses the exact layout it was written for, which is what this shape caught.
    #>
    param([string] $Account, [string] $Password)

    $svcDir = Join-Path $Pm2Home 'service'
    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Pm2Home 'logs') | Out-Null
    Copy-Item -LiteralPath 'C:\cx\nodeshapes\pm2-service\index.js' -Destination (Join-Path $svcDir 'index.js') -Force

    # A .cmd launcher rather than node-windows' bundled winsw.exe. Two reasons:
    #
    #  1. That winsw binary does nothing at all in this base image (it targets an older .NET than
    #     ltsc2022 ships) - `install` returns no output and registers no service.
    #  2. It keeps the fixture FAITHFUL where it matters. pm2-installer's service image path is a
    #     renamed winsw at `<PM2_HOME>\service\pm2.exe`, with the word `node` nowhere in it. Naming
    #     the launcher pm2-daemon.cmd reproduces that property, so this shape pins the probe fix:
    #     a service-detection rule that demands both 'pm2' AND 'node' in the image path misses it.
    #
    # `start "" /b` detaches the daemon from the service process on purpose. A service binary that
    # never calls StartServiceCtrlDispatcher is killed by the SCM after ~30s, which would take the
    # PM2 daemon with it; detaching means the SCM times the launcher out (error 1053, expected) while
    # the daemon keeps running - and, critically, still owned by the service account. That is the
    # property under test. The service therefore reports Stopped while its daemon runs, so callers
    # wait for the PROCESS, not for Win32_Service.State.
    $launcher = Join-Path $svcDir 'pm2-daemon.cmd'
    $launchBody = @"
@echo off
set PM2_HOME=$Pm2Home
set PATH=C:\nodejs;C:\npm-global;%PATH%
"$NODE" "$(Join-Path $svcDir 'index.js')" >> "$(Join-Path $Pm2Home 'logs\daemon.log')" 2>&1
"@
    Set-Content -LiteralPath $launcher -Value $launchBody -Encoding ascii

    $null = & sc.exe delete $ServiceName 2>&1
    # binPath carries NO quotes. `sc.exe` re-parses its own command line, and a value containing
    # embedded quotes makes it print its usage text and create nothing (silently, as far as the
    # caller can tell). None of these paths contain spaces, so unquoted is both safe and the only
    # form that survives.
    $bin = '{0}\System32\cmd.exe /c start /b {1}' -f $env:SystemRoot, $launcher
    $cr = & sc.exe create $ServiceName binPath= $bin start= demand type= own 2>&1 | Out-String
    Say "sc create: $(($cr.Trim() -split "`r?`n" | Select-Object -First 1))"
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        Say "SKIP $Case - the service could not be created"
        return $false
    }

    # Run as the requested account. sc.exe does NOT grant SeServiceLogonRight, so a plain user
    # account needs that granted separately (see Grant-ServiceLogonRight).
    if ($Password) {
        $null = & sc.exe config $ServiceName obj= $Account password= $Password 2>&1
    } else {
        $null = & sc.exe config $ServiceName obj= $Account 2>&1
    }
    $conf = & sc.exe qc $ServiceName 2>&1 | Out-String
    $svcStart = ($conf -split "`r?`n" | Where-Object { $_ -match 'SERVICE_START_NAME' }) -join ''
    Say "service account -> $($svcStart.Trim())"

    # The service account must be able to read node/pm2/the apps and write PM2_HOME.
    foreach ($p in @($Pm2Home)) { Grant-CxPath -Account $Account -Path $p -Rights '(OI)(CI)F' }
    foreach ($p in @('C:\nodejs', 'C:\npm-global', 'C:\cx\nodeshapes', 'C:\cx\otel-node')) {
        Grant-CxPath -Account $Account -Path $p -Rights '(OI)(CI)RX'
    }
    return $true
}

function Grant-ServiceLogonRight {
    <#
      Grant SeServiceLogonRight to an account via secedit. Without it a service configured to run
      as a normal user fails to start with 1069 (logon failure) - which would look like a bug in
      the tooling rather than a missing privilege.
      Returns $false when it could not be granted, so the caller can SKIP the shape honestly.
    #>
    param([string] $Account)

    $inf = Join-Path $STATE 'sec-export.inf'
    $new = Join-Path $STATE 'sec-import.inf'
    $sdb = Join-Path $STATE 'sec.sdb'
    Remove-Item -LiteralPath $inf, $new, $sdb -Force -ErrorAction SilentlyContinue
    $null = & secedit.exe /export /cfg $inf /areas USER_RIGHTS 2>&1
    if (-not (Test-Path -LiteralPath $inf)) { Say 'secedit /export failed - cannot grant SeServiceLogonRight'; return $false }

    $lines   = Get-Content -LiteralPath $inf
    $current = ($lines | Where-Object { $_ -match '^SeServiceLogonRight' }) -join ''
    $sidPart = if ($current -match '=\s*(.+)$') { $matches[1].Trim() } else { '' }
    if ($sidPart -match [regex]::Escape($Account)) { Say "SeServiceLogonRight already includes $Account"; return $true }
    $newLine = if ($sidPart) { "SeServiceLogonRight = $sidPart,$Account" } else { "SeServiceLogonRight = $Account" }

    $body = @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1',
              '[Privilege Rights]', $newLine)
    Set-Content -LiteralPath $new -Value $body -Encoding unicode
    $out = & secedit.exe /configure /db $sdb /cfg $new /areas USER_RIGHTS 2>&1 | Out-String
    Say "secedit /configure: $(($out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' | ')"
    return ($out -notmatch 'not( been)? completed successfully' -or $out -match 'completed successfully')
}

function New-CxIisSite {
    param([string] $Name, [string] $PhysicalPath, [int] $Port, [string] $Pool)
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    $null = & $appcmd delete site $Name 2>&1
    if ($Pool) {
        $null = & $appcmd delete apppool $Pool 2>&1
        $null = & $appcmd add apppool /name:$Pool /managedRuntimeVersion: 2>&1
    }
    $null = & $appcmd add site /name:$Name /physicalPath:$PhysicalPath /bindings:"http/*:${Port}:" 2>&1
    if ($Pool) { $null = & $appcmd set app "$Name/" /applicationPool:$Pool 2>&1 }
    # IIS_IUSRS must be able to read the app directory.
    Grant-CxPath -Account 'IIS_IUSRS' -Path $PhysicalPath -Rights '(OI)(CI)RX'
    Say "IIS site '$Name' -> $PhysicalPath on :$Port (pool=$Pool)"
}

function Set-Pm2CliHidden {
    <#
      Move the pm2 shims (pm2, pm2.cmd, pm2.ps1, ...) between C:\npm-global and a stash.

      "PM2 is not installed" is the state of most fleet hosts and one of the shapes the matrix
      claims to cover, but this image installs pm2 globally so every probe finds it. Hiding the
      shims is the only way to reach that path - and it exercises exactly what a real PM2-less host
      exercises, because every pm2 lookup here goes through Get-Command / Get-CxPm2CommandPath.
    #>
    param([bool] $Hidden)

    $live  = 'C:\npm-global'
    $stash = 'C:\cx\state\pm2-shims'
    New-Item -ItemType Directory -Force -Path $stash | Out-Null
    if ($Hidden) {
        foreach ($f in @(Get-ChildItem -Path $live -Filter 'pm2*' -File -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $stash $f.Name) -Force -ErrorAction SilentlyContinue
        }
        Say "pm2 CLI shims moved to $stash (host now looks PM2-less)"
    } else {
        foreach ($f in @(Get-ChildItem -Path $stash -Filter 'pm2*' -File -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $live $f.Name) -Force -ErrorAction SilentlyContinue
        }
        Say 'pm2 CLI shims restored'
    }
}

function Get-Pm2DaemonProcess {
    <#
      Is the service's PM2 daemon up, and who owns it?

      Deliberately its OWN Win32_Process query rather than a call into the product's
      Get-CxPm2Processes: a fixture that decides "the shape was applied" using the same code the
      shape exists to test could report success because both sides are wrong in the same way.
    #>
    param([string] $HomeDir = $Pm2Home)
    $needle = [regex]::Escape((Join-Path $HomeDir 'service\index.js'))
    $procs = @()
    try { $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop) } catch { return $null }
    foreach ($pr in $procs) {
        if ([string]$pr.CommandLine -notmatch $needle) { continue }
        $owner = '?'
        try {
            $o = Invoke-CimMethod -InputObject $pr -MethodName GetOwner -ErrorAction Stop
            if ($o.User) { $owner = "$($o.Domain)\$($o.User)" }
        } catch { }
        return [pscustomobject]@{ Pid = [int]$pr.ProcessId; Owner = $owner }
    }
    return $null
}

function Start-Pm2Service {
    <#
      Start the service and wait for its DAEMON PROCESS, not for Win32_Service.State.

      The launcher detaches the daemon (see New-Pm2Service), so the SCM reports the service Stopped
      or start-pending with error 1053 while the daemon it launched runs perfectly - owned by the
      service account, which is the whole point of the shape. Polling State would therefore report
      failure on a working fixture.
    #>
    param([int] $TimeoutSec = 90)

    $null = & sc.exe start $ServiceName 2>&1
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 3
        $daemon = Get-Pm2DaemonProcess
        if ($daemon) {
            Say "daemon up: pid=$($daemon.Pid) owner=$($daemon.Owner)"
            # Give resurrect() time to bring the saved apps back before anyone inspects.
            Start-Sleep -Seconds 12
            $workers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
                         Where-Object { [string]$_.CommandLine -match 'ProcessContainerFork' })
            Say "service status: Running (daemon pid=$($daemon.Pid), workers=$($workers.Count))"
            return $true
        }
    } while ((Get-Date) -lt $deadline)
    Say "service status: FAILED - no daemon process within ${TimeoutSec}s"
    $log = Join-Path $Pm2Home 'logs\daemon.log'
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 8 | ForEach-Object { Say "  daemon.log: $_" } }
    return $false
}

function Get-IisModulesPresent {
    $f = Join-Path 'C:\cx\state' 'iis-modules.txt'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    return @(Get-Content -LiteralPath $f | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
switch ($Case) {

'probeEnv' {
    # Which mechanisms for "run something as another account" actually work in a Windows container?
    # Invoke-CxPm2AsOwner needs one of them, so this decides what the rest of the matrix can prove.
    Say 'probing the container for the mechanisms Invoke-CxPm2AsOwner depends on'

    $schedModule = [bool](Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)
    Say "PROBE ScheduledTasks module: $(if ($schedModule) { 'PRESENT' } else { 'ABSENT' })"

    $schedSvc = Get-Service -Name Schedule -ErrorAction SilentlyContinue
    Say "PROBE Schedule service: $(if ($schedSvc) { $schedSvc.Status } else { 'ABSENT' })"

    $taskOk = $false; $taskErr = ''
    if ($schedModule) {
        $tn = 'cx-probe-task'
        try {
            $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c echo probe > C:\cx\state\probe-task.txt'
            $p = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $tn -Action $a -Principal $p -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $tn -ErrorAction Stop
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                if ((Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue).State -ne 'Running') { break }
            }
            $rc = (Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue).LastTaskResult
            $taskOk = (Test-Path C:\cx\state\probe-task.txt)
            $taskErr = "LastTaskResult=$rc"
        } catch { $taskErr = $_.Exception.Message }
        finally {
            try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch { }
            Remove-Item C:\cx\state\probe-task.txt -Force -ErrorAction SilentlyContinue
        }
    }
    Say "PROBE scheduled task as LOCAL SERVICE: $(if ($taskOk) { 'WORKS' } else { 'FAILS' })  ($taskErr)"

    # The sc.exe fallback: can a transient service run as LOCAL SERVICE at all here?
    $scOk = $false; $scErr = ''
    $sn = 'cxprobesvc'
    try {
        $null = & sc.exe delete $sn 2>&1
        $cmd = 'cmd.exe /c echo probe > C:\cx\state\probe-svc.txt'
        $null = & sc.exe create $sn binPath= $cmd start= demand obj= 'NT AUTHORITY\LOCAL SERVICE' 2>&1
        $null = & sc.exe start $sn 2>&1
        # A non-service binary always reports 1053 to the SCM, but it DOES get launched - which is
        # all the fallback needs. Look for the side effect, not the SCM's opinion.
        for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path C:\cx\state\probe-svc.txt) { break } }
        $scOk = (Test-Path C:\cx\state\probe-svc.txt)
    } catch { $scErr = $_.Exception.Message }
    finally {
        $null = & sc.exe delete $sn 2>&1
        Remove-Item C:\cx\state\probe-svc.txt -Force -ErrorAction SilentlyContinue
    }
    Say "PROBE transient service as LOCAL SERVICE: $(if ($scOk) { 'WORKS' } else { 'FAILS' })  ($scErr)"

    Say "PROBE identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Say "PROBE node: $((& node --version 2>$null))   pm2: $((& $PM2CLI --version 2>$null))"
    Say "PROBE winsw baked: $(if (Test-Path $WINSW) { 'YES' } else { 'NO' })"
    Say "PROBE IIS modules: $((Get-IisModulesPresent) -join ',')"
}

'pm2Hide'   { Set-Pm2CliHidden -Hidden $true }
'pm2Unhide' { Set-Pm2CliHidden -Hidden $false }

'resetAll' {
    Say 'resetting to a clean host'
    # Unhide FIRST and unconditionally: a run that died mid-P1 must not leave the image without a
    # pm2 CLI, which would silently turn every later shape into "PM2 absent".
    Set-Pm2CliHidden -Hidden $false
    Remove-CxService -Name $ServiceName
    Remove-CxService -Name 'cx-bare-node'
    Stop-AllNode

    foreach ($tn in @('cx-bare-node','cx-probe-task')) {
        try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }

    # Both PM2 homes: the per-user one and the service one.
    foreach ($h in @($USERHOME, $Pm2Home)) {
        if (Test-Path -LiteralPath $h) { Remove-Item -LiteralPath $h -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Machine env the deploy scripts write. Left behind, these make the NEXT shape's assertions
    # meaningless (a stale CX_NODE_SERVICES reads as drift, a stale OTEL_RESOURCE_ATTRIBUTES as
    # detection).
    foreach ($v in @('CX_NODE_SERVICES','OTEL_RESOURCE_ATTRIBUTES','NODE_OPTIONS','OTEL_SERVICE_NAME',
                     'OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL',
                     'OTEL_TRACES_EXPORTER','OTEL_METRICS_EXPORTER','OTEL_LOGS_EXPORTER','PM2_HOME')) {
        [Environment]::SetEnvironmentVariable($v, $null, 'Machine')
    }

    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    foreach ($s in @('cx-iisnode','cx-arr')) { $null = & $appcmd delete site $s 2>&1 }
    foreach ($p in @('cx-iisnode-pool','cx-arr-pool')) { $null = & $appcmd delete apppool $p 2>&1 }

    try { & net.exe user $LocalUser /delete 2>&1 | Out-Null } catch { }
    Say 'reset complete'
}

'inspect' {
    . C:\cx\deploy\Resolve-NodeServiceNames.ps1
    $t = Get-CxPm2Topology
    Say "topology: hosting=$($t.Hosting) owner=$($t.Owner) home=$($t.Home) service=$($t.ServiceName) daemonPid=$($t.DaemonPid) workers=$($t.WorkerCount) identity=$($t.Identity) mismatch=$($t.OwnerMismatch)"
    $map = Get-PM2ServiceMap -Topology $t
    foreach ($r in $map) { Say "app: $($r.Name) svc=$($r.ServiceName) mode=$($r.ExecMode) inst=$($r.Instances) src=$($r.Source) esm=$($r.IsEsm)" }
    Say "CX_NODE_SERVICES=$([Environment]::GetEnvironmentVariable('CX_NODE_SERVICES','Machine'))"
    Say "OTEL_RESOURCE_ATTRIBUTES=$([Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES','Machine'))"
    Say "node processes:"
    foreach ($p in @(Get-CxPm2Processes)) { Say "  $($p.Kind) pid=$($p.Pid) ppid=$($p.ParentPid) owner=$($p.Owner)" }
}

'pm2ZeroApps' {
    # A daemon that manages nothing. Distinct from "PM2 absent": the doctor must say NO_PM2_APPS
    # (skip), and nothing may invent a CX_NODE_SERVICES value.
    $out = Invoke-Pm2 -Pm2Args @('ping') -Pm2HomeDir $USERHOME -TimeoutSec 90
    Say "pm2 ping: $(($out -split "`n" | Where-Object { $_ -match 'pong|daemon' } | Select-Object -First 1))"
}

'pm2UserFork'   { Start-Pm2App -Name 'shape-user-fork'    -Script "$APPS\cjs\server.js"  -Cwd "$APPS\cjs" -Port 9101 }
'pm2UserCluster'{ Start-Pm2App -Name 'shape-user-cluster' -Script "$APPS\cjs\server.js"  -Cwd "$APPS\cjs" -Port 9105 -Instances 2 }
'pm2Esm'        { Start-Pm2App -Name 'shape-esm'          -Script "$APPS\esm\server.js"  -Cwd "$APPS\esm" -Port 9102 }
'pm2Mjs'        { Start-Pm2App -Name 'shape-mjs'          -Script "$APPS\mjs\server.mjs" -Cwd "$APPS\mjs" -Port 9103 }

'pm2DottedNames' {
    # SGA's real naming: dots and dashes, which must survive naming and the comma-joined
    # CX_NODE_SERVICES round trip.
    Start-Pm2App -Name 'synapse-qa-v2.betway'  -Script "$APPS\cjs\server.js" -Cwd "$APPS\cjs" -Port 9106
    Start-Pm2App -Name 'uat-reg.jackpotcity'   -Script "$APPS\cjs\server.js" -Cwd "$APPS\cjs" -Port 9107
}

'pm2PreexistingNodeOptions' {
    # The app already uses NODE_OPTIONS for its own reasons. Instrumentation must ADD the bootstrap,
    # not replace the app's flags - losing --max-old-space-size silently changes its heap limit.
    Start-Pm2App -Name 'shape-preexisting-nodeopts' -Script "$APPS\cjs\server.js" -Cwd "$APPS\cjs" -Port 9108 `
                 -ExtraEnv @{ NODE_OPTIONS = '--max-old-space-size=512' }
}

'pm2ServiceLocalService' {
    Say 'installing PM2 as a Windows service owned by NT AUTHORITY\LOCAL SERVICE (the SGA shape)'
    Write-Pm2Dump -Pm2HomeDir $Pm2Home -Apps @(
        [pscustomobject]@{ Name='shape-svc-localservice'; Script="$APPS\cjs\server.js"; Cwd="$APPS\cjs"; Port=9111; Instances=1 }
    )
    if (New-Pm2Service -Account 'NT AUTHORITY\LOCAL SERVICE') {
        $null = Start-Pm2Service
    }
}

'pm2ServiceLocalSystem' {
    Say 'installing PM2 as a Windows service owned by LocalSystem'
    Write-Pm2Dump -Pm2HomeDir $Pm2Home -Apps @(
        [pscustomobject]@{ Name='shape-svc-localsystem'; Script="$APPS\cjs\server.js"; Cwd="$APPS\cjs"; Port=9112; Instances=1 }
    )
    if (New-Pm2Service -Account 'LocalSystem') {
        $null = Start-Pm2Service
    }
}

'pm2ServiceLocalUser' {
    Say "installing PM2 as a Windows service owned by the local account $LocalUser"
    $null = & net.exe user $LocalUser $LocalUserPassword /add 2>&1
    $null = & net.exe localgroup Administrators $LocalUser /add 2>&1
    if (-not (Grant-ServiceLogonRight -Account $LocalUser)) {
        Say 'SKIP pm2ServiceLocalUser - SeServiceLogonRight could not be granted in this container'
        break
    }
    Write-Pm2Dump -Pm2HomeDir $Pm2Home -Apps @(
        [pscustomobject]@{ Name='shape-svc-localuser'; Script="$APPS\cjs\server.js"; Cwd="$APPS\cjs"; Port=9113; Instances=1 }
    )
    if (New-Pm2Service -Account ".\$LocalUser" -Password $LocalUserPassword) {
        $null = Start-Pm2Service
    }
}

'pm2DaemonStop' {
    # The daemon is gone but dump.pm2 remains: the app set must still be resolvable from disk,
    # which is the only source left on a host whose daemon is down.
    Say 'stopping the PM2 service daemon, leaving dump.pm2 in place'
    try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch { }
    # The daemon is DETACHED from the service, so stopping the service does not stop it.
    Stop-AllNode
    Say "dump.pm2 present: $(Test-Path (Join-Path $Pm2Home 'dump.pm2'))"
}

'pm2ServiceStart' { $null = Start-Pm2Service }

'nodeBareTask' {
    # Node with no supervisor at all, launched by a scheduled task - a shape nothing in this repo
    # instruments. The assertion is that the tooling says so plainly.
    Say 'starting bare node.exe via a scheduled task'
    $tn = 'cx-bare-node'
    try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    $a = New-ScheduledTaskAction -Execute $NODE -Argument "`"$APPS\bare\server.js`"" -WorkingDirectory "$APPS\bare"
    $p = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $tn -Action $a -Principal $p -Force -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    Say "node processes now: $(@(Get-Process -Name node -ErrorAction SilentlyContinue).Count)"
}

'nodeServiceNoPm2' {
    # Node as a Windows service WITHOUT PM2 (what node-windows/nssm produce). The pm2-service probe
    # must not claim this as PM2 just because a node.exe runs as a service.
    #
    # Launched the same detached way as the PM2 service (winsw is unusable in this base image), so
    # the service row exists and the node process runs owned by LOCAL SERVICE.
    Say 'installing bare node.exe as a Windows service (no PM2)'
    $svcDir = 'C:\cx\stateare-svc'
    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
    $launcher = Join-Path $svcDir 'cx-bare-node.cmd'
    $body = @"
@echo off
set PORT=9121
"$NODE" "$APPSare\server.js" >> "$svcDirare.log" 2>&1
"@
    Set-Content -LiteralPath $launcher -Value $body -Encoding ascii
    $null = & sc.exe delete 'cx-bare-node' 2>&1
    # Unquoted binPath - see New-Pm2Service.
    $bin = '{0}\System32\cmd.exe /c start /b {1}' -f $env:SystemRoot, $launcher
    $cr = & sc.exe create 'cx-bare-node' binPath= $bin start= demand type= own obj= 'NT AUTHORITY\LOCAL SERVICE' 2>&1 | Out-String
    Say "sc create: $(($cr.Trim() -split "`r?`n" | Select-Object -First 1))"
    Grant-CxPath -Account 'NT AUTHORITY\LOCAL SERVICE' -Path $svcDir -Rights '(OI)(CI)F'
    $null = & sc.exe start 'cx-bare-node' 2>&1
    Start-Sleep -Seconds 8
    $n = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
           Where-Object { [string]$_.CommandLine -match 'bare\server\.js' })
    Say "bare node service: $($n.Count) node process(es) from the service launcher"
}

'iisnodeSite' {
    $mods = Get-IisModulesPresent
    if ($mods -notcontains 'iisnode') {
        Say 'SKIP iisnodeSite - iisnode was not staged into test/docker-win/vendor/iis at build time'
        break
    }
    New-CxIisSite -Name 'cx-iisnode' -PhysicalPath "$APPS\iisnode" -Port 9131 -Pool 'cx-iisnode-pool'
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:9131/' -UseBasicParsing -TimeoutSec 15
        Say "iisnode site responded $($r.StatusCode): $($r.Content)"
    } catch { Say "iisnode site request failed: $($_.Exception.Message)" }
}

'arrSite' {
    $mods = Get-IisModulesPresent
    if ($mods -notcontains 'arr' -or $mods -notcontains 'urlrewrite') {
        Say "SKIP arrSite - ARR/URL Rewrite not staged at build time (present: $($mods -join ','))"
        break
    }
    # ARR only proxies when the server-level proxy switch is on; off by default after install.
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    $null = & $appcmd set config -section:system.webServer/proxy /enabled:"True" /commit:apphost 2>&1
    New-CxIisSite -Name 'cx-arr' -PhysicalPath "$APPS\arr" -Port 9132 -Pool 'cx-arr-pool'
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:9132/proxied' -UseBasicParsing -TimeoutSec 15
        Say "ARR site responded $($r.StatusCode): $($r.Content)"
    } catch { Say "ARR proxy request failed: $($_.Exception.Message)" }
}

}
