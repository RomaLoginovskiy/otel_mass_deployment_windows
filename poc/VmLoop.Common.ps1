<#
.SYNOPSIS
  Shared VirtualBox guest transport + assertion helpers for the asserting VM loops.
  Dot-source it; it defines functions and a small amount of script-scope state.

.DESCRIPTION
  Every VM harness needs the same four things, and each of them has a trap that cost real time
  to find, so they live here once:

    1. A guest transport that survives QUOTING. The values under test are Windows paths,
       DOMAIN\user names, apostrophes and control characters. Passing those as command-line
       arguments through PowerShell -> VBoxManage -> guest powershell.exe mangles them, and then
       the harness is testing its own escaping rather than the product. So a scriptblock is
       materialized into a .ps1 IN the guest and its arguments arrive as a JSON file.

    2. A bare '--' cannot be passed to VBoxManage from PowerShell: PS eats it as its own
       end-of-parameters marker, VBoxManage then parses -NoProfile as its own option and fails
       with "Unknown option: -NoProfile". It has to be quoted: '--'.

    3. Output has to be CAPPED. A guest step that accidentally emits an object graph (Get-Content
       lines carry PSPath note properties, and ConvertTo-Json will happily walk them) produced a
       44 MB response in an earlier run. Guest steps return one JSON line; everything else is
       trimmed to the tail.

    4. Readiness is an EXIT CODE, not a string match. After an unattended install the Guest
       Additions run level can read 3 while the execution service is still not up, so
       Wait-GuestReady polls `run --exe cmd.exe` and only trusts exit 0.

  Assertion state is script-scope in the CALLER (this file is dot-sourced), so each loop keeps
  its own counters and its own exit code.

.NOTES
  POC scaffolding. Windows PowerShell 5.1 compatible. Not part of the fleet payload.
#>

# ---- transport state ----------------------------------------------------------
$script:VmlName      = $null
$script:VmlUser      = $null
$script:VmlPwFile      = $null
$script:VmlHostStage   = $null
$script:VmlGuestStage  = $null
$script:VmlGcBase      = @()
$script:VmlStepSeq     = 0
$script:VmlVBoxPath    = $null

# ---- assertion state ----------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:Notes = @()
$script:Results = @()      # ordered record of every assertion, for the summary table
$script:CurrentPhase = ''

function Get-VBoxManagePath {
    if ($script:VmlVBoxPath) { return $script:VmlVBoxPath }
    $p = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
    if (-not (Test-Path $p)) { $p = 'VBoxManage.exe' }   # rely on PATH
    $script:VmlVBoxPath = $p
    return $p
}

function VBoxSoft {
    <#
      VBoxManage that never throws and never lets a native stderr write become a terminating
      error: under $ErrorActionPreference='Stop', PS 5.1 turns any stderr line from a native exe
      into a NativeCommandError, and VBoxManage writes progress to stderr on perfectly successful
      commands. Returns the output lines; check $LASTEXITCODE yourself when you care.
    #>
    $exe = Get-VBoxManagePath
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $exe @args 2>&1 | ForEach-Object { "$_" } } catch { $out = @("$_") }
    $ErrorActionPreference = $old
    return @($out)
}

function Invoke-HostScript {
    <#
      Run a PowerShell script ON THE HOST (a Verify-* gate, say) and return its exit code and
      output, without letting its stderr kill the caller.

      This exists because of the same PS 5.1 trap VBoxSoft guards against, hit again in a place it
      was not expected: under $ErrorActionPreference='Stop', ANY stderr write by a native command -
      here powershell.exe running the verifier - is turned into a terminating NativeCommandError. So
      the telemetry phase aborted the whole try block on the verifier's first warning line, and P7,
      P9 and P10 never ran while the summary still printed as if the run had simply ended.

      Returns Code and Out (tail-limited), never throws.
    #>
    param([Parameter(Mandatory)] [string] $Path,
          [string[]] $Arguments = @(),
          [int] $Tail = 12)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Code = -1; Out = "script not found: $Path" }
    }

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 |
                    ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } catch {
        $lines = @("$_")
        $code  = -1
    } finally {
        $ErrorActionPreference = $old
    }

    return [pscustomobject]@{
        Code = $code
        Out  = ((@($lines) | Select-Object -Last $Tail) -join ' | ')
        All  = @($lines).Count
    }
}

function Initialize-VmLoop {
    <#
      Bind the transport to one VM. The password reaches VBoxManage through a FILE, never on a
      command line, so it does not show up in the host's process list.
    #>
    param(
        [Parameter(Mandatory)] [string] $VmName,
        [string] $User       = 'Administrator',
        [string] $Password   = 'Otel!Passw0rd2026',
        [string] $HostStage  = $null,
        [string] $GuestStage = 'C:\cx-vmloop'
    )

    if (-not $HostStage) {
        $HostStage = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-vmloop-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
    }
    if (-not (Test-Path $HostStage)) { New-Item -ItemType Directory -Path $HostStage -Force | Out-Null }

    $script:VmlName     = $VmName
    $script:VmlUser     = $User
    $script:VmlHostStage  = $HostStage
    $script:VmlGuestStage = $GuestStage
    $script:VmlPwFile     = Join-Path $HostStage 'gc.pw'
    Set-Content -LiteralPath $script:VmlPwFile -Value $Password -Encoding Ascii -NoNewline
    $script:VmlGcBase = @('guestcontrol', $VmName, '--username', $User, '--passwordfile', $script:VmlPwFile)

    return [pscustomobject]@{ VmName = $VmName; HostStage = $HostStage; GuestStage = $GuestStage }
}

function Remove-VmLoopTemp {
    # The password file is the only thing here that matters; the rest is step scripts.
    if ($script:VmlPwFile -and (Test-Path $script:VmlPwFile)) {
        try { [System.IO.File]::Delete($script:VmlPwFile) } catch { }
    }
}

# ---- VM lifecycle -------------------------------------------------------------

function Test-VmExists {
    param([string] $Name = $script:VmlName)
    return [bool](@(VBoxSoft list vms) -match ('^"' + [regex]::Escape($Name) + '"'))
}

function Test-VmRunning {
    param([string] $Name = $script:VmlName)
    return [bool](@(VBoxSoft list runningvms) -match ('^"' + [regex]::Escape($Name) + '"'))
}

function Start-VmHeadless {
    param([string] $Name = $script:VmlName)
    if (Test-VmRunning -Name $Name) { return $true }
    VBoxSoft startvm $Name --type headless | Out-Null
    return (Test-VmRunning -Name $Name)
}

function Wait-GuestReady {
    <#
      True once the guest execution service answers. Exit code only - a string match would
      accept a banner printed while the service is still coming up.
    #>
    param([int] $TimeoutSeconds = 2400, [int] $PollSeconds = 15)

    $exe = Get-VBoxManagePath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $exe @script:VmlGcBase run --exe 'C:\Windows\System32\cmd.exe' --wait-stdout --wait-stderr `
                '--' cmd /c 'echo READY' 2>&1 | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
        } catch { $ok = $false }
        $ErrorActionPreference = $old
        if ($ok) { return $true }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $false
}

function New-VmSnapshot {
    <#
      Take a snapshot of the VM under test.

      NOT --live, and that was measured the hard way. `snapshot take --live` on a running guest put
      both VMs into VMState="livesnapshotting" on this host and left them there: no snapshot ever
      appeared, nothing was being written, and `guestcontrol` stopped answering for as long as the
      state persisted - so the harness's own P0 killed its own transport. Worse, interrupting the
      VBoxManage client mid-operation left the machine XML <inaccessible>, which is only recoverable
      by unregistering and re-cloning.

      So: pause, snapshot, resume. The guest is frozen for a few seconds instead of being asked to
      snapshot itself while running.
    #>
    param([string] $SnapshotName, [switch] $IfMissing)

    $existing = @(VBoxSoft snapshot $script:VmlName list --machinereadable) -join "`n"
    if ($IfMissing -and $existing -match ('SnapshotName[^=]*="' + [regex]::Escape($SnapshotName) + '"')) {
        return $false    # already there, nothing taken
    }

    $wasRunning = Test-VmRunning
    if ($wasRunning) { VBoxSoft controlvm $script:VmlName pause | Out-Null; Start-Sleep -Seconds 2 }
    VBoxSoft snapshot $script:VmlName take $SnapshotName | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    if ($wasRunning) { VBoxSoft controlvm $script:VmlName resume | Out-Null }
    return $ok
}

function Restore-VmSnapshot {
    <#
      Restoring requires the VM powered off, so this stops it, restores, and starts it again -
      then waits for the guest to answer, because every caller's next step needs a live guest.
    #>
    param([string] $SnapshotName, [int] $ReadyTimeoutSeconds = 900)

    VBoxSoft controlvm $script:VmlName poweroff | Out-Null
    Start-Sleep -Seconds 4
    VBoxSoft snapshot $script:VmlName restore $SnapshotName | Out-Null
    VBoxSoft startvm $script:VmlName --type headless | Out-Null
    return (Wait-GuestReady -TimeoutSeconds $ReadyTimeoutSeconds)
}

function Restart-Guest {
    param([int] $ReadyTimeoutSeconds = 900)

    Invoke-Guest -Script { shutdown /r /t 0 /f; 'REBOOTING' } | Out-Null
    Start-Sleep -Seconds 25          # let it actually go down before polling, or we see the old session
    return (Wait-GuestReady -TimeoutSeconds $ReadyTimeoutSeconds)
}

# ---- file transfer ------------------------------------------------------------

function Copy-ToGuest {
    param([Parameter(Mandatory)] [string] $LocalPath,
          [Parameter(Mandatory)] [string] $GuestPath)

    $dir = Split-Path -Parent $GuestPath
    if ($dir) { VBoxSoft @script:VmlGcBase mkdir $dir --parents | Out-Null }
    $out = VBoxSoft @script:VmlGcBase copyto $LocalPath $GuestPath
    if ($LASTEXITCODE -ne 0) { throw "copyto failed ($LocalPath -> $GuestPath): $($out -join ' ')" }
}

function Copy-DirToGuestAsZip {
    <#
      Stage a directory into the guest as ONE archive, then expand it there.

      guestcontrol copies file by file, and the trees this harness stages are the worst possible
      shape for that: otel-node is ~71 MB across thousands of tiny node_modules files, and npm-global
      is not much better. One zip is a single transfer plus a local expand, which turns tens of
      minutes into a couple of them - and it removes the partial-copy failure mode where a tree
      arrives with a few files missing and the failure surfaces later as a confusing "module not
      found" inside the guest.

      Falls back to the per-file path when compression or expansion is unavailable, so a guest with
      an unusual PowerShell still works.
    #>
    param([Parameter(Mandatory)] [string] $LocalDir,
          [Parameter(Mandatory)] [string] $GuestDir,
          [string] $StagingDir = $null)

    if (-not (Test-Path -LiteralPath $LocalDir)) { return $false }
    if (-not $StagingDir) { $StagingDir = $script:VmlHostStage }

    $leaf = Split-Path -Leaf $LocalDir
    $zip  = Join-Path $StagingDir ("$leaf-" + [System.Diagnostics.Process]::GetCurrentProcess().Id + '.zip')
    try {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        # -Force so a re-run overwrites; Optimal rather than NoCompression because node_modules
        # compresses extremely well and the transfer, not the CPU, is the bottleneck here.
        Compress-Archive -Path (Join-Path $LocalDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force -ErrorAction Stop
    } catch {
        Write-Host "  [transport] could not compress $LocalDir ($($_.Exception.Message)); falling back to per-file copy" -ForegroundColor DarkYellow
        return (Copy-DirToGuest -LocalDir $LocalDir -GuestDir $GuestDir)
    }

    $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Host "  [transport] $leaf -> ${sizeMb} MB archive"
    $guestZip = "$($script:VmlGuestStage)\$leaf.zip"
    try { Copy-ToGuest -LocalPath $zip -GuestPath $guestZip }
    catch {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Write-Host "  [transport] archive copy failed; falling back to per-file" -ForegroundColor DarkYellow
        return (Copy-DirToGuest -LocalDir $LocalDir -GuestDir $GuestDir)
    }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $res = Invoke-Guest -Script {
        param($zipPath, $dest)
        $ErrorActionPreference = 'Continue'
        try {
            if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Expand-Archive -LiteralPath $zipPath -DestinationPath $dest -Force -ErrorAction Stop
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            "EXPANDED:" + @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue).Count
        } catch { "FAILED:$($_.Exception.Message)" }
    } -ArgumentList @($guestZip, $GuestDir) -TimeoutSeconds 1800

    if ("$res" -match '^EXPANDED:(\d+)') {
        Write-Host "  [transport] expanded $($Matches[1]) file(s) into $GuestDir"
        return $true
    }
    Write-Host "  [transport] guest expand said: $res - falling back to per-file copy" -ForegroundColor DarkYellow
    return (Copy-DirToGuest -LocalDir $LocalDir -GuestDir $GuestDir)
}

function Copy-DirToGuest {
    <#
      Recursive copy. VBoxManage's own --recursive is used where it works, but it refuses when the
      target exists, so the directory is created first and the copy is retried per-file on failure
      (large trees like npm-global tend to hit one file and abort the whole copy otherwise).
    #>
    param([Parameter(Mandatory)] [string] $LocalDir,
          [Parameter(Mandatory)] [string] $GuestDir)

    VBoxSoft @script:VmlGcBase mkdir $GuestDir --parents | Out-Null
    $out = VBoxSoft @script:VmlGcBase copyto $LocalDir $GuestDir --recursive
    if ($LASTEXITCODE -eq 0) { return $true }

    Write-Host "  [transport] recursive copy of $LocalDir reported failure; falling back to per-file" -ForegroundColor DarkYellow
    $root = (Resolve-Path $LocalDir).Path.TrimEnd('\')
    $failed = 0
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        try { Copy-ToGuest -LocalPath $f.FullName -GuestPath (Join-Path $GuestDir $rel) } catch { $failed++ }
    }
    if ($failed) { Write-Host "  [transport] $failed file(s) failed to copy under $LocalDir" -ForegroundColor DarkYellow }
    return ($failed -eq 0)
}

# ---- guest execution ----------------------------------------------------------

function Invoke-Guest {
    <#
      Run a scriptblock in the guest. Returns the LAST non-empty output line by default (guest
      steps are written to emit exactly one JSON object or one delimited line, so that is the
      whole answer and any transport banner is discarded). -Tail N returns the last N lines
      instead - use it for logs, never for data you intend to parse.

      Arguments arrive as a JSON file, not on a command line: the values under test contain
      backslashes, quotes and control characters, and JSON escaping makes the transport
      irrelevant to what is being tested.
    #>
    param([Parameter(Mandatory)] [scriptblock] $Script,
          [object[]] $ArgumentList = @(),
          [int] $Tail = 0,
          [int] $TimeoutSeconds = 0)

    $script:VmlStepSeq++
    $stepName = "step-$($script:VmlStepSeq)"
    $argsFile = Join-Path $script:VmlHostStage "$stepName.args.json"
    $ps1File  = Join-Path $script:VmlHostStage "$stepName.ps1"

    @{ args = @($ArgumentList) } | ConvertTo-Json -Depth 8 -Compress |
        Set-Content -LiteralPath $argsFile -Encoding utf8

    # The body is embedded verbatim inside a single-quoted here-string, so nothing in it is
    # expanded by the wrapper. It is rebuilt into a scriptblock in the guest and splatted.
    $wrapper = @"
`$ErrorActionPreference = 'Continue'
`$__json = Get-Content -LiteralPath '$($script:VmlGuestStage)\$stepName.args.json' -Raw
`$__a = @((ConvertFrom-Json `$__json).args)
`$__sb = [scriptblock]::Create(@'
$($Script.ToString())
'@)
& `$__sb @__a
"@
    Set-Content -LiteralPath $ps1File -Value $wrapper -Encoding utf8

    Copy-ToGuest -LocalPath $argsFile -GuestPath "$($script:VmlGuestStage)\$stepName.args.json"
    Copy-ToGuest -LocalPath $ps1File  -GuestPath "$($script:VmlGuestStage)\$stepName.ps1"

    $gcArgs = @($script:VmlGcBase) + @('run')
    if ($TimeoutSeconds -gt 0) { $gcArgs += @('--timeout', ($TimeoutSeconds * 1000)) }
    $gcArgs += @('--exe', 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
                 '--wait-stdout', '--wait-stderr', '--',
                 '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$($script:VmlGuestStage)\$stepName.ps1")

    $out = VBoxSoft @gcArgs
    $lines = @($out | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($Tail -gt 0) { return ($lines | Select-Object -Last $Tail) }
    return ($lines | Select-Object -Last 1)
}

function Invoke-GuestJson {
    <#
      Invoke-Guest whose guest step ends in ConvertTo-Json -Compress, parsed on the host.
      Returns $null (and warns) when the guest emitted something that is not JSON - which is
      almost always a guest-side exception, so the raw tail is printed rather than swallowed.
    #>
    param([Parameter(Mandatory)] [scriptblock] $Script,
          [object[]] $ArgumentList = @(),
          [int] $TimeoutSeconds = 0)

    $line = Invoke-Guest -Script $Script -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
    if (-not $line) { Write-Host '  [guest] no output' -ForegroundColor DarkYellow; return $null }
    try { return ($line | ConvertFrom-Json) }
    catch {
        $short = if ($line.Length -gt 400) { $line.Substring(0, 400) + ' ...' } else { $line }
        Write-Host "  [guest] expected JSON, got: $short" -ForegroundColor DarkYellow
        return $null
    }
}

function Invoke-GuestFile {
    <#
      Copy a LOCAL script into the guest and run it there with plain arguments. For the
      provisioners and installers that already exist as files (Install-GuestPrereqs.ps1,
      New-IISShapes.ps1, setup-nodeshape.ps1, deploy.bat) - they are not scriptblocks and their
      output is a log, not a value.
    #>
    param([Parameter(Mandatory)] [string] $LocalPath,
          [string[]] $Arguments = @(),
          [string] $GuestPath = $null,
          [int] $Tail = 40,
          [int] $TimeoutSeconds = 0)

    if (-not $GuestPath) { $GuestPath = Join-Path $script:VmlGuestStage (Split-Path -Leaf $LocalPath) }
    Copy-ToGuest -LocalPath $LocalPath -GuestPath $GuestPath

    $isBat  = $GuestPath -match '\.(bat|cmd)$'
    $gcArgs = @($script:VmlGcBase) + @('run')
    if ($TimeoutSeconds -gt 0) { $gcArgs += @('--timeout', ($TimeoutSeconds * 1000)) }
    if ($isBat) {
        $gcArgs += @('--exe', 'C:\Windows\System32\cmd.exe', '--wait-stdout', '--wait-stderr', '--',
                     'cmd', '/c', $GuestPath) + $Arguments
    } else {
        $gcArgs += @('--exe', 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
                     '--wait-stdout', '--wait-stderr', '--',
                     '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $GuestPath) + $Arguments
    }

    $out  = VBoxSoft @gcArgs
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
    return [pscustomobject]@{
        Code = $code
        Out  = (($lines | Select-Object -Last $Tail) -join "`n")
        All  = $lines.Count
    }
}

# ---- assertions ---------------------------------------------------------------

function Write-PhaseHeader {
    param([string] $Id, [string] $Title)
    $script:CurrentPhase = $Id
    Write-Host ''
    Write-Host ("== $Id  $Title " + ('=' * [Math]::Max(1, 62 - $Id.Length - $Title.Length))) -ForegroundColor Cyan
}

function Assert-True {
    param([Parameter(Mandatory)] [string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) {
        $script:Pass++
        Write-Host "  ok   $Name" -ForegroundColor DarkGray
        $script:Results += [pscustomobject]@{ Phase = $script:CurrentPhase; Name = $Name; Result = 'pass'; Detail = '' }
    } else {
        $script:Fail++
        Write-Host "  FAIL $Name$(if ($Detail) { " -> $Detail" })" -ForegroundColor Red
        $script:Results += [pscustomobject]@{ Phase = $script:CurrentPhase; Name = $Name; Result = 'FAIL'; Detail = $Detail }
    }
}

function Assert-Equal {
    param([Parameter(Mandatory)] [string] $Name, $Expected, $Actual)
    Assert-True -Name $Name -Condition ($Expected -eq $Actual) -Detail "expected [$Expected], got [$Actual]"
}

function Assert-Match {
    param([Parameter(Mandatory)] [string] $Name, [string] $Pattern, [string] $Value)
    Assert-True -Name $Name -Condition ([bool]($Value -match $Pattern)) -Detail "pattern [$Pattern] not found in [$($Value -replace "`n", ' | ')]"
}

function Assert-SetEqual {
    <#
      Set comparison, because "the names this host claims" is a SET: order and duplicates are not
      part of the contract, and comparing joined strings has produced false failures before.
    #>
    param([Parameter(Mandatory)] [string] $Name, [string[]] $Expected, [string[]] $Actual)
    $e = @($Expected | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $a = @($Actual   | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $missing = @($e | Where-Object { $a -notcontains $_ })
    $extra   = @($a | Where-Object { $e -notcontains $_ })
    Assert-True -Name $Name -Condition (($missing.Count -eq 0) -and ($extra.Count -eq 0)) `
        -Detail "missing: [$($missing -join ', ')]; unexpected: [$($extra -join ', ')]"
}

function Note {
    <#
      Something worth printing that is NOT a pass/fail - an environmental limitation, a skipped
      phase, a known-open. Counted separately so a run that skipped half the matrix cannot look
      like a clean pass.
    #>
    param([Parameter(Mandatory)] [string] $Name, [string] $Message)
    $script:Skip++
    $script:Notes += "[$($script:CurrentPhase)] $Name : $Message"
    Write-Host "  NOTE $Name -> $Message" -ForegroundColor Yellow
    $script:Results += [pscustomobject]@{ Phase = $script:CurrentPhase; Name = $Name; Result = 'note'; Detail = $Message }
}

function Write-LoopSummary {
    param([string] $Title = 'VM loop')

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "$Title summary" -ForegroundColor Cyan
    $byPhase = $script:Results | Group-Object Phase
    foreach ($g in $byPhase) {
        $p = @($g.Group | Where-Object { $_.Result -eq 'pass' }).Count
        $f = @($g.Group | Where-Object { $_.Result -eq 'FAIL' }).Count
        $n = @($g.Group | Where-Object { $_.Result -eq 'note' }).Count
        $colour = if ($f) { 'Red' } elseif ($n) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-6} pass {1,-4} fail {2,-4} note {3}" -f $g.Name, $p, $f, $n) -ForegroundColor $colour
    }
    if ($script:Fail) {
        Write-Host ''
        Write-Host '  failures:' -ForegroundColor Red
        foreach ($r in ($script:Results | Where-Object { $_.Result -eq 'FAIL' })) {
            Write-Host ("   - [{0}] {1}{2}" -f $r.Phase, $r.Name, $(if ($r.Detail) { " -> $($r.Detail)" })) -ForegroundColor Red
        }
    }
    if ($script:Notes.Count) {
        Write-Host ''
        Write-Host '  notes (not pass/fail):' -ForegroundColor Yellow
        foreach ($n in $script:Notes) { Write-Host "   - $n" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host ("{0} passed, {1} failed, {2} noted" -f $script:Pass, $script:Fail, $script:Skip) `
        -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Get-LoopExitCode { return [int]$script:Fail }
