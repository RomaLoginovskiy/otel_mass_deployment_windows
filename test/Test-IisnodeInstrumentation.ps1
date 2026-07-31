<#
.SYNOPSIS
  Unit tests for the iisnode path: classification in deploy\Resolve-IISAppRuntime.ps1, the shared
  NODE_OPTIONS merge/strip helpers, and the standalone fallbacks in
  misc\Enable-IisnodeInstrumentation.ps1.

.DESCRIPTION
  Fixture-only. Writes throwaway web.config trees and a fake package layout under the user's TEMP,
  and touches no IIS site, no app pool, no registry and no machine environment - so this runs
  anywhere in about a second and needs no elevation.

  What it pins, and why each one is here:

    * iisnode is a THIRD axis, not a DotNetRuntime value. A hybrid application - managed modules
      for some paths, an iisnode handler for others - is both an ASP.NET Framework app and an
      iisnode app, because w3wp hosts the CLR while its node.exe child runs the JavaScript. A test
      that lets NodeHosting change DotNetRuntime would silently narrow CX_IIS_SERVICES.

    * An ARR reverse proxy to 127.0.0.1 is NOT iisnode. Claiming it would put a service name on a
      host for a process the app pool's environment never reaches.

    * ESM vs CommonJS. --require cannot patch an ESM import graph: the SDK starts, the app looks
      healthy, and no telemetry is produced. So the module system must be detected, not assumed,
      and an ESM app with no loader hook must be reported rather than instrumented.

    * NODE_OPTIONS merge AND strip, round-tripped. An app that sets --max-old-space-size keeps it
      through instrument AND uninstall; ours is added exactly once and removed completely. A pool
      value is a single merged string, so a blanket delete on uninstall would silently drop the
      app's heap ceiling.

    * DRIFT between misc\Enable-IisnodeInstrumentation.ps1's standalone fallbacks and the deploy
      libraries they mirror. The patch script must run on a host with no deploy package, so it
      carries its own copies - and the moment they disagree, it "fixes" a host into a state the
      real installer then overwrites. These tests compare the two implementations directly.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-IisnodeInstrumentation.ps1

.NOTES
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param([switch] $KeepFixtures)

$ErrorActionPreference = 'Stop'

$here    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$deploy  = Join-Path $here '..\deploy'
$rtLib   = Join-Path $deploy 'Resolve-IISAppRuntime.ps1'
$nodeLib = Join-Path $deploy 'Resolve-NodeServiceNames.ps1'
# The per-app <appSettings> writer and its inverse live here, next to the <aspNetCore> pair they
# parallel - a pool-sharing iisnode application is named through them.
$svcLib  = Join-Path $deploy 'Resolve-IISServiceNames.ps1'
$patch   = Join-Path $here '..\misc\Enable-IisnodeInstrumentation.ps1'
foreach ($p in @($rtLib, $nodeLib, $svcLib, $patch)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing: $p" }
}

# The libraries are dot-sourceable. The patch script is not - it is a SCRIPT that runs stages and
# exits - so its functions are lifted out by AST.
#
# The helper RETURNS the source text and the caller evaluates it at script scope on purpose:
# Invoke-Expression inside a function defines the function in that function's scope, so it vanishes
# on return. Failing loudly on a rename is the point.
. $nodeLib
. $rtLib
. $svcLib

# The lifted patch-script functions report through Write-Step, which belongs to that script's own
# preamble. A no-op stand-in keeps their FAILURE paths exercisable here instead of turning a
# reported error into a CommandNotFoundException that hides the assertion it was meant to fail.
function Write-Step { param([string]$Level, [string]$Message, [string]$Fix) }

function Get-ScriptFunctionText {
    param([string] $Path, [string[]] $Names)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $texts = @(); $found = @()
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($Names -contains $fn.Name) { $texts += $fn.Extent.Text; $found += $fn.Name }
    }
    $missing = @($Names | Where-Object { $found -notcontains $_ })
    if ($missing.Count) { throw "not found in $(Split-Path -Leaf $Path): $($missing -join ', ') (renamed?)" }
    return ($texts -join "`n")
}

Invoke-Expression (Get-ScriptFunctionText -Path $patch -Names @(
    'Get-LocalIisnodeEvidence','Test-LocalAppIsEsm','Resolve-LocalNodeBootstrap','Merge-LocalNodeOptions','Get-PoolIdentityAccount','Get-LocalIISNodeNamingDecision','Get-LocalWebConfigAppSetting','Set-LocalWebConfigAppSetting','Test-CxBootstrapInValue'))

$script:Pass = 0; $script:Fail = 0
function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { $script:Fail++; Write-Host "  FAIL $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red }
}
function Assert-Eq {
    param([string] $Name, $Expected, $Actual)
    Assert-True -Name $Name -Condition ("$Expected" -eq "$Actual") -Detail "expected [$Expected] got [$Actual]"
}

$root = Join-Path $env:TEMP ("cx-iisnode-tests-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null

# $WebConfig is UNTYPED on purpose: [string]$WebConfig coerces a passed $null to '', which writes an
# EMPTY web.config and makes the application 'unreadable' instead of 'absent' - a different test.
function New-App {
    param([string] $Name, $WebConfig, [hashtable] $Files = @{})
    $d = Join-Path $root $Name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    if ($null -ne $WebConfig) { [IO.File]::WriteAllText((Join-Path $d 'web.config'), [string]$WebConfig) }
    foreach ($k in $Files.Keys) { [IO.File]::WriteAllText((Join-Path $d $k), [string]$Files[$k]) }
    return $d
}

$WC_IISNODE = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="iisnode" path="server.js" verb="*" modules="iisnode" />
    </handlers>
    <iisnode nodeProcessCountPerApplication="1" />
  </system.webServer>
</configuration>
'@

$WC_HYBRID = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.web><compilation targetFramework="4.8" /><sessionState mode="InProc" /></system.web>
  <system.webServer>
    <handlers>
      <add name="iisnode" path="app.js" verb="*" modules="iisnode" />
      <add name="Legacy" path="*.ashx" verb="*" type="Contoso.Handler, Contoso" />
    </handlers>
  </system.webServer>
</configuration>
'@

$WC_ARR = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite><rules><rule name="p"><match url="(.*)" /><action type="Rewrite" url="http://127.0.0.1:3001/{R:1}" /></rule></rules></rewrite>
  </system.webServer>
</configuration>
'@

$WC_SCRIPTPROC = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="node" path="index.js" verb="*" scriptProcessor="C:\Program Files\iisnode\iisnode.dll" resourceType="Unspecified" />
    </handlers>
  </system.webServer>
</configuration>
'@

try {
    Write-Host ''
    Write-Host '== iisnode classification (library) ==' -ForegroundColor Cyan

    $d = New-App 'nodeonly' $WC_IISNODE @{ 'server.js' = 'x' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq   'iisnode app -> NodeHosting=iisnode' 'iisnode'   $r.NodeHosting
    Assert-Eq   'entry script from the handler path' 'server.js' $r.NodeEntryScript
    Assert-Eq   'no .NET wiring -> NonDotNet'       'NonDotNet' $r.DotNetRuntime
    Assert-True 'handler recorded as evidence' ([bool](@($r.NodeEvidence) -contains 'handlers/iisnode'))

    $d = New-App 'hybrid' $WC_HYBRID @{ 'app.js' = 'x' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq 'hybrid keeps its .NET verdict' 'AspNetFramework' $r.DotNetRuntime
    Assert-Eq 'hybrid stays instrumentable'   'Supported'       $r.Instrumentability
    Assert-Eq 'hybrid is ALSO iisnode'        'iisnode'         $r.NodeHosting

    $d = New-App 'arr' $WC_ARR
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq 'ARR proxy is not claimed as iisnode' '' $r.NodeHosting

    $d = New-App 'scriptproc' $WC_SCRIPTPROC @{ 'index.js' = 'x' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq 'scriptProcessor=iisnode.dll counts' 'iisnode' $r.NodeHosting

    $d = New-App 'wild' ($WC_IISNODE -replace 'path="server\.js"', 'path="*"')
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq 'a wildcard handler path invents no entry script' '' $r.NodeEntryScript

    $parent = New-App 'inh'       $WC_IISNODE @{ 'server.js' = 'x' }
    $child  = New-App 'inh\kid'   $null
    $r = Resolve-IISAppRuntime -PhysicalPath $child -PoolManagedRuntimeVersion 'v4.0' -AncestorPhysicalPaths @($parent) -InheritedFromLabels @('Site/')
    Assert-Eq 'a child with no web.config inherits the handler' 'iisnode' $r.NodeHosting
    Assert-Eq 'and names where it came from'                    'Site/'   $r.NodeInheritedFrom

    $kid2 = New-App 'inh\kid2' $WC_ARR
    $r = Resolve-IISAppRuntime -PhysicalPath $kid2 -PoolManagedRuntimeVersion 'v4.0' -AncestorPhysicalPaths @($parent) -InheritedFromLabels @('Site/')
    Assert-Eq 'an app with its own web.config and no handler does not inherit' '' $r.NodeHosting

    $kid3 = New-App 'inh\kid3' '<configuration><system.webServer>'
    $r = Resolve-IISAppRuntime -PhysicalPath $kid3 -PoolManagedRuntimeVersion 'v4.0' -AncestorPhysicalPaths @($parent) -InheritedFromLabels @('Site/')
    Assert-Eq 'a malformed web.config is not an inheritance guess' '' $r.NodeHosting

    $d = New-App 'ovr' $WC_IISNODE @{ 'server.js' = 'x' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0' -Override 'AspNetFramework'
    Assert-Eq 'an operator .NET override does not disable node detection' 'iisnode' $r.NodeHosting

    Write-Host ''
    Write-Host '== ESM detection ==' -ForegroundColor Cyan

    $d = New-App 'esm-ext' ($WC_IISNODE -replace 'server\.js', 'app.mjs') @{ 'app.mjs' = 'x' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq '.mjs entry -> ESM' 'True' $r.NodeIsEsm

    $d = New-App 'esm-pkg' $WC_IISNODE @{ 'server.js' = 'x'; 'package.json' = '{"type":"module"}' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq '"type":"module" -> ESM' 'True' $r.NodeIsEsm

    $d = New-App 'cjs-pkg' $WC_IISNODE @{ 'server.js' = 'x'; 'package.json' = '{"name":"a"}' }
    $r = Resolve-IISAppRuntime -PhysicalPath $d -PoolManagedRuntimeVersion 'v4.0'
    Assert-Eq 'no type field -> CommonJS' 'False' $r.NodeIsEsm

    Write-Host ''
    Write-Host '== NODE_OPTIONS merge and strip (round trip) ==' -ForegroundColor Cyan

    $reg  = 'C:/cx/otel-node/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js'
    $hook = 'file:///C:/cx/otel-node/node_modules/@opentelemetry/instrumentation/hook.mjs'
    $cjs  = "--require $reg"
    $esm  = "--experimental-loader=$hook --require $reg"
    $own  = '--max-old-space-size=512'

    $m = Merge-CxNodeOptions -Existing $own -Bootstrap $cjs -OwnedTargets @($reg, $hook)
    Assert-Eq "the app's own flag survives instrument" "$own $cjs" $m
    Assert-Eq 'and uninstall gives it back untouched' $own (Remove-CxNodeOptionsBootstrap -Existing $m -OwnedTargets @($reg, $hook))

    $m2 = Merge-CxNodeOptions -Existing $m -Bootstrap $cjs -OwnedTargets @($reg, $hook)
    Assert-Eq 're-running adds ours exactly once' "$own $cjs" $m2

    $mEsm = Merge-CxNodeOptions -Existing "$esm $own" -Bootstrap $cjs -OwnedTargets @($reg, $hook)
    Assert-True 'switching ESM->CommonJS drops the stale loader hook' ($mEsm -notmatch 'experimental-loader')
    Assert-True 'and keeps the app flag'                              ($mEsm -match [regex]::Escape($own))

    Assert-Eq 'stripping ours from a value that is only ours leaves nothing' '' (Remove-CxNodeOptionsBootstrap -Existing $esm -OwnedTargets @($reg, $hook))
    Assert-Eq "an app's own --require is never removed" '--require C:/app/patch.js' (Remove-CxNodeOptionsBootstrap -Existing '--require C:/app/patch.js' -OwnedTargets @($reg, $hook))
    Assert-Eq 'a marker-bearing legacy hook is still recognised' '-X' (Remove-CxNodeOptionsBootstrap -Existing '--require D:/old/opentelemetry/register.js -X' -OwnedTargets @())

    Write-Host ''
    Write-Host '== the write gate: does the merged value actually carry the bootstrap? ==' -ForegroundColor Cyan

    # This gate is the difference between a run that FAILS loudly and one that writes a service name
    # onto 35 pools with no --require among them. It exists because a drifted library returned a
    # bootstrap object the patch script could not read, $merged came out empty, and every OTEL_*
    # variable was written anyway - so the empty and whitespace cases are pinned, not assumed.
    Assert-True 'a merged CommonJS value passes'        (Test-CxBootstrapInValue -Value "$own $cjs" -RegisterPath $reg)
    Assert-True 'a merged ESM value passes'             (Test-CxBootstrapInValue -Value "$esm $own"  -RegisterPath $reg)
    Assert-True 'backslashes still match'               (Test-CxBootstrapInValue -Value "--require $($reg -replace '/','\')" -RegisterPath $reg)
    Assert-True 'case differences still match'          (Test-CxBootstrapInValue -Value "--require $($reg.ToUpperInvariant())" -RegisterPath $reg)
    Assert-True 'an empty value is refused'        (-not (Test-CxBootstrapInValue -Value ''    -RegisterPath $reg))
    Assert-True 'a null value is refused'          (-not (Test-CxBootstrapInValue -Value $null -RegisterPath $reg))
    Assert-True 'whitespace only is refused'       (-not (Test-CxBootstrapInValue -Value '   ' -RegisterPath $reg))
    Assert-True "the app's own flags alone are refused" (-not (Test-CxBootstrapInValue -Value $own -RegisterPath $reg))
    Assert-True 'a DIFFERENT register.js is refused'    (-not (Test-CxBootstrapInValue -Value '--require C:/app/patch.js' -RegisterPath $reg))
    Assert-True 'the path present without a preload flag is refused' (-not (Test-CxBootstrapInValue -Value "--stack-size=2000 $reg" -RegisterPath $reg))
    # A bootstrap-less merge and an unresolvable package are the same refusal: nothing gets written.
    Assert-True 'no RegisterPath to compare against is refused' (-not (Test-CxBootstrapInValue -Value "$own $cjs" -RegisterPath ''))

    Write-Host ''
    Write-Host '== bootstrap resolution against a staged package ==' -ForegroundColor Cyan

    # Fake the package layout: only the two files matter to either resolver.
    $prefix = Join-Path $root 'pkg'
    $regDir  = Join-Path $prefix 'node_modules\@opentelemetry\auto-instrumentations-node\build\src'
    $hookDir = Join-Path $prefix 'node_modules\@opentelemetry\instrumentation'
    New-Item -ItemType Directory -Force -Path $regDir, $hookDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $regDir 'register.js'), '//x')
    [IO.File]::WriteAllText((Join-Path $hookDir 'hook.mjs'),   '//x')

    $libBoot   = Resolve-CxNodeBootstrap  -InstallPrefix $prefix
    $localBoot = Resolve-LocalNodeBootstrap -Prefix      $prefix
    Assert-True 'library resolver finds register.js'    ([bool]$libBoot.RegisterPath)
    Assert-True 'library resolver finds the ESM hook'   ([bool]$libBoot.EsmSupported)
    Assert-Eq   'STANDALONE register path matches the library' $libBoot.RegisterPath $localBoot.RegisterPath
    Assert-Eq   'STANDALONE hook url matches the library'      $libBoot.HookUrl      $localBoot.HookUrl
    Assert-Eq   'STANDALONE CommonJS flags match the library'   $libBoot.NodeOptionsCjs $localBoot.Cjs
    Assert-Eq   'STANDALONE ESM flags match the library'        $libBoot.NodeOptionsEsm $localBoot.Esm

    # No hook staged -> ESM must be reported unsupported, by BOTH resolvers.
    $prefix2 = Join-Path $root 'pkg-nohook'
    $regDir2 = Join-Path $prefix2 'node_modules\@opentelemetry\auto-instrumentations-node\build\src'
    New-Item -ItemType Directory -Force -Path $regDir2 | Out-Null
    [IO.File]::WriteAllText((Join-Path $regDir2 'register.js'), '//x')
    Assert-Eq 'library: no hook -> EsmSupported false'    'False' (Resolve-CxNodeBootstrap  -InstallPrefix $prefix2).EsmSupported
    Assert-Eq 'standalone: no hook -> EsmSupported false' 'False' (Resolve-LocalNodeBootstrap -Prefix      $prefix2).EsmSupported

    $missing = Resolve-LocalNodeBootstrap -Prefix (Join-Path $root 'nope')
    Assert-True 'standalone: an unstaged package is reported, not thrown' ([bool]$missing.Reason -and -not $missing.RegisterPath)

    Write-Host ''
    Write-Host '== standalone fallbacks agree with the library ==' -ForegroundColor Cyan

    foreach ($case in @(
        @{ Name = 'iisnode only'; Dir = (New-App 'agree-node' $WC_IISNODE    @{ 'server.js' = 'x' }) },
        @{ Name = 'hybrid';       Dir = (New-App 'agree-hyb'  $WC_HYBRID     @{ 'app.js'    = 'x' }) },
        @{ Name = 'ARR only';     Dir = (New-App 'agree-arr'  $WC_ARR) },
        @{ Name = 'scriptProc';   Dir = (New-App 'agree-sp'   $WC_SCRIPTPROC @{ 'index.js'  = 'x' }) },
        @{ Name = 'esm by ext';   Dir = (New-App 'agree-esm'  ($WC_IISNODE -replace 'server\.js','app.mjs') @{ 'app.mjs' = 'x' }) },
        @{ Name = 'no web.config';Dir = (New-App 'agree-none' $null) }
    )) {
        $libSt = Get-CxWebConfigRuntimeState -PhysicalPath $case.Dir
        $locSt = Get-LocalIisnodeEvidence    -PhysicalPath $case.Dir
        Assert-Eq "$($case.Name): iisnode verdict agrees" ([bool](@($libSt.NodeEvidence).Count -gt 0)) $locSt.IsIisnode
        Assert-Eq "$($case.Name): entry script agrees"    ([string]$libSt.NodeEntryScript)             ([string]$locSt.Entry)
        Assert-Eq "$($case.Name): web.config state agrees" $libSt.State                               $locSt.State

        $libEsm = [bool](Test-CxNodeAppIsEsm -Script $(if ($libSt.NodeEntryScript) { Join-Path $case.Dir $libSt.NodeEntryScript } else { '' }) -Cwd $case.Dir)
        $locEsm = [bool](Test-LocalAppIsEsm -Entry $locSt.Entry -Cwd $case.Dir)
        Assert-Eq "$($case.Name): ESM verdict agrees" $libEsm $locEsm
    }

    # The merge is the one that silently corrupts an app if the two drift.
    foreach ($existing in @('', $own, "$own $cjs", "$esm $own", '--require C:/app/patch.js')) {
        foreach ($bs in @($cjs, $esm)) {
            $a = Merge-CxNodeOptions     -Existing $existing -Bootstrap $bs -OwnedTargets @($reg, $hook)
            $b = Merge-LocalNodeOptions  -Existing $existing -Bootstrap $bs -OwnedTargets @($reg, $hook)
            Assert-Eq "STANDALONE merge matches: [$existing] + [$(if ($bs -eq $cjs) { 'cjs' } else { 'esm' })]" $a $b
        }
    }

    Write-Host ''
    Write-Host '== naming decision: pool, per-app, or refuse (one function, two callers) ==' -ForegroundColor Cyan

    function New-Rec {
        param([string]$Key, [string]$Pool, [bool]$Node, [bool]$DotNet, [string]$Svc, [bool]$Framework)
        [pscustomobject]@{ Key = $Key; Pool = $Pool; IsIisnode = $Node; IsDotNet = $DotNet; IsFramework = $Framework
                           ServiceName = $(if ($Svc) { $Svc } else { $Key }) }
    }
    # Both implementations, over the same inputs. The standalone script must not drift from the
    # library: a host patched by one and re-deployed by the other must not flip between
    # instrumented and not, and that is what these two lambdas assert together.
    function Decide {
        param($Record, [object[]]$All, [string]$PoolSvc, [string[]]$OwnNames)
        $lib = Get-IISNodeNamingDecision -Key $Record.Key -Pool $Record.Pool -ServiceName $Record.ServiceName `
            -Peers @($All | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Pool = $_.Pool; IsIisnode = [bool]$_.IsIisnode; IsDotNetInstrumented = [bool]$_.IsDotNet } }) `
            -ExistingPoolServiceName $PoolSvc -PoolOwnNames $OwnNames -IsFrameworkInstrumented ([bool]$Record.IsFramework)
        $loc = Get-LocalIISNodeNamingDecision -Record $Record -All $All -ExistingPoolServiceName $PoolSvc -PoolOwnNames $OwnNames
        Assert-Eq "standalone agrees with the library on $($Record.Key) (mode)"    $lib.Mode    $loc.Mode
        Assert-Eq "standalone agrees with the library on $($Record.Key) (outcome)" $lib.Outcome $loc.Outcome
        Assert-Eq "standalone agrees with the library on $($Record.Key) (remove)"  ([bool]$lib.RemovePoolName) ([bool]$loc.RemovePoolName)
        return $lib
    }

    # A lone iisnode app on its own pool: the name goes on the pool, as it always did.
    $solo = New-Rec 'Site/api' 'PoolA' $true $false
    Assert-Eq 'lone iisnode app on its own pool -> pool' 'pool' (Decide $solo @($solo)).Mode

    # A static co-tenant does not read OTEL_SERVICE_NAME, so it must NOT force the per-app route.
    $static = New-Rec 'Site/' 'PoolA' $false $false
    Assert-Eq 'a static co-tenant does not change the route' 'pool' (Decide $solo @($solo, $static)).Mode

    # Two iisnode apps in one pool. One pool value cannot name both - but each app's own
    # <appSettings> can, and iisnode appends it to that app's node.exe environment.
    $node2 = New-Rec 'Site/admin' 'PoolA' $true $false
    Assert-Eq 'two iisnode apps in one pool -> per-app naming' 'perApp' (Decide $solo @($solo, $node2)).Mode

    # THE CASE THIS FEATURE EXISTS FOR: a pool holding an instrumented .NET app and a Node app.
    # Each is named separately - the .NET one by Instrument-IIS.ps1 in its <aspNetCore> element,
    # this one in its own <appSettings> - and neither renames the other.
    $dotnet = New-Rec 'Site/wallet' 'PoolA' $false $true
    $d = Decide $solo @($solo, $dotnet)
    Assert-Eq   'a mixed .NET + Node pool -> per-app naming' 'perApp' $d.Mode
    Assert-Eq   'and it is graded as a pass outcome'         'perAppNamed' $d.Outcome
    Assert-True 'and the reason names the co-tenant'         ($d.Rivals -match 'Site/wallet')
    Assert-True 'and nothing is written on the pool for it'  (-not $d.RemovePoolName)

    # A hybrid app is BOTH - itself, not a rival, so a dedicated pool still names it on the pool.
    $hybridRec = New-Rec 'Site/hyb' 'PoolB' $true $true
    Assert-Eq 'a hybrid app is not its own rival' 'pool' (Decide $hybridRec @($hybridRec)).Mode

    # The one shape per-app naming cannot solve: Framework promotes web.config OTEL_* PROCESS-wide,
    # so on a SHARED pool the name would leak onto the co-tenants through w3wp.
    $hybShared = New-Rec 'Site/hyb2' 'PoolC' $true $true '' $true
    $hs = Decide $hybShared @($hybShared, (New-Rec 'Site/other2' 'PoolC' $false $true))
    Assert-Eq 'iisnode + Framework on a shared pool is refused' 'refuse' $hs.Mode
    Assert-Eq 'and says which case it is'                       'sharedPoolFw' $hs.Outcome

    # An app in a DIFFERENT pool is irrelevant.
    $other = New-Rec 'Site/other' 'PoolZ' $true $true
    Assert-Eq 'an app in another pool does not change the route' 'pool' (Decide $solo @($solo, $other)).Mode

    # Belt and braces on a DEDICATED pool: a pool already claiming a different name is refused.
    Assert-Eq 'a foreign OTEL_SERVICE_NAME already on the pool is refused' 'refuse' `
        (Decide $solo @($solo) 'Wallet').Mode
    Assert-Eq 'our own name already on the pool is fine (re-run)' 'pool' `
        (Decide $solo @($solo) 'Site/api').Mode

    # On a SHARED pool a leftover pool-level name must come OFF first: iisnode copies the parent
    # environment before appending appSettings and Windows resolves the first entry, so a pool value
    # shadows the per-app one. Ours (it is a name this installer computes for an app in the pool).
    $sh = Decide $solo @($solo, $dotnet) 'Site/api' @('Site/api','Site/wallet')
    Assert-Eq   'a stale pool name we wrote still allows per-app naming' 'perApp' $sh.Mode
    Assert-True 'and it is removed first, or the per-app name is inert'  ([bool]$sh.RemovePoolName)

    # Somebody else's pool value is NOT ours to remove, and it would shadow the per-app name, so
    # refuse rather than write a name that does nothing.
    $fs = Decide $solo @($solo, $dotnet) 'HandSetName' @('Site/api','Site/wallet')
    Assert-Eq 'a foreign pool name on a shared pool is refused' 'refuse' $fs.Mode
    Assert-Eq 'and says the pool value shadows the per-app one' 'poolNameShadow' $fs.Outcome

    # The library classifier must agree about what counts as .NET, or the two gates diverge.
    $dnDir  = New-App 'gate-dotnet' $WC_HYBRID @{ 'app.js' = 'x' }
    $stDir  = New-App 'gate-static' $WC_ARR
    $libDn  = Get-CxWebConfigRuntimeState -PhysicalPath $dnDir
    $libSt  = Get-CxWebConfigRuntimeState -PhysicalPath $stDir
    Assert-Eq 'library sees .NET evidence in the hybrid app' 'True' ([bool]((@($libDn.CoreEvidence).Count + @($libDn.FrameworkEvidence).Count) -gt 0))
    Assert-Eq 'standalone agrees'                            'True' (Get-LocalIisnodeEvidence -PhysicalPath $dnDir).IsDotNet
    Assert-Eq 'library sees no .NET evidence in the ARR site' 'False' ([bool]((@($libSt.CoreEvidence).Count + @($libSt.FrameworkEvidence).Count) -gt 0))
    Assert-Eq 'standalone agrees'                            'False' (Get-LocalIisnodeEvidence -PhysicalPath $stDir).IsDotNet

    # IsFramework is the NARROWER question, and the two implementations must agree about it too:
    # it alone decides whether per-app naming is refused on a shared pool, so a divergence here
    # means one writer instruments an app the other refuses.
    Assert-Eq 'library and standalone agree on Framework evidence (hybrid)' `
        ([bool](@($libDn.FrameworkEvidence).Count -gt 0)) ([bool](Get-LocalIisnodeEvidence -PhysicalPath $dnDir).IsFramework)
    Assert-Eq 'library and standalone agree on Framework evidence (ARR site)' `
        ([bool](@($libSt.FrameworkEvidence).Count -gt 0)) ([bool](Get-LocalIisnodeEvidence -PhysicalPath $stDir).IsFramework)

    Write-Host ''
    Write-Host '== per-app naming: the web.config <appSettings> round trip ==' -ForegroundColor Cyan

    # This is the channel that makes a mixed pool work, so the writer and its inverse are asserted
    # against real files - iisnode reads /configuration/appSettings, nothing else.
    $paDir = New-App 'perapp-plain' $WC_IISNODE @{ 'server.js' = 'x' }
    Assert-True 'writer creates <appSettings> when the file has none' `
        (Set-WebConfigAppSettingServiceName -PhysicalPath $paDir -ServiceName 'Site/api')
    Assert-Eq   'and the value reads back'  'Site/api' (Get-CxWebConfigAppSetting -PhysicalPath $paDir -Key 'OTEL_SERVICE_NAME')
    Assert-Eq   'standalone reader agrees'  'Site/api' (Get-LocalWebConfigAppSetting -PhysicalPath $paDir -Key 'OTEL_SERVICE_NAME')
    Assert-True 'the file is still valid XML and still an iisnode app' `
        ([bool](([xml](Get-Content -LiteralPath (Join-Path $paDir 'web.config') -Raw)).SelectSingleNode('//handlers/add')))

    # Re-running must be idempotent, and a rename must land rather than add a second entry.
    [void](Set-WebConfigAppSettingServiceName -PhysicalPath $paDir -ServiceName 'Site/api')
    Assert-Eq 'a re-run adds no second entry' 1 `
        (@(([xml](Get-Content -LiteralPath (Join-Path $paDir 'web.config') -Raw)).SelectNodes("/configuration/appSettings/add[@key='OTEL_SERVICE_NAME']")).Count)
    [void](Set-WebConfigAppSettingServiceName -PhysicalPath $paDir -ServiceName 'Site/renamed')
    Assert-Eq 'a rename overwrites in place' 'Site/renamed' (Get-CxWebConfigAppSetting -PhysicalPath $paDir -Key 'OTEL_SERVICE_NAME')

    # Uninstall: ours comes out, the section we created is pruned, and an app setting that was
    # already there is left alone.
    Assert-True 'remover takes ours out' (Remove-WebConfigAppSettingServiceName -PhysicalPath $paDir -ExpectedValue 'Site/renamed')
    Assert-Eq   'and the value is gone'  '' ([string](Get-CxWebConfigAppSetting -PhysicalPath $paDir -Key 'OTEL_SERVICE_NAME'))
    Assert-True 'and an <appSettings> we created is pruned' `
        (-not ([xml](Get-Content -LiteralPath (Join-Path $paDir 'web.config') -Raw)).SelectSingleNode('/configuration/appSettings'))

    # A value somebody else set is not ours to remove.
    $paKeep = New-App 'perapp-handset' $WC_IISNODE @{ 'server.js' = 'x' }
    [void](Set-WebConfigAppSettingServiceName -PhysicalPath $paKeep -ServiceName 'HandSet')
    Assert-True 'a value that is not the installer''s is left alone' `
        (-not (Remove-WebConfigAppSettingServiceName -PhysicalPath $paKeep -ExpectedValue 'SomethingElse'))
    Assert-Eq 'and it still reads back' 'HandSet' (Get-CxWebConfigAppSetting -PhysicalPath $paKeep -Key 'OTEL_SERVICE_NAME')

    # A prior value is RESTORED, not deleted - the same contract the <aspNetCore> writer has.
    Assert-True 'a prior value is restored' (Remove-WebConfigAppSettingServiceName -PhysicalPath $paKeep -ExpectedValue 'HandSet' -PriorValue 'TheirOwnName')
    Assert-Eq   'to what was there before'  'TheirOwnName' (Get-CxWebConfigAppSetting -PhysicalPath $paKeep -Key 'OTEL_SERVICE_NAME')

    # The standalone writer must produce a file the library reader accepts, and vice versa.
    $paStd = New-App 'perapp-standalone' $WC_IISNODE @{ 'server.js' = 'x' }
    Assert-True 'standalone writer succeeds' (Set-LocalWebConfigAppSetting -PhysicalPath $paStd -Key 'OTEL_SERVICE_NAME' -Value 'Site/std')
    Assert-Eq   'library reader agrees with the standalone writer' 'Site/std' (Get-CxWebConfigAppSetting -PhysicalPath $paStd -Key 'OTEL_SERVICE_NAME')

    # Absent file / absent key must be $null, never a throw: the doctor grades a missing name as a
    # finding, and a reader that threw would take the whole per-app report down with it.
    Assert-Eq 'a missing key reads as null'  '' ([string](Get-CxWebConfigAppSetting -PhysicalPath $paStd -Key 'NO_SUCH_KEY'))
    Assert-Eq 'a missing path reads as null' '' ([string](Get-CxWebConfigAppSetting -PhysicalPath (Join-Path $paStd 'nope') -Key 'OTEL_SERVICE_NAME'))
    Assert-Eq 'standalone agrees on a missing path' '' ([string](Get-LocalWebConfigAppSetting -PhysicalPath (Join-Path $paStd 'nope') -Key 'OTEL_SERVICE_NAME'))

    Write-Host ''
    Write-Host '== finding emitter ==' -ForegroundColor Cyan

    # New-Finding comes from Write-DeployLog.ps1; without it the emitter returns $null by contract.
    $fmt = Join-Path $deploy 'Write-DeployLog.ps1'
    if (Test-Path -LiteralPath $fmt) { . $fmt }
    if (Get-Command New-Finding -ErrorAction SilentlyContinue) {
        $rec = Resolve-IISAppRuntime -PhysicalPath (New-App 'fx-find' $WC_IISNODE @{ 'server.js' = 'x' }) -PoolManagedRuntimeVersion 'v4.0'
        $codes = @{}
        foreach ($o in 'instrumented','perAppNamed','missing','esmUnsupported','sharedPool','sharedPoolFw','poolNameShadow','packageMissing','stalePath','customCmdLine') {
            $f = New-IISNodeFinding -Outcome $o -Record $rec -Target 'Site/api'
            Assert-True "$o produces a finding with a code and a message" ([bool]($f.code -and $f.message))
            $codes[$o] = $f.code
        }
        Assert-Eq 'instrumented is graded pass' 'pass' (New-IISNodeFinding -Outcome 'instrumented' -Record $rec -Target 'x').severity
        Assert-Eq 'a dark iisnode app is graded warn' 'warn' (New-IISNodeFinding -Outcome 'missing' -Record $rec -Target 'x').severity
        # MEASURED on a real host: iisnode cannot host an ES module at all (its interceptor.js
        # require()s the entry point -> ERR_REQUIRE_ESM -> HTTP 500 on every request, with and
        # without our bootstrap). warn, because the agent neither caused it nor is blocked by it -
        # but never pass, because the app cannot serve.
        $esmF = New-IISNodeFinding -Outcome 'esmUnsupported' -Record $rec -Target 'x'
        Assert-Eq   'esmUnsupported is graded warn' 'warn' $esmF.severity
        Assert-Eq   'esmUnsupported code'           'IISNODE_ESM_NOT_HOSTABLE' $esmF.code
        Assert-True 'and names the real cause'      ($esmF.message -match 'ERR_REQUIRE_ESM')
        Assert-True 'and does not blame a missing hook' ($esmF.message -notmatch 'hook\.mjs')
        Assert-Eq 'every outcome has a distinct code' $codes.Count (@($codes.Values | Select-Object -Unique).Count)
        # A pool-sharing app that IS named must grade pass, or a correctly instrumented mixed pool
        # reads as degraded and the feature looks broken on every host that uses it.
        Assert-Eq   'perAppNamed is graded pass' 'pass' (New-IISNodeFinding -Outcome 'perAppNamed' -Record $rec -Target 'x').severity
        Assert-True 'and says where the name lives' ((New-IISNodeFinding -Outcome 'perAppNamed' -Record $rec -Target 'x').message -match 'appSettings')
        Assert-Eq   'the Framework refusal is graded warn' 'warn' (New-IISNodeFinding -Outcome 'sharedPoolFw' -Record $rec -Target 'x').severity
        Assert-True 'and explains the process-wide promotion' ((New-IISNodeFinding -Outcome 'sharedPoolFw' -Record $rec -Target 'x').message -match 'PROCESS-level')
        Assert-True 'the shadow finding explains the ordering' ((New-IISNodeFinding -Outcome 'poolNameShadow' -Record $rec -Target 'x').message -match 'FIRST entry')
        Assert-True 'the dark-app message says pool env, not PM2' ((New-IISNodeFinding -Outcome 'missing' -Record $rec -Target 'x').message -match 'CHILD OF W3WP')
    } else {
        Write-Host '  (skipped: Write-DeployLog.ps1 not available, so New-Finding is absent)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '== CX_SERVICES union (the variable the collector actually reads) ==' -ForegroundColor Cyan

    # Instrumenting an application is only half the job: the collector stamps host Service ownership
    # from CX_SERVICES, so a writer that updates only its own slice leaves the service reporting in
    # APM with no host ownership - and every variable still looking correct. Pure function, so the
    # rule is testable without touching the machine environment.
    if (Get-Command Get-CxServicesUnionValue -ErrorAction SilentlyContinue) {
        Assert-Eq 'order is IIS, then Node, then .NET' 'shop,api,cxnodesvc,worker' `
            ((Get-CxServicesUnionValue -Iis 'shop,api' -Node 'cxnodesvc' -DotNet 'worker') -join ',')
        Assert-Eq 'a name in two slices is claimed once' 'shop,api' `
            ((Get-CxServicesUnionValue -Iis 'shop,api' -Node 'shop') -join ',')
        # Case-insensitive, first spelling wins: the collector stamps the literal string, and two
        # spellings of one service would claim it twice.
        Assert-Eq 'dedup is case-insensitive, first spelling wins' 'MyApp,other' `
            ((Get-CxServicesUnionValue -Iis 'MyApp' -Node 'myapp,other') -join ',')
        Assert-Eq 'whitespace around names is trimmed' 'a,b,c' `
            ((Get-CxServicesUnionValue -Iis ' a , b ' -Node 'c ') -join ',')
        Assert-Eq 'empty slices produce an empty union' 0 `
            (@(Get-CxServicesUnionValue -Iis '' -Node $null -DotNet '').Count)
        Assert-Eq 'a Node-only host still gets a union' 'cxnodesvc' `
            ((Get-CxServicesUnionValue -Node 'cxnodesvc') -join ',')
        # The helper's whole reason for existing: the instrumenters and Install-Agent must agree.
        Assert-True 'Update-CxServicesUnion exists for the writers to call' ([bool](Get-Command Update-CxServicesUnion -ErrorAction SilentlyContinue))
        Assert-True 'Restart-CxCollector exists (env is read at process start)' ([bool](Get-Command Restart-CxCollector -ErrorAction SilentlyContinue))
    } else {
        Write-Host '  (skipped: Write-DeployLog.ps1 not available)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '== pool identity mapping ==' -ForegroundColor Cyan

    # Get-PoolIdentityAccount shells out to appcmd, which is absent on a dev box: what is testable
    # without IIS is that an unknown/absent identityType falls back to the IIS default
    # (ApplicationPoolIdentity) rather than returning something icacls would reject.
    $acct = Get-PoolIdentityAccount -Pool 'SomePool'
    Assert-True 'an unreadable identityType falls back to the pool virtual account' ($acct -eq 'IIS AppPool\SomePool' -or $null -eq $acct)
}
finally {
    if (-not $KeepFixtures) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host "fixtures kept: $root" -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
