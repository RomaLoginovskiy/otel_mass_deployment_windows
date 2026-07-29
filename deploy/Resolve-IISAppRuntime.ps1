<#
.SYNOPSIS
  Classify the actual runtime behind an IIS application, and decide whether the .NET
  OpenTelemetry automatic instrumentation can do anything for it.

.DESCRIPTION
  "No Managed Code" is a property of the APP POOL, not of the application. It means IIS does
  not load the .NET Framework CLR into the worker process. It does NOT mean the application is
  unmanaged: ASP.NET Core apps are managed, they just run on CoreCLR booted by the ASP.NET Core
  Module rather than on the IIS-managed .NET Framework pipeline.

  So neither of these is a sound rule:

      managedRuntimeVersion=""  ->  supported
      managedRuntimeVersion=""  ->  unsupported

  This library classifies the application itself, then derives instrumentability from the
  (runtime, pool) pair:

      DotNetRuntime      AspNetCore | AspNetFramework | NonDotNet | Unknown
      Instrumentability  Supported  | Misconfigured   | Unsupported | RequiresOverride

    ASP.NET Core     in a No Managed Code pool  -> Supported
    ASP.NET Core     in a v4.0/v2.0 pool        -> Misconfigured (still works; see below)
    ASP.NET Framework in a v4.0/v2.0 pool       -> Supported
    ASP.NET Framework in a No Managed Code pool -> Misconfigured (the app cannot run at all)
    non-.NET (static, native/ISAPI, PHP, Node, Java, ARR reverse proxy) -> Unsupported
    undeterminable                                                     -> RequiresOverride

  ON "MISCONFIGURED" FOR ASP.NET CORE. Microsoft's own wording is that setting the .NET CLR
  version to No Managed Code is "optional but recommended" - the app still runs and still
  reports. The pool merely loads a desktop CLR nothing uses. That is a warn, never a failure,
  and the app is still instrumented and still claimed in CX_IIS_SERVICES.

  ON REVERSE PROXIES. An IIS site that ARR-rewrites to a backend process on another port is
  NonDotNet as far as IIS is concerned: the pool's environment never reaches that backend, so
  the backend must be instrumented where it runs. This is NOT the same as ASP.NET Core's
  out-of-process hosting model, where the ASP.NET Core Module launches dotnet.exe as a CHILD of
  w3wp - that child does inherit the pool environment and is instrumented normally.

.NOTES
  Dot-sourced by Instrument-IIS.ps1, Resolve-IISServiceNames.ps1 and Test-IISInstrumentation.ps1,
  and mirrored (inlined) into the standalone misc\Test-CxInstrumentation.ps1.

  HOUSE RULES for everything in this file, because the doctor loads it and a doctor must never
  make things worse than it found them:

    * NO function throws, with exactly one documented exception: Resolve-IISRuntimeOverrides,
      which rejects a bad override value. That path is only reachable when an operator passed
      -RuntimeOverrides explicitly, and a typo there must fail loudly at parse time rather than
      silently classify nothing.
    * NO function requires the WebAdministration module. Test-IISInstrumentation.ps1 avoids it
      on purpose so it still works on a host missing the IIS management tools.
    * NO function mutates anything. Every probe is a read.
    * Source-agnostic: the installer enumerates apps through WebAdministration, the doctor
      parses applicationHost.config. Both feed the same classifier because it takes only a
      physical path, a pool CLR value and a list of ancestor paths.
#>

# Runtime values an operator may force through -RuntimeOverrides. 'Unknown' is deliberately not
# offered: forcing "I cannot tell" is meaningless, and the point of an override is to resolve it.
$script:CxRuntimeOverrideValues = @('AspNetCore', 'AspNetFramework', 'NonDotNet')

# <system.web> children that mean "this is a real ASP.NET Framework application". An EMPTY
# <system.web/>, or one carrying only <httpRuntime>, does not qualify - both turn up in the
# web.config of plain static sites and would misclassify them as Framework.
$script:CxFrameworkSystemWebChildren = @(
    'compilation', 'httpHandlers', 'httpModules', 'authentication', 'authorization',
    'pages', 'sessionState', 'machineKey', 'globalization', 'customErrors', 'membership',
    'roleManager', 'profile', 'siteMap', 'webServices', 'trust', 'identity'
)

# Extensions served by managed handlers in the classic pipeline.
$script:CxClassicPageExtensions = @('*.aspx', '*.asmx', '*.ashx', '*.axd', '*.asax')

function Get-IISAppKey {
    <#
    .SYNOPSIS
      The one canonical identity string for an IIS application: "<Site><virtual path>".

    .DESCRIPTION
      Root application  -> 'Wallet/'            (note the trailing slash)
      Nested at /api    -> 'Wallet/api'

      Byte-identical to the Target column Test-IISInstrumentation.ps1 already prints, so an
      operator can copy a key straight off the diagnostic output into -RuntimeOverrides.

      This is NOT the service-name key space. -ServiceNameOverrides is keyed by the auto-derived
      SERVICE name ('Wallet' for a root app, no trailing slash) because a rename changes the
      label, not the application. The two spaces collide textually for nested apps and differ by
      one character for root apps, which is exactly why there is a single former for each and
      why Resolve-IISRuntimeOverrides accepts the slash-less form as an alias.
    #>
    [CmdletBinding()]
    param(
        [string] $Site,
        [string] $AppPath
    )

    $p = [string]$AppPath
    if (-not $p) { $p = '/' }
    $p = $p.Trim()
    if (-not $p.StartsWith('/')) { $p = '/' + $p }
    # Collapse '//' and drop a trailing slash on nested paths ('/api/' -> '/api'), but keep the
    # root as the bare '/' so 'Wallet/' and 'Wallet' are distinguishable before aliasing.
    while ($p.Contains('//')) { $p = $p.Replace('//', '/') }
    if ($p.Length -gt 1) { $p = $p.TrimEnd('/') }
    return ("{0}{1}" -f $Site, $p)
}

function Get-CxAppAncestorPaths {
    <#
    .SYNOPSIS
      Applications on the same site sitting ABOVE this one in the URL hierarchy, nearest first.

    .DESCRIPTION
      IIS configuration inheritance follows the URL path, not the filesystem, so this - and not
      a walk up the physical directory tree - is how a child application finds the web.config it
      may be inheriting <aspNetCore> from.

      Duck-typed: -Apps is any collection whose members expose .Site, .AppPath and .PhysicalPath.
      Both the Get-IISServiceMap record list and the doctor's $model.Apps satisfy that, which is
      what keeps the two enumeration paths on one implementation.
    #>
    [CmdletBinding()]
    param(
        $Apps,
        [string] $Site,
        [string] $AppPath
    )

    if (-not $Apps) { return ,@() }
    $self = ([string]$AppPath).TrimEnd('/')          # '/' -> '',  '/api' -> '/api'
    $out = @($Apps | Where-Object {
        $_.Site -eq $Site -and $_.AppPath -ne $AppPath -and
        ($_.AppPath -eq '/' -or $self.StartsWith((([string]$_.AppPath).TrimEnd('/') + '/'), [StringComparison]::OrdinalIgnoreCase))
    })
    return ,@($out | Sort-Object { ([string]$_.AppPath).Length } -Descending)
}

function Get-CxWebConfigRuntimeState {
    <#
    .SYNOPSIS
      Read an application's own web.config once and answer both runtime questions from it.

    .DESCRIPTION
      Supersedes Get-CxWebConfigCoreState, which answered only the ASP.NET Core half. Same four
      states, same semantics, plus FrameworkEvidence harvested from the SAME parsed DOM - one
      file read, both answers, no extra I/O.

        nopath      the application has no physicalPath, so there is nothing to look at
        absent      no web.config there (DirMissing also says the folder itself is gone).
                    ANCM is wired BY web.config, so barring inheritance from a parent
                    application this is not an ASP.NET Core app
        unreadable  it exists but could not be opened or parsed - Error carries the reason,
                    which is the only way to tell an ACL apart from malformed XML
        ok          parsed; IsCore and FrameworkEvidence are authoritative

      Distinguishing absent from unreadable is load-bearing: stock IIS ships
      C:\inetpub\wwwroot with iisstart.htm and no web.config at all, so folding them together
      reported a permissions problem on essentially every host in the fleet.

      <aspNetCore> is matched with //aspNetCore because `dotnet publish` wraps the block in
      <location path="." inheritInChildApplications="false"> rather than putting it directly
      under <system.webServer>. Inheritable reports whether that <location> lets the setting
      flow into child applications - publish emits inheritInChildApplications="false" precisely
      to stop it, and when it is absent a child app with no web.config of its own still gets
      ANCM from the parent.

      Reads through [System.IO.File] rather than Test-Path/Get-Content on purpose: the .NET
      exceptions distinguish not-found from access-denied, where Test-Path under
      SilentlyContinue returns $false for both.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)

    # $Reason, not $Error: a parameter named Error would shadow the automatic $Error collection.
    function New-State {
        param($State, $IsCore, $Inheritable = $false, $DirMissing = $false, $Reason = $null, $FrameworkEvidence = @(), $CoreEvidence = @())
        [pscustomobject]@{
            State             = $State
            IsCore            = $IsCore
            Inheritable       = $Inheritable
            DirMissing        = $DirMissing
            Error             = $Reason
            FrameworkEvidence = @($FrameworkEvidence)
            CoreEvidence      = @($CoreEvidence)
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

    # -- ASP.NET Core --------------------------------------------------------------------
    $core = $x.SelectSingleNode('//aspNetCore')
    $inheritable = $true
    $coreEv = New-Object System.Collections.Generic.List[string]
    if ($core) {
        [void]$coreEv.Add('<aspNetCore>')
        $hm = [string]$core.GetAttribute('hostingModel')
        if ($hm) { [void]$coreEv.Add("hostingModel=$hm") }
        foreach ($loc in @($core.SelectNodes('ancestor::location'))) {
            $v = [string]$loc.GetAttribute('inheritInChildApplications')
            if ($v -match '^\s*(false|0)\s*$') { $inheritable = $false; break }
        }
    }
    # Corroboration only - never enough on its own to call something Core.
    try {
        foreach ($h in @($x.SelectNodes('//handlers/add'))) {
            if (([string]$h.GetAttribute('modules')) -match 'AspNetCoreModule') {
                [void]$coreEv.Add('handlers/AspNetCoreModule'); break
            }
        }
    } catch {}

    # -- ASP.NET Framework: POSITIVE evidence only ----------------------------------------
    # Never the pool's managedRuntimeVersion. That attribute is absent by default and defaults
    # to v4.0, so "no <aspNetCore> and pool is v4.0" would classify every static site on
    # DefaultAppPool as Framework - reintroducing exactly the over-claim this file exists to
    # remove.
    $fw = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($sw in @($x.SelectNodes('//system.web'))) {
            foreach ($child in @($sw.ChildNodes)) {
                if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ($script:CxFrameworkSystemWebChildren -contains $child.LocalName) {
                    $tok = "system.web/$($child.LocalName)"
                    if (-not $fw.Contains($tok)) { [void]$fw.Add($tok) }
                }
            }
        }
    } catch {}
    try {
        # A managed handler or module - type="Namespace.Class, Assembly" - can only run in the
        # managed pipeline, which means a CLR-loading pool and a Framework app.
        foreach ($n in @($x.SelectNodes('//system.webServer/handlers/add')) + @($x.SelectNodes('//system.webServer/modules/add'))) {
            $t = [string]$n.GetAttribute('type')
            if ($t -and $t -notmatch 'AspNetCoreModule') {
                if (-not $fw.Contains('managed handler/module type')) { [void]$fw.Add('managed handler/module type') }
            }
            $p = [string]$n.GetAttribute('path')
            if ($p -match '\.(aspx|asmx|ashx|axd)$') {
                if (-not $fw.Contains('classic handler mapping')) { [void]$fw.Add('classic handler mapping') }
            }
        }
    } catch {}
    try {
        if ($x.SelectSingleNode('//runtime/assemblyBinding')) { [void]$fw.Add('runtime/assemblyBinding') }
        if ($x.SelectSingleNode('//system.web.extensions'))   { [void]$fw.Add('system.web.extensions') }
        if ($x.SelectSingleNode('//system.serviceModel'))     { [void]$fw.Add('system.serviceModel') }
    } catch {}

    return (New-State 'ok' ([bool]$core) -Inheritable $inheritable -FrameworkEvidence $fw.ToArray() -CoreEvidence $coreEv.ToArray())
}

function Get-CxWebConfigCoreState {
    <#
      Back-compat shim for the pre-classification callers. Prefer Get-CxWebConfigRuntimeState,
      which answers the Framework half too. Shape is unchanged, so existing property access
      (.State / .IsCore / .Inheritable / .DirMissing / .Error) keeps working.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)
    return (Get-CxWebConfigRuntimeState -PhysicalPath $PhysicalPath)
}

function Get-CxAppFilesystemEvidence {
    <#
    .SYNOPSIS
      Cheap, non-recursive probes of the application root.

    .DESCRIPTION
      Root directory only. No recursion, no assembly metadata: a fleet deploy touches every app
      on every host, and a recursive scan of a content share is how an installer starts taking
      minutes instead of seconds.

      Accessible reports whether the probes could run at all. A denied ACL or a dead UNC path
      must land on Unknown, never on NonDotNet - "I could not look" is not "there is nothing
      there", and reporting the second as the first is how an operator gets sent to fix the
      wrong thing.
    #>
    [CmdletBinding()]
    param([string] $PhysicalPath)

    $ev = New-Object System.Collections.Generic.List[string]
    if (-not $PhysicalPath) { return [pscustomobject]@{ Accessible = $false; Evidence = @() } }

    try {
        if (-not [System.IO.Directory]::Exists($PhysicalPath)) {
            return [pscustomobject]@{ Accessible = $false; Evidence = @() }
        }
    } catch {
        return [pscustomobject]@{ Accessible = $false; Evidence = @() }
    }

    $accessible = $true
    try {
        foreach ($pat in $script:CxClassicPageExtensions) {
            $hit = @([System.IO.Directory]::EnumerateFiles($PhysicalPath, $pat, [System.IO.SearchOption]::TopDirectoryOnly) | Select-Object -First 1)
            if ($hit.Count -gt 0) {
                $name = [System.IO.Path]::GetFileName($hit[0])
                if ($name -match '(?i)^global\.asax$') { [void]$ev.Add('Global.asax') }
                else { if (-not $ev.Contains('classic page files')) { [void]$ev.Add('classic page files') } }
            }
        }
    } catch { $accessible = $false }

    try {
        foreach ($pat in @('*.runtimeconfig.json', '*.deps.json')) {
            $hit = @([System.IO.Directory]::EnumerateFiles($PhysicalPath, $pat, [System.IO.SearchOption]::TopDirectoryOnly) | Select-Object -First 1)
            if ($hit.Count -gt 0) { [void]$ev.Add('dotnet publish artifacts'); break }
        }
    } catch {}

    try {
        $bin = Join-Path $PhysicalPath 'bin'
        if ([System.IO.Directory]::Exists($bin)) {
            $hit = @([System.IO.Directory]::EnumerateFiles($bin, '*.dll', [System.IO.SearchOption]::TopDirectoryOnly) | Select-Object -First 1)
            if ($hit.Count -gt 0) { [void]$ev.Add('bin/*.dll') }
        }
    } catch {}

    return [pscustomobject]@{ Accessible = $accessible; Evidence = @($ev.ToArray()) }
}

function Get-IISAppInstrumentability {
    <#
    .SYNOPSIS
      The policy table. Pure - no I/O, no side effects, no host access.

    .DESCRIPTION
      PoolClrLoads is the NORMALIZED pool input, not the raw attribute:

          managedRuntimeVersion=""       -> $false  (No Managed Code)
          managedRuntimeVersion="v4.0"   -> $true
          attribute absent               -> $true   (IIS defaults it to v4.0)

      Normalizing here is what lets the installer and the doctor agree. WebAdministration
      resolves an absent attribute to 'v4.0' before we ever see it, so the installer physically
      cannot reproduce the doctor's absent-vs-empty distinction; keying policy on the boolean
      means it never has to. The raw value is carried separately, for message text only.
    #>
    [CmdletBinding()]
    param(
        [string] $Runtime,
        [bool]   $PoolClrLoads
    )

    switch ($Runtime) {
        'AspNetCore'      { if ($PoolClrLoads) { return 'Misconfigured' } else { return 'Supported' } }
        'AspNetFramework' { if ($PoolClrLoads) { return 'Supported' }     else { return 'Misconfigured' } }
        'NonDotNet'       { return 'Unsupported' }
        default           { return 'RequiresOverride' }
    }
}

function Resolve-IISAppRuntime {
    <#
    .SYNOPSIS
      Classify one IIS application. The entry point every caller uses.

    .PARAMETER PhysicalPath
      The application's resolved physical path. Empty means "no physicalPath in config".

    .PARAMETER PoolManagedRuntimeVersion
      $null   the attribute is absent (only the applicationHost.config reader can tell)
      ''      No Managed Code
      'v4.0'  / 'v2.0'  a CLR-loading pool
      Both $null and a version normalize to PoolClrLoads = $true.

      DELIBERATELY UNTYPED. Declaring it [string] would make PowerShell coerce $null to '',
      collapsing "attribute absent" (which means v4.0) into "No Managed Code" - the exact
      inversion of the distinction Get-CxAppHostModel goes out of its way to preserve. Every
      ASP.NET Core app on a default pool would then report as correctly configured.

    .PARAMETER PoolFound
      Whether the pool was declared at all. Recorded, never branched on: POOL_NOT_FOUND is a
      configuration finding of its own and the caller that knows about pools owns it.

    .PARAMETER AncestorPhysicalPaths
      Physical paths of the URL-hierarchy ancestors, NEAREST FIRST, from Get-CxAppAncestorPaths.

    .PARAMETER Override
      An operator-forced runtime. Short-circuits all detection.

    .PARAMETER InheritedFromLabels
      Optional labels parallel to -AncestorPhysicalPaths, used only to name the ancestor an
      inherited <aspNetCore> came from.
    #>
    [CmdletBinding()]
    param(
        [string] $PhysicalPath,
        $PoolManagedRuntimeVersion,          # untyped on purpose - see .PARAMETER above
        [bool] $PoolFound = $true,
        [string[]] $AncestorPhysicalPaths = @(),
        [string[]] $InheritedFromLabels = @(),
        [string] $Override
    )

    # '' is No Managed Code; anything else - including an absent attribute, which arrives here
    # as $null - loads a CLR.
    $poolClrLoads = -not ($null -ne $PoolManagedRuntimeVersion -and ([string]$PoolManagedRuntimeVersion) -eq '')

    $runtime       = 'Unknown'
    $source        = 'none'
    $evidence      = New-Object System.Collections.Generic.List[string]
    $inheritedFrom = $null
    $reason        = ''
    $wcState       = 'nopath'

    if ($Override) {
        $runtime = $Override
        $source  = 'override'
        [void]$evidence.Add("operator override -RuntimeOverrides")
        $reason  = "runtime forced to $Override by -RuntimeOverrides"
        $wc = $null
    } else {
        $wc = Get-CxWebConfigRuntimeState -PhysicalPath $PhysicalPath
        $wcState = $wc.State

        if ($wc.State -eq 'unreadable' -or $wc.State -eq 'nopath') {
            $runtime = 'Unknown'
            $source  = 'none'
            $reason  = "$($wc.Error) - so the application runtime cannot be determined"
        } else {
            if ($wc.State -eq 'ok' -and $wc.IsCore) {
                $runtime = 'AspNetCore'; $source = 'webconfig'
                foreach ($e in $wc.CoreEvidence) { [void]$evidence.Add($e) }
                $reason = 'web.config declares <aspNetCore>, so this is an ASP.NET Core application hosted by the ASP.NET Core Module'
            }
            elseif ($wc.State -eq 'ok' -and @($wc.FrameworkEvidence).Count -gt 0) {
                $runtime = 'AspNetFramework'; $source = 'webconfig'
                foreach ($e in $wc.FrameworkEvidence) { [void]$evidence.Add($e) }
                $reason = "web.config carries classic ASP.NET configuration ($($wc.FrameworkEvidence -join ', ')), so this is an ASP.NET Framework application"
            }
            else {
                # No decisive web.config evidence. Only now is the filesystem worth touching -
                # the common Core and Framework cases were both answered from the DOM, so a
                # 200-app host does not pay for hundreds of directory probes it never reads.
                $fs = Get-CxAppFilesystemEvidence -PhysicalPath $PhysicalPath

                # Try inheritance first, then the filesystem. The ancestor scan runs for a
                # missing web.config AND for one that parsed but said nothing about either
                # runtime: in both cases an ancestor's inheritable <aspNetCore> still applies.
                for ($i = 0; $i -lt @($AncestorPhysicalPaths).Count; $i++) {
                    $awc = Get-CxWebConfigRuntimeState -PhysicalPath $AncestorPhysicalPaths[$i]
                    if ($awc.State -ne 'ok') { continue }
                    if ($awc.IsCore -and $awc.Inheritable) {
                        $runtime = 'AspNetCore'; $source = 'inherited'
                        $inheritedFrom = if ($i -lt @($InheritedFromLabels).Count) { $InheritedFromLabels[$i] } else { $AncestorPhysicalPaths[$i] }
                        [void]$evidence.Add('<aspNetCore> inherited from an ancestor application')
                        $reason = "it has no web.config of its own, but <aspNetCore> is inherited from '$inheritedFrom', so this is an ASP.NET Core application"
                    }
                    # Only the NEAREST ancestor with a readable web.config decides - a further
                    # ancestor cannot override the one between it and this app.
                    break
                }

                if ($runtime -eq 'Unknown') {
                    $fsEv = @($fs.Evidence)
                    if ($fsEv -contains 'Global.asax' -or $fsEv -contains 'classic page files') {
                        $runtime = 'AspNetFramework'; $source = 'filesystem'
                        foreach ($e in $fsEv) { [void]$evidence.Add($e) }
                        $reason = "classic ASP.NET files are present in the application root ($($fsEv -join ', ')), so this is an ASP.NET Framework application"
                    }
                    elseif ($wc.DirMissing) {
                        # Checked BEFORE the accessibility test: DirMissing comes from a
                        # DirectoryNotFoundException, which is a definite "the folder is gone",
                        # not the "I could not look" that an ACL produces. IIS cannot serve
                        # this application at all, so it is certainly not a .NET app.
                        $runtime = 'NonDotNet'; $source = 'filesystem'
                        $reason  = "the physical path '$PhysicalPath' does not exist, so IIS cannot serve this application at all"
                    }
                    elseif (-not $fs.Accessible) {
                        $runtime = 'Unknown'; $source = 'none'
                        $reason  = "the application root '$PhysicalPath' could not be enumerated, so the runtime cannot be determined"
                    }
                    elseif ($fsEv -contains 'bin/*.dll' -or $fsEv -contains 'dotnet publish artifacts') {
                        # Managed assemblies with nothing wiring them to a pipeline. Deliberately
                        # NOT promoted to Framework: static sites carry stray bin folders, and an
                        # out-of-process Core publish puts DLLs in the app root. Guessing here
                        # would put a non-reporting name back into CX_IIS_SERVICES, which is the
                        # whole failure this classifier exists to prevent.
                        $runtime = 'Unknown'; $source = 'filesystem'
                        foreach ($e in $fsEv) { [void]$evidence.Add($e) }
                        $reason = "managed assemblies are present ($($fsEv -join ', ')) but nothing in web.config wires them to a request pipeline, so the runtime is ambiguous"
                    }
                    elseif ($wc.State -eq 'absent') {
                        $runtime = 'NonDotNet'; $source = 'filesystem'
                        $reason  = "no web.config and no .NET content in '$PhysicalPath' - ASP.NET Core is wired by <aspNetCore> in web.config and classic ASP.NET by <system.web>, so this is static or non-.NET content. Normal for the stock Default Web Site."
                    }
                    else {
                        $runtime = 'NonDotNet'; $source = 'webconfig'
                        [void]$evidence.Add('web.config has no .NET runtime configuration')
                        $reason  = "web.config parsed but declares neither <aspNetCore> nor classic ASP.NET configuration - static content, a native/ISAPI handler, or a reverse proxy to a backend process"
                    }
                }
            }
        }
    }

    $instr = Get-IISAppInstrumentability -Runtime $runtime -PoolClrLoads $poolClrLoads

    # Sharpen the reason for the two Misconfigured cases: the pool, not the app, is the problem.
    if ($instr -eq 'Misconfigured') {
        $shown = if ($null -eq $PoolManagedRuntimeVersion) { '<inherited default, v4.0>' } elseif ($PoolManagedRuntimeVersion -eq '') { "'' (No Managed Code)" } else { $PoolManagedRuntimeVersion }
        if ($runtime -eq 'AspNetCore') {
            $reason = "$reason, but its pool has managedRuntimeVersion=$shown. Microsoft recommends No Managed Code for ASP.NET Core; the pool loads a desktop CLR nothing uses. The application still runs and still reports."
        } else {
            $reason = "$reason, but its pool has managedRuntimeVersion=$shown. A .NET Framework application needs a CLR-loading pool (usually v4.0); with No Managed Code its managed handlers cannot load and IIS fails the request."
        }
    }

    return [pscustomobject]@{
        DotNetRuntime             = $runtime
        Instrumentability         = $instr
        RuntimeSource             = $source
        RuntimeEvidence           = @($evidence.ToArray())
        InheritedFrom             = $inheritedFrom
        WebConfigState            = $wcState
        PoolClrLoads              = $poolClrLoads
        PoolManagedRuntimeVersion = $PoolManagedRuntimeVersion
        PoolFound                 = $PoolFound
        RuntimeReason             = $reason
    }
}

function New-IISRuntimeFinding {
    <#
    .SYNOPSIS
      Turn a Resolve-IISAppRuntime record into a finding.

    .DESCRIPTION
      The single mapping from (runtime, instrumentability) to code, severity and message. The
      installer and both doctors all call this, so they cannot drift into describing the same
      condition three different ways - which is the failure mode that produced two
      contradictory explanations of "No Managed Code" in this repo already.

      SEVERITIES, against the model in Write-DeployLog.ps1:

        pass     the pairing is correct
        warn     it runs but is misconfigured. Note FRAMEWORK_POOL_NO_MANAGED_CLR is warn and
                 not fail even though the app is down: 'fail' means the AGENT cannot do its job,
                 and the agent neither caused this nor is blocked by it
        info     NON_DOTNET_APP_NOT_INSTRUMENTED. Must never be warn - the stock Default Web
                 Site is non-.NET and exists on essentially every host, so grading it warn would
                 pin the entire fleet at exit 2 permanently
        unknown  RUNTIME_UNKNOWN_NEEDS_OVERRIDE - could not determine, which is not the same as
                 bad, and must not be reported as a failure

      POOL_NOT_NO_MANAGED_CODE is kept rather than renamed to ASPNETCORE_POOL_HAS_MANAGED_CLR:
      it is the same condition, and it is a stable token the docs already tell operators to grep
      for.

      Returns $null (never throws) if the New-Finding helper is not loaded.
    #>
    [CmdletBinding()]
    param(
        $Record,
        [string] $Target,
        [string] $Check = 'poolRuntime'
    )

    if (-not (Get-Command New-Finding -ErrorAction SilentlyContinue)) { return $null }
    if (-not $Record) { return $null }

    $code = ''
    $sev  = 'info'
    switch ("$($Record.DotNetRuntime)/$($Record.Instrumentability)") {
        'AspNetCore/Supported'          { $code = 'ASPNETCORE_NO_MANAGED_CODE_OK';    $sev = 'pass' }
        'AspNetCore/Misconfigured'      { $code = 'POOL_NOT_NO_MANAGED_CODE';         $sev = 'warn' }
        'AspNetFramework/Supported'     { $code = 'FRAMEWORK_POOL_OK';                $sev = 'pass' }
        'AspNetFramework/Misconfigured' { $code = 'FRAMEWORK_POOL_NO_MANAGED_CLR';    $sev = 'warn' }
        'NonDotNet/Unsupported'         { $code = 'NON_DOTNET_APP_NOT_INSTRUMENTED';  $sev = 'info' }
        default                         { $code = 'RUNTIME_UNKNOWN_NEEDS_OVERRIDE';   $sev = 'unknown' }
    }

    $msg = $Record.RuntimeReason
    if ($code -eq 'NON_DOTNET_APP_NOT_INSTRUMENTED') {
        $msg = "$msg. The .NET OpenTelemetry automatic instrumentation does not apply, so no OTEL_SERVICE_NAME is written and the app is not claimed in CX_IIS_SERVICES. If IIS reverse-proxies to a backend process, instrument that backend where it runs."
    } elseif ($code -eq 'RUNTIME_UNKNOWN_NEEDS_OVERRIDE') {
        $msg = "$msg. Not instrumented and not claimed in CX_IIS_SERVICES rather than guessed. Resolve it with -RuntimeOverrides @{'$Target'='AspNetCore'|'AspNetFramework'|'NonDotNet'}."
    } elseif ($code -eq 'FRAMEWORK_POOL_NO_MANAGED_CLR') {
        $msg = "$msg Fix: set the pool's .NET CLR Version to v4.0."
    } elseif ($code -eq 'POOL_NOT_NO_MANAGED_CODE') {
        $msg = "$msg Fix: set the pool's .NET CLR Version to No Managed Code."
    }

    return (New-Finding -Check $Check -Severity $sev -Code $code -Target $Target -Message $msg -Data @{
        dotNetRuntime             = $Record.DotNetRuntime
        instrumentability         = $Record.Instrumentability
        runtimeSource             = $Record.RuntimeSource
        runtimeEvidence           = @($Record.RuntimeEvidence)
        inheritedFrom             = $Record.InheritedFrom
        webConfigState            = $Record.WebConfigState
        managedRuntimeVersion     = $Record.PoolManagedRuntimeVersion
        poolClrLoads              = $Record.PoolClrLoads
    })
}

function Resolve-IISRuntimeOverrides {
    <#
    .SYNOPSIS
      Normalize -RuntimeOverrides / -RuntimeOverridesJson into one case-insensitive table keyed
      by canonical app key.

    .DESCRIPTION
      Precedence matches every other override pair in this repo: the JSON file first, then the
      hashtable on top.

      Keys are normalized so both forms an operator might reasonably type resolve to the same
      application:

          'Wallet'      -> 'Wallet/'      (the -ServiceNameOverrides shape, accepted as an alias)
          'Wallet/'     -> 'Wallet/'
          'Wallet/api'  -> 'Wallet/api'

      A key with no '/' is a root application, so the slash is appended. Keys are compared
      OrdinalIgnoreCase because IIS site names and virtual paths are case-insensitive.

      THIS IS THE ONE FUNCTION IN THIS FILE THAT THROWS, and only on a value outside
      AspNetCore/AspNetFramework/NonDotNet. A typo in an override must fail at parse time: the
      alternative is silently classifying nothing and reporting success. Unmatched KEYS do not
      throw - the caller reports them as RUNTIME_OVERRIDE_UNMATCHED once it knows which
      applications exist.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Table = @{},
        [string] $JsonPath
    )

    $out = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)

    function Add-Entry {
        param($Map, $Key, $Value)
        $k = ([string]$Key).Trim()
        if (-not $k) { return }
        while ($k.Contains('//')) { $k = $k.Replace('//', '/') }
        if (-not $k.Contains('/')) { $k = $k + '/' }          # root-app alias: 'Wallet' -> 'Wallet/'
        $v = ([string]$Value).Trim()
        $match = @($script:CxRuntimeOverrideValues | Where-Object { $_ -eq $v })
        if ($match.Count -ne 1) {
            throw "Invalid -RuntimeOverrides value '$Value' for '$Key'. Allowed: $($script:CxRuntimeOverrideValues -join ', ')."
        }
        $Map[$k] = $match[0]     # canonical casing, so downstream comparisons are exact
    }

    if ($JsonPath) {
        if (-not (Test-Path -LiteralPath $JsonPath)) { throw "Runtime overrides JSON not found: $JsonPath" }
        $fromFile = $null
        try {
            $fromFile = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
        } catch {
            throw "Runtime overrides JSON is not valid JSON ($JsonPath): $($_.Exception.Message)"
        }
        # Some callers wrap it: { "runtimeOverrides": { ... } }. Accept both shapes.
        if ($fromFile -and $fromFile.PSObject.Properties['runtimeOverrides']) { $fromFile = $fromFile.runtimeOverrides }
        if ($fromFile) {
            foreach ($p in $fromFile.PSObject.Properties) { Add-Entry $out $p.Name $p.Value }
        }
    }

    if ($Table) {
        foreach ($k in @($Table.Keys)) { Add-Entry $out $k $Table[$k] }
    }

    return $out
}

function Get-IISRuntimeOverrideFor {
    <#
      Look up the forced runtime for one application, or '' when none applies. Kept separate
      from the table so the key-forming rule lives in exactly one place.
    #>
    [CmdletBinding()]
    param(
        $Overrides,
        [string] $Site,
        [string] $AppPath
    )
    if (-not $Overrides -or $Overrides.Count -eq 0) { return '' }
    $key = Get-IISAppKey -Site $Site -AppPath $AppPath
    if ($Overrides.Contains($key)) { return [string]$Overrides[$key] }
    # Root applications are keyed 'Site/'; Get-IISAppKey already produces that, but a caller
    # passing an empty AppPath would land here.
    if ($Overrides.Contains("$Site/")) { return [string]$Overrides["$Site/"] }
    return ''
}

function Get-IISUnmatchedRuntimeOverrideKeys {
    <#
      Override keys that matched no application on this host. Almost always one of: a key pasted
      from -ServiceNameOverrides (a different key space), a typo, or a decommissioned site. Any
      of the three means the operator believes a classification is in force that is not, so the
      caller reports these as RUNTIME_OVERRIDE_UNMATCHED (warn).
    #>
    [CmdletBinding()]
    param(
        $Overrides,
        $Apps          # anything exposing .Site and .AppPath
    )
    if (-not $Overrides -or $Overrides.Count -eq 0) { return ,@() }
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($Apps)) { [void]$present.Add((Get-IISAppKey -Site $a.Site -AppPath $a.AppPath)) }
    $out = @(@($Overrides.Keys) | Where-Object { -not $present.Contains([string]$_) })
    return ,@($out)
}
