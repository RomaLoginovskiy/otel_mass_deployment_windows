<#
.SYNOPSIS
  Unit tests for deploy\Resolve-IISAppRuntime.ps1 - the runtime classifier.

.DESCRIPTION
  Fixture-only. Builds throwaway directories under the user's TEMP and calls the classifier
  against them. Touches no IIS, no registry, no machine environment, and needs no elevation,
  so unlike the docker-win harnesses this one is safe to run anywhere and finishes in about a
  second.

  That is the point: the classification RULES are pure functions of (web.config, app-root
  files, pool CLR version), and pinning them here means the Windows-container runs are left to
  prove the things only a real IIS can - enumeration, appcmd writes, CX_IIS_SERVICES, the
  doctor's exit grading. Getting a rule wrong is cheap to find here and expensive to find
  there.

  Covers the cases the deploy scripts get wrong if the rules regress:
    * "No Managed Code" is correct for ASP.NET Core and WRONG for ASP.NET Framework
    * an ABSENT managedRuntimeVersion means v4.0, not No Managed Code
    * a web.config existing does not make an app .NET
    * a reverse proxy is not instrumentable from IIS
    * ambiguity is reported, never guessed
    * the two override key spaces, and the trailing-slash alias between them

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-ResolveIISAppRuntime.ps1

.NOTES
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param([switch] $KeepFixtures)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$lib  = Join-Path $here '..\deploy\Resolve-IISAppRuntime.ps1'
if (-not (Test-Path -LiteralPath $lib)) { throw "classifier not found: $lib" }
. $lib

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-runtime-fx-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null

$script:Fail = 0
$script:Pass = 0

function New-Fixture {
    param([string] $Name, [string] $WebConfig, [string[]] $Files = @())
    $p = Join-Path $root $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    if ($null -ne $WebConfig) { Set-Content -LiteralPath (Join-Path $p 'web.config') -Value $WebConfig -Encoding utf8 }
    foreach ($f in $Files) {
        $fp = Join-Path $p $f
        New-Item -ItemType Directory -Path (Split-Path $fp) -Force | Out-Null
        Set-Content -LiteralPath $fp -Value 'fixture' -Encoding utf8
    }
    return $p
}

function Assert-Runtime {
    <#
      -Mrv is passed through untyped so $null stays $null. Typing it [string] would coerce
      $null to '' and turn "attribute absent" into "No Managed Code" - the inversion this
      suite exists to catch.
    #>
    param(
        [string] $Name, [string] $Path, $Mrv,
        [string] $Runtime, [string] $Instrumentability,
        [string[]] $Ancestors = @(), [string] $Override = ''
    )
    $r = Resolve-IISAppRuntime -PhysicalPath $Path -PoolManagedRuntimeVersion $Mrv `
        -AncestorPhysicalPaths $Ancestors -Override $Override
    if ($r.DotNetRuntime -eq $Runtime -and $r.Instrumentability -eq $Instrumentability) {
        Write-Host ("  [PASS] {0,-42} {1}/{2}" -f $Name, $r.DotNetRuntime, $r.Instrumentability) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ("  [FAIL] {0,-42} got {1}/{2}  want {3}/{4}" -f $Name, $r.DotNetRuntime, $r.Instrumentability, $Runtime, $Instrumentability) -ForegroundColor Red
        Write-Host ("         evidence=[{0}]" -f ($r.RuntimeEvidence -join '|')) -ForegroundColor DarkGray
        Write-Host ("         reason={0}" -f $r.RuntimeReason) -ForegroundColor DarkGray
        $script:Fail++
    }
}

function Assert-Equal {
    param([string] $Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") {
        Write-Host ("  [PASS] {0,-42} '{1}'" -f $Name, $Actual) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ("  [FAIL] {0,-42} got '{1}' want '{2}'" -f $Name, $Actual, $Expected) -ForegroundColor Red
        $script:Fail++
    }
}

# --- fixtures ------------------------------------------------------------------------------
$coreCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer>
  <handlers><add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" /></handlers>
  <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
</system.webServer></configuration>
'@
# What `dotnet publish` actually emits: wrapped in <location>, and NOT inheritable.
$wrappedCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><location path="." inheritInChildApplications="false"><system.webServer>
  <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="outofprocess" />
</system.webServer></location></configuration>
'@
$inheritCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><location path="."><system.webServer>
  <aspNetCore processPath="dotnet" arguments=".\App.dll" hostingModel="inprocess" />
</system.webServer></location></configuration>
'@
$frameworkCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.web><compilation targetFramework="4.8" /></system.web></configuration>
'@
# <system.web> carrying only <httpRuntime> is NOT Framework evidence - static sites have this.
$hollowCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.web><httpRuntime maxRequestLength="4096" /></system.web></configuration>
'@
$staticCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer>
  <staticContent><mimeMap fileExtension=".woff2" mimeType="font/woff2" /></staticContent>
  <defaultDocument><files><add value="index.html" /></files></defaultDocument>
</system.webServer></configuration>
'@
$arrCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer><rewrite><rules>
  <rule name="proxy" stopProcessing="true"><match url="(.*)" />
  <action type="Rewrite" url="http://localhost:5000/{R:1}" /></rule>
</rules></rewrite></system.webServer></configuration>
'@
$handlerCfg = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer><handlers>
  <add name="Report" path="*.ashx" verb="*" type="Acme.Web.ReportHandler, Acme.Web" />
</handlers></system.webServer></configuration>
'@

$P = @{}
$P.core       = New-Fixture 'core'       $coreCfg
$P.wrapped    = New-Fixture 'wrapped'    $wrappedCfg
$P.parentInh  = New-Fixture 'parentInh'  $inheritCfg
$P.child      = New-Fixture 'child'      $null
$P.fw         = New-Fixture 'fw'         $frameworkCfg
$P.hollow     = New-Fixture 'hollow'     $hollowCfg
$P.static     = New-Fixture 'static'     $staticCfg
$P.arr        = New-Fixture 'arr'        $arrCfg
$P.handler    = New-Fixture 'handler'    $handlerCfg
$P.nocfg      = New-Fixture 'nocfg'      $null @('index.html')
$P.binonly    = New-Fixture 'binonly'    $null @('bin\App.dll')
$P.classic    = New-Fixture 'classic'    $null @('Default.aspx','Global.asax')
$P.badxml     = New-Fixture 'badxml'     '<configuration><system.web>'
$P.gone       = Join-Path $root 'does-not-exist'

Write-Host ''
Write-Host '== the app decides, the pool only qualifies it ==' -ForegroundColor Cyan
Assert-Runtime 'Core + No Managed Code'              $P.core    ''     AspNetCore      Supported
Assert-Runtime 'Core + v4.0 pool (works, warned)'    $P.core    'v4.0' AspNetCore      Misconfigured
Assert-Runtime 'Core + ABSENT attr means v4.0'       $P.core    $null  AspNetCore      Misconfigured
Assert-Runtime 'Core out-of-process, <location>'     $P.wrapped ''     AspNetCore      Supported
Assert-Runtime 'Framework + v4.0 pool'               $P.fw      'v4.0' AspNetFramework Supported
Assert-Runtime 'Framework + absent attr (= v4.0)'    $P.fw      $null  AspNetFramework Supported
Assert-Runtime 'Framework + No Managed Code = broken' $P.fw     ''     AspNetFramework Misconfigured
Assert-Runtime 'managed handler type is Framework'   $P.handler 'v4.0' AspNetFramework Supported
Assert-Runtime 'aspx + Global.asax, no web.config'   $P.classic 'v4.0' AspNetFramework Supported

Write-Host ''
Write-Host '== a web.config does not make an app .NET ==' -ForegroundColor Cyan
Assert-Runtime 'static-content-only web.config'      $P.static  ''     NonDotNet       Unsupported
Assert-Runtime '<system.web> with only httpRuntime'  $P.hollow  'v4.0' NonDotNet       Unsupported
Assert-Runtime 'ARR reverse proxy to a backend'      $P.arr     ''     NonDotNet       Unsupported
Assert-Runtime 'no web.config, static content'       $P.nocfg   $null  NonDotNet       Unsupported
Assert-Runtime 'physical path does not exist'        $P.gone    ''     NonDotNet       Unsupported

Write-Host ''
Write-Host '== ambiguity is reported, never guessed ==' -ForegroundColor Cyan
Assert-Runtime 'bin\*.dll with no web.config'        $P.binonly ''     Unknown         RequiresOverride
Assert-Runtime 'malformed web.config'                $P.badxml  ''     Unknown         RequiresOverride
Assert-Runtime 'no physicalPath at all'              ''         ''     Unknown         RequiresOverride

Write-Host ''
Write-Host '== <aspNetCore> inheritance follows the URL path ==' -ForegroundColor Cyan
Assert-Runtime 'child inherits from an inheriting parent' $P.child '' AspNetCore  Supported   @($P.parentInh)
Assert-Runtime 'child under inheritInChildApplications=false' $P.child '' NonDotNet Unsupported @($P.wrapped)

Write-Host ''
Write-Host '== overrides short-circuit detection ==' -ForegroundColor Cyan
Assert-Runtime 'override forces Core on a static site' $P.nocfg '' AspNetCore  Supported   @() 'AspNetCore'
Assert-Runtime 'override forces NonDotNet on a Core app' $P.core '' NonDotNet Unsupported @() 'NonDotNet'

Write-Host ''
Write-Host '== app-identity keys (NOT the service-name key space) ==' -ForegroundColor Cyan
Assert-Equal 'root app keeps a trailing slash'  (Get-IISAppKey -Site 'Wallet' -AppPath '/')     'Wallet/'
Assert-Equal 'nested app keeps its path'        (Get-IISAppKey -Site 'Wallet' -AppPath '/api')  'Wallet/api'
Assert-Equal 'trailing slash trimmed on nested' (Get-IISAppKey -Site 'Wallet' -AppPath '/api/') 'Wallet/api'
Assert-Equal 'site name with spaces'            (Get-IISAppKey -Site 'Default Web Site' -AppPath '/') 'Default Web Site/'
Assert-Equal 'empty app path is the root'       (Get-IISAppKey -Site 'Wallet' -AppPath '')      'Wallet/'

Write-Host ''
Write-Host '== override table: aliasing, case, unmatched keys, bad values ==' -ForegroundColor Cyan
$ov = Resolve-IISRuntimeOverrides -Table @{ 'Wallet' = 'AspNetCore'; 'Shop/api' = 'NonDotNet' }
Assert-Equal 'slash-less root key is an alias' (Get-IISRuntimeOverrideFor -Overrides $ov -Site 'Wallet' -AppPath '/') 'AspNetCore'
Assert-Equal 'lookup is case-insensitive'      (Get-IISRuntimeOverrideFor -Overrides $ov -Site 'shop' -AppPath '/API') 'NonDotNet'
Assert-Equal 'no override for other apps'      (Get-IISRuntimeOverrideFor -Overrides $ov -Site 'Other' -AppPath '/')  ''

$apps = @([pscustomobject]@{ Site = 'Wallet'; AppPath = '/' })
# No @() around the call: the function uses the repo's `return ,@(...)` idiom, which emits the
# array as a single pipeline object so an empty or one-element result survives. Re-wrapping it
# in @() nests it one level deeper. Production callers all iterate it with foreach, which is
# correct either way.
$un = Get-IISUnmatchedRuntimeOverrideKeys -Overrides $ov -Apps $apps
Assert-Equal 'unmatched keys are surfaced' ($un -join ',') 'Shop/api'
Assert-Equal 'no unmatched keys when every key matches' `
    ((Get-IISUnmatchedRuntimeOverrideKeys -Overrides (Resolve-IISRuntimeOverrides -Table @{ 'Wallet/' = 'AspNetCore' }) -Apps $apps) -join ',') ''

# A typo in a value must fail at parse time. Silently classifying nothing and reporting a
# successful install is the outcome this prevents.
try {
    Resolve-IISRuntimeOverrides -Table @{ 'X/' = 'Nope' } | Out-Null
    Write-Host '  [FAIL] an invalid override value did not throw' -ForegroundColor Red
    $script:Fail++
} catch {
    Write-Host '  [PASS] an invalid override value throws' -ForegroundColor Green
    $script:Pass++
}

Write-Host ''
Write-Host '== policy table is pure ==' -ForegroundColor Cyan
Assert-Equal 'Core + CLR loading'      (Get-IISAppInstrumentability -Runtime 'AspNetCore'      -PoolClrLoads $true)  'Misconfigured'
Assert-Equal 'Core + no CLR'           (Get-IISAppInstrumentability -Runtime 'AspNetCore'      -PoolClrLoads $false) 'Supported'
Assert-Equal 'Framework + CLR loading' (Get-IISAppInstrumentability -Runtime 'AspNetFramework' -PoolClrLoads $true)  'Supported'
Assert-Equal 'Framework + no CLR'      (Get-IISAppInstrumentability -Runtime 'AspNetFramework' -PoolClrLoads $false) 'Misconfigured'
Assert-Equal 'NonDotNet is never instrumented' (Get-IISAppInstrumentability -Runtime 'NonDotNet' -PoolClrLoads $true) 'Unsupported'
Assert-Equal 'Unknown needs an override'       (Get-IISAppInstrumentability -Runtime 'Unknown'   -PoolClrLoads $true) 'RequiresOverride'

Write-Host ''
Write-Host '== misc/Test-CxInstrumentation.ps1 clone has not drifted ==' -ForegroundColor Cyan

# misc\Test-CxInstrumentation.ps1 is a deliberate zero-dependency copy — it is the validator you
# drop on a host whose deploy package is missing — so it inlines the classifier instead of
# dot-sourcing it. Nothing else in the repo notices if the two implementations diverge, and a
# divergence is not cosmetic: the standalone validator would hand an operator a different
# verdict than the installer acted on. Run both over the same fixtures and require agreement.
$clone = Join-Path $here '..\misc\Test-CxInstrumentation.ps1'
if (-not (Test-Path -LiteralPath $clone)) {
    Write-Host '  [SKIP] misc/Test-CxInstrumentation.ps1 not present' -ForegroundColor DarkGray
} else {
    # Both files define their functions above any dot-source guard, so this loads the clone's
    # functions without executing its validator body.
    . $clone
    if (-not (Get-Command Resolve-CxAppRuntime -ErrorAction SilentlyContinue)) {
        Write-Host '  [FAIL] the clone no longer exposes Resolve-CxAppRuntime' -ForegroundColor Red
        $script:Fail++
    } else {
        $parityCases = @(
            @{ n = 'core+nmc';     p = $P.core;    mrv = '' },
            @{ n = 'core+v4';      p = $P.core;    mrv = 'v4.0' },
            @{ n = 'core+absent';  p = $P.core;    mrv = $null },
            @{ n = 'fw+v4';        p = $P.fw;      mrv = 'v4.0' },
            @{ n = 'fw+nmc';       p = $P.fw;      mrv = '' },
            @{ n = 'handler-type'; p = $P.handler; mrv = 'v4.0' },
            @{ n = 'static-wc';    p = $P.static;  mrv = '' },
            @{ n = 'hollow';       p = $P.hollow;  mrv = 'v4.0' },
            @{ n = 'arrproxy';     p = $P.arr;     mrv = '' },
            @{ n = 'nocfg';        p = $P.nocfg;   mrv = '' },
            @{ n = 'binonly';      p = $P.binonly; mrv = '' },
            @{ n = 'classic-fs';   p = $P.classic; mrv = 'v4.0' },
            @{ n = 'badxml';       p = $P.badxml;  mrv = '' },
            @{ n = 'missing-dir';  p = $P.gone;    mrv = '' },
            @{ n = 'inherit-yes';  p = $P.child;   mrv = ''; anc = @($P.parentInh) },
            @{ n = 'inherit-no';   p = $P.child;   mrv = ''; anc = @($P.wrapped) }
        )
        foreach ($c in $parityCases) {
            $anc = if ($c.ContainsKey('anc')) { $c.anc } else { @() }
            $a = Resolve-IISAppRuntime -PhysicalPath $c.p -PoolManagedRuntimeVersion $c.mrv -AncestorPhysicalPaths $anc
            $b = Resolve-CxAppRuntime  -PhysicalPath $c.p -PoolManagedRuntimeVersion $c.mrv -AncestorPhysicalPaths $anc
            if ($a.DotNetRuntime -eq $b.DotNetRuntime -and $a.Instrumentability -eq $b.Instrumentability) {
                Write-Host ("  [PASS] {0,-13} {1}/{2}" -f $c.n, $a.DotNetRuntime, $a.Instrumentability) -ForegroundColor Green
                $script:Pass++
            } else {
                Write-Host ("  [FAIL] {0,-13} shared={1}/{2}  clone={3}/{4}" -f $c.n, $a.DotNetRuntime, $a.Instrumentability, $b.DotNetRuntime, $b.Instrumentability) -ForegroundColor Red
                $script:Fail++
            }
        }
    }
}

if (-not $KeepFixtures) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "`nfixtures kept at $root" -ForegroundColor DarkGray }

Write-Host ''
Write-Host ("== RESULT: {0} passed, {1} failed ==" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
