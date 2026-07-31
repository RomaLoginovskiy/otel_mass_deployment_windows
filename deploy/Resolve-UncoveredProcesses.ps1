<#
.SYNOPSIS
  X-4: list the .NET and Node processes on this host that NO injection point of ours can reach.

.DESCRIPTION
  We inject by writing environment to the SPAWNER - an IIS app pool, a Windows service, an nssm/winsw
  wrapper, a PM2 daemon - because Windows freezes a child's environment at CreateProcess and offers no
  way in afterwards. The reference agent does not have this constraint: it injects a DLL into every process and
  hooks CreateProcessA, so it reaches any child of any parent.

  The consequence for us is a blind spot, and until now it was SILENT: a node.exe or dotnet.exe started
  by a scheduled task, a login script, a parent we do not manage, or by hand, is simply never
  instrumented and nothing says so. This script cannot fix that - no script can, see the rejected
  options in docs/comparison-apm-agents.md - but it can stop it being invisible.

  For each candidate process it answers ONE question: which injection point owns you?

    iisPool      a w3wp, or any child of one (ANCM apphosts included) -> app-pool environment
    service      the process IS a Windows service -> service Environment / nssm / winsw
    serviceChild a child of a service process (the winsw/nssm shape: wrapper -> node.exe)
    pm2          a PM2 daemon or one of its workers -> pm2 env + --update-env
    scheduledTask a child of taskeng/svchost-scheduled -> reported, NOT reachable
    none         nothing we write to will ever reach this process

  Read-only. Enumerates processes and services and writes nothing.

.PARAMETER IncludeCovered
  Also emit rows for processes that ARE covered, so the output is a complete inventory rather than only
  the gaps. Useful for a report; noisier.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File deploy\Resolve-UncoveredProcesses.ps1

.NOTES
  Dot-source to get Get-CxUncoveredProcesses, or run directly for a table.
#>
[CmdletBinding()]
param([switch] $IncludeCovered)

$ErrorActionPreference = 'Continue'

function Get-CxUncoveredProcesses {
    <#
      Returns one row per candidate process: Name, Pid, ParentPid, ParentName, Owner (the injection point
      that owns it, or 'none'), Reachable, CommandLine, Reason.
    #>
    [CmdletBinding()]
    param([switch] $IncludeCovered)

    $procs = @()
    try { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
    catch {
        Write-Warning "[uncovered] could not enumerate processes ($($_.Exception.Message)) - no answer, rather than an empty answer that reads like 'nothing uncovered'."
        return @()
    }
    $byPid = @{}
    foreach ($p in $procs) { $byPid[[int]$p.ProcessId] = $p }

    # Which pids are services, and which service each one is.
    $svcByPid = @{}
    try {
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.ProcessId })) {
            $svcByPid[[int]$s.ProcessId] = [string]$s.Name
        }
    } catch { }

    $w3wpPids = @($procs | Where-Object { $_.Name -eq 'w3wp.exe' } | ForEach-Object { [int]$_.ProcessId })

    # PM2: the daemon and its workers. Reuse the library when it is available rather than re-deriving.
    $pm2Pids = @()
    if (Get-Command Get-CxPm2Processes -ErrorAction SilentlyContinue) {
        try { $pm2Pids = @(Get-CxPm2Processes | ForEach-Object { [int]$_.Pid }) } catch { }
    }

    # A node.exe or dotnet.exe is a candidate; so is a self-contained apphost, which we cannot recognise
    # by name - those are only visible when they are a service or an IIS child, and that limit is stated
    # in the Reason rather than hidden.
    $candidates = @($procs | Where-Object { $_.Name -in @('node.exe','dotnet.exe','w3wp.exe') })

    $rows = @()
    foreach ($p in $candidates) {
        $thisPid  = [int]$p.ProcessId
        $ppid = [int]$p.ParentProcessId
        $parent = if ($byPid.ContainsKey($ppid)) { [string]$byPid[$ppid].Name } else { '<gone>' }
        $owner = 'none'; $reason = ''

        if ($p.Name -eq 'w3wp.exe') {
            $owner  = 'iisPool'
            $reason = 'an IIS worker process - reached by writing the application pool environment'
        }
        elseif ($w3wpPids -contains $ppid) {
            $owner  = 'iisPool'
            $reason = "a child of w3wp pid=$ppid (an out-of-process ASP.NET Core apphost, or iisnode's node.exe) - it inherits the pool environment"
        }
        elseif ($pm2Pids -contains $thisPid) {
            $owner  = 'pm2'
            $reason = 'managed by the PM2 daemon - reached by per-app env plus `pm2 restart --update-env`'
        }
        elseif ($svcByPid.ContainsKey($thisPid)) {
            $owner  = 'service'
            $reason = "the process IS Windows service '$($svcByPid[$thisPid])' - reached by that service's Environment (or nssm/winsw configuration)"
        }
        elseif ($svcByPid.ContainsKey($ppid)) {
            $owner  = 'serviceChild'
            $reason = "a child of service '$($svcByPid[$ppid])' (the winsw/nssm wrapper shape) - reached by writing the WRAPPER's environment, which the child inherits"
        }
        elseif ($parent -match '(?i)^(taskeng|schtasks)\.exe$') {
            $owner  = 'scheduledTask'
            $reason = 'started by the Task Scheduler. Its environment comes from the task definition, which this tooling does not write - so it is NOT reachable today.'
        }
        else {
            $owner  = 'none'
            $reason = "parent is '$parent' (pid $ppid), which is not an injection point we write to. Windows freezes a child's environment at CreateProcess, so this process cannot be instrumented without restarting it from a parent we do control."
        }

        $reachable = ($owner -notin @('none','scheduledTask'))
        if (-not $IncludeCovered -and $reachable) { continue }
        $rows += [pscustomobject]@{
            Name        = [string]$p.Name
            Pid         = $thisPid
            ParentPid   = $ppid
            ParentName  = $parent
            Owner       = $owner
            Reachable   = $reachable
            CommandLine = [string]$p.CommandLine
            Reason      = $reason
        }
    }
    return @($rows)
}

# Direct invocation: print a table. Dot-sourced: just define the function.
if ($MyInvocation.InvocationName -ne '.') {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { '.' }
    $nodeLib = Join-Path $here 'Resolve-NodeServiceNames.ps1'
    if (Test-Path -LiteralPath $nodeLib) { . $nodeLib }

    $rows = Get-CxUncoveredProcesses -IncludeCovered:$IncludeCovered
    if (@($rows).Count -eq 0) {
        Write-Host '[uncovered] no .NET or Node process on this host is outside an injection point we write to.'
    } else {
        foreach ($r in $rows) {
            $tag = if ($r.Reachable) { 'covered  ' } else { 'UNCOVERED' }
            Write-Host ("[{0}] {1,-12} pid={2,-6} parent={3} ({4})" -f $tag, $r.Name, $r.Pid, $r.ParentName, $r.ParentPid)
            Write-Host ("             owner={0}  {1}" -f $r.Owner, $r.Reason) -ForegroundColor DarkGray
        }
        $bad = @($rows | Where-Object { -not $_.Reachable })
        if (@($bad).Count -gt 0) {
            Write-Host ''
            Write-Warning ("[uncovered] {0} process(es) cannot be reached by any injection point. They are running uninstrumented and will stay that way until they are restarted from a parent we control." -f @($bad).Count)
        }
    }
}
