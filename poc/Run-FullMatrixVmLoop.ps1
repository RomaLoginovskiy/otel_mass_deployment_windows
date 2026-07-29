<#
.SYNOPSIS
  Full-matrix end-to-end validation against a real Windows guest: every workload shape the fleet
  runs, in BOTH install modes, with health and telemetry gated. Exit code = failed assertions.

.DESCRIPTION
  This is the harness that had to exist. Every test\docker-win runner installs with
  CX_NO_SUPERVISOR=1, because the vendor installer cannot fetch the collector MSI in a Server Core
  container - so no automated test has ever run a collector at all, in either mode. The supervisor
  loop (Run-SupervisorVmLoop.ps1) covers the AgentDescription/config half of supervisor mode; this
  covers the whole matrix:

    * IIS across four runtime/CLR combinations: ASP.NET Core 8 (in-process and out-of-process),
      ASP.NET Core 6 side by side, ASP.NET Framework 4.8, and a CLR 2.0 pool as a REFUSAL case
    * the 14 IIS classification shapes (test\docker-win\entrypoint.e2e.ps1, shared with the
      container matrix so the two cannot drift)
    * Node under PM2: per-user fork, ESM, and service-hosted daemons
    * Node as a plain Windows service with no PM2, and a .NET worker service - the two shapes the
      new Instrument-NodeService.ps1 / Instrument-DotNetService.ps1 handle
    * IIS ARR reverse-proxying to a PM2 app, where the IIS side is correctly NOT claimed and the
      Node side carries the telemetry

  Both modes are asserted for what makes them different, not just for "something is running":
  supervisor mode must have opampsupervisor supervising a collector child and must survive a
  reboot; -NoSupervisor mode must have otelcol-contrib and NO supervisor anywhere.

  Telemetry is gated by QUERYING Coralogix, never by reading a UI: a span count is the only proof
  that instrumentation took effect, and "the service is Running" has already been shown to be
  compatible with a host that emits nothing.

.PARAMETER Mode
  supervisor    - deploy.bat with no CX_NO_SUPERVISOR (the fleet default)
  nosupervisor  - deploy.bat with CX_NO_SUPERVISOR=1

.PARAMETER Phase
  Subset of phases to run, e.g. -Phase P4,P7. Default: all. P0 always runs (it establishes the
  transport). NOTE: `powershell -File ... -Phase P4,P7` delivers ONE string, so it is re-split
  here - without that the run silently does nothing and exits 0.

.PARAMETER VmName
  The guest. It is treated as DISPOSABLE: this harness installs runtimes, creates services and
  local accounts, rewrites IIS, and reboots it.

.PARAMETER PrivateKey
  Coralogix Send-Your-Data key for the install. Defaults to CORALOGIX_PRIVATE_KEY, then to
  artifacs\SendDataKey.txt if present. Without one, P3 onwards are skipped rather than failed.

.PARAMETER QueryKeyFile
  Coralogix QUERY key for the telemetry phase (querydata_key.txt at the repo root by default).
  Without it P7 is skipped - and reported as skipped, so a run that proved nothing cannot read as
  a pass.

.EXAMPLE
  .\poc\Run-FullMatrixVmLoop.ps1 -Mode supervisor   -VmName cx-e2e-c1 -Region eu1
  .\poc\Run-FullMatrixVmLoop.ps1 -Mode nosupervisor -VmName cx-e2e-c2 -Region eu1

.NOTES
  Never point this at a production host, or at a VM you care about. Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('supervisor','nosupervisor')] [string] $Mode,
    [string]   $VmName        = 'cx-e2e-c1',
    [string]   $User          = 'Administrator',
    [string]   $Password      = 'Otel!Passw0rd2026',
    [string]   $RepoRoot      = $null,
    # Where the BAKED guest assets live (node.zip, npm-global, otel-dotnet.zip, otel-node). They are
    # gitignored - multi-GB binaries and host-installed node_modules - so they are not in a fresh
    # clone or a worktree, and the machine that has them is not necessarily the one holding the
    # branch under test. Defaults to this repo's test\docker-win; point it elsewhere when the assets
    # were baked in another checkout. Missing assets skip the shapes that need them, with a note.
    [string]   $AssetRoot     = $null,
    # Deliberately NOT C:\cx-deploy. A guest that has ever been deployed to by hand already has a
    # payload there, and deploy.bat runs "%~dp0Install-Agent.ps1" - the scripts next to ITSELF - so a
    # stale copy silently shadows the branch under test. Every P3/P4/P5 result in an earlier run of
    # this matrix described the guest's OLD scripts for exactly that reason.
    [string]   $GuestStage    = 'C:\cx-matrix',
    [string]   $GuestFixtures = 'C:\cx-fixtures',
    [string]   $PrivateKey    = $env:CORALOGIX_PRIVATE_KEY,
    [string]   $Region        = 'eu1',
    [string]   $Environment   = 'vm-matrix',
    [string]   $QueryKeyFile  = $null,
    [string[]] $Phase         = @(),
    [string]   $HostRename    = $null,     # empty = derive from the VM name
    [switch]   $SkipReboot,
    [switch]   $KeepState,
    # Take a 'matrix-clean' snapshot in P0. Off by default: see New-VmSnapshot in VmLoop.Common.ps1
    # for why snapshotting a running guest is the riskiest thing this harness can do on this host.
    [switch]   $TakeSnapshot,
    [int]      $IngestWaitSeconds = 240
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $here }
if (-not $AssetRoot) { $AssetRoot = Join-Path $RepoRoot 'test\docker-win' }
. (Join-Path $here 'VmLoop.Common.ps1')

# `-Phase P4,P7` through `powershell -File` arrives as a single "P4,P7" string. Re-split, or the
# run quietly does nothing and exits 0 - which looks exactly like a clean pass.
$Phase = @($Phase | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
function Want { param([string] $P) return (($Phase.Count -eq 0) -or ($Phase -contains $P)) }

if (-not $PrivateKey) {
    foreach ($c in @((Join-Path $RepoRoot 'artifacs\SendDataKey.txt'),
                     (Join-Path $RepoRoot 'deploy\SendDataKey.txt'),
                     (Join-Path $RepoRoot 'SimpleWebApp\coralogix\SendDataKey.txt'))) {
        if ((Test-Path $c) -and (Get-Content $c -Raw).Trim()) { $PrivateKey = (Get-Content $c -Raw).Trim(); break }
    }
}
if (-not $QueryKeyFile) {
    foreach ($c in @((Join-Path $RepoRoot 'querydata_key.txt'), (Join-Path $RepoRoot 'deploy\querydata_key.txt'))) {
        if (Test-Path $c) { $QueryKeyFile = $c; break }
    }
}
if (-not $HostRename) {
    # host.name is the join key for every telemetry assertion, and two clones of one image share a
    # computer name - so each guest is renamed after its VM. Windows caps NetBIOS names at 15.
    $HostRename = ($VmName -replace '[^A-Za-z0-9-]', '-')
    if ($HostRename.Length -gt 15) { $HostRename = $HostRename.Substring(0, 15) }
}

Write-Host ''
Write-Host "=== full-matrix VM loop : $VmName : mode=$Mode ===" -ForegroundColor Cyan
Write-Host "    region=$Region environment=$Environment rename-to=$HostRename"
Write-Host "    send key: $(if ($PrivateKey) { 'present' } else { 'MISSING (P3+ will be skipped)' })"
Write-Host "    query key file: $(if ($QueryKeyFile) { $QueryKeyFile } else { 'MISSING (P7 will be skipped)' })"

# Names the shapes will use. Kept here so the assertions and the provisioning cannot disagree.
$svcNames = [ordered]@{
    Net8      = 'coreweb-net8'
    Net8Oop   = 'coreweb-net8-oop'
    Net6      = 'coreweb-net6'
    Fw48      = 'fw48app'
    Clr2      = 'clr2app'          # expected to be classified and NOT claimed
    NodeSvc   = 'cxnodesvc'
    DotnetSvc = 'cxworkersvc'
}

$exitCode = 1
try {
    # ---- P0 : transport, guest, snapshot ---------------------------------------
    Write-PhaseHeader 'P0' 'transport and guest baseline'
    Assert-True 'VBoxManage present' ((VBoxSoft --version) -match '^\d')
    [void](Initialize-VmLoop -VmName $VmName -User $User -Password $Password -GuestStage $GuestStage)
    Assert-True "VM '$VmName' is registered" (Test-VmExists)
    if (-not (Test-VmRunning)) { [void](Start-VmHeadless) }
    Assert-True "VM '$VmName' is running" (Test-VmRunning)

    $ready = Wait-GuestReady -TimeoutSeconds 1200
    Assert-True 'guestcontrol reaches the guest' $ready 'Guest Additions not answering, or wrong -User/-Password'
    if (-not $ready) { throw 'no guest transport - nothing else can be asserted' }

    $who = Invoke-GuestJson -Script {
        [pscustomobject]@{
            Host    = $env:COMPUTERNAME
            Admin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            Os      = (Get-CimInstance Win32_OperatingSystem).Caption
            PsVer   = $PSVersionTable.PSVersion.ToString()
        } | ConvertTo-Json -Compress
    }
    Assert-True 'guest session is elevated' ([bool]$who.Admin) "IsInRole=$($who.Admin)"
    Write-Host "  guest: $($who.Host) / $($who.Os) / PS $($who.PsVer)"

    # The transport must carry hostile values VERBATIM. Without this assertion a harness bug can
    # produce a green run about a value the fleet never sees - that has happened here before, with
    # JSON escaping silently doubling backslashes.
    $hostile = 'C:\ProgramData\pm2|NT AUTHORITY\LocalService|it''s "quoted"'
    $echo = Invoke-Guest -Script { param($v) "ECHO:$v" } -ArgumentList @($hostile)
    Assert-Equal 'transport carries backslashes and quotes verbatim' "ECHO:$hostile" $echo

    # host.name is the join key for the telemetry phase, so a clone must not keep its parent's name.
    if ($who.Host -ne $HostRename) {
        Write-Host "  renaming guest $($who.Host) -> $HostRename (host.name is the telemetry join key)"
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
        $after = Invoke-Guest -Script { $env:COMPUTERNAME }
        Assert-Equal 'guest now carries the expected host name' $HostRename $after
    } else {
        Write-Host '  guest already carries the expected name'
    }

    # Opt-in, not default. A snapshot here is a convenience for re-running phases, but taking one
    # is the single most dangerous thing this phase can do: on this host it wedged the guest and
    # then corrupted its machine registration (see New-VmSnapshot). The matrix does not need it.
    if ($TakeSnapshot) {
        $snapOk = New-VmSnapshot -SnapshotName 'matrix-clean' -IfMissing
        Assert-True 'baseline snapshot taken (or already present)' ([bool]$snapOk) 'snapshot failed - continuing without one'
        Assert-True 'guest still answers after snapshotting' (Wait-GuestReady -TimeoutSeconds 300) `
            'the snapshot left the VM in a state where guestcontrol does not answer'
    }

    # A clone of a host that already had the agent is not a clean baseline. Uninstall first so P3
    # is a real install rather than an upgrade over whatever the image happened to carry.
    $pre = Invoke-GuestJson -Script {
        [pscustomobject]@{
            Supervisor = [bool](Get-Service opampsupervisor -ErrorAction SilentlyContinue)
            Collector  = [bool](Get-Service otelcol-contrib -ErrorAction SilentlyContinue)
        } | ConvertTo-Json -Compress
    }
    if ($pre -and ($pre.Supervisor -or $pre.Collector)) {
        Write-Host '  guest already carries an agent - uninstalling to get a clean baseline'
        # The payload has to be in place first: uninstall.bat, like deploy.bat, resolves its scripts
        # with %~dp0, so it must sit beside the Uninstall-Agent.ps1 it is meant to run.
        [void](Copy-DirToGuestAsZip -LocalDir (Join-Path $RepoRoot 'deploy') -GuestDir "$GuestStage\deploy")
        $un = Invoke-GuestFile -LocalPath (Join-Path $RepoRoot 'deploy\uninstall.bat') `
                               -GuestPath "$GuestStage\deploy\uninstall.bat" -Tail 12 -TimeoutSeconds 900
        Write-Host "  uninstall exit=$($un.Code)"
        $post = Invoke-GuestJson -Script {
            [pscustomobject]@{
                Supervisor = [bool](Get-Service opampsupervisor -ErrorAction SilentlyContinue)
                Collector  = [bool](Get-Service otelcol-contrib -ErrorAction SilentlyContinue)
            } | ConvertTo-Json -Compress
        }
        Assert-True 'baseline is clean: no collector service before the install phase' `
            (-not ($post.Supervisor -or $post.Collector)) "supervisor=$($post.Supervisor) collector=$($post.Collector)"
    } else {
        Assert-True 'baseline is clean: no collector service before the install phase' $true
    }

    # ---- P1 : prerequisites ----------------------------------------------------
    if (Want 'P1') {
        Write-PhaseHeader 'P1' 'guest prerequisites (runtimes, IIS, ARR, node, pm2)'

        # Stage everything the guest needs. node.zip / npm-global / otel-dotnet.zip are only present
        # on a machine that has built the container harnesses; each is reported rather than assumed.
        $stage = 'C:\cx-stage'
        # Baked binaries come from -AssetRoot; text fixtures come from the branch under test, so the
        # shapes are always the ones in this checkout even when the assets were baked elsewhere.
        $assets = @(
            @{ Local = (Join-Path $AssetRoot 'node.zip');        Guest = "$stage\node.zip";        Kind = 'file' }
            @{ Local = (Join-Path $AssetRoot 'otel-dotnet.zip'); Guest = "$stage\otel-dotnet.zip"; Kind = 'file' }
            @{ Local = (Join-Path $AssetRoot 'npm-global');      Guest = "$stage\npm-global";      Kind = 'dir'  }
            # The OTel Node package, staged rather than npm-installed in the guest: npm on a Server
            # SKU hits an intermittent OpenSSL AES-GCM fault, and both Node instrumenters resolve
            # their bootstrap out of this prefix.
            @{ Local = (Join-Path $AssetRoot 'otel-node');       Guest = 'C:\cx\otel-node';        Kind = 'dir'  }
            @{ Local = (Join-Path $RepoRoot 'test\docker-win\nodeshapes\apps');        Guest = 'C:\cx\nodeshapes\apps';        Kind = 'dir' }
            # The app fixtures require pino, so they need node_modules or every Node shape dies with
            # MODULE_NOT_FOUND - which is exactly how the node-as-a-service shape first failed here,
            # with the service installed and immediately Stopped. Dockerfile.nodeshapes solves it by
            # copying nodeapp/node_modules to the PARENT of the app directories (Node resolves
            # upward, so one copy serves cjs/esm/mjs); this mirrors that placement deliberately.
            @{ Local = (Join-Path $AssetRoot 'nodeapp\node_modules');                  Guest = 'C:\cx\nodeshapes\apps\node_modules'; Kind = 'dir' }
            @{ Local = (Join-Path $RepoRoot 'test\docker-win\nodeshapes\pm2-service'); Guest = 'C:\cx\nodeshapes\pm2-service'; Kind = 'dir' }
            @{ Local = (Join-Path $RepoRoot 'test\fixtures\out');               Guest = $GuestFixtures;           Kind = 'dir'  }
        )
        foreach ($a in $assets) {
            if (-not (Test-Path $a.Local)) { Note "asset missing: $(Split-Path -Leaf $a.Local)" "expected at $($a.Local) - the shapes that need it will be skipped"; continue }
            Write-Host "  staging $(Split-Path -Leaf $a.Local) -> $($a.Guest)"
            # Directories go in as ONE archive: guestcontrol copies file by file, and otel-node alone
            # is ~71 MB of thousands of tiny node_modules files. It also removes the partial-copy
            # failure mode, where a tree arrives a few files short and only fails much later.
            if ($a.Kind -eq 'dir') { [void](Copy-DirToGuestAsZip -LocalDir $a.Local -GuestDir $a.Guest) }
            else { Copy-ToGuest -LocalPath $a.Local -GuestPath $a.Guest }
        }

        $prereq = Invoke-GuestFile -LocalPath (Join-Path $here 'Install-GuestPrereqs.ps1') `
                                   -Arguments @('-Stage', $stage) -Tail 6 -TimeoutSeconds 3600
        Write-Host "  prereq installer exit=$($prereq.Code)"

        $env1 = Invoke-GuestJson -Script {
            $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
            $mods = if (Test-Path $appcmd) { (& $appcmd list module 2>&1) -join ' ' } else { '' }
            $runtimes = @()
            try { $runtimes = @(& dotnet --list-runtimes 2>&1 | ForEach-Object { "$_" }) } catch { }
            [pscustomobject]@{
                Iis       = [bool]((Get-Service W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running')
                Ancm      = [bool]($mods -match 'AspNetCoreModuleV2')
                Rewrite   = [bool]($mods -match 'RewriteModule')
                Net8      = [bool](($runtimes -join ' ') -match 'Microsoft\.AspNetCore\.App 8\.')
                Net6      = [bool](($runtimes -join ' ') -match 'Microsoft\.AspNetCore\.App 6\.')
                Net35     = [bool]((Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue).Installed)
                # $(if ...) not (if ...): in Windows PowerShell 5.1 the bare parenthesised form
                # PARSES fine and then fails at runtime with "The term 'if' is not recognized",
                # because it is read as a command invocation. It would have reported node as absent.
                Node      = $(if (Test-Path 'C:\nodejs\node.exe') { (& 'C:\nodejs\node.exe' --version 2>&1 | Select-Object -First 1) } else { '' })
                Pm2       = [bool](Test-Path 'C:\npm-global\pm2.cmd')
                OtelZip   = [bool](Test-Path 'C:\cx-stage\otel-dotnet.zip')
                Fixtures  = @(Get-ChildItem 'C:\cx-fixtures' -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            } | ConvertTo-Json -Compress
        }
        if ($env1) {
            Assert-True 'IIS running'                        ([bool]$env1.Iis)
            Assert-True 'ASP.NET Core Module (ANCM) present'  ([bool]$env1.Ancm) 'no AspNetCoreModuleV2 - every Core shape would 500 with no telemetry'
            Assert-True 'ASP.NET Core 8 runtime present'      ([bool]$env1.Net8)
            Assert-True 'ASP.NET Core 6 runtime present'      ([bool]$env1.Net6) 'the side-by-side case cannot be tested without it'
            Assert-True 'node present'                        ([bool]$env1.Node) "node --version returned '$($env1.Node)'"
            Assert-True 'pm2 CLI present'                     ([bool]$env1.Pm2)
            Assert-True 'otel-dotnet payload staged'          ([bool]$env1.OtelZip)
            if (-not $env1.Rewrite) { Note 'URL Rewrite / ARR not installed' 'the IIS->PM2 proxy shape will be provisioned but cannot be verified' }
            if (-not $env1.Net35)   { Note '.NET 3.5 not installed' 'the CLR 2.0 refusal case cannot be provisioned' }
            Assert-True 'app fixtures staged' (@($env1.Fixtures).Count -ge 3) "found: $(@($env1.Fixtures) -join ', ')"
            Write-Host "  node=$($env1.Node) fixtures=$(@($env1.Fixtures) -join ',')"
        } else {
            Assert-True 'prerequisite report parsed' $false 'guest returned no JSON'
        }
    }

    # ---- P2 : shapes -----------------------------------------------------------
    if (Want 'P2') {
        Write-PhaseHeader 'P2' 'provision every workload shape'

        # 14 IIS classification shapes, from the SAME script the container matrix uses.
        $shapes = Invoke-GuestFile -LocalPath (Join-Path $RepoRoot 'test\docker-win\entrypoint.e2e.ps1') `
                                   -Arguments @('-NoWait') -Tail 8 -TimeoutSeconds 1200
        Assert-True 'IIS classification shapes provisioned' ($shapes.Code -eq 0) "exit=$($shapes.Code): $($shapes.Out)"

        # The four runtime apps that actually emit, plus the two services.
        $apps = Invoke-GuestJson -Script {
            param($fixtures, $names)
            $ErrorActionPreference = 'Continue'
            Import-Module WebAdministration -ErrorAction Stop
            $out = [ordered]@{}
            $n = $names | ConvertFrom-Json

            function New-Site {
                param([string] $Name, [string] $Physical, [int] $Port, [string] $Pool, [string] $ManagedRuntime = '', [bool] $NoManagedCode = $false)
                if (-not (Test-Path "IIS:\AppPools\$Pool")) { New-WebAppPool -Name $Pool | Out-Null }
                if ($NoManagedCode)      { Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedRuntimeVersion -Value '' }
                elseif ($ManagedRuntime) { Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedRuntimeVersion -Value $ManagedRuntime }
                if (-not (Get-Website -Name $Name -ErrorAction SilentlyContinue)) {
                    New-Website -Name $Name -PhysicalPath $Physical -Port $Port -ApplicationPool $Pool -Force | Out-Null
                } else {
                    Set-ItemProperty "IIS:\Sites\$Name" -Name applicationPool -Value $Pool
                    Set-ItemProperty "IIS:\Sites\$Name" -Name physicalPath    -Value $Physical
                }
                Start-Website -Name $Name -ErrorAction SilentlyContinue
            }

            # ASP.NET Core 8, in-process: the ordinary case. Pool is No Managed Code, as recommended.
            if (Test-Path "$fixtures\coreweb-net8") {
                New-Site -Name $n.Net8 -Physical "$fixtures\coreweb-net8" -Port 8801 -Pool $n.Net8 -NoManagedCode $true
                $out['net8'] = 'provisioned'
            }
            # The same net8 publish hosted OUT-OF-PROCESS: ANCM launches dotnet.exe as a child of
            # w3wp, which DOES inherit the pool environment - the opposite verdict to an ARR proxy.
            if (Test-Path "$fixtures\coreweb-net8") {
                $oopDir = "$fixtures\coreweb-net8-oop"
                if (-not (Test-Path $oopDir)) { Copy-Item "$fixtures\coreweb-net8" $oopDir -Recurse -Force }
                $cfg = Join-Path $oopDir 'web.config'
                if (Test-Path $cfg) {
                    [xml]$doc = Get-Content $cfg -Raw
                    $node = $doc.SelectSingleNode('//aspNetCore')
                    if ($node) { $node.SetAttribute('hostingModel', 'outofprocess') ; $doc.Save($cfg) }
                }
                New-Site -Name $n.Net8Oop -Physical $oopDir -Port 8802 -Pool $n.Net8Oop -NoManagedCode $true
                $out['net8oop'] = 'provisioned'
            }
            if (Test-Path "$fixtures\coreweb-net6") {
                New-Site -Name $n.Net6 -Physical "$fixtures\coreweb-net6" -Port 8803 -Pool $n.Net6 -NoManagedCode $true
                $out['net6'] = 'provisioned'
            }
            # ASP.NET Framework 4.8 on a v4.0 pool - runtime-compiled .aspx, no build needed.
            if (Test-Path "$fixtures\fw48") {
                New-Site -Name $n.Fw48 -Physical "$fixtures\fw48" -Port 8804 -Pool $n.Fw48 -ManagedRuntime 'v4.0'
                $out['fw48'] = 'provisioned'
            }
            # CLR 2.0: the refusal case. Only meaningful when .NET 3.5 is actually installed.
            if (Test-Path "$fixtures\clr2") {
                $net35 = [bool]((Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue).Installed)
                if ($net35) {
                    New-Site -Name $n.Clr2 -Physical "$fixtures\clr2" -Port 8805 -Pool $n.Clr2 -ManagedRuntime 'v2.0'
                    $out['clr2'] = 'provisioned'
                } else { $out['clr2'] = 'skipped: no .NET 3.5' }
            }

            # Node as a Windows service with NO pm2, via winsw from node-windows.
            $winsw = 'C:\npm-global\node_modules\node-windows\bin\winsw\winsw.exe'
            $appJs = 'C:\cx\nodeshapes\apps\cjs\server.js'
            if ((Test-Path $winsw) -and (Test-Path $appJs)) {
                $svcDir = 'C:\cx\nodesvc'
                New-Item -ItemType Directory -Path $svcDir -Force | Out-Null
                Copy-Item $winsw (Join-Path $svcDir 'cxnodesvc.exe') -Force
                @"
<service>
  <id>$($n.NodeSvc)</id>
  <name>$($n.NodeSvc)</name>
  <description>Node app as a Windows service, no PM2 (E2E fixture)</description>
  <executable>C:\nodejs\node.exe</executable>
  <argument>$appJs</argument>
  <env name="PORT" value="8901"/>
  <logpath>$svcDir</logpath>
  <logmode>rotate</logmode>
</service>
"@ | Set-Content -LiteralPath (Join-Path $svcDir 'cxnodesvc.xml') -Encoding utf8
                & (Join-Path $svcDir 'cxnodesvc.exe') install 2>&1 | Out-Null
                Start-Service $n.NodeSvc -ErrorAction SilentlyContinue
                $out['nodeSvc'] = [string](Get-Service $n.NodeSvc -ErrorAction SilentlyContinue).Status
            } else { $out['nodeSvc'] = 'skipped: winsw or app fixture missing' }

            # The .NET worker service.
            if (Test-Path "$fixtures\workersvc\cxworkersvc.exe") {
                $exe = "$fixtures\workersvc\cxworkersvc.exe"
                if (-not (Get-Service $n.DotnetSvc -ErrorAction SilentlyContinue)) {
                    & sc.exe create $n.DotnetSvc binPath= "`"$exe`"" start= auto DisplayName= $n.DotnetSvc | Out-Null
                }
                # Point it at a local IIS fixture so its outbound call produces a client span.
                & sc.exe failure $n.DotnetSvc reset= 86400 actions= restart/10000 | Out-Null
                $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($n.DotnetSvc)"
                $existing = @()
                try { $existing = @((Get-ItemProperty -LiteralPath $key -Name Environment -ErrorAction Stop).Environment) } catch { }
                $keep = @($existing | Where-Object { $_ -and $_ -notmatch '^CX_WORKER_' })
                Set-ItemProperty -LiteralPath $key -Name Environment -Type MultiString `
                    -Value ([string[]](@($keep) + @('CX_WORKER_TARGET=http://127.0.0.1:8801/ping', 'CX_WORKER_INTERVAL=10')))
                Start-Service $n.DotnetSvc -ErrorAction SilentlyContinue
                $out['dotnetSvc'] = [string](Get-Service $n.DotnetSvc -ErrorAction SilentlyContinue).Status
            } else { $out['dotnetSvc'] = 'skipped: workersvc fixture missing' }

            [pscustomobject]$out | ConvertTo-Json -Compress
        } -ArgumentList @($GuestFixtures, ($svcNames | ConvertTo-Json -Compress)) -TimeoutSeconds 1200

        if ($apps) {
            foreach ($k in @('net8','net8oop','net6','fw48')) {
                Assert-Equal "$k app provisioned" 'provisioned' ([string]$apps.$k)
            }
            if ([string]$apps.clr2 -like 'skipped*') { Note 'clr2 shape skipped' ([string]$apps.clr2) }
            else { Assert-Equal 'clr2 app provisioned (refusal case)' 'provisioned' ([string]$apps.clr2) }
            if ([string]$apps.nodeSvc -like 'skipped*') { Note 'node service shape skipped' ([string]$apps.nodeSvc) }
            else { Assert-Equal 'node-as-service is Running' 'Running' ([string]$apps.nodeSvc) }
            if ([string]$apps.dotnetSvc -like 'skipped*') { Note '.NET service shape skipped' ([string]$apps.dotnetSvc) }
            else { Assert-Equal '.NET worker service is Running' 'Running' ([string]$apps.dotnetSvc) }
        } else {
            Assert-True 'shape provisioning report parsed' $false 'guest returned no JSON'
        }

        # PM2 shapes come from the container harness's own fixture script, so the two matrices agree.
        $nodeShape = Join-Path $RepoRoot 'test\docker-win\setup-nodeshape.ps1'
        if (Test-Path $nodeShape) {
            $r = Invoke-GuestFile -LocalPath $nodeShape -Arguments @('-Case','pm2UserFork') -Tail 6 -TimeoutSeconds 900
            Assert-True 'PM2 per-user fork shape provisioned' ($r.Code -eq 0) "exit=$($r.Code): $($r.Out)"
        } else {
            Note 'setup-nodeshape.ps1 missing' 'PM2 shapes not provisioned'
        }

        # Every app must answer locally BEFORE the agent is installed: a 500 here would otherwise
        # be mistaken for an instrumentation failure three phases later.
        $http = Invoke-GuestJson -Script {
            $urls = [ordered]@{
                net8    = 'http://127.0.0.1:8801/work'
                net8oop = 'http://127.0.0.1:8802/work'
                net6    = 'http://127.0.0.1:8803/work'
                fw48    = 'http://127.0.0.1:8804/Default.aspx?work=1'
                clr2    = 'http://127.0.0.1:8805/Default.aspx'
                nodesvc = 'http://127.0.0.1:8901/'
            }
            $out = [ordered]@{}
            foreach ($k in $urls.Keys) {
                try {
                    $r = Invoke-WebRequest -Uri $urls[$k] -UseBasicParsing -TimeoutSec 20
                    $out[$k] = [int]$r.StatusCode
                } catch {
                    $code = 0
                    try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch { }
                    $out[$k] = $code
                }
            }
            [pscustomobject]$out | ConvertTo-Json -Compress
        } -TimeoutSeconds 600
        if ($http) {
            foreach ($k in @('net8','net8oop','net6','fw48')) {
                Assert-Equal "$k answers HTTP 200 locally" 200 ([int]$http.$k)
            }
            # clr2 is the REFUSAL case, and its contract is about classification, not about serving:
            # it must be classified, must NOT be claimed in CX_IIS_SERVICES, and must produce no
            # telemetry (asserted in P5 and P7). Whether ASP.NET 2.0 is even mapped to *.aspx on the
            # host is a property of the host, so a 404 here is reported rather than failed - it means
            # the handler mapping is absent (aspnet_regiis never ran), not that the shape is wrong.
            if ([int]$http.clr2 -eq 200)      { Assert-True 'clr2 answers HTTP 200 locally' $true }
            elseif ([int]$http.clr2 -eq 404)  { Note 'clr2 serves 404' 'ASP.NET 2.0 is not mapped to *.aspx on this host, so the CLR-2 app is not executing managed code. The not-claimed and no-telemetry assertions still apply and are the point of this shape.' }
            else                              { Assert-Equal 'clr2 answers locally (200, or 404 = unmapped)' 200 ([int]$http.clr2) }
            if ([int]$http.nodesvc -ne 0) { Assert-Equal 'node service answers HTTP 200 locally' 200 ([int]$http.nodesvc) }
        }
    }

    # ---- P3 : deploy in the mode under test ------------------------------------
    if (Want 'P3') {
        Write-PhaseHeader 'P3' "deploy.bat ($Mode)"
        if (-not $PrivateKey) {
            Note 'P3 skipped' 'no Send-Your-Data key (-PrivateKey / CORALOGIX_PRIVATE_KEY / artifacs\SendDataKey.txt)'
        } else {
            # Stage the CURRENT working tree, always overwriting: a stale C:\cx-deploy copy means
            # testing last week's code while believing otherwise.
            # One directory, as an archive, and deploy.bat is RUN FROM INSIDE it - never copied to
            # the parent. deploy.bat resolves its scripts with %~dp0, so a deploy.bat sitting one
            # level up executes whatever Install-Agent.ps1 happens to be beside it, which on a guest
            # with an inherited payload is last month's code.
            [void](Copy-DirToGuestAsZip -LocalDir (Join-Path $RepoRoot 'deploy') -GuestDir "$GuestStage\deploy")

            # Prove the payload deploy.bat will use is the one under test, before running it. A
            # marker carrying this checkout's HEAD is written next to the scripts and read back.
            $headSha = ''
            try { $headSha = (& git -C $RepoRoot rev-parse --short HEAD 2>$null | Out-String).Trim() } catch { }
            if (-not $headSha) { $headSha = 'nogit-' + (Get-Date -Format 'yyyyMMddHHmmss') }
            $markerLocal = Join-Path $script:VmlHostStage 'cx-payload-id.txt'
            Set-Content -LiteralPath $markerLocal -Value $headSha -Encoding Ascii -NoNewline
            Copy-ToGuest -LocalPath $markerLocal -GuestPath "$GuestStage\deploy\cx-payload-id.txt"

            $payload = Invoke-GuestJson -Script {
                param($stage)
                $dir = "$stage\deploy"
                [pscustomobject]@{
                    Marker   = $(if (Test-Path "$dir\cx-payload-id.txt") { (Get-Content "$dir\cx-payload-id.txt" -Raw).Trim() } else { '' })
                    HasBat   = (Test-Path "$dir\deploy.bat")
                    HasAgent = (Test-Path "$dir\Install-Agent.ps1")
                    # Only the payload's own ENTRY POINTS can shadow: deploy.bat resolves
                    # Install-Agent.ps1 / Uninstall-Agent.ps1 next to itself. The harness's own
                    # transport step scripts also live at this level (step-N.ps1, wrap-N.ps1) and are
                    # harmless - counting them turned a correct staging into a failure.
                    ParentPs1 = @(Get-ChildItem $stage -Filter '*.ps1' -ErrorAction SilentlyContinue |
                                  Where-Object { $_.Name -in @('Install-Agent.ps1','Uninstall-Agent.ps1') }).Count
                } | ConvertTo-Json -Compress
            } -ArgumentList @($GuestStage) -TimeoutSeconds 300
            if ($payload) {
                Assert-Equal 'the guest is running THIS checkout''s payload' $headSha ([string]$payload.Marker)
                Assert-True  'deploy.bat and Install-Agent.ps1 are in the same directory' `
                    (([bool]$payload.HasBat) -and ([bool]$payload.HasAgent)) "bat=$($payload.HasBat) agent=$($payload.HasAgent)"
                Assert-Equal 'no shadowing scripts at the stage root' 0 ([int]$payload.ParentPs1)
            }

            $envBlock = @{
                CX_REGION      = $Region
                CX_ENVIRONMENT = $Environment
            }
            if ($Mode -eq 'nosupervisor') { $envBlock['CX_NO_SUPERVISOR'] = '1' }

            $deploy = Invoke-GuestJson -Script {
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
                    Collector  = [string](Get-Service otelcol-contrib -ErrorAction SilentlyContinue).Status
                    Marker     = [bool](($out -join ' ') -match 'SupervisorCollectorBaseConfig|-Supervisor\b')
                    ConfigArg  = [bool](($out -join ' ') -match '-Config\b')
                    Exception  = [bool](($out -join ' ') -match 'FullyQualifiedErrorId')
                    Tail       = (($out | Select-Object -Last 12) -join ' | ')
                } | ConvertTo-Json -Compress
            } -ArgumentList @($GuestStage, $PrivateKey, ($envBlock | ConvertTo-Json -Compress)) -TimeoutSeconds 3600

            if (-not $deploy) {
                Assert-True 'deploy.bat produced a parsable result' $false 'no JSON from the guest'
            } else {
                Assert-Equal 'deploy.bat exited 0' 0 ([int]$deploy.Code)
                Assert-True  'no unhandled exception in the deploy output' (-not [bool]$deploy.Exception) $deploy.Tail
                if ($Mode -eq 'supervisor') {
                    Assert-True  'installer took the SUPERVISOR path' ([bool]$deploy.Marker) $deploy.Tail
                    Assert-Equal 'opampsupervisor is Running' 'Running' ([string]$deploy.Supervisor)
                } else {
                    Assert-True  'installer took the -Config path'    ([bool]$deploy.ConfigArg) $deploy.Tail
                    Assert-Equal 'otelcol-contrib is Running'         'Running' ([string]$deploy.Collector)
                    Assert-True  'NO supervisor service in this mode' ([string]$deploy.Supervisor -eq '') "supervisor status=$($deploy.Supervisor)"
                }
            }
        }
    }

    # ---- P4 : health -----------------------------------------------------------
    if (Want 'P4') {
        Write-PhaseHeader 'P4' 'collector and supervisor health'
        $health = Invoke-GuestJson -Script {
            $ErrorActionPreference = 'Continue'
            $out = [ordered]@{}
            $out['supervisor'] = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
            $out['collector']  = [string](Get-Service otelcol-contrib -ErrorAction SilentlyContinue).Status
            $out['supStart']   = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).StartType
            $out['otelChild']  = @(Get-Process otelcol* -ErrorAction SilentlyContinue).Count
            try {
                $r = Invoke-WebRequest -Uri 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 15
                $out['health'] = [int]$r.StatusCode
            } catch {
                $c = 0; try { $c = [int]$_.Exception.Response.StatusCode.value__ } catch { }
                $out['health'] = $c
            }
            $sent = 0; $failed = 0
            try {
                $m = (Invoke-WebRequest -Uri 'http://127.0.0.1:8888/metrics' -UseBasicParsing -TimeoutSec 15).Content
                foreach ($line in ($m -split "`n")) {
                    if ($line -match '^otelcol_exporter_sent_(spans|log_records|metric_points)[^ ]* ([0-9.e+]+)') { $sent += [double]$Matches[2] }
                    if ($line -match '^otelcol_exporter_send_failed[^ ]* ([0-9.e+]+)')                            { $failed += [double]$Matches[1] }
                }
                $out['metricsReachable'] = $true
            } catch { $out['metricsReachable'] = $false }
            $out['sent'] = $sent
            $out['sendFailed'] = $failed
            $listen = @()
            try { $listen = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -ExpandProperty LocalPort) } catch { }
            $out['p4317'] = [bool]($listen -contains 4317)
            $out['p4318'] = [bool]($listen -contains 4318)
            [pscustomobject]$out | ConvertTo-Json -Compress
        } -TimeoutSeconds 600

        if (-not $health) {
            Assert-True 'health report parsed' $false 'no JSON from the guest'
        } else {
            if ($Mode -eq 'supervisor') {
                Assert-Equal 'opampsupervisor Running'          'Running' ([string]$health.supervisor)
                Assert-True  'supervisor start type is automatic (survives reboot)' ([string]$health.supStart -match 'Auto') "StartType=$($health.supStart)"
                Assert-True  'collector child process alive'     ([int]$health.otelChild -ge 1) "otelcol processes=$($health.otelChild)"
            } else {
                Assert-Equal 'otelcol-contrib Running'          'Running' ([string]$health.collector)
                Assert-True  'no supervisor process in this mode' ([string]$health.supervisor -eq '') "supervisor=$($health.supervisor)"
            }
            Assert-Equal 'health endpoint 13133 returns 200' 200 ([int]$health.health)
            Assert-True  'OTLP 4318 listening' ([bool]$health.p4318)
            Assert-True  'OTLP 4317 listening' ([bool]$health.p4317)
            if ([bool]$health.metricsReachable) {
                Assert-True 'collector has exported something'      ([double]$health.sent -gt 0)    "sent=$($health.sent)"
                Assert-True 'no export failures'                    ([double]$health.sendFailed -eq 0) "send_failed=$($health.sendFailed)"
            } else {
                Note 'collector :8888 metrics unreachable' 'export counters could not be read'
            }
        }

        # The supervising contract itself: kill the collector child and the supervisor must bring it
        # back. Nothing in the repo tests this today, and it is the entire reason to run supervisor
        # mode rather than a plain service.
        if ($Mode -eq 'supervisor') {
            $resp = Invoke-GuestJson -Script {
                $before = @(Get-Process otelcol* -ErrorAction SilentlyContinue)
                foreach ($p in $before) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
                Start-Sleep -Seconds 25
                $after = @(Get-Process otelcol* -ErrorAction SilentlyContinue)
                [pscustomobject]@{
                    Killed  = $before.Count
                    Back    = $after.Count
                    SamePid = [bool](($before | ForEach-Object { $_.Id }) -contains ($after | Select-Object -First 1 -ExpandProperty Id -ErrorAction SilentlyContinue))
                } | ConvertTo-Json -Compress
            } -TimeoutSeconds 300
            if ($resp) {
                Assert-True 'supervisor restarted the collector child after it was killed' `
                    (([int]$resp.Killed -ge 1) -and ([int]$resp.Back -ge 1)) "killed=$($resp.Killed) back=$($resp.Back)"
                Assert-True 'and it is a NEW process, not the one we killed' (-not [bool]$resp.SamePid)
            }
        }
    }

    # ---- P5 : naming and claims -----------------------------------------------
    if (Want 'P5') {
        Write-PhaseHeader 'P5' 'service naming and CX_* claims'
        $naming = Invoke-GuestJson -Script {
            $ErrorActionPreference = 'Continue'
            function M { param($n) [Environment]::GetEnvironmentVariable($n, 'Machine') }
            $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
            $pools = @()
            if (Test-Path $appcmd) {
                foreach ($line in (& $appcmd list apppool /text:name 2>&1)) {
                    $name = "$line".Trim(); if (-not $name) { continue }
                    $sn = (& $appcmd list apppool "$name" /text:add.environmentVariables.[name='OTEL_SERVICE_NAME'].value 2>&1 | Select-Object -First 1)
                    $pools += [pscustomobject]@{ Pool = $name; ServiceName = "$sn".Trim() }
                }
            }
            [pscustomobject]@{
                IisServices    = (M 'CX_IIS_SERVICES')
                NodeServices   = (M 'CX_NODE_SERVICES')
                DotnetServices = (M 'CX_DOTNET_SERVICES')
                AllServices    = (M 'CX_SERVICES')
                Environment    = (M 'CX_ENVIRONMENT')
                ResourceAttrs  = (M 'OTEL_RESOURCE_ATTRIBUTES')
                Pools          = $pools
            } | ConvertTo-Json -Depth 4 -Compress
        } -TimeoutSeconds 600

        if (-not $naming) {
            Assert-True 'naming report parsed' $false 'no JSON from the guest'
        } else {
            $claimed = @(([string]$naming.IisServices) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            # Carried into P7: the telemetry gate must check the value the GUEST stamped, not the
            # value of CX_IIS_SERVICES on this controller machine (the verifier's default), which
            # would silently verify the wrong host.
            $script:GuestIisServices = [string]$naming.IisServices
            $script:GuestAllServices = [string]$naming.AllServices
            Write-Host "  CX_IIS_SERVICES    = $($naming.IisServices)"
            Write-Host "  CX_NODE_SERVICES   = $($naming.NodeServices)"
            Write-Host "  CX_DOTNET_SERVICES = $($naming.DotnetServices)"
            Write-Host "  CX_SERVICES        = $($naming.AllServices)"

            # CX_SERVICES is what the collector stamps for host ownership, and it must cover the
            # NON-IIS services too - that is exactly what was missing when an APM service had spans
            # but no host correlation. Asserted as a superset of the three per-technology lists.
            $claimedAll = @(([string]$naming.AllServices) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $perTech    = @(@(([string]$naming.IisServices) -split ','), @(([string]$naming.NodeServices) -split ','),
                            @(([string]$naming.DotnetServices) -split ',')) |
                          ForEach-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique
            Assert-True 'CX_SERVICES is set (host ownership covers every instrumented service)' ($claimedAll.Count -gt 0)
            Assert-SetEqual 'CX_SERVICES equals the union of IIS + Node + .NET service names' $perTech $claimedAll
            Assert-True 'CX_IIS_SERVICES is set' ($claimed.Count -gt 0)
            Assert-Equal 'CX_ENVIRONMENT carries the deploy environment' $Environment ([string]$naming.Environment)

            foreach ($n in @($svcNames.Net8, $svcNames.Net8Oop, $svcNames.Net6, $svcNames.Fw48)) {
                Assert-True "$n is claimed in CX_IIS_SERVICES" ($claimed -contains $n) "claimed: $($claimed -join ', ')"
            }
            # The refusal cases: classified, deliberately NOT claimed.
            Assert-True "$($svcNames.Clr2) is NOT claimed (CLR 2 is unsupported by the profiler)" `
                ($claimed -notcontains $svcNames.Clr2) "claimed: $($claimed -join ', ')"
            foreach ($shape in @('arrproxy','staticwc','nocfg','binonly')) {
                Assert-True "$shape is NOT claimed" ($claimed -notcontains $shape) "claimed: $($claimed -join ', ')"
            }
        }
    }

    # ---- P6 : load -------------------------------------------------------------
    if (Want 'P6') {
        Write-PhaseHeader 'P6' 'generate load against every shape'
        $load = Invoke-GuestJson -Script {
            $ErrorActionPreference = 'Continue'
            $targets = @(
                'http://127.0.0.1:8801/work','http://127.0.0.1:8801/ping','http://127.0.0.1:8801/boom',
                'http://127.0.0.1:8802/work','http://127.0.0.1:8803/work',
                'http://127.0.0.1:8804/Default.aspx?work=1','http://127.0.0.1:8805/Default.aspx',
                'http://127.0.0.1:8901/'
            )
            $counts = [ordered]@{}
            foreach ($t in $targets) {
                $ok = 0
                for ($i = 0; $i -lt 12; $i++) {
                    try { $null = Invoke-WebRequest -Uri $t -UseBasicParsing -TimeoutSec 10; $ok++ } catch { }
                }
                $counts[$t] = $ok
            }
            [pscustomobject]@{ Counts = $counts } | ConvertTo-Json -Depth 4 -Compress
        } -TimeoutSeconds 1200
        if ($load) {
            $total = 0
            foreach ($p in $load.Counts.PSObject.Properties) { $total += [int]$p.Value; Write-Host ("  {0,-46} {1,3} ok" -f $p.Name, $p.Value) }
            Assert-True 'load generated against the shapes' ($total -gt 0) "total successful requests=$total"
        }
        Write-Host "  waiting ${IngestWaitSeconds}s for ingestion before querying Coralogix"
        Start-Sleep -Seconds $IngestWaitSeconds
    }

    # ---- P7 : telemetry, query-gated -------------------------------------------
    if (Want 'P7') {
        Write-PhaseHeader 'P7' 'telemetry in Coralogix (query-gated)'
        if (-not $QueryKeyFile -or -not (Test-Path $QueryKeyFile)) {
            Note 'P7 skipped' 'no Coralogix query key - telemetry could not be verified, so this run proves nothing about ingestion'
        } else {
            $verifier = Join-Path $RepoRoot 'scripts\Verify-CoralogixInfraLabels.ps1'
            if (Test-Path $verifier) {
                Write-Host '  (host telemetry / IIS service labels)'
                # -ExpectedValue is passed explicitly: its default is CX_IIS_SERVICES on THIS
                # machine, which would verify the controller's value against the guest's telemetry.
                # -MustNotContain turns the refusal cases into a backend assertion rather than a
                # claim about the installer: a name that was never claimed must never show up as a
                # Service either.
                # CX_SERVICES, not CX_IIS_SERVICES: the stamp now covers Node and .NET services as well,
                # and checking the narrower value would pass while ownership was incomplete.
                $expected = if ($script:GuestAllServices) { $script:GuestAllServices }
                            elseif ($script:GuestIisServices) { $script:GuestIisServices } else { '' }
                $mustNot  = @($svcNames.Clr2, 'arrproxy', 'staticwc', 'nocfg', 'binonly')
                # A [string[]] parameter reached through `powershell -File` must be ONE
                # comma-separated token. Spreading the array instead binds only its first element and
                # shoves the rest onto whatever positional parameters follow - here 'staticwc' landed
                # on -LookbackMinutes and the verifier died with "Cannot convert value 'staticwc' to
                # type System.Int32" before running a single query.
                $vArgs = @('-QueryKeyFile', $QueryKeyFile, '-Region', $Region, '-HostName', $HostRename,
                           '-MustNotContain', ($mustNot -join ','))
                if ($expected) { $vArgs += @('-ExpectedValue', $expected) }
                # Through Invoke-HostScript, not a bare call: the verifier writes to stderr, and under
                # $ErrorActionPreference='Stop' that becomes a terminating NativeCommandError which
                # aborted this phase (and P9/P10 with it) while the summary still printed normally.
                $r = Invoke-HostScript -Path $verifier -Arguments $vArgs
                Assert-True 'infra labels verified in Coralogix' ($r.Code -eq 0) $r.Out
            } else {
                Note 'Verify-CoralogixInfraLabels.ps1 missing' 'host-telemetry gate skipped'
            }

            # PER-APPLICATION gate. This is the one that makes the matrix mean something: every
            # instrumented shape must be visible in Coralogix under its own service name, and every
            # shape the classification rules declined must be visible NOWHERE. Local state cannot
            # distinguish "claimed and reporting" from "claimed and silent" - only the backend can,
            # and a silent claimed Service reads as an outage.
            $svcVerifier = Join-Path $RepoRoot 'scripts\Verify-CoralogixServiceTelemetry.ps1'
            if (Test-Path $svcVerifier) {
                Write-Host '  (per-application spans: every instrumented shape, and every refusal case)'
                $expectReporting = @($svcNames.Net8, $svcNames.Net8Oop, $svcNames.Net6, $svcNames.Fw48,
                                     $svcNames.NodeSvc, $svcNames.DotnetSvc, 'shape-user-fork')
                # The refusal cases: a CLR-2 app the profiler cannot instrument, an ARR proxy whose
                # backend reports instead, a static site, a config-less app, and the deliberately
                # ambiguous bin-only app.
                $expectSilent = @($svcNames.Clr2, 'arrproxy', 'staticwc', 'nocfg', 'binonly')
                $sArgs = @('-QueryKeyFile', $QueryKeyFile, '-Region', $Region, '-HostName', $HostRename,
                           '-Services', ($expectReporting -join ','),
                           '-MustBeSilent', ($expectSilent -join ','))
                $r = Invoke-HostScript -Path $svcVerifier -Arguments $sArgs -Tail 24
                Assert-True 'every instrumented shape reports spans, every refusal case is silent' ($r.Code -eq 0) $r.Out
            } else {
                Note 'Verify-CoralogixServiceTelemetry.ps1 missing' 'per-application telemetry was NOT verified - this run proves nothing about individual shapes'
            }

            $nodeVerifier = Join-Path $RepoRoot 'scripts\Verify-CoralogixNodeSpans.ps1'
            if (Test-Path $nodeVerifier) {
                Write-Host '  (Node spans + logs)'
                # The PM2 shape this matrix provisions is the fork app; cluster is a known-open
                # (env applies, no telemetry), so gating on it here would fail for a reason that is
                # already documented rather than for anything this run changed.
                # -Services is [string[]]: one comma-separated token, for the same reason as above.
                $nArgs = @('-QueryKeyFile', $QueryKeyFile, '-Region', $Region, '-Services', 'shape-user-fork',
                           '-ClusterService', 'shape-user-fork', '-MinClusterWorkers', '1')
                # (single value, so no join needed here - but keep the shape identical if more are added)
                $r = Invoke-HostScript -Path $nodeVerifier -Arguments $nArgs
                Assert-True 'Node telemetry verified in Coralogix' ($r.Code -eq 0) $r.Out
            }

            # The Coralogix APPLICATION name. CX_APPLICATION is deliberately unset by this matrix, so
            # the exporter must fall through to host.name - and that fallback is the only mechanism
            # that works (cx.application.name alone is dead code), which makes it worth gating rather
            # than assuming. It also proves nothing from this host is still reporting under a stale
            # application name.
            $appVerifier = Join-Path $RepoRoot 'scripts\Verify-CoralogixAppName.ps1'
            if (Test-Path $appVerifier) {
                Write-Host '  (application name = host.name fallback)'
                $r = Invoke-HostScript -Path $appVerifier `
                        -Arguments @('-QueryKeyFile', $QueryKeyFile, '-Region', $Region, '-ExpectedApplication', $HostRename)
                Assert-True 'Coralogix application name resolves to the host name' ($r.Code -eq 0) $r.Out
            }
        }
    }

    # ---- P9 : reboot survival --------------------------------------------------
    if ((Want 'P9') -and -not $SkipReboot) {
        Write-PhaseHeader 'P9' 'reboot survival'
        Assert-True 'guest came back after reboot' (Restart-Guest -ReadyTimeoutSeconds 1200)

        # POLL, do not sleep-then-peek. The installer deliberately configures the supervisor as
        # delayed auto-start (so it comes up after networking has settled), and a delayed-auto
        # service starts roughly two minutes after boot - while guestcontrol answers much sooner.
        # A fixed 90s wait therefore measured a service that had not been asked to start yet and
        # reported a reboot-survival failure that was not one. What matters is that it comes back
        # WITHOUT intervention inside a bounded window, and how long that window was: that gap is
        # the host's blind period, so it is printed rather than hidden.
        $svcName  = if ($Mode -eq 'supervisor') { 'opampsupervisor' } else { 'otelcol-contrib' }
        $deadline = (Get-Date).AddSeconds(420)
        $sw       = [System.Diagnostics.Stopwatch]::StartNew()
        $after    = $null
        do {
            $after = Invoke-GuestJson -Script {
                [pscustomobject]@{
                    Supervisor = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
                    Collector  = [string](Get-Service otelcol-contrib -ErrorAction SilentlyContinue).Status
                    OtelChild  = @(Get-Process otelcol* -ErrorAction SilentlyContinue).Count
                } | ConvertTo-Json -Compress
            } -TimeoutSeconds 600
            $up = if ($Mode -eq 'supervisor') { [string]$after.Supervisor -eq 'Running' } else { [string]$after.Collector -eq 'Running' }
            if ($up) { break }
            Start-Sleep -Seconds 20
        } while ((Get-Date) -lt $deadline)
        $sw.Stop()
        Write-Host ("  $svcName came back after {0:N0}s of polling (delayed auto-start is expected to take ~2 min)" -f $sw.Elapsed.TotalSeconds)
        if ($after) {
            if ($Mode -eq 'supervisor') {
                Assert-Equal 'opampsupervisor Running after reboot with no intervention' 'Running' ([string]$after.Supervisor)
                Assert-True  'collector child back after reboot' ([int]$after.OtelChild -ge 1) "otelcol processes=$($after.OtelChild)"

                # The three settings that make the above true are asserted directly, because a
                # reboot that happens to work is weaker evidence than the configuration being right:
                # StartType=Automatic alone was measured to leave the service dead (it starts, exits
                # ~27s later, and with no recovery actions nothing retries). failureflag matters
                # because the supervisor exits CLEANLY, and the SCM skips recovery for a non-crash
                # exit unless it is set.
                $res = Invoke-GuestJson -Script {
                    $qc = (& sc.exe qc opampsupervisor) -join ' '
                    $qf = (& sc.exe qfailure opampsupervisor) -join ' '
                    $ff = (& sc.exe qfailureflag opampsupervisor) -join ' '
                    [pscustomobject]@{
                        Delayed     = [bool]($qc -match 'AUTO_START\s*\(DELAYED\)')
                        HasActions  = [bool]($qf -match 'RESTART')
                        ResetPeriod = [bool]($qf -match 'RESET_PERIOD[^:]*:\s*8640')
                        FailureFlag = [bool]($ff -match 'FAILURE_ACTIONS_ON_NONCRASH_FAILURES:\s*TRUE')
                    } | ConvertTo-Json -Compress
                } -TimeoutSeconds 300
                if ($res) {
                    Assert-True 'start type is delayed auto-start' ([bool]$res.Delayed)
                    Assert-True 'SCM recovery actions are configured' ([bool]$res.HasActions)
                    Assert-True 'recovery applies to a CLEAN exit (failureflag=1)' ([bool]$res.FailureFlag) `
                        'without this the SCM skips recovery for the supervisor''s clean exit, and the host sits unmonitored'
                }
            } else {
                Assert-Equal 'otelcol-contrib Running after reboot with no intervention' 'Running' ([string]$after.Collector)
            }
        }
    }

    # ---- P10 : uninstall -------------------------------------------------------
    if (Want 'P10') {
        Write-PhaseHeader 'P10' 'uninstall leaves a working host'
        $un = Invoke-GuestFile -LocalPath (Join-Path $RepoRoot 'deploy\uninstall.bat') `
                               -GuestPath "$GuestStage\deploy\uninstall.bat" -Tail 10 -TimeoutSeconds 1800
        Assert-True 'uninstall.bat exited 0' ($un.Code -eq 0) "exit=$($un.Code): $($un.Out)"
        $post = Invoke-GuestJson -Script {
            $ErrorActionPreference = 'Continue'
            $w3 = @()
            try { $w3 = @((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W3SVC' -Name Environment -ErrorAction Stop).Environment) } catch { }
            [pscustomobject]@{
                Supervisor = [string](Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status
                Collector  = [string](Get-Service otelcol-contrib -ErrorAction SilentlyContinue).Status
                Iis        = [string](Get-Service W3SVC -ErrorAction SilentlyContinue).Status
                W3Empty    = [bool](@($w3 | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
                W3Profiler = [bool](($w3 -join ' ') -match 'CORECLR_PROFILER|COR_PROFILER')
            } | ConvertTo-Json -Compress
        } -TimeoutSeconds 600
        if ($post) {
            Assert-True 'collector services are gone' (([string]$post.Supervisor -eq '') -and ([string]$post.Collector -eq '')) `
                "supervisor=$($post.Supervisor) collector=$($post.Collector)"
            Assert-Equal 'IIS still running after uninstall' 'Running' ([string]$post.Iis)
            Assert-True  'no empty element left in the W3SVC Environment (that alone stops IIS starting)' (-not [bool]$post.W3Empty)
            Assert-True  'profiler entries removed from W3SVC' (-not [bool]$post.W3Profiler)
        }
    }

    $exitCode = Get-LoopExitCode
}
finally {
    Write-LoopSummary -Title "full-matrix ($Mode, $VmName)"
    Remove-VmLoopTemp
}

exit $exitCode
