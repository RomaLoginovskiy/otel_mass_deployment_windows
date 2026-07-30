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
    f. poolRuntime    classify each application's ACTUAL runtime (ASP.NET Core /
                      ASP.NET Framework / non-.NET / undeterminable) and check it
                      against its pool's CLR setting. "No Managed Code" is a pool
                      property, not an app property: it is correct for ASP.NET
                      Core, wrong for ASP.NET Framework, and says nothing at all
                      about a static, native, PHP, Node or reverse-proxied app

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
    # Force an application's runtime when detection cannot decide. Keyed by APP IDENTITY -
    # "<Site><virtual path>", root apps ending in '/' - which is the same string this script
    # prints in the Target column, so a key can be copied straight off the output. That is a
    # DIFFERENT key space from Instrument-IIS.ps1's -ServiceNameOverrides, which is keyed by
    # the derived service name; the slash-less form is accepted as an alias for a root app.
    # Pass the SAME overrides the install used, or the two disagree about what is instrumented.
    [hashtable] $RuntimeOverrides = @{},
    # Defaults to the env var, as Instrument-IIS.ps1 does, so the install and this check see
    # the same overrides without either caller having to remember to pass them.
    [string] $RuntimeOverridesJson = $env:CX_RUNTIME_OVERRIDES_JSON,
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

# Application runtime classification, shared with Instrument-IIS.ps1 so the installer and the
# doctor cannot disagree about which apps are instrumentable. Guarded the same way: without it
# the poolRuntime sub-check reports HELPER_MISSING (unknown) and every other check still runs.
# Deliberately NOT reimplemented here - two copies of this policy is how the repo ended up with
# two contradictory explanations of "No Managed Code".
$rtLib = Join-Path $script:CxIisHere 'Resolve-IISAppRuntime.ps1'
if (Test-Path -LiteralPath $rtLib -ErrorAction SilentlyContinue) {
    try { . $rtLib } catch { }
}

# Node helpers, for iisnode applications - Node hosted BY IIS, whose node.exe is a child of w3wp
# and inherits the APP POOL's environment. Two things here need them: Test-CxNodeAppIsEsm (without
# it Resolve-IISAppRuntime answers "CommonJS" for every app, and a CommonJS answer for an ESM app
# is the silent-zero-telemetry case this doctor exists to catch) and the bootstrap parser below.
$nodeLib = Join-Path $script:CxIisHere 'Resolve-NodeServiceNames.ps1'
if (Test-Path -LiteralPath $nodeLib -ErrorAction SilentlyContinue) {
    try { . $nodeLib } catch { }
}
if (-not (Get-Command Get-CxRegisterPathFromNodeOptions -ErrorAction SilentlyContinue)) {
    function Get-CxRegisterPathFromNodeOptions {
        param([string] $NodeOptions)
        if (-not $NodeOptions) { return $null }
        $m = [regex]::Match($NodeOptions, '--require(?:=|\s+)(?:"([^"]+)"|(\S+))')
        if (-not $m.Success) { return $null }
        if ($m.Groups[1].Success) { return $m.Groups[1].Value }
        return $m.Groups[2].Value
    }
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

# web.config reading and URL-hierarchy ancestry now live in Resolve-IISAppRuntime.ps1
# (Get-CxWebConfigRuntimeState / Get-CxAppAncestorPaths), because Instrument-IIS.ps1 needs the
# identical answers and a second copy here would drift. Get-CxWebConfigCoreState survives there
# as a back-compat shim with the same shape (.State/.IsCore/.Inheritable/.DirMissing/.Error).
#
# No local fallback on purpose. A degraded reimplementation that answers DIFFERENTLY from the
# installer is worse than no answer at all - it would report an app as correctly instrumented
# when the installer skipped it. If the helper is missing, the poolRuntime sub-check says so
# with HELPER_MISSING (unknown) and defers, which is what 'unknown' is for.

function Get-CxAncestorApps {
    <#
      Applications on the same site that sit ABOVE this one in the URL hierarchy,
      nearest first. Thin adapter over the shared Get-CxAppAncestorPaths: this file's
      callers pass ($Model, $App), the shared one takes a flat app collection so the
      installer's service-map records feed it unchanged.
    #>
    [CmdletBinding()]
    param($Model, $App)
    if (-not (Get-Command Get-CxAppAncestorPaths -ErrorAction SilentlyContinue)) { return ,@() }
    return (Get-CxAppAncestorPaths -Apps $Model.Apps -Site $App.Site -AppPath $App.AppPath)
}

function Test-CxAspNetCoreApp {
    <#
      Back-compat wrapper: $true / $false / $null-when-unknowable. Prefer
      Resolve-IISAppRuntime, which says WHICH runtime and WHY.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)
    if (-not (Get-Command Get-CxWebConfigRuntimeState -ErrorAction SilentlyContinue)) { return $null }
    $s = Get-CxWebConfigRuntimeState -PhysicalPath $PhysicalPath
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
        [string] $BackupRoot,
        # See the script-level parameter for the key space and why it differs from
        # -ServiceNameOverrides.
        [hashtable] $RuntimeOverrides = @{},
        [string] $RuntimeOverridesJson
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
            # WHOSE profiler, not merely whether one is registered. Only ONE CLR profiler can attach
            # to a process, so a GUID that is not ours means another vendor's agent owns IIS here and
            # our .NET instrumentation produces NOTHING - while a check that stopped at "a profiler
            # is registered and enabled" graded that host a pass. That is the reads-healthy /
            # emits-nothing report this tooling exists to prevent.
            #
            # Decided by comparing against OUR CLSID, never by recognising a vendor: an agent we have
            # never heard of must fail this too. The name is a hint for the operator, nothing more.
            $otelClsid = '{918728DD-259F-4A6A-AC2B-B85E1B658318}'
            $foreign = @()
            foreach ($pair in @(@('CORECLR_PROFILER', $clrGuid), @('COR_PROFILER', $fwGuid))) {
                $n, $g = $pair
                if ($g -and $g -ne $otelClsid) { $foreign += "$n=$g" }
            }
            if (@($foreign).Count -gt 0) {
                # Path is the stronger vendor signal than the CLSID, and it is the one an operator can
                # act on: it names the product and the tree to uninstall or exclude.
                $paths = @('CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH','COR_PROFILER_PATH_64','COR_PROFILER_PATH' |
                            ForEach-Object { Get-CxEnvEntry -Entries $entries -Name $_ } | Where-Object { $_ } | Select-Object -Unique)
                $vendor = switch -Regex ($paths -join ';') {
                    'the reference agent|the reference agent'   { 'the reference agent'; break }
                    'newrelic'             { 'New Relic'; break }
                    'appdynamics|appdynam' { 'AppDynamics'; break }
                    'datadog|dd-trace'     { 'Datadog'; break }
                    'elastic'              { 'Elastic APM'; break }
                    'instana'              { 'Instana'; break }
                    default                { 'an unidentified third-party agent' }
                }
                Add-F (New-Finding -Check 'profiler' -Severity 'fail' -Code 'PROFILER_FOREIGN_OWNER' -Target $svc `
                    -Message "$svc registers a CLR profiler that is NOT the OpenTelemetry one ($($foreign -join ', ')), and only one profiler can attach to a process - so .NET auto-instrumentation emits NOTHING for anything this service starts, however healthy the collector is. The DLL path points at $vendor$(if ($paths) { " ($($paths -join ', '))" }). Decide which agent owns .NET on this host: keep theirs and instrument these applications another way, or remove/exclude theirs and re-run the install." `
                    -Data @{ foreign = $foreign; expected = $otelClsid; paths = @($paths); vendorHint = $vendor })
            } else {
                # REGISTERED is not LOADED, and the difference is the whole finding. MEASURED on a
                # host running the reference agent in fullstack mode: W3SVC carried our CLSID and all
                # four path variants, every value correct - and no process on the box had
                # OpenTelemetry.AutoInstrumentation.Native.dll in it. the reference agent injects at process
                # creation, into w3wp AND into the dotnet/apphost children of out-of-process apps, and
                # only one CLR profiler can attach - so ours never did. This check graded that host a
                # pass, which is the false green this tooling exists to prevent.
                #
                # Evidence, not inference: enumerate the worker processes and look for our library.
                # Absence is only meaningful once a worker is actually up, so a host with no worker
                # running is 'unknown', never a fail - an idle pool has nothing to load it into yet.
                $ourDll  = 'OpenTelemetry.AutoInstrumentation.Native'
                $workers = @()
                try {
                    $workers = @(Get-CimInstance Win32_Process -ErrorAction Stop |
                        Where-Object { $_.Name -in @('w3wp.exe','dotnet.exe') -or ($_.CommandLine -and $_.CommandLine -match '\\aspnetcorev2') })
                } catch { }
                if (@($workers).Count -eq 0) {
                    Add-F (New-Finding -Check 'profiler' -Severity 'unknown' -Code 'PROFILER_LOAD_UNVERIFIED' -Target $svc `
                        -Message "$svc registers our profiler correctly, but no IIS worker process is running, so whether the profiler actually LOADS could not be verified. Send a request to an application and re-run - a registration that never loads is the failure mode this check exists for.")
                } else {
                    $withOurs = @(); $withForeign = @()
                    foreach ($w in $workers) {
                        $mods = @()
                        try { $mods = @((Get-Process -Id $w.ProcessId -ErrorAction Stop).Modules | Select-Object -ExpandProperty ModuleName) } catch { continue }
                        if ($mods -match $ourDll) { $withOurs += $w.ProcessId }
                        # Any other vendor's CLR profiler in the same process explains WHY ours is not
                        # there, and is the actionable half for the operator.
                        $f = @($mods | Where-Object { $_ -match 'the reference agent|newrelic|appdynamics|datadog|elastic.*profiler|instana' } | Select-Object -Unique)
                        if (@($f).Count -gt 0) { $withForeign += "pid $($w.ProcessId): $($f -join ',')" }
                    }
                    if (@($withOurs).Count -gt 0) {
                        Add-F (New-Finding -Check 'profiler' -Severity 'pass' -Target $svc `
                            -Message "profiler registered AND loaded - our native library is in $(@($withOurs).Count) of $(@($workers).Count) worker process(es) (coreclr=$([bool]$clrGuid) framework=$([bool]$fwGuid), enabled)" `
                            -Data @{ coreclrProfiler = $clrGuid; corProfiler = $fwGuid; loadedIn = @($withOurs) })
                    } else {
                        Add-F (New-Finding -Check 'profiler' -Severity 'fail' -Code 'PROFILER_NOT_LOADED_IN_PROCESS' -Target $svc `
                            -Message "$svc registers OUR profiler correctly, but our native library ($ourDll.dll) is loaded in NONE of the $(@($workers).Count) running worker process(es) - so .NET auto-instrumentation produces no spans while every variable reads as configured.$(if (@($withForeign).Count -gt 0) { " Another vendor's CLR profiler is in those processes instead ($($withForeign -join '; ')), and only ONE profiler can attach per process - it injects at process creation and wins over environment-based registration." } else { ' No other vendor profiler was found either, so check the profiler DLL path and that the worker restarted after the install.' }) Registration is not attachment: this is the state a check on the environment alone reports as healthy." `
                            -Data @{ workers = @($workers | ForEach-Object { $_.ProcessId }); foreign = @($withForeign) })
                    }
                }
            }

            # Our GUID with somebody else's library is the subtler half, and it is silent: the CLR
            # loads that DLL, asks it for our CLSID, gets nothing, and attaches no profiler. It
            # happens when a bitness-specific path from another agent outranks the unsuffixed one.
            if (@($foreign).Count -eq 0) {
                $home = Get-CxEnvEntry -Entries $entries -Name 'OTEL_DOTNET_AUTO_HOME'
                foreach ($pn in @('CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH',
                                  'COR_PROFILER_PATH_64','COR_PROFILER_PATH_32','COR_PROFILER_PATH')) {
                    $dll = Get-CxEnvEntry -Entries $entries -Name $pn
                    if (-not $dll -or -not $home) { continue }
                    if ($dll -notlike "$home*") {
                        Add-F (New-Finding -Check 'profiler' -Severity 'fail' -Code 'PROFILER_PATH_FOREIGN' -Target "$svc/$pn" `
                            -Message "$pn points outside OTEL_DOTNET_AUTO_HOME while CORECLR_PROFILER is ours: '$dll' is not under '$home'. The CLR loads that library, asks it for our CLSID and gets nothing, so no profiler attaches and no spans are produced - with every variable reading as configured. The CLR prefers the *_PATH_64 name over the unsuffixed one, so this is what a leftover from another agent looks like." `
                            -Data @{ path = $dll; home = $home; name = $pn })
                    }
                }
            }
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

    # -- f: what runtime is each app, and does its pool match? ----------------
    # "No Managed Code" is a property of the POOL, not of the application. It means IIS does
    # not load the .NET Framework CLR - it does NOT mean the app is unmanaged. So the pool
    # setting alone decides nothing: it is correct for ASP.NET Core, wrong for ASP.NET
    # Framework, and irrelevant to a static, native, PHP, Node or reverse-proxied app.
    # Classify the app first, then judge the pairing. Policy lives in Resolve-IISAppRuntime.ps1
    # so the installer skips exactly the apps this reports as not instrumentable.
    if (-not (Get-Command Resolve-IISAppRuntime -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'HELPER_MISSING' `
            -Message "Resolve-IISAppRuntime.ps1 was not found next to this script, so application runtimes could not be classified. Deferring rather than guessing: a guess here would report apps as correctly instrumented that the installer skipped.")
    } else {
        # Same JSON-file-first, hashtable-on-top precedence as every other override pair in
        # the deploy scripts. A bad VALUE or an unreadable JSON path is an operator error, not
        # a host condition: graded 'fail' (exit 1) so it cannot be mistaken for a passing run,
        # but converted from the library's throw rather than propagated - this function's
        # contract is that it never throws, and Test-Agent.ps1 relies on that.
        $rtOverrides = $null
        try {
            $rtOverrides = Resolve-IISRuntimeOverrides -Table $RuntimeOverrides -JsonPath $RuntimeOverridesJson
        } catch {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'fail' -Code 'BAD_ARGUMENT' `
                -Message "-RuntimeOverrides could not be parsed: $($_.Exception.Message)")
        }

        foreach ($k in (Get-IISUnmatchedRuntimeOverrideKeys -Overrides $rtOverrides -Apps $model.Apps)) {
            Add-F (New-Finding -Check 'poolRuntime' -Severity 'warn' -Code 'RUNTIME_OVERRIDE_UNMATCHED' -Target $k `
                -Message "-RuntimeOverrides has an entry for '$k' but no such IIS application exists on this host, so that classification is not in force. Usual causes: the key was copied from -ServiceNameOverrides (a different key space - runtime keys are '<Site><virtual path>' with root apps ending in '/'), a typo, or a decommissioned site.")
        }

        # ONE read per application, cached - the loop below needs the state twice (once for the
        # WEBCONFIG_* findings, once via the classifier) and the iisnode-per-pool tally has to be
        # complete BEFORE any app is judged, because "can a pool-level OTEL_SERVICE_NAME name this
        # app" is a question about the pool's other tenants.
        #
        # The tally counts apps whose OWN web.config declares iisnode. An app that inherits the
        # handler from a parent is still classified (and instrumented) correctly, it just does not
        # add to the count - so a pool shared between a parent and an inheriting child can escape
        # the sharedPool finding here. Instrument-IIS.ps1 gates on the full records, inheritance
        # included, so the install decision is not affected; only this report can under-warn.
        $wcCache      = @{}
        $iisnodePools = @{}
        $claimPools   = @{}
        foreach ($app in $model.Apps) {
            $st = Get-CxWebConfigRuntimeState -PhysicalPath $app.PhysicalPath
            $wcCache["$($app.Site)$($app.AppPath)"] = $st
            if (@($st.NodeEvidence).Count -gt 0) {
                if ($iisnodePools.ContainsKey($app.Pool)) { $iisnodePools[$app.Pool]++ }
                else { $iisnodePools[$app.Pool] = 1 }
            }
            # Apps that READ OTEL_SERVICE_NAME, whether Node or .NET. Two of these in one pool means
            # the pool-level name can only be right for one of them - the same gate the installer
            # applies, so the doctor does not pass an app the installer refused (or the reverse).
            # Positive evidence only, exactly as the classifier does it.
            if (@($st.NodeEvidence).Count -gt 0 -or @($st.CoreEvidence).Count -gt 0 -or @($st.FrameworkEvidence).Count -gt 0) {
                if ($claimPools.ContainsKey($app.Pool)) { $claimPools[$app.Pool]++ }
                else { $claimPools[$app.Pool] = 1 }
            }
        }

        foreach ($app in $model.Apps) {
            $label = "$($app.Site)$($app.AppPath)"

            # A read FAILURE is genuinely unknown. A web.config that is simply not there is
            # not, and reporting both as "cannot read web.config" made the stock Default Web
            # Site - wwwroot ships iisstart.htm and no web.config - look like an ACL problem
            # on every host in the fleet. Kept as its own finding because it describes the
            # FILE, where the classification below describes the APPLICATION.
            $wc = $wcCache[$label]
            if ($wc.State -eq 'unreadable' -or $wc.State -eq 'nopath') {
                Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'WEBCONFIG_UNREADABLE' -Target $label `
                    -Message "$($wc.Error) - so this application's runtime cannot be determined" `
                    -Data @{ physicalPath = $app.PhysicalPath; error = $wc.Error })
                continue
            }

            $pool = $model.Pools[$app.Pool]
            if (-not $pool) {
                Add-F (New-Finding -Check 'poolRuntime' -Severity 'unknown' -Code 'POOL_NOT_FOUND' -Target $label `
                    -Message "pool '$($app.Pool)' is not declared in applicationHost.config, so its CLR setting cannot be checked")
                continue
            }

            $anc       = @(Get-CxAncestorApps -Model $model -App $app)
            $ancPaths  = @($anc | ForEach-Object { [string]$_.PhysicalPath })
            $ancLabels = @($anc | ForEach-Object { "$($_.Site)$($_.AppPath)" })
            $ov        = Get-IISRuntimeOverrideFor -Overrides $rtOverrides -Site $app.Site -AppPath $app.AppPath

            $rt = Resolve-IISAppRuntime -PhysicalPath $app.PhysicalPath `
                -PoolManagedRuntimeVersion $pool.ManagedRuntimeVersion `
                -AncestorPhysicalPaths $ancPaths -InheritedFromLabels $ancLabels -Override $ov

            # web.config state, reported ALONGSIDE the verdict rather than instead of it: they
            # answer different questions and an operator needs both ("there is no file" vs
            # "so nothing is instrumented here"). Suppressed when the app turned out to be
            # Core by inheritance - there the missing file is expected, not informative.
            if ($wc.State -eq 'absent' -and $rt.RuntimeSource -ne 'inherited') {
                $msg = if ($wc.DirMissing) {
                    "physical path '$($app.PhysicalPath)' does not exist, so there is no web.config - IIS cannot serve this app at all"
                } else {
                    "no web.config at '$($app.PhysicalPath)' - ASP.NET Core in IIS is wired by <aspNetCore> in web.config and classic ASP.NET by <system.web>, so neither is configured here. Normal for the stock Default Web Site."
                }
                Add-F (New-Finding -Check 'poolRuntime' -Severity 'info' -Code 'WEBCONFIG_ABSENT' -Target $label `
                    -Message $msg -Data @{ physicalPath = $app.PhysicalPath; dirMissing = [bool]$wc.DirMissing })
            }

            if ($ov) {
                Add-F (New-Finding -Check 'poolRuntime' -Severity 'info' -Code 'RUNTIME_OVERRIDE_APPLIED' -Target $label `
                    -Message "runtime forced to $ov by -RuntimeOverrides; detection was not consulted. The install must be given the same override or the two will disagree about what is instrumented." `
                    -Data @{ override = $ov })
            }

            Add-F (New-IISRuntimeFinding -Record $rt -Target $label)

            # -- iisnode: Node hosted BY IIS ------------------------------------
            # Graded separately from the .NET verdict because it is a different process. An
            # iisnode app's node.exe is a CHILD of w3wp and inherits the POOL's environment, so
            # everything the Node doctor checks on a PM2 app has to be checked here on the pool -
            # and Test-NodeInstrumentation cannot see these apps at all, because PM2 does not
            # manage them. Without this block a host could report a clean bill on both doctors
            # while every iisnode app emitted nothing.
            if ($rt.NodeHosting -eq 'iisnode') {
                $poolEnvEff = Get-CxEffectivePoolEnv -Pool $pool -Defaults $model.Defaults
                $nodeOpts   = if ($poolEnvEff -and $poolEnvEff.ContainsKey('NODE_OPTIONS')) { [string]$poolEnvEff['NODE_OPTIONS'] } else { '' }
                $reg        = Get-CxRegisterPathFromNodeOptions -NodeOptions $nodeOpts
                $nodeCount  = if ($iisnodePools.ContainsKey($app.Pool)) { [int]$iisnodePools[$app.Pool] } else { 0 }
                $claimCount = if ($claimPools.ContainsKey($app.Pool))   { [int]$claimPools[$app.Pool]   } else { 0 }

                # Sharing a pool is no longer a verdict on its own. The NAME can live in the
                # application's own web.config <appSettings>, which iisnode promotes into the node
                # child's environment, so a shared pool is instrumentable - the pool just must not
                # carry an OTEL_SERVICE_NAME of its own. Read both sides before deciding.
                $isShared = ($nodeCount -gt 1 -or $claimCount -gt 1)
                $poolSvc  = if ($poolEnvEff -and $poolEnvEff.ContainsKey('OTEL_SERVICE_NAME')) { [string]$poolEnvEff['OTEL_SERVICE_NAME'] } else { '' }
                $perAppSvc = if (Get-Command Get-CxWebConfigAppSetting -ErrorAction SilentlyContinue) {
                    Get-CxWebConfigAppSetting -PhysicalPath $app.PhysicalPath -Key 'OTEL_SERVICE_NAME'
                } else { $null }
                # iisnode copies the pool environment first and appends appSettings after it, and
                # Windows resolves the FIRST entry - so the pool value wins wherever both exist.
                $effSvc   = if ($poolSvc) { $poolSvc } else { $perAppSvc }
                $sharedDetail = if ($nodeCount -gt 1) {
                    "$nodeCount iisnode applications share pool '$($app.Pool)'"
                } else {
                    "pool '$($app.Pool)' hosts $claimCount applications that read OTEL_SERVICE_NAME (this one plus at least one instrumented .NET application)"
                }

                if ($isShared -and $rt.DotNetRuntime -eq 'AspNetFramework' -and $rt.Instrumentability -eq 'Supported') {
                    Add-F (New-IISNodeFinding -Outcome 'sharedPoolFw' -Record $rt -Target $label -Detail $sharedDetail)
                }
                elseif ($isShared -and $poolSvc) {
                    # Either a name we left behind before per-app naming existed, or one someone
                    # else set. Both shadow the per-app value, and both mis-name a shared pool.
                    Add-F (New-IISNodeFinding -Outcome 'poolNameShadow' -Record $rt -Target $label `
                        -Detail "$sharedDetail, and that pool carries OTEL_SERVICE_NAME='$poolSvc'$(if ($perAppSvc) { " while this application's own web.config asks for '$perAppSvc' - the pool value is what takes effect" })")
                }
                elseif ($isShared -and -not $perAppSvc) {
                    Add-F (New-IISNodeFinding -Outcome 'sharedPool' -Record $rt -Target $label `
                        -Detail "$sharedDetail, and no per-app OTEL_SERVICE_NAME is set in this application's own web.config <appSettings>")
                }
                elseif ($rt.NodeIsEsm) {
                    # Checked BEFORE the bootstrap checks, and it outranks them: an ESM app under
                    # iisnode returns HTTP 500 to every request (ERR_REQUIRE_ESM in its
                    # interceptor), so whether a bootstrap is present is not the interesting fact
                    # about it - and grading it a pass would be a green report on a dead app.
                    Add-F (New-IISNodeFinding -Outcome 'esmUnsupported' -Record $rt -Target $label)
                }
                elseif (-not $nodeOpts -or -not $reg) {
                    Add-F (New-IISNodeFinding -Outcome 'missing' -Record $rt -Target $label `
                        -Detail "Pool '$($app.Pool)' has no NODE_OPTIONS=--require <register>")
                }
                elseif (-not (Test-Path -LiteralPath $reg -ErrorAction SilentlyContinue)) {
                    Add-F (New-IISNodeFinding -Outcome 'stalePath' -Record $rt -Target $label `
                        -Detail "The bootstrap on pool '$($app.Pool)' points at $reg")
                }
                elseif (-not (Get-Command Test-CxNodeAppIsEsm -ErrorAction SilentlyContinue)) {
                    # NodeIsEsm above is only trustworthy when the probe was loadable. Without it
                    # every app reads as CommonJS - and an ESM app under iisnode is a 500, not a
                    # silent success, so say the verdict is undetermined rather than pass it.
                    Add-F (New-Finding -Check 'iisnode' -Severity 'unknown' -Code 'IISNODE_ESM_UNDETERMINED' -Target $label `
                        -Message "the bootstrap is present on pool '$($app.Pool)', but Resolve-NodeServiceNames.ps1 was not next to this script, so this application's module system could not be determined. iisnode cannot host an ES module at all (ERR_REQUIRE_ESM), so if this one is ESM it is returning HTTP 500 rather than reporting telemetry. Copy the full package and re-run.")
                }
                else {
                    # Same bootstrap, two naming shapes: on a dedicated pool the name is on the
                    # pool, on a shared one it is in the app's own web.config. Grading them with
                    # one code would hide which mechanism is actually carrying the name.
                    Add-F (New-IISNodeFinding -Outcome $(if ($isShared) { 'perAppNamed' } else { 'instrumented' }) -Record $rt -Target $label)
                    # Same localhost trap as everywhere else: ::1 first, export silently dropped.
                    $nodeEp = if ($poolEnvEff -and $poolEnvEff.ContainsKey('OTEL_EXPORTER_OTLP_ENDPOINT')) { [string]$poolEnvEff['OTEL_EXPORTER_OTLP_ENDPOINT'] } else { '' }
                    if ($nodeEp -match 'localhost') {
                        Add-F (New-Finding -Check 'iisnode' -Severity 'warn' -Code 'OTLP_ENDPOINT_LOCALHOST' -Target $label `
                            -Message "pool '$($app.Pool)' exports to '$nodeEp'; localhost resolves to ::1 first and the OTLP export is silently dropped. Use http://127.0.0.1:4318." `
                            -Data @{ endpoint = $nodeEp })
                    }
                    if (-not $effSvc) {
                        Add-F (New-Finding -Check 'iisnode' -Severity 'warn' -Code 'IISNODE_SERVICE_NAME_MISSING' -Target $label `
                            -Message "the bootstrap is on pool '$($app.Pool)' but no OTEL_SERVICE_NAME is - not on the pool, and not in this application's own web.config <appSettings> either, which is where a pool-sharing application carries it. Its spans land under the SDK default (unknown_service:node)")
                    }
                }
            }
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
    if ($RuntimeOverrides -and $RuntimeOverrides.Count -gt 0) { $callArgs['RuntimeOverrides'] = $RuntimeOverrides }
    if ($RuntimeOverridesJson) { $callArgs['RuntimeOverridesJson'] = $RuntimeOverridesJson }

    $result = Test-IISInstrumentation @callArgs
    $code   = Get-GradedExitCode -Findings $result

    Write-FindingTable   -Findings $result -Title 'IIS instrumentation' -Quiet:$Quiet
    Write-FindingSummary -Findings $result -Label 'IIS-INSTRUMENTATION' -ExitCode $code

    if ($PassThru) { $result }
    exit $code
}
