<#
.SYNOPSIS
  Asserting VM loop for the supervisor's agent settings - agent.config_apply_timeout and
  agent.passthrough_logs - against the REAL OpAMP Supervisor binary.

.DESCRIPTION
  WHY THIS EXISTS. test\Test-SupervisorConfigWriter.ps1 pins the string rules offline in about a
  second, and that is all it can do. Three claims in this change cannot be checked without the
  real binary and a real Windows host:

    1. go-yaml ACCEPTS what we wrote. A supervisor config that parses in our head and not in
       go-yaml leaves the host with no agent, and the repo has shipped exactly that before.
    2. The 5s default was genuinely UNREACHABLE on this config. That is a measurement, not an
       opinion: S6 times the collector's cold start to a healthy health endpoint and fails if it
       comes in under 5s - because then the diagnosis behind this whole change is wrong.
    3. passthrough_logs actually PASSES SOMETHING THROUGH. A key that parses but does nothing is
       indistinguishable from a key that works, unless you watch the log grow.

  Every docker-win harness installs with CX_NO_SUPERVISOR=1 (the vendor MSI cannot be fetched in a
  Server Core container), so no container test reaches the supervisor branch at all.

  The guest-side probes deliberately compute indents and key counts with their OWN regexes and
  never call the functions under test. A harness that reuses the code it is grading agrees with
  its bugs.

.PARAMETER VmName
  The guest. Treated as DISPOSABLE: this harness installs the agent, rewrites the supervisor's
  config, kills processes, reboots it and uninstalls.

.PARAMETER PrivateKey
  Coralogix Send-Your-Data key for the install. Defaults to CORALOGIX_PRIVATE_KEY, then to
  artifacs\SendDataKey.txt / deploy\SendDataKey.txt. Without one every phase from S2 is SKIPPED
  rather than failed, and the summary says so - a run that proved nothing must not read as a pass.

.PARAMETER Phase
  Subset of S0..S12 to run. Empty = all. Note that S3 onward assume S2 ran at some point on this
  guest; running S4 alone against a guest that was never deployed to is meaningless, not a failure.

.EXAMPLE
  .\poc\Run-SupervisorAgentSettingsVmLoop.ps1 -VmName cx-fleet-test
  .\poc\Run-SupervisorAgentSettingsVmLoop.ps1 -VmName cx-fleet-test -Phase S0,S2,S3,S6

.NOTES
  Never point this at a production host, or at a VM you care about. Windows PowerShell 5.1.
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param(
    [string]   $VmName      = 'cx-fleet-test',
    [string]   $User        = 'Administrator',
    [string]   $Password    = 'Otel!Passw0rd2026',
    [string]   $RepoRoot    = $null,
    # Deliberately NOT C:\cx-deploy. deploy.bat resolves its scripts with %~dp0, so a stale payload
    # a human once unzipped there would silently shadow the branch under test.
    [string]   $GuestStage  = 'C:\cx-supcfg',
    [string]   $PrivateKey  = $env:CORALOGIX_PRIVATE_KEY,
    [string]   $Region      = 'eu1',
    [string]   $Environment = 'vm-supcfg',
    [string[]] $Phase       = @(),
    [string]   $HostRename  = $null,
    # What the installer should have written. Kept as parameters so this harness can also grade a
    # deliberately different -ConfigApplyTimeout without being edited.
    [string]   $ExpectTimeout = '30s',
    [int]      $MinHealthyMs  = 5000,
    [int]      $MaxHealthyMs  = 30000
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $here }
. (Join-Path $here 'VmLoop.Common.ps1')

# `-Phase S3,S6` through `powershell -File` arrives as ONE "S3,S6" string. Re-split, or the run
# quietly does nothing and exits 0 - which looks exactly like a clean pass.
$Phase = @($Phase | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
function Want { param([string] $P) return (($Phase.Count -eq 0) -or ($Phase -contains $P)) }

if (-not $PrivateKey) {
    foreach ($c in @((Join-Path $RepoRoot 'artifacs\SendDataKey.txt'),
                     (Join-Path $RepoRoot 'deploy\SendDataKey.txt'),
                     (Join-Path $RepoRoot 'SimpleWebApp\coralogix\SendDataKey.txt'))) {
        if ((Test-Path $c) -and (Get-Content $c -Raw).Trim()) { $PrivateKey = (Get-Content $c -Raw).Trim(); break }
    }
}
if (-not $HostRename) {
    # Two linked clones of one image share a computer name, and host.name is the join key for
    # anything Coralogix-side. Windows caps NetBIOS names at 15.
    $HostRename = ($VmName -replace '[^A-Za-z0-9-]', '-')
    if ($HostRename.Length -gt 15) { $HostRename = $HostRename.Substring(0, 15) }
}

$SupCfg  = 'C:\Program Files\OpenTelemetry OpAMP Supervisor\config.yaml'
$SupState = 'C:\ProgramData\opampsupervisor'

Write-Host ''
Write-Host "=== supervisor agent-settings VM loop : $VmName ===" -ForegroundColor Cyan
Write-Host "    region=$Region environment=$Environment rename-to=$HostRename"
Write-Host "    expect config_apply_timeout=$ExpectTimeout passthrough_logs=true"
Write-Host "    healthy window asserted: >${MinHealthyMs}ms and <${MaxHealthyMs}ms"
Write-Host "    send key: $(if ($PrivateKey) { 'present' } else { 'MISSING (S2+ will be skipped)' })"

# ---------------------------------------------------------------------------
# Guest probes. Written once, called from several phases - and written with their own regexes so
# a bug in Set-SupervisorAgentSettings cannot be mirrored here and cancel itself out.
# ---------------------------------------------------------------------------

$ProbeConfig = {
    param($cfgPath)
    $ErrorActionPreference = 'Continue'
    $o = [ordered]@{}
    $o['exists'] = [bool](Test-Path -LiteralPath $cfgPath)
    $o['preEdit'] = [bool](Test-Path -LiteralPath ($cfgPath + '.pre-agentdesc'))
    if (-not $o['exists']) { [pscustomobject]$o | ConvertTo-Json -Compress; return }

    $lines = @(Get-Content -LiteralPath $cfgPath)

    # Independent scan for the agent block and the indent its direct children use.
    $ai = -1; $aLen = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)agent:\s*$') { $ai = $i; $aLen = $Matches[1].Length; break }
    }
    $o['agentIdx'] = $ai
    $o['agentIndentLen'] = $aLen

    function IndentLen { param($s) return ([regex]::Match($s, '^\s*')).Value.Length }

    $exe = @($lines | Where-Object { $_ -match '^\s*executable\s*:' })
    $o['exeCount']     = $exe.Count
    $o['exeIndentLen'] = $(if ($exe.Count) { IndentLen $exe[0] } else { -1 })
    # [string] matters: Get-Content emits strings decorated with PSPath/PSParentPath note properties
    # and ConvertTo-Json serializes the whole decorated object - the first run printed
    # "@{value=  executable: ...; PSPath=...}" instead of the line.
    $o['exeLine']      = $(if ($exe.Count) { [string]$exe[0] } else { '' })

    foreach ($k in @('passthrough_logs', 'config_apply_timeout')) {
        $hits = @($lines | Where-Object { $_ -match ('^\s*' + [regex]::Escape($k) + '\s*:') })
        $o[($k + '_count')] = $hits.Count
        $o[($k + '_raw')]   = ($hits -join '|')
        $o[($k + '_indent')] = $(if ($hits.Count) { IndentLen $hits[0] } else { -1 })
        $val = ''
        if ($hits.Count -and ($hits[0] -match ':\s*(.*?)\s*$')) { $val = $Matches[1] }
        $o[($k + '_value')] = $val
        # Quoting is a bug for these two keys: go-yaml must read a duration and a bool, not strings.
        $o[($k + '_quoted')] = [bool]($val -match '^["''].*["'']$')
    }

    # The vendor's own lines, which neither writer may touch.
    $sn = @($lines | Where-Object { $_ -match '^\s*service\.name\s*:' })
    $at = @($lines | Where-Object { $_ -match '^\s*cx\.agent\.type\s*:' })
    $o['serviceNameLine'] = $(if ($sn.Count) { ([string]$sn[0]).Trim() } else { '' })
    $o['agentTypeLine']   = $(if ($at.Count) { ([string]$at[0]).Trim() } else { '' })
    $o['descAnchor']      = [bool](@($lines | Where-Object { $_ -match '^\s*non_identifying_attributes\s*:\s*$' }).Count)

    [pscustomobject]$o | ConvertTo-Json -Compress
}

$ProbeRuntime = {
    param($statePath)
    $ErrorActionPreference = 'Continue'
    $o = [ordered]@{}
    $sup = Get-Service opampsupervisor -ErrorAction SilentlyContinue
    $o['supervisor'] = [string]$sup.Status
    $o['supStart']   = [string]$sup.StartType
    $o['otelChild']  = @(Get-Process otelcol* -ErrorAction SilentlyContinue).Count

    # The health endpoint is RESOLVED from the merged effective config, never assumed to be 13133.
    # In supervisor mode the supervisor composes the collector's config and owns its own
    # health_check wiring, so the port the base config asks for is not necessarily the port being
    # served. misc\Test-CxInstrumentation.ps1 already resolves it this way for exactly this reason;
    # the first run of this loop hardcoded 13133 and reported 503 / never-healthy against a
    # collector whose log said "Everything is ready".
    $eff = Join-Path $statePath 'state\effective.yaml'
    $o['healthUrl'] = 'http://127.0.0.1:13133'
    try {
        if (Test-Path -LiteralPath $eff) {
            $fs = New-Object System.IO.FileStream($eff, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $cfgTxt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $m = [regex]::Match($cfgTxt, '(?ms)^\s{2}health_check(/[\w\.\-]+)?\s*:\s*.*?^\s{4}endpoint\s*:\s*["'']?([^\s"'']+)')
            if ($m.Success) {
                $ep = $m.Groups[2].Value -replace '^0\.0\.0\.0', '127.0.0.1' -replace '^\[::\]', '127.0.0.1'
                $o['healthUrl'] = "http://$ep"
                $o['healthFrom'] = 'effective.yaml'
            } else { $o['healthFrom'] = 'default (no health_check endpoint in effective.yaml)' }
        } else { $o['healthFrom'] = 'default (no effective.yaml)' }
    } catch { $o['healthFrom'] = "default (parse failed: $($_.Exception.Message))" }

    try {
        $r = Invoke-WebRequest -Uri $o['healthUrl'] -UseBasicParsing -TimeoutSec 15
        $o['health'] = [int]$r.StatusCode
    } catch {
        $c = 0; try { $c = [int]$_.Exception.Response.StatusCode.value__ } catch { }
        $o['health'] = $c
    }

    # effective.yaml is the supervisor's merged base+remote config - its existence is the local
    # evidence that an apply completed. It is held OPEN by the supervisor, so a plain Get-Content
    # fails with "being used by another process"; FileShare::ReadWrite is mandatory.
    $eff = Join-Path $statePath 'state\effective.yaml'
    $o['effPath'] = $eff
    $o['effExists'] = [bool](Test-Path -LiteralPath $eff)
    $o['effLen'] = 0
    $o['effReadable'] = $false
    if ($o['effExists']) {
        try {
            $fs = New-Object System.IO.FileStream($eff, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $o['effLen'] = $txt.Length
            $o['effReadable'] = $true
        } catch { $o['effReadErr'] = "$($_.Exception.Message)" }
    }
    [pscustomobject]$o | ConvertTo-Json -Compress
}

$ProbeLogs = {
    param($statePath, $cfgPath, $sinceIso)
    $ErrorActionPreference = 'Continue'
    $o = [ordered]@{}

    # Only events written SINCE we patched config.yaml count. Measured on the dev host: an
    # 'opampsupervisor' event-log source survives an uninstall, so an unfiltered read returned 90 KB
    # of events from a previous install - which would have failed S8 on lines written before the fix
    # existed. The config's own mtime is the right boundary and needs no state threaded between
    # phases, so a single-phase run gets the same answer as a full one.
    $since = [datetime]::MinValue
    if ($cfgPath -and (Test-Path -LiteralPath $cfgPath)) {
        try { $since = (Get-Item -LiteralPath $cfgPath).LastWriteTime } catch { }
    }
    # An explicit marker wins when it is LATER: that is how a caller asks "what arrived after this
    # moment", the only sound way to detect new output when the source is a fixed-size window.
    # Measured: the Application log read with -Newest 200 saturates at 200 events, so its total
    # character count can FALL as old events roll off - the first run of this loop saw
    # 135883 -> 131663 chars and read that as "the log did not grow".
    if ($sinceIso) {
        try { $m = [datetime]::Parse($sinceIso); if ($m -gt $since) { $since = $m } } catch { }
    }
    $o['since'] = $since.ToString('o')

    # DISCOVER the log rather than hardcoding a path - the supervisor's own layout is not ours to
    # assume, and a wrong path would make every log assertion vacuously silent.
    $files = @(Get-ChildItem -Path $statePath -Filter '*.log' -Recurse -ErrorAction SilentlyContinue)
    $files += @(Get-ChildItem -Path 'C:\Program Files\OpenTelemetry OpAMP Supervisor' -Filter '*.log' -ErrorAction SilentlyContinue)
    $o['files'] = @($files | ForEach-Object { $_.FullName }) -join '|'
    $o['bytes'] = [int64](($files | Measure-Object -Property Length -Sum).Sum)

    $text = ''
    foreach ($f in $files) {
        try {
            $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $text += $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        } catch { }
    }
    # The Application event log is the other place the service's output can land.
    $o['newest'] = ''
    try {
        $all = @(Get-EventLog -LogName Application -Source 'opampsupervisor' -Newest 200 -ErrorAction Stop)
        if ($all.Count) {
            $o['newest'] = ($all | Sort-Object TimeGenerated -Descending | Select-Object -First 1).TimeGenerated.ToString('o')
        }
        $ev = @($all | Where-Object { $_.TimeGenerated -gt $since })
        foreach ($e in $ev) { $text += "`n" + $e.Message }
        $o['events'] = $ev.Count
        $o['eventsTotal'] = $all.Count
    } catch { $o['events'] = 0; $o['eventsTotal'] = 0 }

    $o['chars'] = $text.Length
    # A collector-emitted line is what proves passthrough_logs is not inert. These are otelcol's
    # own startup strings, not the supervisor's.
    $o['collectorLines'] = @([regex]::Matches($text, '(?im)^.*(everything is ready|starting otelcol|service/telemetry|kind:\s*exporter|Beginning shutdown).*$') |
                             ForEach-Object { $_.Value.Trim() } | Select-Object -Last 3) -join ' || '
    $o['hasCollector'] = [bool]$o['collectorLines']
    # The symptom under test, in the supervisor's own words.
    $o['applyFailLines'] = @([regex]::Matches($text, '(?im)^.*(failed to apply|config apply|apply.{0,20}timeout|timeout.{0,20}apply).*$') |
                             ForEach-Object { $_.Value.Trim() } | Select-Object -Last 3) -join ' || '
    $o['hasApplyFail'] = [bool]$o['applyFailLines']
    [pscustomobject]$o | ConvertTo-Json -Compress
}

# ---------------------------------------------------------------------------

function Invoke-DeployInGuest {
    <#
      Stage THIS checkout's deploy\ into the guest as one archive and run deploy.bat from inside
      it. Called by S2, and again by S9/S10 to prove the re-deploy paths - so the staging and the
      payload-identity check cannot drift between them.
    #>
    param([string] $Stage, [string] $Key, [hashtable] $EnvBlock, [int] $TimeoutSeconds = 3600)

    [void](Copy-DirToGuestAsZip -LocalDir (Join-Path $RepoRoot 'deploy') -GuestDir "$Stage\deploy")

    return (Invoke-GuestJson -Script {
        param($stage, $key, $envJson)
        $ErrorActionPreference = 'Continue'
        $envMap = $envJson | ConvertFrom-Json
        foreach ($p in $envMap.PSObject.Properties) { Set-Item -Path "env:$($p.Name)" -Value ([string]$p.Value) }
        $env:CORALOGIX_PRIVATE_KEY = $key
        Set-Content -LiteralPath "$stage\deploy\SendDataKey.txt" -Value $key -Encoding Ascii -NoNewline
        $out = & cmd.exe /c "`"$stage\deploy\deploy.bat`"" 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            Code       = $code
            Supervisor = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
            SupPath    = [bool](($out -join ' ') -match 'SupervisorCollectorBaseConfig|-Supervisor\b')
            Exception  = [bool](($out -join ' ') -match 'FullyQualifiedErrorId')
            # The installer's own narration about this change, so a silent no-op is visible.
            SettingsMsg = (@($out | Where-Object { $_ -match 'agent settings' }) -join ' | ')
            RolledBack  = [bool](($out -join ' ') -match 'rolled back')
            Tail        = (($out | Select-Object -Last 15) -join ' | ')
        } | ConvertTo-Json -Compress
    } -ArgumentList @($Stage, $Key, ($EnvBlock | ConvertTo-Json -Compress)) -TimeoutSeconds $TimeoutSeconds)
}

$exitCode = 1
try {
    # ---- S0 : transport and guest baseline -------------------------------------
    Write-PhaseHeader 'S0' 'transport and guest baseline'
    Assert-True 'VBoxManage present' ((VBoxSoft --version) -match '^\d')
    [void](Initialize-VmLoop -VmName $VmName -User $User -Password $Password -GuestStage $GuestStage)
    # Bail before the long wait, not after it. Wait-GuestReady polls for 20 minutes; against a VM
    # that is not registered or would not start, every one of those polls is guaranteed to fail, so
    # a mistyped -VmName used to buy 20 minutes of silence before the loop said anything useful.
    $exists = Test-VmExists
    Assert-True "VM '$VmName' is registered" $exists
    if (-not $exists) { throw "no VM named '$VmName' - check the name against: VBoxManage list vms" }
    if (-not (Test-VmRunning)) { [void](Start-VmHeadless) }
    $running = Test-VmRunning
    Assert-True "VM '$VmName' is running" $running
    if (-not $running) { throw "'$VmName' would not start - nothing else can be asserted" }

    $ready = Wait-GuestReady -TimeoutSeconds 1200
    Assert-True 'guestcontrol reaches the guest' $ready 'Guest Additions not answering, or wrong -User/-Password'
    if (-not $ready) { throw 'no guest transport - nothing else can be asserted' }

    $who = Invoke-GuestJson -Script {
        [pscustomobject]@{
            Host  = $env:COMPUTERNAME
            Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            Os    = (Get-CimInstance Win32_OperatingSystem).Caption
        } | ConvertTo-Json -Compress
    }
    Assert-True 'guest session is elevated' ([bool]$who.Admin) "IsInRole=$($who.Admin)"
    Write-Host "  guest: $($who.Host) / $($who.Os)"

    if ($who.Host -ne $HostRename) {
        Write-Host "  renaming guest $($who.Host) -> $HostRename"
        $renamed = Invoke-GuestJson -Script {
            param($newName)
            try {
                Rename-Computer -NewName $newName -Force -ErrorAction Stop
                [pscustomobject]@{ Ok = $true; Reason = '' } | ConvertTo-Json -Compress
            } catch {
                [pscustomobject]@{ Ok = $false; Reason = "$($_.Exception.Message)" } | ConvertTo-Json -Compress
            }
        } -ArgumentList @($HostRename)
        Assert-True 'rename accepted' ([bool]$renamed.Ok) "$($renamed.Reason)"
        Assert-True 'guest came back after the rename reboot' (Restart-Guest -ReadyTimeoutSeconds 900)
    } else {
        Write-Host '  guest already carries the expected name'
    }

    # ---- S1 : clean state ------------------------------------------------------
    # Without this, S3 can pass on a config.yaml left behind by an earlier run - a green result
    # about code that never executed.
    if (Want 'S1') {
        Write-PhaseHeader 'S1' 'prerequisites, and a clean baseline'

        # IIS IS A HARD PREREQUISITE, and this check exists because its absence cost three full
        # runs. The base config ships a windowsperfcounters/iis_apppool receiver and an IIS filelog
        # receiver. On a host without IIS the APP_POOL_WAS counter object does not exist, that
        # component fails to start, the collector SHUTS ITSELF DOWN, and the supervisor restarts it
        # in a loop. The visible result is not "no IIS" - it is health 503 or refused, S6 unable to
        # measure anything, and S7 seeing killed=1/back=0, i.e. five confusing failures that all
        # look like the config edit broke something. One actionable failure here beats that.
        $prereq = Invoke-GuestJson -Script {
            [pscustomobject]@{
                W3SVC   = [string](Get-Service W3SVC -ErrorAction SilentlyContinue).Status
                AppCmd  = [bool](Test-Path 'C:\Windows\System32\inetsrv\appcmd.exe')
                WasCtr  = [bool](Get-Counter -ListSet 'APP_POOL_WAS' -ErrorAction SilentlyContinue)
            } | ConvertTo-Json -Compress
        } -TimeoutSeconds 300
        $iisOk = $prereq -and [bool]$prereq.AppCmd -and [bool]$prereq.WasCtr
        Assert-True 'IIS is installed, so the base config''s IIS receivers can start' $iisOk `
            "appcmd=$($prereq.AppCmd) APP_POOL_WAS=$($prereq.WasCtr) W3SVC=$($prereq.W3SVC) - run poc\Configure-Guest.ps1 on this guest first"
        if (-not $iisOk) {
            throw 'IIS missing: the collector will crash-loop on windowsperfcounters/iis_apppool and every health assertion below would fail for that reason rather than anything this loop is testing. Run poc\Configure-Guest.ps1 against the guest, then re-run.'
        }
        $pre = Invoke-GuestJson -Script {
            param($cfg)
            [pscustomobject]@{
                Supervisor = [bool](Get-Service opampsupervisor -ErrorAction SilentlyContinue)
                Collector  = [bool](Get-Service otelcol-contrib -ErrorAction SilentlyContinue)
                Config     = [bool](Test-Path -LiteralPath $cfg)
            } | ConvertTo-Json -Compress
        } -ArgumentList @($SupCfg)

        if ($pre -and ($pre.Supervisor -or $pre.Collector -or $pre.Config)) {
            Write-Host '  guest already carries an agent - uninstalling for a real install'
            # uninstall.bat resolves its scripts with %~dp0, so the payload must be staged first.
            [void](Copy-DirToGuestAsZip -LocalDir (Join-Path $RepoRoot 'deploy') -GuestDir "$GuestStage\deploy")
            $un = Invoke-GuestFile -LocalPath (Join-Path $RepoRoot 'deploy\uninstall.bat') `
                                   -GuestPath "$GuestStage\deploy\uninstall.bat" -Tail 12 -TimeoutSeconds 1200
            Write-Host "  uninstall exit=$($un.Code)"
            $post = Invoke-GuestJson -Script {
                param($cfg)
                [pscustomobject]@{
                    Supervisor = [bool](Get-Service opampsupervisor -ErrorAction SilentlyContinue)
                    Collector  = [bool](Get-Service otelcol-contrib -ErrorAction SilentlyContinue)
                    Config     = [bool](Test-Path -LiteralPath $cfg)
                } | ConvertTo-Json -Compress
            } -ArgumentList @($SupCfg)
            Assert-True 'no collector service before the install' (-not ($post.Supervisor -or $post.Collector)) `
                "supervisor=$($post.Supervisor) collector=$($post.Collector)"
            Assert-True 'no leftover supervisor config.yaml' (-not [bool]$post.Config) `
                'a stale config.yaml would let S3 pass without our code running'
        } else {
            Assert-True 'no collector service before the install' $true
            Assert-True 'no leftover supervisor config.yaml' $true
        }
    }

    # ---- S2 : deploy -----------------------------------------------------------
    if (Want 'S2') {
        Write-PhaseHeader 'S2' 'deploy.bat (supervisor mode)'
        if (-not $PrivateKey) {
            Note 'S2 skipped' 'no Send-Your-Data key (-PrivateKey / CORALOGIX_PRIVATE_KEY / artifacs\SendDataKey.txt)'
        } else {
            $deploy = Invoke-DeployInGuest -Stage $GuestStage -Key $PrivateKey -EnvBlock @{
                CX_REGION      = $Region
                CX_ENVIRONMENT = $Environment
            }
            if (-not $deploy) {
                Assert-True 'deploy.bat produced a parsable result' $false 'no JSON from the guest'
            } else {
                Assert-Equal 'deploy.bat exited 0' 0 ([int]$deploy.Code)
                Assert-True  'no unhandled exception in the deploy output' (-not [bool]$deploy.Exception) $deploy.Tail
                Assert-True  'installer took the SUPERVISOR path' ([bool]$deploy.SupPath) $deploy.Tail
                Assert-Equal 'opampsupervisor is Running' 'Running' ([string]$deploy.Supervisor)
                # If the edit had made config.yaml unparseable, Publish-SupervisorAgentDescription
                # would have restored the pre-edit copy and said so. A rollback is a pass for the
                # safety net and a FAILURE for this change.
                Assert-True  'the config edit was NOT rolled back' (-not [bool]$deploy.RolledBack) $deploy.Tail
                Assert-Match 'the installer reported writing the agent settings' `
                    'passthrough_logs|config_apply_timeout|already correct' ([string]$deploy.SettingsMsg)
            }
        }
    }

    # ---- S3 : the keys are on disk, at the right level --------------------------
    if (Want 'S3') {
        Write-PhaseHeader 'S3' 'agent settings written to the supervisor config'
        $cfg = Invoke-GuestJson -Script $ProbeConfig -ArgumentList @($SupCfg) -TimeoutSeconds 300
        if (-not $cfg) {
            Assert-True 'supervisor config probe returned data' $false 'no JSON from the guest'
        } elseif (-not [bool]$cfg.exists) {
            Assert-True 'supervisor config.yaml exists' $false "not found at $SupCfg - did S2 run?"
        } else {
            Assert-True  'supervisor config.yaml exists' $true
            Assert-True  'the config still has an agent: block' ([int]$cfg.agentIdx -ge 0) "agentIdx=$($cfg.agentIdx)"

            Assert-Equal 'passthrough_logs appears exactly once' 1 ([int]$cfg.passthrough_logs_count)
            Assert-Equal 'config_apply_timeout appears exactly once' 1 ([int]$cfg.config_apply_timeout_count)

            Assert-Equal 'config_apply_timeout carries the expected value' $ExpectTimeout ([string]$cfg.config_apply_timeout_value)
            Assert-Equal 'passthrough_logs is true' 'true' ([string]$cfg.passthrough_logs_value)

            # Quoting either of these turns a duration into a string and a bool into a string.
            Assert-True  'config_apply_timeout is UNQUOTED' (-not [bool]$cfg.config_apply_timeout_quoted) ([string]$cfg.config_apply_timeout_raw)
            Assert-True  'passthrough_logs is UNQUOTED'     (-not [bool]$cfg.passthrough_logs_quoted)     ([string]$cfg.passthrough_logs_raw)

            # The whole correctness question for this writer is INDENT: a key one level too deep
            # lands under description: and does nothing at all.
            Assert-Equal 'config_apply_timeout sits at the same indent as agent.executable' `
                ([int]$cfg.exeIndentLen) ([int]$cfg.config_apply_timeout_indent)
            Assert-Equal 'passthrough_logs sits at the same indent as agent.executable' `
                ([int]$cfg.exeIndentLen) ([int]$cfg.passthrough_logs_indent)
            Assert-True  'and that indent is deeper than agent: itself' `
                ([int]$cfg.config_apply_timeout_indent -gt [int]$cfg.agentIndentLen) `
                "child=$($cfg.config_apply_timeout_indent) agent=$($cfg.agentIndentLen)"

            # The vendor's lines and the description block, which this change must not touch.
            Assert-Equal 'agent.executable is still a single line' 1 ([int]$cfg.exeCount)
            # NOT an equality check against a literal. Measured on vendor collector 0.156.0, the
            # installer writes service.name: "opentelemetry-collector"; an older version wrote
            # "coralogix-collector". Pinning either one makes this assertion fail on the other
            # vendor build while saying nothing about our change. The invariant that actually
            # matters is that the line is still the VENDOR'S: present, and in the vendor's
            # double-quoted style rather than the single-quoted style our writer emits. That the
            # value is never modified is proved fixture-side in test\Test-SupervisorConfigWriter.ps1,
            # against both spellings.
            Assert-Match 'vendor service.name still present, in the vendor''s own quoting style' `
                '^service\.name:\s*"[^"]+"$' ([string]$cfg.serviceNameLine)
            Write-Host "  vendor service.name = $($cfg.serviceNameLine)\"
            Assert-True  'the non_identifying_attributes anchor is intact' ([bool]$cfg.descAnchor)
            Write-Host "  executable: $($cfg.exeLine)"
        }
    }

    # ---- S4 : the real binary accepted it --------------------------------------
    if (Want 'S4') {
        Write-PhaseHeader 'S4' 'the real supervisor loaded the patched config'
        $rt = Invoke-GuestJson -Script $ProbeRuntime -ArgumentList @($SupState) -TimeoutSeconds 300
        if (-not $rt) {
            Assert-True 'runtime probe returned data' $false 'no JSON from the guest'
        } else {
            Assert-Equal 'opampsupervisor Running' 'Running' ([string]$rt.supervisor)
            Assert-True  'supervisor start type survives a reboot' ([string]$rt.supStart -match 'Auto') "StartType=$($rt.supStart)"
            # "Service is Running" is not sufficient anywhere in this code: a config the supervisor
            # rejects can still leave the service up with no collector under it.
            Assert-True  'a collector child process is alive' ([int]$rt.otelChild -ge 1) "otelcol processes=$($rt.otelChild)"
            # Polled, not sampled once. The collector legitimately needs seconds to come up - the
            # installer itself sleeps 6 before its own probe - so a single read straight after a
            # deploy reports 503 on a collector that is merely still starting. That is exactly what
            # the first run of this loop did, and the event log then showed "Everything is ready"
            # moments later.
            Write-Host "  health endpoint $($rt.healthUrl) (from $($rt.healthFrom))"
            $h = Invoke-GuestJson -Script {
                param($url)
                $ErrorActionPreference = 'Continue'
                $code = 0
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($sw.Elapsed.TotalSeconds -lt 120) {
                    try {
                        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
                        $code = [int]$r.StatusCode
                        if ($code -eq 200) { break }
                    } catch {
                        $code = 0
                        try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { }
                    }
                    Start-Sleep -Milliseconds 500
                }
                [pscustomobject]@{ Code = $code; WaitedMs = [int]$sw.Elapsed.TotalMilliseconds } | ConvertTo-Json -Compress
            } -ArgumentList @([string]$rt.healthUrl) -TimeoutSeconds 300
            Assert-Equal 'health endpoint returns 200 (polled up to 120s)' 200 ([int]$h.Code)
            Write-Host "  health 200 after $($h.WaitedMs)ms of polling\"
        }
    }

    # ---- S5 : an apply completed, and nothing was rolled back -------------------
    if (Want 'S5') {
        Write-PhaseHeader 'S5' 'an apply completed, and the edit was not rolled back'
        $st = Invoke-GuestJson -Script $ProbeRuntime -ArgumentList @($SupState) -TimeoutSeconds 300
        $cf = Invoke-GuestJson -Script $ProbeConfig  -ArgumentList @($SupCfg)   -TimeoutSeconds 300
        if ($st) {
            Assert-True  'effective.yaml exists' ([bool]$st.effExists) "expected $($st.effPath)"
            Assert-True  'effective.yaml is readable while the supervisor holds it open' ([bool]$st.effReadable) `
                "FileShare::ReadWrite is mandatory here: $($st.effReadErr)"
            Assert-True  'effective.yaml is not empty' ([int]$st.effLen -gt 0) "length=$($st.effLen)"
        }
        if ($cf) {
            # Publish-SupervisorAgentDescription deletes this copy ONLY after a verified restart.
            # Its presence means our edit did not load and the safety net put the old file back.
            Assert-True 'no .pre-agentdesc rollback copy left behind' (-not [bool]$cf.preEdit) `
                'the edit did not load and was rolled back - the keys on disk are the vendor''s, not ours'
        }
    }

    # ---- S6 : the measurement that justifies 30s -------------------------------
    if (Want 'S6') {
        Write-PhaseHeader 'S6' 'cold start to healthy, measured'
        # A supervisor restart makes it hand the config to a FRESH collector and wait for it to
        # report healthy - the same work, and the same clock, as applying a remote config. So the
        # interval from "supervisor service is Running" to "health endpoint answers 200" is the
        # window config_apply_timeout is racing. Timed on the guest; a host-side stopwatch would
        # be measuring guestcontrol round trips.
        # Resolve the endpoint first - same reason as S4: in supervisor mode the served health port
        # comes from the merged effective config, not from the base config's request.
        $pre = Invoke-GuestJson -Script $ProbeRuntime -ArgumentList @($SupState) -TimeoutSeconds 300
        $healthUrl = 'http://127.0.0.1:13133'
        if ($pre -and $pre.healthUrl) { $healthUrl = [string]$pre.healthUrl }
        Write-Host "  measuring against $healthUrl (from $($pre.healthFrom))"

        $m = Invoke-GuestJson -Script {
            param($url)
            $ErrorActionPreference = 'Continue'
            $o = [ordered]@{}
            try { Stop-Service -Name opampsupervisor -Force -ErrorAction Stop } catch { $o['stopErr'] = "$($_.Exception.Message)" }
            $t = 0
            while ($t -lt 60 -and (Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
                Start-Sleep -Milliseconds 500; $t += 0.5
            }
            # Kill any orphaned collector so the measurement is a genuine cold start, not a
            # health endpoint the previous child is still serving.
            foreach ($p in @(Get-Process otelcol* -ErrorAction SilentlyContinue)) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
            }
            Start-Sleep -Seconds 2

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { Start-Service -Name opampsupervisor -ErrorAction Stop } catch { $o['startErr'] = "$($_.Exception.Message)" }
            while ($sw.Elapsed.TotalSeconds -lt 120 -and (Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status -ne 'Running') {
                Start-Sleep -Milliseconds 250
            }
            $o['svcRunningMs'] = [int]$sw.Elapsed.TotalMilliseconds

            $healthy = -1
            $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw2.Elapsed.TotalSeconds -lt 180) {
                try {
                    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
                    if ($r.StatusCode -eq 200) { $healthy = [int]$sw2.Elapsed.TotalMilliseconds; break }
                } catch { }
                Start-Sleep -Milliseconds 250
            }
            $o['healthyMs']  = $healthy
            $o['otelChild']  = @(Get-Process otelcol* -ErrorAction SilentlyContinue).Count
            [pscustomobject]$o | ConvertTo-Json -Compress
        } -ArgumentList @($healthUrl) -TimeoutSeconds 900

        if (-not $m) {
            Assert-True 'the startup measurement returned data' $false 'no JSON from the guest'
        } else {
            $ms = [int]$m.healthyMs
            Write-Host "  service Running after $($m.svcRunningMs)ms; health 200 after a further ${ms}ms"
            Assert-True 'the collector became healthy at all' ($ms -ge 0) `
                "no 200 from $healthUrl within 180s after a supervisor restart\"
            if ($ms -ge 0) {
                # The falsifiable core. If this host reaches healthy inside the supervisor's 5s
                # default, then a timeout cannot explain the FAILED status and the diagnosis behind
                # this change is wrong - so it fails loudly rather than passing quietly.
                Assert-True "cold start EXCEEDS the supervisor's 5s default (so the FAILED status was a timeout)" `
                    ($ms -gt $MinHealthyMs) `
                    "healthy in ${ms}ms, which is inside the 5s default - the config_apply_timeout diagnosis does not hold on this host"
                Assert-True "cold start fits inside the configured $ExpectTimeout" `
                    ($ms -lt $MaxHealthyMs) `
                    "healthy in ${ms}ms, at or beyond ${MaxHealthyMs}ms - $ExpectTimeout is not enough margin on this host"
            }
            Assert-True 'the collector child came back' ([int]$m.otelChild -ge 1) "otelcol processes=$($m.otelChild)"
        }
    }

    # ---- S7 : passthrough_logs is not inert ------------------------------------
    if (Want 'S7') {
        Write-PhaseHeader 'S7' 'passthrough_logs actually passes something through'
        $before = Invoke-GuestJson -Script $ProbeLogs -ArgumentList @($SupState, $SupCfg) -TimeoutSeconds 300
        if (-not $before) {
            Assert-True 'log probe returned data' $false 'no JSON from the guest'
        } else {
            Write-Host "  log sources: $(if ($before.files) { $before.files } else { '(none on disk)' }); events=$($before.events)"
            if ([int]$before.chars -eq 0) {
                # Silence is not success. A harness that greps an empty string passes forever.
                Note 'no supervisor log text found' `
                    'neither a *.log under the supervisor state dir nor an Application event log source - the growth assertion below cannot mean anything'
            }

            # Kill the collector: the supervisor must restart it, and with passthrough_logs on the
            # child's own startup output has to reach one of these sinks.
            $killed = Invoke-GuestJson -Script {
                $b = @(Get-Process otelcol* -ErrorAction SilentlyContinue)
                foreach ($p in $b) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
                Start-Sleep -Seconds 30
                $a = @(Get-Process otelcol* -ErrorAction SilentlyContinue)
                [pscustomobject]@{ Killed = $b.Count; Back = $a.Count } | ConvertTo-Json -Compress
            } -TimeoutSeconds 300
            if ($killed) {
                Assert-True 'the supervisor restarted the collector child after it was killed' `
                    (([int]$killed.Killed -ge 1) -and ([int]$killed.Back -ge 1)) "killed=$($killed.Killed) back=$($killed.Back)"
            }

            # Ask for output strictly NEWER than the newest line already seen. Comparing total
            # characters cannot work: the only source is a -Newest 200 window, so it is capped and
            # its character count falls as old events age out.
            $marker = [string]$before.newest
            $after = Invoke-GuestJson -Script $ProbeLogs -ArgumentList @($SupState, $SupCfg, $marker) -TimeoutSeconds 300
            if ($after) {
                Assert-True 'new supervisor/collector output appeared after the restart' `
                    ([int]$after.events -gt 0) `
                    "no events newer than [$marker] - passthrough_logs is inert, or nothing was logged"
                Assert-True 'and it carries a line the COLLECTOR emitted, not just the supervisor' `
                    ([bool]$after.hasCollector) "no collector startup line found; last matches: $($after.collectorLines)"
            }
        }
    }

    # ---- S8 : no apply failure, in the supervisor's own words -------------------
    if (Want 'S8') {
        Write-PhaseHeader 'S8' 'no config-apply failure reported locally'
        $lg = Invoke-GuestJson -Script $ProbeLogs -ArgumentList @($SupState, $SupCfg) -TimeoutSeconds 300
        if (-not $lg) {
            Assert-True 'log probe returned data' $false 'no JSON from the guest'
        } elseif ([int]$lg.chars -eq 0) {
            Note 'apply-failure check inconclusive' 'no supervisor log text on this host, so absence of the phrase proves nothing'
        } else {
            # The event-log half of this is bounded by the config's mtime. A *.log FILE cannot be
            # bounded the same way without knowing the supervisor's line format, so on a long-lived
            # host a pre-fix line could still trip this - which is why the failure detail prints the
            # matches: they carry their own timestamps and an operator can date them.
            Assert-True 'no "failed to apply" / apply-timeout line anywhere in the supervisor output' `
                (-not [bool]$lg.hasApplyFail) "since $($lg.since); matches: $($lg.applyFailLines)"
        }
    }

    # ---- S9 : upgrade a host that already carries the 5s default ----------------
    if (Want 'S9') {
        Write-PhaseHeader 'S9' 'a re-deploy repairs a host stuck on 5s'
        if (-not $PrivateKey) {
            Note 'S9 skipped' 'no Send-Your-Data key, so the re-deploy cannot run'
        } else {
            # Put the host into the broken state on purpose, with the real binary running it. This
            # is the path a skip-if-present writer would silently no-op on, which is how an earlier
            # bug in the sibling writer left a whole host dead across re-deploys.
            $broke = Invoke-GuestJson -Script {
                param($cfg)
                $ErrorActionPreference = 'Continue'
                $lines = @(Get-Content -LiteralPath $cfg)
                $n = 0
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^(\s*)config_apply_timeout\s*:') {
                        $lines[$i] = $Matches[1] + 'config_apply_timeout: 5s'; $n++
                    }
                }
                Set-Content -LiteralPath $cfg -Value $lines -Encoding utf8
                try { Restart-Service -Name opampsupervisor -Force -ErrorAction Stop } catch { }
                # NOT a fixed 10s. Cold start to healthy measured ~14s on this shape of guest, so a
                # 10s wait ends while the collector is still coming up and the re-deploy then
                # reinstalls over a running otelcol-contrib.exe whose binary is locked. Wait for the
                # agent to actually settle, and report how long it took so the margin is visible.
                $settle = 0
                while ($settle -lt 90) {
                    try {
                        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 3
                        if ($r.StatusCode -eq 200) { break }
                    } catch { }
                    Start-Sleep -Seconds 2; $settle += 2
                }
                [pscustomobject]@{
                    Rewrote       = $n
                    Status        = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
                    SettleSeconds = $settle
                    OtelProcs     = @(Get-Process otelcol* -ErrorAction SilentlyContinue).Count
                } | ConvertTo-Json -Compress
            } -ArgumentList @($SupCfg) -TimeoutSeconds 600
            Assert-True 'the guest was put back on the 5s default' ([int]$broke.Rewrote -ge 1) "settled after $($broke.SettleSeconds)s, otelcol procs=$($broke.OtelProcs), rewrote=$($broke.Rewrote)"

            $re = Invoke-DeployInGuest -Stage $GuestStage -Key $PrivateKey -EnvBlock @{
                CX_REGION      = $Region
                CX_ENVIRONMENT = $Environment
            }
            if ($re) {
                # Print the tail UNCONDITIONALLY on a non-zero exit. Passing it as an assertion
                # Detail is not enough: Detail only surfaces when THAT assertion fails, so a failing
                # re-deploy whose neighbouring assertions pass discards the only text that explains
                # it. That is how this failure survived three runs undiagnosed.
                if ([int]$re.Code -ne 0) {
                    Write-Host "  re-deploy exit=$($re.Code); output tail:" -ForegroundColor Yellow
                    foreach ($ln in (($re.Tail -split ' \| ') | Select-Object -Last 15)) { Write-Host "    $ln" -ForegroundColor DarkYellow }
                }
                Assert-Equal 'the re-deploy exited 0' 0 ([int]$re.Code)
                Assert-True  'the re-deploy was not rolled back' (-not [bool]$re.RolledBack) $re.Tail
                # Deliberately not asserted as "updated": the vendor installer re-runs on every
                # deploy and may rewrite config.yaml from its own template, in which case our
                # writer legitimately ADDS the key instead of updating it. What must hold is the
                # value on disk below - 5s surviving a re-deploy is the bug this guards.
                Assert-Match 'the installer acted on config_apply_timeout' `
                    'config_apply_timeout' ([string]$re.SettingsMsg)
                Write-Host "  installer said: $($re.SettingsMsg)"
            }
            $cfg2 = Invoke-GuestJson -Script $ProbeConfig -ArgumentList @($SupCfg) -TimeoutSeconds 300
            if ($cfg2) {
                Assert-Equal 'the 5s value was rewritten in place' $ExpectTimeout ([string]$cfg2.config_apply_timeout_value)
                Assert-Equal 'and not duplicated' 1 ([int]$cfg2.config_apply_timeout_count)
                Assert-True  'no rollback copy left behind' (-not [bool]$cfg2.preEdit)
            }
            $rt2 = Invoke-GuestJson -Script $ProbeRuntime -ArgumentList @($SupState) -TimeoutSeconds 300
            if ($rt2) { Assert-Equal 'supervisor still Running after the repair' 'Running' ([string]$rt2.supervisor) }
        }
    }

    # ---- S10 : idempotent on a live host ---------------------------------------
    if (Want 'S10') {
        Write-PhaseHeader 'S10' 'a second re-deploy changes nothing'
        if (-not $PrivateKey) {
            Note 'S10 skipped' 'no Send-Your-Data key, so the re-deploy cannot run'
        } else {
            $re2 = Invoke-DeployInGuest -Stage $GuestStage -Key $PrivateKey -EnvBlock @{
                CX_REGION      = $Region
                CX_ENVIRONMENT = $Environment
            }
            if ($re2) {
                if ([int]$re2.Code -ne 0) {
                    Write-Host "  re-deploy exit=$($re2.Code); output tail:" -ForegroundColor Yellow
                    foreach ($ln in (($re2.Tail -split ' \| ') | Select-Object -Last 15)) { Write-Host "    $ln" -ForegroundColor DarkYellow }
                }
                Assert-Equal 'the re-deploy exited 0' 0 ([int]$re2.Code)
                # Same caveat as S9: if the vendor rewrote config.yaml this reads "added" rather
                # than "already correct". The idempotency that matters is the file state asserted
                # below - one key each, unchanged values.
                Assert-Match 'the installer acted on both settings' `
                    'passthrough_logs|config_apply_timeout|already correct' ([string]$re2.SettingsMsg)
                Write-Host "  installer said: $($re2.SettingsMsg)"
            }
            $cfg3 = Invoke-GuestJson -Script $ProbeConfig -ArgumentList @($SupCfg) -TimeoutSeconds 300
            if ($cfg3) {
                Assert-Equal 'still exactly one config_apply_timeout' 1 ([int]$cfg3.config_apply_timeout_count)
                Assert-Equal 'still exactly one passthrough_logs' 1 ([int]$cfg3.passthrough_logs_count)
                Assert-Equal 'timeout value unchanged' $ExpectTimeout ([string]$cfg3.config_apply_timeout_value)
                Assert-Match 'vendor service.name still in the vendor''s own quoting style' `
                    '^service\.name:\s*"[^"]+"$' ([string]$cfg3.serviceNameLine)
            }
        }
    }

    # ---- S11 : reboot survival -------------------------------------------------
    if (Want 'S11') {
        Write-PhaseHeader 'S11' 'the settings and the service survive a reboot'
        # 2400s, not 1200. Measured on this guest: a reboot took 24.4 MINUTES to restore the
        # guestcontrol transport, so 1200 expired while the guest was still coming back and S11
        # failed for a reason that has nothing to do with the settings it is meant to check - then
        # aborted the loop, so S12 never ran either.
        Assert-True 'guest came back from the reboot' (Restart-Guest -ReadyTimeoutSeconds 2400)
        # Poll rather than sleeping a fixed interval: the supervisor is delayed-auto-start, so it
        # legitimately appears well after the guest answers.
        $up = Invoke-GuestJson -Script {
            $ErrorActionPreference = 'Continue'
            $t = 0; $st = ''
            while ($t -lt 300) {
                $st = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
                if ($st -eq 'Running') { break }
                Start-Sleep -Seconds 5; $t += 5
            }
            [pscustomobject]@{ Status = $st; WaitedSeconds = $t } | ConvertTo-Json -Compress
        } -TimeoutSeconds 600
        if ($up) {
            Assert-Equal 'opampsupervisor is Running after the reboot' 'Running' ([string]$up.Status)
            Write-Host "  supervisor was Running after $($up.WaitedSeconds)s"
        }
        $cfg4 = Invoke-GuestJson -Script $ProbeConfig -ArgumentList @($SupCfg) -TimeoutSeconds 300
        if ($cfg4) {
            Assert-Equal 'config_apply_timeout survived the reboot' $ExpectTimeout ([string]$cfg4.config_apply_timeout_value)
            Assert-Equal 'passthrough_logs survived the reboot' 'true' ([string]$cfg4.passthrough_logs_value)
        }
        $lg2 = Invoke-GuestJson -Script $ProbeLogs -ArgumentList @($SupState, $SupCfg) -TimeoutSeconds 300
        if ($lg2 -and [int]$lg2.chars -gt 0) {
            Assert-True 'still no apply-failure line after the reboot' (-not [bool]$lg2.hasApplyFail) "matches: $($lg2.applyFailLines)"
        } elseif ($lg2) {
            Note 'post-reboot apply-failure check inconclusive' 'no supervisor log text to read'
        }
    }

    # ---- S12 : uninstall -------------------------------------------------------
    if (Want 'S12') {
        Write-PhaseHeader 'S12' 'uninstall leaves a working host'
        [void](Copy-DirToGuestAsZip -LocalDir (Join-Path $RepoRoot 'deploy') -GuestDir "$GuestStage\deploy")
        $un = Invoke-GuestFile -LocalPath (Join-Path $RepoRoot 'deploy\uninstall.bat') `
                               -GuestPath "$GuestStage\deploy\uninstall.bat" -Tail 15 -TimeoutSeconds 1200
        Write-Host "  uninstall exit=$($un.Code)"
        $gone = Invoke-GuestJson -Script {
            param($cfg)
            [pscustomobject]@{
                Supervisor = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
                Collector  = [string](Get-Service otelcol-contrib -ErrorAction SilentlyContinue).Status
                Config     = [bool](Test-Path -LiteralPath $cfg)
                PreEdit    = [bool](Test-Path -LiteralPath ($cfg + '.pre-agentdesc'))
            } | ConvertTo-Json -Compress
        } -ArgumentList @($SupCfg) -TimeoutSeconds 300
        if ($gone) {
            Assert-True 'no supervisor service remains' ([string]$gone.Supervisor -eq '') "status=$($gone.Supervisor)"
            Assert-True 'no collector service remains'  ([string]$gone.Collector -eq '')  "status=$($gone.Collector)"
            Assert-True 'no .pre-agentdesc copy left on the host' (-not [bool]$gone.PreEdit)
        }
    }

    $exitCode = Get-LoopExitCode
} catch {
    Write-Host ''
    Write-Host "LOOP ABORTED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
    $exitCode = 1
} finally {
    Write-LoopSummary -Title 'supervisor agent-settings VM loop'
    Remove-VmLoopTemp
}

exit $exitCode
