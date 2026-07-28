<#
.SYNOPSIS
  Read-only check that the zero-code .NET/IIS instrumentation was actually
  APPLIED on this host - the CLR profiler, the OTLP pool environment, and the
  pool runtime settings the profiler depends on.

.DESCRIPTION
  DUAL MODE.
    * Run it directly            -> prints a table and exits 0 / 1 / 2.
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-IISInstrumentation.ps1
    * Dot-source it              -> defines Test-IISInstrumentation and returns
                                    findings for an aggregator (Test-Agent.ps1).
        . .\Test-IISInstrumentation.ps1 ; $f = Test-IISInstrumentation

  This answers a question nothing else in the repo answers: Instrument-IIS.ps1
  logs that it ran, but nothing ever reads back whether the profiler is attached.
  A host can look perfectly healthy - collector up, spans pipeline configured -
  and still emit nothing because the profiler was never registered, its DLL was
  deleted, or an app pool is not "No Managed Code".

  Six sub-checks:
    a. profiler       CORECLR_PROFILER / CORECLR_ENABLE_PROFILING in the W3SVC
                      and WAS service Environment (REG_MULTI_SZ)
    b. profilerPath   the profiler DLL the registry points at exists on disk
    c. profilerReg    the REG_MULTI_SZ is well-formed - an empty element here
                      PREVENTS IIS FROM STARTING, so this one is a hard fail
    d. autoHome       OTEL_DOTNET_AUTO_HOME resolves; version cross-checked
                      against the deploy manifest
    e. poolOtlp       OTEL_EXPORTER_OTLP_ENDPOINT / _PROTOCOL are EFFECTIVE per
                      pool, modelling the applicationPoolDefaults inheritance trap
    f. poolRuntime    every ASP.NET Core app's pool is "No Managed Code"

  READ-ONLY. Reads the registry, applicationHost.config, and each app's
  web.config. Writes nothing, starts nothing, runs no appcmd and no iisreset.

.NOTES
  Windows PowerShell 5.1. Run ELEVATED - applicationHost.config and the service
  registry keys are readable by Administrators only, so a non-elevated run would
  report every app as unconfigured. The script refuses rather than lie.

  It deliberately does NOT use the WebAdministration module. Everything it needs
  is in applicationHost.config, so it still works on a host where the IIS
  management tools are missing - which is itself one of the failure modes the
  fleet has hit.

  WOW64. The inetsrv path is resolved through Get-CxInetsrvDir, not hardcoded to
  System32. See that function for why: a 32-bit host process can drive appcmd
  perfectly while every direct read of applicationHost.config returns "not
  found", which looks exactly like "the config is gone" and is not.
#>
# PositionalBinding=$false: reject stray tokens instead of silently binding them
# to the wrong parameter (see Test-Agent.ps1 for the failure this prevents).
[CmdletBinding(PositionalBinding = $false)]
param(
    # The endpoint the pools SHOULD carry. Note 127.0.0.1, not localhost: on a
    # dual-stack host `localhost` resolves to ::1 first and OTLP export is
    # silently dropped (docs/iis-service-ownership.md).
    [string] $ExpectedOtlpEndpoint = 'http://127.0.0.1:4318',
    # Empty = resolve with Get-CxAppHostConfigPath below. It is NOT defaulted
    # here because a param default is evaluated at binding time, before any
    # function in this file exists, and the correct path depends on process
    # bitness (see Get-CxInetsrvDir).
    [string] $AppHostConfig,
    [string] $BackupRoot,                # default: Backup-Config.ps1's ProgramData root
    [switch] $Quiet,
    [switch] $PassThru
)

# Native tools are not called here, but keep the repo-wide convention: under
# 'Stop' a native stderr write becomes a terminating NativeCommandError in 5.1.
$ErrorActionPreference = 'Continue'

# $PSScriptRoot is empty under `powershell -File <relative>`.
$script:CxIisHere = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# Shared finding model. Guarded, with a local fallback, so this script still runs
# if it was copied somewhere on its own.
$script:CxFmtLoaded = $false
$fmt = Join-Path $script:CxIisHere 'Write-DeployLog.ps1'
if (Test-Path -LiteralPath $fmt -ErrorAction SilentlyContinue) {
    try { . $fmt; $script:CxFmtLoaded = $true } catch { }
}

# IIS log-path discovery. Guarded: without it the log-coverage sub-check reports
# 'unknown' and everything else still runs. Availability is decided by the function
# being callable, not by the file existing.
$logLib = Join-Path $script:CxIisHere 'Resolve-IISLogPaths.ps1'
if (Test-Path -LiteralPath $logLib -ErrorAction SilentlyContinue) {
    try { . $logLib } catch { }
}
if (-not (Get-Command New-Finding -ErrorAction SilentlyContinue)) {
    function New-Finding {
        param([string]$Check, [string]$Severity, [string]$Code = '', [string]$Message = '', [string]$Target = '', $Data = $null)
        [pscustomobject]@{ check = $Check; severity = $Severity; code = $Code; target = $Target; message = $Message; data = $Data }
    }
}
if (-not (Get-Command Get-GradedExitCode -ErrorAction SilentlyContinue)) {
    function Get-GradedExitCode {
        param([object[]]$Findings)
        $f = @($Findings) | Where-Object { $_ }
        if (@($f | Where-Object { $_.severity -eq 'fail' }).Count -gt 0) { return 1 }
        if (@($f | Where-Object { $_.severity -eq 'warn' }).Count -gt 0) { return 2 }
        return 0
    }
}
if (-not (Get-Command Write-FindingTable -ErrorAction SilentlyContinue)) {
    function Write-FindingTable {
        param([object[]]$Findings, [string]$Title, [switch]$Quiet)
        if ($Title) { Write-Host ''; Write-Host "== $Title ==" }
        foreach ($f in @($Findings)) {
            if (-not $f) { continue }
            if ($Quiet -and ($f.severity -eq 'pass' -or $f.severity -eq 'skip')) { continue }
            Write-Host ("  [{0,-7}] {1} {2} {3}" -f $f.severity.ToUpperInvariant(), $f.check, $f.target, $f.message)
        }
    }
}
if (-not (Get-Command Write-FindingSummary -ErrorAction SilentlyContinue)) {
    function Write-FindingSummary {
        param([object[]]$Findings, [string]$Label = 'RESULT', [int]$ExitCode = -1)
        if ($ExitCode -lt 0) { $ExitCode = Get-GradedExitCode -Findings $Findings }
        Write-Host "=== $Label RESULT: exit=$ExitCode ==="
    }
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

function Test-CxElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-CxInetsrvDir {
    <#
      The REAL inetsrv directory for THIS process.

      On 64-bit Windows the WOW64 file system redirector rewrites
      %windir%\System32 to %windir%\SysWOW64 for a 32-bit process.
      SysWOW64\inetsrv exists and contains appcmd.exe. It even has a config\
      folder - but that folder holds only Schema\ and Export\, never
      applicationHost.config. The consequence is a genuinely confusing split:

        * appcmd works.       It reaches the IIS configuration system through
                              the ahadmin COM API, which is bitness-agnostic, so
                              pool environment variables are written correctly.
        * direct reads fail.  Get-Content on
                              %windir%\System32\inetsrv\config\applicationHost.config
                              lands in SysWOW64\inetsrv\config, which does not
                              exist, and reports "not found".

      So a 32-bit host process - a 32-bit BatchPatch/RMM agent launching
      deploy.bat or doctor.bat, a 32-bit scheduled task, a 32-bit cmd - can
      instrument a host successfully while the doctor swears the config is gone.

      %windir%\Sysnative is the un-redirected view of the real System32. It
      exists ONLY when observed from a 32-bit process, so this branches on
      process bitness and NOT on Test-Path: Test-Path returns $false on an
      access-denied path (applicationHost.config is Administrators-only), which
      would silently pick the wrong directory on exactly the hosts that matter.
    #>
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        return (Join-Path $env:windir 'Sysnative\inetsrv')
    }
    return (Join-Path $env:windir 'System32\inetsrv')
}

function Get-CxAppHostConfigPath {
    Join-Path (Get-CxInetsrvDir) 'config\applicationHost.config'
}

function Test-CxIisPresent {
    # Cheap, no module. Mirrors the appcmd probe Instrument-IIS.ps1 relies on.
    # appcmd.exe is present under both System32\inetsrv and SysWOW64\inetsrv, so
    # this probe answers correctly either way; it goes through the resolver for
    # consistency, not because it has to.
    (Test-Path -LiteralPath (Join-Path (Get-CxInetsrvDir) 'appcmd.exe') -ErrorAction SilentlyContinue) -or
    [bool](Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue)
}

function Get-CxServiceEnvironment {
    <#
      Read a Windows service's Environment value (REG_MULTI_SZ) as a string[].
      Returns $null when the key or value is absent - which is NOT an error:
      a host that was never instrumented has no Environment value at all.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ServiceName)

    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        if (-not (Test-Path -LiteralPath $key -ErrorAction SilentlyContinue)) { return $null }
        $p = Get-ItemProperty -LiteralPath $key -Name 'Environment' -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        return @($p.Environment)
    } catch { return $null }
}

function Get-CxEnvEntry {
    <#
      Pull NAME=value out of a REG_MULTI_SZ entry list. Case-insensitive on the
      name, as Windows environment blocks are. Returns $null if absent.
    #>
    [CmdletBinding()]
    param([string[]] $Entries, [Parameter(Mandatory)][string] $Name)

    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $i = $e.IndexOf('=')
        if ($i -lt 1) { continue }
        if ($e.Substring(0, $i).Trim() -ieq $Name) { return $e.Substring($i + 1) }
    }
    return $null
}

function Get-CxAppHostModel {
    <#
      Parse applicationHost.config ONCE into a model:

        Pools    - name -> @{ ManagedRuntimeVersion; HasOwnEnvBlock; Env = @{} }
        Defaults - the applicationPoolDefaults environmentVariables as @{}
        Apps     - one record per site/application with Pool + PhysicalPath

      Node selection is done in PowerShell rather than by interpolating names
      into an XPath literal, so a pool named  Bob's Pool  cannot break the query.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $model = [pscustomobject]@{
        Ok       = $false
        Error    = $null
        Denied   = $false
        Pools    = @{}
        Defaults = @{}
        Apps     = @()
    }

    # Read first and classify the failure, rather than pre-checking with Test-Path.
    # Test-Path on a permission-denied path emits a NON-TERMINATING error (which
    # escapes a try/catch under 'Continue') and then returns $false - so a
    # pre-check reports "not found" for a file that exists but is unreadable.
    # That misdiagnosis is exactly what this script exists to prevent.
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        $model.Error = "access denied reading applicationHost.config (run elevated): $Path"
        $model.Denied = $true
        return $model
    } catch {
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.Exception -is [System.IO.FileNotFoundException] -or
            $_.Exception -is [System.IO.DirectoryNotFoundException]) {
            $model.Error = "applicationHost.config not found at $Path"
        } elseif ($_.Exception.GetType().Name -match 'UnauthorizedAccess') {
            # PS 5.1 sometimes wraps it rather than surfacing the typed exception.
            $model.Error = "access denied reading applicationHost.config (run elevated): $Path"
            $model.Denied = $true
        } else {
            $model.Error = "could not read/parse applicationHost.config: $($_.Exception.Message)"
        }
        return $model
    }

    function ConvertTo-EnvMap($node) {
        $map = @{}
        if (-not $node) { return $map }
        $block = $node.SelectSingleNode('environmentVariables')
        if (-not $block) { return $map }
        foreach ($a in @($block.SelectNodes('add'))) {
            $n = [string]$a.GetAttribute('name')
            if ($n) { $map[$n] = [string]$a.GetAttribute('value') }
        }
        return $map
    }

    try {
        $poolsRoot = $xml.SelectSingleNode('/configuration/system.applicationHost/applicationPools')
        if ($poolsRoot) {
            $defNode = $poolsRoot.SelectSingleNode('applicationPoolDefaults')
            $model.Defaults = ConvertTo-EnvMap $defNode

            foreach ($p in @($poolsRoot.SelectNodes('add'))) {
                $name = [string]$p.GetAttribute('name')
                if (-not $name) { continue }
                $model.Pools[$name] = [pscustomobject]@{
                    Name                  = $name
                    # Absent attribute means "inherit the default", which is v4.0 -
                    # NOT "No Managed Code". Only an explicitly empty string is
                    # No Managed Code, so distinguish absent from empty.
                    ManagedRuntimeVersion = if ($p.HasAttribute('managedRuntimeVersion')) { [string]$p.GetAttribute('managedRuntimeVersion') } else { $null }
                    HasOwnEnvBlock        = [bool]$p.SelectSingleNode('environmentVariables')
                    Env                   = (ConvertTo-EnvMap $p)
                }
            }
        }

        $sitesRoot = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
        if ($sitesRoot) {
            # An <application> may OMIT applicationPool, in which case IIS resolves it
            # from <sites><applicationDefaults applicationPool="...">. The stock
            # "Default Web Site" does exactly this on a fresh IIS, so skipping this
            # fallback makes the pool look empty and every check keyed on it report a
            # FALSE "not configured" - on essentially every host in the fleet.
            $poolDefault = ''
            $defNode = $sitesRoot.SelectSingleNode('applicationDefaults')
            if ($defNode) { $poolDefault = [string]$defNode.GetAttribute('applicationPool') }

            foreach ($site in @($sitesRoot.SelectNodes('site'))) {
                $siteName = [string]$site.GetAttribute('name')
                foreach ($app in @($site.SelectNodes('application'))) {
                    $appPath = [string]$app.GetAttribute('path')
                    if (-not $appPath) { $appPath = '/' }

                    # Resolution order, matching IIS: the application's own attribute,
                    # then a per-site applicationDefaults, then the sites-wide default.
                    $pool = [string]$app.GetAttribute('applicationPool')
                    if (-not $pool) {
                        $siteDef = $site.SelectSingleNode('applicationDefaults')
                        if ($siteDef) { $pool = [string]$siteDef.GetAttribute('applicationPool') }
                    }
                    if (-not $pool) { $pool = $poolDefault }

                    $phys = ''
                    foreach ($vd in @($app.SelectNodes('virtualDirectory'))) {
                        if (([string]$vd.GetAttribute('path')) -eq '/') {
                            $phys = [string]$vd.GetAttribute('physicalPath'); break
                        }
                    }
                    if ($phys) {
                        try { $phys = [Environment]::ExpandEnvironmentVariables($phys) } catch { }
                    }

                    $model.Apps += [pscustomobject]@{
                        Site         = $siteName
                        AppPath      = $appPath
                        Pool         = $pool
                        PhysicalPath = $phys
                    }
                }
            }
        }

        $model.Ok = $true
    } catch {
        $model.Error = "unexpected shape in applicationHost.config: $($_.Exception.Message)"
    }

    return $model
}

function Get-CxWebConfigCoreState {
    <#
      Does this app's own web.config declare <aspNetCore> - i.e. is it an
      ASP.NET Core app, which REQUIRES a "No Managed Code" pool?

      Returns a state, not a tri-state boolean, because "there is no web.config"
      and "web.config could not be read" are DIFFERENT ANSWERS and reporting them
      as one produced a wrong diagnosis on essentially every host in the fleet:
      stock IIS ships C:\inetpub\wwwroot with iisstart.htm and no web.config at
      all, so "Default Web Site/" always came back as unreadable and read like a
      permissions problem.

        nopath      the application has no physicalPath in applicationHost.config
        absent      no web.config there (DirMissing says whether the folder is
                    gone too). ANCM is wired BY web.config, so barring inheritance
                    from a parent application this is NOT an ASP.NET Core app
        unreadable  it exists but could not be opened or parsed - Error carries
                    the reason, which is the only way to tell an ACL apart from
                    malformed XML
        ok          parsed; IsCore is authoritative

      Matched with //aspNetCore because the publish output commonly wraps the node
      in <location path="." ...> rather than putting it directly under
      <system.webServer> - the same reason Set-WebConfigServiceName does.

      Inheritable reports whether that <location> lets the setting flow into child
      applications. `dotnet publish` emits inheritInChildApplications="false"
      precisely to stop it; when it is absent, a child app with no web.config of
      its own still gets ANCM from the parent.

      Reads through [System.IO.File] rather than Test-Path/Get-Content on purpose:
      the .NET exceptions distinguish not-found from access-denied, where a
      Test-Path under SilentlyContinue returns $false for both.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)

    # $Reason, not $Error: a parameter named Error would shadow the automatic
    # $Error collection inside this function.
    function New-State {
        param($State, $IsCore, $Inheritable = $false, $DirMissing = $false, $Reason = $null)
        [pscustomobject]@{
            State = $State; IsCore = $IsCore; Inheritable = $Inheritable
            DirMissing = $DirMissing; Error = $Reason
        }
    }

    if (-not $PhysicalPath) {
        return (New-State 'nopath' $null -Reason 'the application has no physicalPath in applicationHost.config, so its web.config cannot be located')
    }

    $wc = Join-Path $PhysicalPath 'web.config'
    $raw = $null
    try {
        $raw = [System.IO.File]::ReadAllText($wc)
    } catch [System.IO.DirectoryNotFoundException] {
        return (New-State 'absent' $false -DirMissing $true)
    } catch [System.IO.FileNotFoundException] {
        return (New-State 'absent' $false)
    } catch {
        return (New-State 'unreadable' $null -Reason $_.Exception.Message)
    }

    try {
        [xml]$x = $raw
    } catch {
        return (New-State 'unreadable' $null -Reason "web.config is not well-formed XML: $($_.Exception.Message)")
    }

    $core = $x.SelectSingleNode('//aspNetCore')
    $inheritable = $true
    if ($core) {
        foreach ($loc in @($core.SelectNodes('ancestor::location'))) {
            $v = [string]$loc.GetAttribute('inheritInChildApplications')
            if ($v -match '^\s*(false|0)\s*$') { $inheritable = $false; break }
        }
    }
    return (New-State 'ok' ([bool]$core) -Inheritable $inheritable)
}

function Get-CxAncestorApps {
    <#
      Applications on the same site that sit ABOVE this one in the URL hierarchy,
      nearest first. IIS config inheritance follows the URL path, not the physical
      one, so this - and not a walk up the filesystem - is how a child app finds
      the web.config it may be inheriting from.
    #>
    [CmdletBinding()]
    param($Model, $App)

    $self = ([string]$App.AppPath).TrimEnd('/')      # '/' -> '',  '/api' -> '/api'
    $out = @($Model.Apps | Where-Object {
        $_.Site -eq $App.Site -and $_.AppPath -ne $App.AppPath -and
        ($_.AppPath -eq '/' -or $self.StartsWith((([string]$_.AppPath).TrimEnd('/') + '/'), [StringComparison]::OrdinalIgnoreCase))
    })
    return ,@($out | Sort-Object { ([string]$_.AppPath).Length } -Descending)
}

function Test-CxAspNetCoreApp {
    <#
      Back-compat wrapper: $true / $false / $null-when-unknowable. Prefer
      Get-CxWebConfigCoreState, which says WHY the answer is unknown.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)
    $s = Get-CxWebConfigCoreState -PhysicalPath $PhysicalPath
    if ($s.State -eq 'ok' -or $s.State -eq 'absent') { return [bool]$s.IsCore }
    return $null
}

function Get-CxEffectivePoolEnv {
    <#
      A pool's own <environmentVariables> block REPLACES applicationPoolDefaults;
      it is not merged with it. So checking the defaults alone can report a false
      pass for a pool that has its own block.

      OBSERVED BEHAVIOUR (verified in the ltsc2022 IIS container): when appcmd
      first writes ANY env var to a pool, IIS MATERIALISES the current
      applicationPoolDefaults entries into that pool's new block alongside it. So
      a pool instrumented by THIS installer carries a full copy, not an empty one.

      That is not the same as "pool has a block but no endpoint is rare". The copy
      is taken from whatever the defaults held AT THE TIME OF THE FIRST WRITE, and
      any earlier `appcmd .../+[name=...].environmentVariables...` counts - a
      brownfield pool given a connection string before the agent was installed
      (which is exactly what misc\wire-db.ps1 does) already owns a block that
      predates the OTLP defaults, so it never sees them. On a SHARED pool that was
      the live failure this check was hardened for; Instrument-IIS.ps1 now stamps
      the OTLP vars directly onto such pools.

      The consequential case is that the copy is a SNAPSHOT: change
      applicationPoolDefaults afterwards and every pool that already has its own
      block keeps the OLD value forever. Get-CxPoolEnvDrift below reports that.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pool, [hashtable] $Defaults)

    if ($Pool.HasOwnEnvBlock) { return $Pool.Env }
    return $Defaults
}

function Get-CxPoolEnvDrift {
    <#
      Names present in BOTH applicationPoolDefaults and the pool's own block whose
      values disagree. Each one is a stale snapshot: the default was changed after
      this pool was instrumented, and the pool never picked the change up.

      This is the failure mode behind "I fixed the OTLP endpoint centrally and
      half the fleet still exports nowhere".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pool, [hashtable] $Defaults)

    $drift = @()
    if (-not $Pool.HasOwnEnvBlock) { return $drift }
    foreach ($k in @($Defaults.Keys)) {
        if ($Pool.Env.ContainsKey($k) -and ([string]$Pool.Env[$k]) -ne ([string]$Defaults[$k])) {
            $drift += [pscustomobject]@{ Name = $k; Pool = [string]$Pool.Env[$k]; Default = [string]$Defaults[$k] }
        }
    }
    return $drift
}

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

function Test-IISInstrumentation {
    <#
      Run the six sub-checks and return findings. Never throws; anything it
      cannot determine comes back as `unknown`, which does not move the grade.
    #>
    [CmdletBinding()]
    param(
        [string] $ExpectedOtlpEndpoint = 'http://127.0.0.1:4318',
        # Safe as a default here (unlike the script-level param): a function's
        # defaults are evaluated when it is CALLED, by which point the whole
        # file has been sourced and Get-CxAppHostConfigPath exists.
        [string] $AppHostConfig        = (Get-CxAppHostConfigPath),
        [string] $BackupRoot
    )

    $findings = New-Object System.Collections.ArrayList
    function Add-F { param($f) [void]$findings.Add($f) }

    # -- gate 0: elevation ---------------------------------------------------
    if (-not (Test-CxElevated)) {
        Add-F (New-Finding -Check 'iisInstr' -Severity 'fail' -Code 'NOT_ELEVATED' `
            -Message 'not running as Administrator - applicationHost.config and the service registry are unreadable, so every result would be a false negative')
        return ,@($findings.ToArray())
    }

    # -- gate 1: is there any IIS here at all? -------------------------------
    if (-not (Test-CxIisPresent)) {
        Add-F (New-Finding -Check 'iisInstr' -Severity 'skip' -Code 'IIS_ABSENT' `
            -Message 'no IIS on this host - nothing to instrument')
        return ,@($findings.ToArray())
    }

    $model = Get-CxAppHostModel -Path $AppHostConfig
    if (-not $model.Ok) {
        $code = if ($model.Denied) { 'APPHOST_ACCESS_DENIED' } else { 'APPHOST_UNREADABLE' }
        Add-F (New-Finding -Check 'iisInstr' -Severity 'unknown' -Code $code `
            -Message $model.Error -Target $AppHostConfig)
    }

    $appCount = @($model.Apps).Count

    # -- gate 2: IIS role present but no applications ------------------------
    # A golden image with the role baked in and no sites yet is a legitimate
    # steady state. Telling it the profiler is missing would be noise.
    if ($model.Ok -and $appCount -eq 0) {
        Add-F (New-Finding -Check 'iisInstr' -Severity 'skip' -Code 'IIS_NO_APPS' `
            -Message 'IIS is installed but hosts no applications - instrumentation is not expected' `
            -Data @{ appCount = 0 })
        return ,@($findings.ToArray())
    }

    # -- a/b/c: the CLR profiler in the service Environment blocks -----------
    foreach ($svc in @('W3SVC', 'WAS')) {
        $entries = Get-CxServiceEnvironment -ServiceName $svc

        if ($null -eq $entries) {
            Add-F (New-Finding -Check 'profiler' -Severity 'warn' -Code 'PROFILER_NOT_REGISTERED' -Target $svc `
                -Message "$svc has no Environment value - Register-OpenTelemetryForIIS never ran (or was undone). No .NET app on this host is instrumented.")
            continue
        }

        # (c) FIRST - a malformed block is act-now severity. An empty element in
        # this REG_MULTI_SZ prevents IIS from starting ("cannot contain empty
        # strings"), so it outranks every other finding here.
        $emptyCount = @($entries | Where-Object { [string]::IsNullOrEmpty($_) }).Count
        if ($emptyCount -gt 0) {
            Add-F (New-Finding -Check 'profilerReg' -Severity 'fail' -Code 'PROFILER_REGISTRY_MALFORMED' -Target $svc `
                -Message "$svc Environment REG_MULTI_SZ contains $emptyCount empty element(s) - this PREVENTS IIS FROM STARTING. Restore $svc.reg from the deploy backup dir (reg import) or remove the blank entry." `
                -Data @{ entryCount = @($entries).Count; emptyCount = $emptyCount })
        } else {
            Add-F (New-Finding -Check 'profilerReg' -Severity 'pass' -Target $svc `
                -Message "$svc Environment is well-formed ($(@($entries).Count) entries)")
        }

        # (a) profiler registration. CORECLR_* is .NET Core/5+; COR_* is Framework.
        $clrGuid   = Get-CxEnvEntry -Entries $entries -Name 'CORECLR_PROFILER'
        $clrEnable = Get-CxEnvEntry -Entries $entries -Name 'CORECLR_ENABLE_PROFILING'
        $fwGuid    = Get-CxEnvEntry -Entries $entries -Name 'COR_PROFILER'
        $fwEnable  = Get-CxEnvEntry -Entries $entries -Name 'COR_ENABLE_PROFILING'

        if (-not $clrGuid -and -not $fwGuid) {
            Add-F (New-Finding -Check 'profiler' -Severity 'warn' -Code 'PROFILER_NOT_REGISTERED' -Target $svc `
                -Message "$svc Environment has no CORECLR_PROFILER or COR_PROFILER - the CLR profiler is not attached, so no spans are produced regardless of collector health")
        } elseif ($clrGuid -and $clrEnable -ne '1') {
            Add-F (New-Finding -Check 'profiler' -Severity 'warn' -Code 'PROFILER_NOT_ENABLED' -Target $svc `
                -Message "$svc has CORECLR_PROFILER but CORECLR_ENABLE_PROFILING='$clrEnable' (expected '1') - the profiler is registered but switched off" `
                -Data @{ profiler = $clrGuid; enable = $clrEnable })
        } else {
            Add-F (New-Finding -Check 'profiler' -Severity 'pass' -Target $svc `
                -Message "profiler registered (coreclr=$([bool]$clrGuid) framework=$([bool]$fwGuid), enabled)" `
                -Data @{ coreclrProfiler = $clrGuid; corProfiler = $fwGuid; coreclrEnable = $clrEnable; corEnable = $fwEnable })
        }

        # (b) does the DLL the registry points at still exist? A stale path lets
        # IIS start and emit nothing - completely invisible until now.
        $pathNames = @('CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH',
                       'COR_PROFILER_PATH_64','COR_PROFILER_PATH_32','COR_PROFILER_PATH')
        $checked = 0
        foreach ($pn in $pathNames) {
            $dll = Get-CxEnvEntry -Entries $entries -Name $pn
            if (-not $dll) { continue }
            $checked++
            if (Test-Path -LiteralPath $dll -ErrorAction SilentlyContinue) {
                Add-F (New-Finding -Check 'profilerPath' -Severity 'pass' -Target "$svc/$pn" `
                    -Message "profiler DLL present" -Data @{ path = $dll })
            } else {
                Add-F (New-Finding -Check 'profilerPath' -Severity 'warn' -Code 'PROFILER_PATH_MISSING' -Target "$svc/$pn" `
                    -Message "$pn points at a file that does not exist - IIS starts but emits no telemetry: $dll" `
                    -Data @{ path = $dll })
            }
        }
        if ($checked -eq 0 -and ($clrGuid -or $fwGuid)) {
            Add-F (New-Finding -Check 'profilerPath' -Severity 'warn' -Code 'PROFILER_PATH_MISSING' -Target $svc `
                -Message "$svc declares a profiler GUID but no *_PROFILER_PATH* entry - the CLR cannot load the profiler")
        }
    }

    # -- d: the auto-instrumentation home + version --------------------------
    $w3 = Get-CxServiceEnvironment -ServiceName 'W3SVC'
    $autoHome = Get-CxEnvEntry -Entries $w3 -Name 'OTEL_DOTNET_AUTO_HOME'
    if (-not $autoHome) {
        if ($w3) {
            Add-F (New-Finding -Check 'autoHome' -Severity 'warn' -Code 'AUTO_HOME_MISSING' `
                -Message 'OTEL_DOTNET_AUTO_HOME is not set on W3SVC - Install-OpenTelemetryCore did not complete')
        }
    } elseif (-not (Test-Path -LiteralPath $autoHome -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'autoHome' -Severity 'warn' -Code 'AUTO_HOME_MISSING' `
            -Message "OTEL_DOTNET_AUTO_HOME points at a missing directory: $autoHome" -Data @{ path = $autoHome })
    } else {
        Add-F (New-Finding -Check 'autoHome' -Severity 'pass' `
            -Message "auto-instrumentation home present" -Data @{ path = $autoHome })
    }

    # Version is best-effort: the deploy manifest is the only place it is recorded.
    $manifestVersion = $null
    try {
        $bc = Join-Path $script:CxIisHere 'Backup-Config.ps1'
        if (Test-Path -LiteralPath $bc -ErrorAction SilentlyContinue) {
            . $bc
            $root = if ($BackupRoot) { $BackupRoot } else { Get-DefaultBackupRoot }
            $m = Get-LatestManifest -BackupRoot $root
            if ($m) { $manifestVersion = [string]$m.instrumentVersion }
        }
    } catch { }

    if ($manifestVersion) {
        Add-F (New-Finding -Check 'autoHome' -Severity 'info' `
            -Message "deploy manifest records instrumentation version $manifestVersion" `
            -Data @{ instrumentVersion = $manifestVersion })
    } elseif ($autoHome) {
        Add-F (New-Finding -Check 'autoHome' -Severity 'info' -Code 'INSTRUMENTATION_VERSION_UNKNOWN' `
            -Message 'no deploy manifest found, so the installed instrumentation version cannot be confirmed')
    }

    if (-not $model.Ok) { return ,@($findings.ToArray()) }

    # -- e: OTLP endpoint effective per pool ---------------------------------
    # Only pools that actually host an application matter.
    $usedPools = @($model.Apps | ForEach-Object { $_.Pool } | Where-Object { $_ } | Select-Object -Unique)

    $defEndpoint = $model.Defaults['OTEL_EXPORTER_OTLP_ENDPOINT']
    if (-not $defEndpoint) {
        Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'IIS_OTLP_DEFAULTS_MISSING' -Target 'applicationPoolDefaults' `
            -Message 'OTEL_EXPORTER_OTLP_ENDPOINT is not set on applicationPoolDefaults - pools that do not set it themselves have no exporter target')
    }

    foreach ($poolName in $usedPools) {
        $pool = $model.Pools[$poolName]
        if (-not $pool) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'unknown' -Code 'POOL_NOT_FOUND' -Target $poolName `
                -Message 'an application references a pool that is not declared in applicationHost.config')
            continue
        }

        $eff      = Get-CxEffectivePoolEnv -Pool $pool -Defaults $model.Defaults
        $endpoint = $eff['OTEL_EXPORTER_OTLP_ENDPOINT']

        if (-not $endpoint) {
            if ($pool.HasOwnEnvBlock -and $defEndpoint) {
                # The trap, caught: defaults look fine, this pool silently opted out.
                Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'POOL_LOST_INHERITANCE' -Target $poolName `
                    -Message "pool declares its own <environmentVariables>, which REPLACES applicationPoolDefaults - it has no OTEL_EXPORTER_OTLP_ENDPOINT even though the defaults do. Usually a pool that owned a block before the agent was installed. Re-run Instrument-IIS.ps1 and recycle the pool: it writes the OTLP vars straight onto pools that own a block." `
                    -Data @{ defaultsEndpoint = $defEndpoint; poolEnvKeys = @($pool.Env.Keys) })
            } else {
                Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'IIS_OTLP_DEFAULTS_MISSING' -Target $poolName `
                    -Message 'no effective OTEL_EXPORTER_OTLP_ENDPOINT for this pool')
            }
            continue
        }

        if ($endpoint -match 'localhost') {
            # Real, documented silent-failure mode. No longer reachable from a stock
            # deploy (Instrument-IIS.ps1 defaults to 127.0.0.1 and rewrites a
            # `localhost` value), so a hit here came from a hand edit, a pool block
            # that predates the agent, or an install from before that change.
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'OTLP_ENDPOINT_LOCALHOST' -Target $poolName `
                -Message "endpoint uses 'localhost' ($endpoint). On a dual-stack host that resolves to ::1 first and OTLP export is silently dropped. Use $ExpectedOtlpEndpoint." `
                -Data @{ endpoint = $endpoint; expected = $ExpectedOtlpEndpoint })
        } elseif ($endpoint -ne $ExpectedOtlpEndpoint) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'info' -Target $poolName `
                -Message "endpoint '$endpoint' differs from the expected '$ExpectedOtlpEndpoint' (intentional if this host exports elsewhere)" `
                -Data @{ endpoint = $endpoint; expected = $ExpectedOtlpEndpoint })
        } else {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'pass' -Target $poolName `
                -Message "endpoint $endpoint" -Data @{ endpoint = $endpoint; inherited = (-not $pool.HasOwnEnvBlock) })
        }

        if (-not $eff['OTEL_EXPORTER_OTLP_PROTOCOL']) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'info' -Target $poolName `
                -Message 'OTEL_EXPORTER_OTLP_PROTOCOL is not set; the SDK default applies')
        }

        # Stale snapshot: this pool's own block disagrees with the current
        # defaults, so a later central fix never reached it.
        foreach ($d in (Get-CxPoolEnvDrift -Pool $pool -Defaults $model.Defaults)) {
            Add-F (New-Finding -Check 'poolOtlp' -Severity 'warn' -Code 'POOL_ENV_STALE' -Target "$poolName/$($d.Name)" `
                -Message "pool has '$($d.Pool)' but applicationPoolDefaults now says '$($d.Default)'. A pool's own <environmentVariables> block replaces the defaults and is only a snapshot taken when the pool was first written, so this pool never picked up the change. Re-run Instrument-IIS.ps1 and recycle the pool." `
                -Data @{ name = $d.Name; pool = $d.Pool; default = $d.Default })
        }
    }

    # -- f: ASP.NET Core pools must be "No Managed Code" ---------------------
    # Wrong here means NO telemetry at all, regardless of everything above.
    foreach ($app in $model.Apps) {
        $label = "$($app.Site)$($app.AppPath)"
        $wc    = Get-CxWebConfigCoreState -PhysicalPath $app.PhysicalPath

        # A read FAILURE is genuinely unknown. A web.config that is simply not
        # there is not, and reporting both as "cannot read web.config" made the
        # stock Default Web Site - wwwroot ships iisstart.htm and no web.config -
        # look like an ACL problem on every host in the fleet.
        if ($wc.State -eq 'unreadable' -or $wc.State -eq 'nopath') {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'WEBCONFIG_UNREADABLE' -Target $label `
                -Message "$($wc.Error) - so it is unknown whether this is an ASP.NET Core app needing 'No Managed Code'" `
                -Data @{ physicalPath = $app.PhysicalPath; error = $wc.Error })
            continue
        }

        $isCore        = [bool]$wc.IsCore
        $inheritedFrom = $null

        if ($wc.State -eq 'absent') {
            # No web.config of its own. ANCM is wired per-application BY web.config,
            # so that normally settles it - except <system.webServer> inherits into
            # child applications unless a parent wraps it in
            # <location inheritInChildApplications="false">. The nearest ancestor
            # that HAS a web.config decides; anything above it is already shadowed.
            foreach ($anc in (Get-CxAncestorApps -Model $model -App $app)) {
                $awc = Get-CxWebConfigCoreState -PhysicalPath $anc.PhysicalPath
                if ($awc.State -ne 'ok') { continue }
                if ($awc.IsCore -and $awc.Inheritable) {
                    $isCore = $true
                    $inheritedFrom = "$($anc.Site)$($anc.AppPath)"
                }
                break
            }

            if (-not $isCore) {
                $msg = if ($wc.DirMissing) {
                    "physical path '$($app.PhysicalPath)' does not exist, so there is no web.config - IIS cannot serve this app at all, and it is certainly not ASP.NET Core"
                } else {
                    "no web.config at '$($app.PhysicalPath)' - ASP.NET Core in IIS is wired by <aspNetCore> in web.config, so this is a static or ASP.NET Framework app and needs no 'No Managed Code' pool. Normal for the stock Default Web Site."
                }
                Add-F (New-Finding -Check 'poolRuntime' -Severity 'info' -Code 'WEBCONFIG_ABSENT' -Target $label `
                    -Message $msg -Data @{ physicalPath = $app.PhysicalPath; dirMissing = [bool]$wc.DirMissing })
                continue
            }
        }

        if (-not $isCore) { continue }   # Framework app: a managed runtime is correct

        $via = if ($inheritedFrom) { " (<aspNetCore> inherited from '$inheritedFrom'; it has no web.config of its own)" } else { '' }

        $pool = $model.Pools[$app.Pool]
        if (-not $pool) {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'POOL_NOT_FOUND' -Target $label `
                -Message "pool '$($app.Pool)' is not declared in applicationHost.config")
            continue
        }

        $mrv = $pool.ManagedRuntimeVersion
        if ($mrv -eq '') {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'pass' -Target $label `
                -Message "ASP.NET Core app on pool '$($app.Pool)' is No Managed Code$via")
        } else {
            $shown = if ($null -eq $mrv) { '<inherited default>' } else { $mrv }
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'warn' -Code 'POOL_NOT_NO_MANAGED_CODE' -Target $label `
                -Message "ASP.NET Core app but pool '$($app.Pool)' has managedRuntimeVersion=$shown - it must be '' (No Managed Code) or the app emits NO telemetry at all$via" `
                -Data @{ pool = $app.Pool; managedRuntimeVersion = $mrv; inheritedFrom = $inheritedFrom })
        }
    }

    # -- g: are the IIS access logs actually reachable by the collector? -------
    # Spans prove the profiler works. This proves the OTHER half of IIS telemetry:
    # a site whose logs land somewhere the filelog receiver never looks ships
    # nothing, and until now said nothing either.
    #
    # Assign, THEN iterate. Do not write `foreach (... in @(Test-CxIisLogCoverage ...))`:
    # the function returns `,@(...)` to stop PowerShell unrolling its array, so it
    # emits ONE pipeline object that IS the array - and @() around a pipeline wraps
    # that in a second array. The loop then runs once with the whole array, Add-F
    # appends it as a single element, and every log finding renders as one row of
    # System.Object[] instead of N rows. Assignment collects the single item
    # directly and keeps the array intact.
    $logFindings = Test-CxIisLogCoverage -AppHostConfig $AppHostConfig
    foreach ($lf in $logFindings) { Add-F $lf }

    return ,@($findings.ToArray())
}

function Test-CxIisLogCoverage {
    <#
      Compare where IIS writes access logs against what the collector is told to
      read. Returns findings; never throws.

      Coverage is judged against the include globs the collector config carries:
      its built-in default plus whatever CX_IIS_LOG_DIR_n currently hold. Reading
      the env vars rather than the YAML is deliberate - the config is Fleet-owned
      and may not be readable here, but the env vars ARE the contract the deploy
      scripts publish and the config consumes.
    #>
    [CmdletBinding()]
    param([string] $AppHostConfig)

    $out = New-Object System.Collections.ArrayList
    function Add-L { param($f) [void]$out.Add($f) }

    if (-not (Get-Command Get-IISLogConfig -ErrorAction SilentlyContinue)) {
        Add-L (New-Finding -Check 'iisLogs' -Severity 'unknown' -Code 'HELPER_MISSING' `
            -Message 'Resolve-IISLogPaths.ps1 is not present, so IIS log coverage could not be checked')
        return ,@($out.ToArray())
    }

    $cfg = Get-IISLogConfig -AppHostConfig $AppHostConfig
    if (-not $cfg.Ok) {
        Add-L (New-Finding -Check 'iisLogs' -Severity 'unknown' -Code 'IIS_LOGCONFIG_UNREADABLE' `
            -Message $cfg.Error)
        return ,@($out.ToArray())
    }

    # The globs in force: the shipped default, plus each populated slot.
    $globs = @($script:CxDefaultLogGlob)
    $slotVals = @()
    for ($i = 1; $i -le $script:CxLogDirSlotCount; $i++) {
        $v = [Environment]::GetEnvironmentVariable("CX_IIS_LOG_DIR_$i", 'Machine')
        if ($v) { $slotVals += $v; $globs += (Join-Path $v '**\*.log') }
    }

    if ($cfg.CentralMode -ne 'Site') {
        # One file for the whole host: per-site attribution is gone before the data
        # ever reaches us. Informational, not a fault - it is a valid IIS setup.
        Add-L (New-Finding -Check 'iisLogs' -Severity 'info' -Code 'IIS_CENTRAL_LOGGING' -Target $cfg.CentralDir `
            -Message "centralLogFileMode=$($cfg.CentralMode): all sites write one log under '$($cfg.CentralDir)', so per-site attribution is not available" `
            -Data @{ mode = $cfg.CentralMode; directory = $cfg.CentralDir })
    }

    $uncovered = @{}
    foreach ($site in @($cfg.Sites)) {
        if (-not $site.Enabled) {
            # Absence of logs here is intended. Saying nothing would leave an
            # operator hunting for a collector fault that does not exist.
            Add-L (New-Finding -Check 'iisLogs' -Severity 'info' -Code 'IIS_LOGGING_DISABLED' -Target $site.Name `
                -Message "logging is turned off for site '$($site.Name)' - no access logs are expected from it")
            continue
        }

        if ($site.Format -ne 'W3C') {
            # The receiver's csv_parser keys off a '#Fields:' header line, which only
            # W3C emits. IIS/NCSA/Custom files still tail, but arrive unparsed.
            Add-L (New-Finding -Check 'iisLogs' -Severity 'warn' -Code 'IIS_LOG_FORMAT_UNSUPPORTED' -Target $site.Name `
                -Message "site '$($site.Name)' logs in $($site.Format) format - the collector's csv_parser needs the W3C '#Fields:' header, so these lines arrive unparsed" `
                -Data @{ format = $site.Format })
        }

        $root = $site.LogRoot
        $hit = $false
        foreach ($g in $globs) { if (Test-IISLogDirCovered -Directory $root -Glob $g) { $hit = $true; break } }
        if ($hit) {
            Add-L (New-Finding -Check 'iisLogs' -Severity 'pass' -Target $site.Name `
                -Message "access logs at '$root' are covered by a collector include")
        } else {
            $uncovered[$site.Directory] = $true
            Add-L (New-Finding -Check 'iisLogs' -Severity 'warn' -Code 'IIS_LOGDIR_NOT_COVERED' -Target $site.Name `
                -Message "site '$($site.Name)' writes access logs to '$root', which no collector include matches - these logs never reach Coralogix. Re-run Instrument-IIS.ps1 to publish CX_IIS_LOG_DIR_n, then restart the collector." `
                -Data @{ logRoot = $root; directory = $site.Directory; globs = $globs })
        }
    }

    # More distinct roots than slots: the extras cannot be expressed at all,
    # because ${env:VAR} cannot expand into multiple include list entries.
    $needed = @($uncovered.Keys).Count + @($slotVals).Count
    if ($needed -gt $script:CxLogDirSlotCount) {
        Add-L (New-Finding -Check 'iisLogs' -Severity 'warn' -Code 'IIS_LOGDIR_SLOTS_EXCEEDED' `
            -Message "this host needs $needed distinct log directories but the collector config declares only $($script:CxLogDirSlotCount) CX_IIS_LOG_DIR_n slots - add slots to the config template or consolidate the log directories" `
            -Data @{ needed = $needed; slots = $script:CxLogDirSlotCount })
    }

    return ,@($out.ToArray())
}

# ---------------------------------------------------------------------------
# Main body - runs ONLY on direct execution, never when dot-sourced.
# Dot-sourcing sets $MyInvocation.InvocationName to '.' (verified on 5.1 for
# `. .\x.ps1`, `. (Join-Path ...)`, and `powershell -Command ". 'x.ps1'"`).
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ''
    Write-Host "IIS instrumentation check on $env:COMPUTERNAME  ($(Get-Date -Format 's'))"

    # NOT $args - that is an automatic variable holding unbound arguments.
    # AppHostConfig is only forwarded when the caller actually supplied one:
    # passing '' would override the function's default with an empty path.
    $callArgs = @{
        ExpectedOtlpEndpoint = $ExpectedOtlpEndpoint
    }
    if ($AppHostConfig) { $callArgs['AppHostConfig'] = $AppHostConfig }
    if ($BackupRoot)    { $callArgs['BackupRoot']    = $BackupRoot }

    $result = Test-IISInstrumentation @callArgs
    $code   = Get-GradedExitCode -Findings $result

    Write-FindingTable   -Findings $result -Title 'IIS instrumentation' -Quiet:$Quiet
    Write-FindingSummary -Findings $result -Label 'IIS-INSTRUMENTATION' -ExitCode $code

    if ($PassThru) { $result }
    exit $code
}
