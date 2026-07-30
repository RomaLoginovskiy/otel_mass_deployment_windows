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
        param($State, $IsCore, $Inheritable = $false, $DirMissing = $false, $Reason = $null, $FrameworkEvidence = @(), $CoreEvidence = @(), $NodeEvidence = @(), $NodeEntryScript = $null)
        [pscustomobject]@{
            State             = $State
            IsCore            = $IsCore
            Inheritable       = $Inheritable
            DirMissing        = $DirMissing
            Error             = $Reason
            FrameworkEvidence = @($FrameworkEvidence)
            CoreEvidence      = @($CoreEvidence)
            # Third axis, deliberately NOT folded into the two above. An iisnode application is
            # very often ALSO an ASP.NET Framework application (same pool, same web.config: managed
            # modules for some paths, an iisnode handler for others), and w3wp then hosts the CLR
            # while node.exe runs as its child. Making this a DotNetRuntime value would force a
            # choice between two things that are both true.
            NodeEvidence      = @($NodeEvidence)
            NodeEntryScript   = $NodeEntryScript
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

    # -- Node hosted by iisnode ------------------------------------------------------------
    # iisnode is a NATIVE IIS module that spawns node.exe as a CHILD OF W3WP, so the Node
    # process inherits the APP POOL's environment - not PM2's, not the machine's. That is the
    # whole reason this axis exists: Instrument-NodePM2.ps1 can never reach such an app, and on a
    # real host three apps that looked like dark PM2 apps turned out to be iisnode pools.
    #
    # Deliberately NOT inferred from an ARR rewrite rule to 127.0.0.1: a reverse proxy in front of
    # a backend process says nothing about what that backend is or where it runs, and the pool's
    # environment does not reach it. Guessing there would put a name into the instrumented set
    # that no process can ever report under.
    $node = New-Object System.Collections.Generic.List[string]
    $nodeEntry = $null
    try {
        foreach ($h in @($x.SelectNodes('//system.webServer/handlers/add')) + @($x.SelectNodes('//handlers/add'))) {
            $mods = [string]$h.GetAttribute('modules')
            $sp   = [string]$h.GetAttribute('scriptProcessor')
            $isNodeHandler = ($mods -match '(^|[,\s])iisnode([,\s]|$)') -or ($sp -match 'iisnode\.dll')
            if (-not $isNodeHandler) { continue }
            if (-not $node.Contains('handlers/iisnode')) { [void]$node.Add('handlers/iisnode') }
            # The handler's path IS the entry script ('server.js', 'app.mjs'). A wildcard path
            # ('*') names no file, so leave the entry null rather than inventing one - the ESM
            # probe falls back to the application directory's package.json.
            $p = [string]$h.GetAttribute('path')
            if (-not $nodeEntry -and $p -and $p -notmatch '[\*\?]') { $nodeEntry = $p }
        }
    } catch {}
    try {
        $inode = $x.SelectSingleNode('//iisnode')
        if ($inode) {
            if (-not $node.Contains('<iisnode>')) { [void]$node.Add('<iisnode>') }
            # An explicit nodeProcessCommandLine REPLACES the node.exe invocation, so an operator
            # can have pinned flags there. Recorded because it changes where instrumentation has to
            # go: a command line that hard-codes its own --require is not something pool env alone
            # can be reasoned about.
            $cl = [string]$inode.GetAttribute('nodeProcessCommandLine')
            if ($cl) { [void]$node.Add("nodeProcessCommandLine=$cl") }
        }
    } catch {}

    return (New-State 'ok' ([bool]$core) -Inheritable $inheritable -FrameworkEvidence $fw.ToArray() -CoreEvidence $coreEv.ToArray() `
                            -NodeEvidence $node.ToArray() -NodeEntryScript $nodeEntry)
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
        [bool]   $PoolClrLoads,
        # WHICH CLR, not just whether one loads. Untyped for the same reason as elsewhere: $null
        # (attribute absent) must not collapse to ''.
        $PoolManagedRuntimeVersion
    )

    # A v2.0 pool loads a CLR, so PoolClrLoads alone cannot tell it apart from v4.0 - and that is
    # exactly how a CLR-2 app came to be classified Supported and CLAIMED in CX_IIS_SERVICES on a
    # real host, advertising a service name that can never report. The OpenTelemetry .NET
    # auto-instrumentation supports .NET Framework 4.6.2+; the desktop CLR 2 (.NET 2.0/3.5) is out
    # of scope for it, so such an app is Unsupported - the app itself runs perfectly well.
    $isClr2 = ($null -ne $PoolManagedRuntimeVersion) -and (([string]$PoolManagedRuntimeVersion) -match '^v?2(\.|$)')

    switch ($Runtime) {
        'AspNetCore'      { if ($PoolClrLoads) { return 'Misconfigured' } else { return 'Supported' } }
        'AspNetFramework' {
            if (-not $PoolClrLoads) { return 'Misconfigured' }   # No Managed Code: the app is DOWN
            if ($isClr2)            { return 'Unsupported'   }   # runs, but nothing can instrument it
            return 'Supported'
        }
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

    # -- Node hosting, resolved independently of the .NET verdict ----------------------------
    # Orthogonal on purpose (see the NodeEvidence note in New-State): a hybrid app is both, and an
    # operator -Override that forces a .NET runtime must not switch iisnode detection off - the two
    # answers are about two different processes (w3wp and its node.exe child).
    $nodeHosting       = $null
    $nodeEvidence      = @()
    $nodeEntry         = $null
    $nodeIsEsm         = $false
    $nodeInheritedFrom = $null

    # An -Override short-circuited the read above, so pay for it here - and only here. Overridden
    # apps are rare; every other app already has its state parsed.
    $nodeWc = if ($null -ne $wc) { $wc } elseif ($PhysicalPath) { Get-CxWebConfigRuntimeState -PhysicalPath $PhysicalPath } else { $null }
    if ($nodeWc -and @($nodeWc.NodeEvidence).Count -gt 0) {
        $nodeHosting  = 'iisnode'
        $nodeEvidence = @($nodeWc.NodeEvidence)
        $nodeEntry    = $nodeWc.NodeEntryScript
    }
    elseif ($nodeWc -and $nodeWc.State -eq 'absent') {
        # Only when the app has NO web.config of its own. IIS inherits <handlers> into child
        # applications, so a parent's iisnode handler really does serve this path - but an app with
        # its own web.config and no iisnode handler in it has already answered the question, and
        # re-reading ancestors for every such app would cost a directory walk per app on a
        # 200-app host for nothing.
        for ($i = 0; $i -lt @($AncestorPhysicalPaths).Count; $i++) {
            $awc = Get-CxWebConfigRuntimeState -PhysicalPath $AncestorPhysicalPaths[$i]
            if ($awc.State -ne 'ok') { continue }
            if (@($awc.NodeEvidence).Count -gt 0) {
                $nodeHosting  = 'iisnode'
                $nodeEvidence = @(@($awc.NodeEvidence) + 'inherited from an ancestor application')
                $nodeEntry    = $awc.NodeEntryScript
                $nodeInheritedFrom = if ($i -lt @($InheritedFromLabels).Count) { $InheritedFromLabels[$i] } else { $AncestorPhysicalPaths[$i] }
            }
            # Nearest readable ancestor decides, exactly as for <aspNetCore> above.
            break
        }
    }

    # ESM vs CommonJS decides the bootstrap FLAG, and getting it wrong fails silently: --require
    # cannot patch an ESM import graph, so the SDK starts and emits nothing. Reuse the Node path's
    # probe rather than writing a second one - guarded, because this library is dot-sourced on its
    # own by callers that do not need the Node helpers.
    if ($nodeHosting -eq 'iisnode' -and (Get-Command Test-CxNodeAppIsEsm -ErrorAction SilentlyContinue)) {
        $entryFull = if ($nodeEntry -and $PhysicalPath) { Join-Path $PhysicalPath $nodeEntry } else { '' }
        try { $nodeIsEsm = [bool](Test-CxNodeAppIsEsm -Script $entryFull -Cwd $PhysicalPath) } catch { $nodeIsEsm = $false }
    }

    $instr = Get-IISAppInstrumentability -Runtime $runtime -PoolClrLoads $poolClrLoads `
                                         -PoolManagedRuntimeVersion $PoolManagedRuntimeVersion

    # A Framework app on CLR 2 is Unsupported for a reason that has nothing to do with the app being
    # non-.NET, so say which it is - otherwise the operator reads the generic NonDotNet wording and
    # goes looking for a misclassification.
    if ($instr -eq 'Unsupported' -and $runtime -eq 'AspNetFramework') {
        $reason = "$reason, but its pool runs the desktop CLR 2 (managedRuntimeVersion=$([string]$PoolManagedRuntimeVersion)). The OpenTelemetry .NET auto-instrumentation supports .NET Framework 4.6.2+, so this application cannot be instrumented and is deliberately NOT claimed in CX_IIS_SERVICES - a claimed name that never reports reads as an outage. The application itself is unaffected; move it to a v4.0 pool to instrument it."
    }

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
        # Node axis. NodeHosting is 'iisnode' or $null; it never changes DotNetRuntime, and a caller
        # that only cares about .NET can ignore these four without its behaviour changing.
        NodeHosting               = $nodeHosting
        NodeEvidence              = @($nodeEvidence)
        NodeEntryScript           = $nodeEntry
        NodeIsEsm                 = $nodeIsEsm
        NodeInheritedFrom         = $nodeInheritedFrom
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
        # A real .NET app that simply cannot be instrumented: the profiler needs Framework 4.6.2+.
        # info, not warn - the application is healthy and this is a property of its pool's CLR, not
        # a defect to act on. It gets its own code so it never reads as "we think this is static".
        'AspNetFramework/Unsupported'   { $code = 'FRAMEWORK_CLR2_NOT_INSTRUMENTABLE'; $sev = 'info' }
        'NonDotNet/Unsupported'         { $code = 'NON_DOTNET_APP_NOT_INSTRUMENTED';  $sev = 'info' }
        default                         { $code = 'RUNTIME_UNKNOWN_NEEDS_OVERRIDE';   $sev = 'unknown' }
    }

    $msg = $Record.RuntimeReason
    if ($code -eq 'FRAMEWORK_CLR2_NOT_INSTRUMENTABLE') {
        $msg = "$msg. No OTEL_SERVICE_NAME is written and the app is not claimed in CX_IIS_SERVICES, because a name that never reports is worse than no name."
    } elseif ($code -eq 'NON_DOTNET_APP_NOT_INSTRUMENTED') {
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

function Get-IISNodeNamingDecision {
    <#
    .SYNOPSIS
      WHERE (or whether) an iisnode application's OTEL_SERVICE_NAME can be written. One
      implementation, called by Instrument-IIS.ps1 and by misc\Enable-IisnodeInstrumentation.ps1.

    .DESCRIPTION
      This used to be two copies of a co-tenancy gate that had to be kept identical by hand, with
      a comment in each saying so. It is one function now: a host patched by the standalone script
      and later re-deployed must not flip between instrumented and not, and that guarantee should
      not depend on someone noticing a divergence in review.

      Three outcomes:

        pool     the pool serves nobody else that reads OTEL_SERVICE_NAME, so the name goes on the
                 pool - the simplest mechanism, and the one that also covers the node child of a
                 hybrid app
        perApp   the pool is shared, so the name goes into the application's OWN web.config
                 <appSettings>, which iisnode appends to the environment block it builds for
                 node.exe. The pool then carries only what its applications genuinely share: the
                 bootstrap and the OTLP endpoint
        refuse   naming it by either route would mis-name or rename something, so nothing is
                 written. .Outcome carries the New-IISNodeFinding token that says which case

      RemovePoolName is $true when a pool-level name this installer wrote must come off the pool
      first. It is not optional cleanup: iisnode copies the parent environment BEFORE appending
      appSettings, and Windows resolves the FIRST entry in the block, so a leftover pool value
      SHADOWS the per-app one and the application reports under the wrong name with both values
      looking correct.

      Peers are normalised by the caller (its record shape is its own business) into objects with
      .Key, .Pool, .IsIisnode and .IsDotNetInstrumented. The whole rival predicate lives here
      because it is the part that must not drift, and that includes the POOL filter: a caller is
      free to pass every application on the host, and one in a different pool must not change this
      application's route. A co-tenant only forces per-app naming if it READS OTEL_SERVICE_NAME - a
      static site, a native handler or an ARR proxy does not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Pool,
        [string]   $ServiceName,
        [object[]] $Peers = @(),
        [AllowNull()][string] $ExistingPoolServiceName,
        # Names this installer computes for the applications in this pool. A pool value inside this
        # set is one we wrote and may remove; anything else belongs to somebody else.
        [string[]] $PoolOwnNames = @(),
        # The application's own .NET side is instrumented ASP.NET Framework.
        [bool]     $IsFrameworkInstrumented = $false
    )

    $rivals = @($Peers | Where-Object {
        $_ -and $_.Pool -eq $Pool -and $_.Key -ne $Key -and ($_.IsIisnode -or $_.IsDotNetInstrumented)
    })
    $rivalLabels = @($rivals | ForEach-Object { "$($_.Key)$(if ($_.IsIisnode) { ' (iisnode)' } else { ' (.NET)' })" }) -join ', '

    if (@($rivals).Count -eq 0) {
        # Nobody else in the pool reads the variable. A pool value that is not this app's name still
        # means something else claimed the pool, so refuse rather than overwrite it.
        if ($ExistingPoolServiceName -and $ExistingPoolServiceName -ne $ServiceName) {
            return [pscustomobject]@{
                Mode = 'refuse'; Outcome = 'poolNameShadow'; Rivals = @(); RemovePoolName = $false
                Reason = "pool '$Pool' already carries OTEL_SERVICE_NAME='$ExistingPoolServiceName', which is not the name for this application - something else has claimed this pool and overwriting it would rename that service"
            }
        }
        return [pscustomobject]@{ Mode = 'pool'; Outcome = 'instrumented'; Rivals = @(); RemovePoolName = $false; Reason = $null }
    }

    # Shared pool. Per-app naming is available, with one exception.
    if ($IsFrameworkInstrumented) {
        return [pscustomobject]@{
            Mode = 'refuse'; Outcome = 'sharedPoolFw'; Rivals = $rivalLabels; RemovePoolName = $false
            Reason = "this application is iisnode AND instrumented ASP.NET Framework and shares pool '$Pool' with $rivalLabels. The Framework SDK promotes web.config OTEL_* values to PROCESS-level environment variables, so a per-app name would leak through w3wp and rename its co-tenants"
        }
    }
    if ($ExistingPoolServiceName -and -not ($PoolOwnNames -contains $ExistingPoolServiceName)) {
        return [pscustomobject]@{
            Mode = 'refuse'; Outcome = 'poolNameShadow'; Rivals = $rivalLabels; RemovePoolName = $false
            Reason = "pool '$Pool' carries OTEL_SERVICE_NAME='$ExistingPoolServiceName' that this installer did not write, and a pool value shadows the per-app one, so the per-app name would not take effect"
        }
    }
    return [pscustomobject]@{
        Mode = 'perApp'; Outcome = 'perAppNamed'; Rivals = $rivalLabels
        RemovePoolName = [bool]$ExistingPoolServiceName
        Reason = "shares pool '$Pool' with $rivalLabels, so the name goes in this application's own web.config <appSettings>"
    }
}

function Get-CxWebConfigAppSetting {
    <#
    .SYNOPSIS
      Read one <appSettings> value out of an application's own web.config.

    .DESCRIPTION
      The read side of per-app iisnode naming. iisnode appends every appSettings key/value of the
      application's resolved configuration to the environment block it builds for node.exe
      (src/iisnode/cmoduleconfiguration.cpp, CreateNodeEnvironment), so this is where a
      pool-sharing app's OTEL_SERVICE_NAME lives - the pool cannot carry it without renaming its
      co-tenants.

      Returns $null for every "not there" case (no path, no file, unreadable, key absent) and
      never throws: the doctor grades a missing name as a finding, and a reader that threw would
      take the whole per-app report down with it. /configuration/appSettings only - a
      <location>-scoped block applies to a different path than this application.
    #>
    [CmdletBinding()]
    param(
        [string] $PhysicalPath,
        [Parameter(Mandatory)][string] $Key
    )

    if (-not $PhysicalPath) { return $null }
    $webConfig = Join-Path $PhysicalPath 'web.config'
    if (-not (Test-Path -LiteralPath $webConfig -ErrorAction SilentlyContinue)) { return $null }
    try {
        [xml]$xml = Get-Content -LiteralPath $webConfig -Raw -ErrorAction Stop
    } catch { return $null }
    $node = $xml.SelectSingleNode("/configuration/appSettings/add[@key='$Key']")
    if (-not $node) { return $null }
    $v = [string]$node.GetAttribute('value')
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}

function New-IISNodeFinding {
    <#
    .SYNOPSIS
      The iisnode counterpart of New-IISRuntimeFinding: one mapping from an outcome token to code,
      severity and message, shared by the installer, the doctor and misc\Enable-IisnodeInstrumentation.ps1.

    .DESCRIPTION
      A SEPARATE function rather than another branch of New-IISRuntimeFinding, because the two are
      not alternatives. New-IISRuntimeFinding keys on DotNetRuntime/Instrumentability, and an
      iisnode application is frequently ALSO AspNetFramework/Supported - it must be able to carry
      both findings at once, one about w3wp and one about w3wp's node.exe child.

      -Outcome tokens:
        instrumented   pool env carries our bootstrap                            pass
        missing        iisnode app with no bootstrap on its pool - it is dark    warn
        esmUnsupported the app is an ES module, and iisnode cannot host one at
                       all - so there is nothing here to instrument             warn
        perAppNamed    a pool-sharing app named in its OWN web.config
                       <appSettings>, which iisnode promotes into the node
                       child's environment; the pool carries only the shared
                       bootstrap                                                 pass
        sharedPool     the app shares its pool and could not be named per-app
                       either, so nothing was written                            warn
        sharedPoolFw   iisnode AND instrumented ASP.NET Framework on a shared
                       pool: naming it per-app would leak that name onto its
                       co-tenants through w3wp                                   warn
        poolNameShadow the pool carries a foreign OTEL_SERVICE_NAME, which
                       SHADOWS the per-app appSettings value                     warn
        packageMissing the Node instrumentation package is not staged here       warn
        stalePath      the bootstrap points at a register.js that is gone        warn
        customCmdLine  <iisnode nodeProcessCommandLine> overrides the node
                       invocation, so pool NODE_OPTIONS may not be the whole
                       story                                                     info

      Returns $null (never throws) if the New-Finding helper is not loaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('instrumented','perAppNamed','missing','esmUnsupported','sharedPool','sharedPoolFw','poolNameShadow','packageMissing','stalePath','customCmdLine')]
        [string] $Outcome,
        $Record,
        [string] $Target,
        [string] $Check  = 'iisnode',
        [string] $Detail
    )

    if (-not (Get-Command New-Finding -ErrorAction SilentlyContinue)) { return $null }

    $isEsm = if ($Record) { [bool]$Record.NodeIsEsm } else { $false }
    $entry = if ($Record) { [string]$Record.NodeEntryScript } else { '' }

    switch ($Outcome) {
        'instrumented' {
            $code = 'IISNODE_APP_INSTRUMENTED'; $sev = 'pass'
            $msg  = "iisnode application: NODE_OPTIONS$(if ($isEsm) { ' (esm loader hook + --require)' } else { ' (--require)' }) is set on its app pool, so the node.exe child of w3wp loads the SDK"
        }
        'missing' {
            $code = 'IISNODE_NODE_OPTIONS_MISSING'; $sev = 'warn'
            $msg  = "iisnode application with no OTel bootstrap on its app pool - it emits NOTHING. iisnode spawns node.exe as a CHILD OF W3WP, so its environment comes from the pool, not from PM2: Instrument-NodePM2.ps1 cannot reach this app however healthy PM2 looks. Fix: Instrument-IIS.ps1, or misc\Enable-IisnodeInstrumentation.ps1 -Apply on an already-deployed host"
        }
        'esmUnsupported' {
            # MEASURED on a real host (iisnode 0.2.26, Node 20.11, Server 2025): iisnode's own
            # interceptor.js does `require(<the app's entry point>)`, and a CommonJS require can
            # never load an ES module. Every request returns HTTP 500 / HRESULT 0x2 with
            # ERR_REQUIRE_ESM in the iisnode stderr log - WITH our bootstrap and WITHOUT it, for an
            # .mjs entry and for a "type":"module" package.json alike. So this is a property of the
            # HOST, not of instrumentation, and no loader hook can rescue it: the app never gets far
            # enough to load one. (Contrast the PM2 path, where the loader hook is exactly the fix -
            # there node runs the app directly, with no CommonJS interceptor in front of it.)
            #
            # warn, not fail: the agent is not broken and did not cause this. But it cannot be a
            # pass either - grading an app that 500s on every request as "instrumented" is precisely
            # the reads-healthy-emits-nothing report this tooling exists to prevent.
            $code = 'IISNODE_ESM_NOT_HOSTABLE'; $sev = 'warn'
            $msg  = "this application is an ES module$(if ($entry) { " ($entry)" }) and iisnode cannot host ES modules: its interceptor.js require()s the entry point, so the application fails with ERR_REQUIRE_ESM and returns HTTP 500 on every request (measured on iisnode 0.2.26 / Node 20 - with and without instrumentation). Not instrumented and not claimed as a service, because there is no working process to instrument. Fix is application-side and unrelated to telemetry: give it a CommonJS entry point that dynamic-import()s the ESM app, or host it under PM2 / a Windows service instead of iisnode"
        }
        'perAppNamed' {
            # The pool-sharing case is NOT a refusal any more. iisnode appends the application's
            # own <appSettings> to the environment block it builds for node.exe
            # (cmoduleconfiguration.cpp, CreateNodeEnvironment), so each application in a shared
            # pool can carry its own name while the pool carries only what they genuinely share -
            # the bootstrap and the OTLP endpoint.
            $code = 'IISNODE_APP_NAMED_PER_APP'; $sev = 'pass'
            $msg  = "iisnode application sharing its app pool: OTEL_SERVICE_NAME is set per-app in its own web.config <appSettings> (iisnode promotes appSettings into the node.exe environment) and the pool carries the shared NODE_OPTIONS bootstrap. No pool-level OTEL_SERVICE_NAME is written, so no co-tenant is renamed"
        }
        'sharedPool' {
            $code = 'IISNODE_SHARED_POOL_AMBIGUOUS'; $sev = 'warn'
            $msg  = "this iisnode application shares its app pool and could not be named per-app either, so nothing was written - a name that maps to two services is worse than no name. Per-app naming writes OTEL_SERVICE_NAME into the application's own web.config <appSettings>; it needs that file to be present and writable. Fix: make it writable, or give the application its own pool"
        }
        'sharedPoolFw' {
            # The one shape per-app appSettings CANNOT solve. On .NET Framework the OTel SDK reads
            # OTEL_* out of web.config and promotes it to PROCESS-level environment variables, once
            # per worker process - so on a shared pool this app's name would reach its co-tenants
            # through w3wp and rename services that were reporting correctly.
            $code = 'IISNODE_SHARED_POOL_FRAMEWORK'; $sev = 'warn'
            $msg  = "this application is iisnode AND instrumented ASP.NET Framework, and it shares its app pool. Naming it per-app is not safe here: on .NET Framework the OTel SDK promotes web.config OTEL_* values to PROCESS-level environment variables, so the name would leak through w3wp onto its co-tenants and rename services that were reporting correctly. Nothing is written. Fix: give this application its own app pool - then the name goes on the pool and there is nobody to leak onto"
        }
        'poolNameShadow' {
            # Ordering fact, measured in iisnode's source: the parent environment is copied FIRST
            # and appSettings appended after it, and GetEnvironmentVariableW returns the FIRST
            # match. So a pool-level value WINS over the per-app one - silently.
            $code = 'IISNODE_POOL_NAME_SHADOWS_APP'; $sev = 'warn'
            $msg  = "this application's app pool carries an OTEL_SERVICE_NAME that this installer did not write. iisnode copies the pool environment BEFORE appending the application's <appSettings>, and Windows resolves the FIRST entry in the block, so the pool value SHADOWS the per-app one: the application would report under the pool's name whatever appSettings says. Nothing is written, because the per-app name would not take effect. Fix: remove the OTEL_SERVICE_NAME from the pool (it cannot correctly name a shared pool anyway), then re-run"
        }
        'packageMissing' {
            $code = 'IISNODE_PACKAGE_MISSING'; $sev = 'warn'
            $msg  = "iisnode application found, but the Node instrumentation package is not staged on this host, so no bootstrap was written. This path deliberately does NOT run npm install (IIS hosts are frequently offline): stage it with Instrument-NodePM2.ps1, or copy a prepared node_modules tree into the install prefix"
        }
        'stalePath' {
            $code = 'IISNODE_REGISTER_PATH_STALE'; $sev = 'warn'
            $msg  = "the pool's NODE_OPTIONS points at a register bootstrap that no longer exists, so node.exe fails the preload and runs uninstrumented"
        }
        'customCmdLine' {
            $code = 'IISNODE_CUSTOM_COMMAND_LINE'; $sev = 'info'
            $msg  = "this application sets <iisnode nodeProcessCommandLine>, which replaces the node.exe invocation. Pool NODE_OPTIONS still applies (Node reads it from the environment), but if that command line carries its own --require of an OTel bootstrap the SDK could load twice"
        }
    }

    if ($Detail) { $msg = "$msg. $Detail" }

    return (New-Finding -Check $Check -Severity $sev -Code $code -Target $Target -Message $msg -Data @{
        nodeHosting       = if ($Record) { $Record.NodeHosting } else { 'iisnode' }
        nodeEvidence      = if ($Record) { @($Record.NodeEvidence) } else { @() }
        nodeEntryScript   = $entry
        nodeIsEsm         = $isEsm
        nodeInheritedFrom = if ($Record) { $Record.NodeInheritedFrom } else { $null }
        dotNetRuntime     = if ($Record) { $Record.DotNetRuntime } else { $null }
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
