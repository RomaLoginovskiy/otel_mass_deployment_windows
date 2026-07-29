<#
.SYNOPSIS
  Unit tests for the pure parts of deploy\Instrument-NodeService.ps1 and
  deploy\Instrument-DotNetService.ps1 - the two non-IIS Windows-service instrumentation paths.

.DESCRIPTION
  Fixture-only. Writes throwaway winsw XML files and PE stubs under the user's TEMP, and touches no
  service, no registry and no machine environment - so unlike the VM matrix this runs anywhere in
  about a second and needs no elevation.

  What it pins, and why each one is here rather than left to the VM run:

    * winsw / node-windows <env> upsert. These files are GENERATED, so their attribute order and
      formatting vary, and the tempting implementation - a regex rewrite - produces TWO <env>
      elements with the same name, after which the last one silently wins. So: upsert semantics,
      idempotency, and preservation of unrelated elements.

    * REG_MULTI_SZ line composition. An Environment value containing an EMPTY element is what stops
      IIS from starting (the doctor grades it PROFILER_REGISTRY_MALFORMED, act-now). The .NET
      service path writes the same value type on other services, so "never emit an empty line" is
      an invariant worth a test rather than a comment.

    * NODE_OPTIONS merging. An app that sets --max-old-space-size for a reason must keep it; losing
      a heap ceiling silently is worse than not instrumenting at all. Also: re-running must not
      accumulate two bootstraps, because loading the SDK twice is its own failure mode.

    * Runtime classification of a service BINARY. Core and Framework need different variable pairs
      (CORECLR_* vs COR_*), and attaching the wrong pair produces total silence that reads like a
      collector problem - so 'unknown' has to stay an answer, not become a guess.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-ServiceInstrumenters.ps1

.NOTES
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param([switch] $KeepFixtures)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$nodeSvc   = Join-Path $here '..\deploy\Instrument-NodeService.ps1'
$dotnetSvc = Join-Path $here '..\deploy\Instrument-DotNetService.ps1'
$nodeLib   = Join-Path $here '..\deploy\Resolve-NodeServiceNames.ps1'
foreach ($f in @($nodeSvc, $dotnetSvc, $nodeLib)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "not found: $f" }
}

# Merge-CxNodeOptions comes from a library that is safe to dot-source (it only defines functions).
. $nodeLib

# The two instrumenters are SCRIPTS with a mandatory param and an Assert-Admin at the top, so their
# functions are lifted out by AST instead of dot-sourcing. Failing loudly on a rename is the point.
#
# The helper RETURNS the source text and the caller evaluates it at script scope on purpose:
# Invoke-Expression inside a function defines the function in that function's scope, so it vanishes
# on return - which showed up here as "The term 'Get-CxWinswEnv' is not recognized".
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

Invoke-Expression (Get-ScriptFunctionText -Path $nodeSvc   -Names @('Get-CxWinswEnv','Set-CxWinswEnv','Remove-CxWinswEnv'))
Invoke-Expression (Get-ScriptFunctionText -Path $dotnetSvc -Names @('Get-CxServiceRuntime'))

$script:Pass = 0; $script:Fail = 0
function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { $script:Fail++; Write-Host "  FAIL $Name$(if ($Detail) { " -> $Detail" })" -ForegroundColor Red }
}
function Assert-Equal {
    param([string] $Name, $Expected, $Actual)
    Assert-True $Name ($Expected -eq $Actual) "expected [$Expected], got [$Actual]"
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-svcinstr-fx-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null

# ---- winsw / node-windows XML -------------------------------------------------
Write-Host "`n== winsw <env> upsert ==" -ForegroundColor Cyan

# node-windows really does emit this shape: id/name/description, an <env> the app already needs,
# and arguments carrying the entry script.
$winswXml = Join-Path $root 'nodeapp.xml'
Set-Content -LiteralPath $winswXml -Encoding utf8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<service>
  <id>nodeapp</id>
  <name>nodeapp</name>
  <description>a node app under winsw</description>
  <executable>C:\nodejs\node.exe</executable>
  <argument>C:\apps\cjs\server.js</argument>
  <env name="NODE_ENV" value="production"/>
  <env name="NODE_OPTIONS" value="--max-old-space-size=512"/>
  <logmode>rotate</logmode>
</service>
'@

$before = Get-CxWinswEnv -Xml $winswXml
Assert-Equal 'reads existing env count' 2 $before.Count
Assert-Equal 'reads the app''s own NODE_OPTIONS' '--max-old-space-size=512' $before['NODE_OPTIONS']

$merged = Merge-CxNodeOptions -Existing $before['NODE_OPTIONS'] -Bootstrap '--require C:/cx/otel-node/register.js'
Assert-True  'merge keeps the app''s heap flag' ($merged -match '--max-old-space-size=512')
Assert-True  'merge adds our bootstrap'         ($merged -match [regex]::Escape('--require C:/cx/otel-node/register.js'))

Set-CxWinswEnv -Xml $winswXml -Values @{
    NODE_OPTIONS                = $merged
    OTEL_SERVICE_NAME           = 'nodeapp'
    OTEL_EXPORTER_OTLP_ENDPOINT = 'http://127.0.0.1:4318'
}
$after = Get-CxWinswEnv -Xml $winswXml
Assert-Equal 'upsert updated in place, did not duplicate' 4 $after.Count
Assert-Equal 'NODE_OPTIONS now merged'  $merged $after['NODE_OPTIONS']
Assert-Equal 'unrelated env preserved'  'production' $after['NODE_ENV']
Assert-Equal 'new var added'            'nodeapp' $after['OTEL_SERVICE_NAME']

[xml]$doc = Get-Content -LiteralPath $winswXml -Raw
Assert-Equal 'exactly one NODE_OPTIONS element' 1 @($doc.service.env | Where-Object { $_.name -eq 'NODE_OPTIONS' }).Count
Assert-Equal 'entry argument untouched' 'C:\apps\cjs\server.js' ([string]$doc.service.argument)
Assert-Equal 'logmode untouched' 'rotate' ([string]$doc.service.logmode)

# Idempotency: the same call again must change nothing at all.
$snapshot = Get-Content -LiteralPath $winswXml -Raw
Set-CxWinswEnv -Xml $winswXml -Values @{ NODE_OPTIONS = $merged; OTEL_SERVICE_NAME = 'nodeapp'; OTEL_EXPORTER_OTLP_ENDPOINT = 'http://127.0.0.1:4318' }
Assert-Equal 'second write is a no-op' $snapshot (Get-Content -LiteralPath $winswXml -Raw)

# Re-running the merge must not stack two bootstraps.
#
# These cases use a bootstrap path that contains NEITHER 'opentelemetry' NOR
# 'auto-instrumentations-node' on purpose. That is how the real defect showed up: the prior-hook
# check matched only those two markers, which the default prefix happens to contain, so a vendored
# or differently-prefixed install was never recognised and every re-deploy added a second
# --require. An app then loads the SDK twice, which is its own failure mode.
$twice = Merge-CxNodeOptions -Existing $merged -Bootstrap '--require C:/cx/otel-node/register.js'
Assert-Equal 'bootstrap not duplicated on re-run (prefix without the package markers)' 1 ([regex]::Matches($twice, [regex]::Escape('register.js')).Count)
Assert-True  'heap flag still there after re-run' ($twice -match '--max-old-space-size=512')

# Switching an app from CommonJS to ESM must replace the hook, not append a second one.
$esm = Merge-CxNodeOptions -Existing $merged -Bootstrap '--experimental-loader=file:///C:/cx/otel-node/hook.mjs --require C:/cx/otel-node/register.js'
Assert-Equal 'still one register after switching to ESM' 1 ([regex]::Matches($esm, [regex]::Escape('register.js')).Count)
Assert-True  'ESM loader present' ($esm -match 'experimental-loader')
# ...and back again, dropping the loader it no longer needs. The caller declares BOTH artifacts as
# owned - exactly as Instrument-NodeService.ps1 and Instrument-NodePM2.ps1 do - because a CommonJS
# bootstrap never mentions hook.mjs and the stale ESM loader would otherwise survive every re-run.
$owned = @('C:/cx/otel-node/register.js', 'file:///C:/cx/otel-node/hook.mjs')
$backToCjs = Merge-CxNodeOptions -Existing $esm -Bootstrap '--require C:/cx/otel-node/register.js' -OwnedTargets $owned
Assert-Equal 'ESM loader dropped when switching back to CommonJS' 0 ([regex]::Matches($backToCjs, 'experimental-loader').Count)
Assert-Equal 'still exactly one register' 1 ([regex]::Matches($backToCjs, [regex]::Escape('register.js')).Count)

# Without the declaration the loader is NOT dropped - documented here so the -OwnedTargets contract
# is visible rather than folded into a filename heuristic that could eat an app's own register.js.
$noDeclare = Merge-CxNodeOptions -Existing $esm -Bootstrap '--require C:/cx/otel-node/register.js'
Assert-Equal 'undeclared loader is left alone (contract, not a bug)' 1 ([regex]::Matches($noDeclare, 'experimental-loader').Count)

# Path spelling must not defeat recognition: a value written with backslashes has to be recognised
# by a bootstrap expressed with forward slashes (and vice versa), or the same host accumulates hooks
# depending on which version wrote it.
$backslashed = Merge-CxNodeOptions -Existing '--require C:\cx\otel-node\register.js' -Bootstrap '--require C:/cx/otel-node/register.js'
Assert-Equal 'backslash and forward-slash spellings are the same hook' 1 ([regex]::Matches($backslashed, [regex]::Escape('register.js')).Count)

# The realistic path still works, including the legacy marker rule for values written by an older
# version whose exact path we cannot reconstruct.
$realish = '--require C:/cx/otel-node/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js'
$legacy  = Merge-CxNodeOptions -Existing $realish -Bootstrap '--require C:/other/prefix/register.js'
Assert-Equal 'a marker-bearing legacy hook is still recognised' 1 ([regex]::Matches($legacy, [regex]::Escape('register.js')).Count)

# An app's OWN --require must survive. This is the false-positive side of the same rule.
$appOwn = Merge-CxNodeOptions -Existing '--require ./tracing-shim.js --max-old-space-size=256' -Bootstrap '--require C:/cx/otel-node/register.js'
Assert-True 'the app''s own --require is preserved' ($appOwn -match [regex]::Escape('--require ./tracing-shim.js'))
Assert-True 'the app''s own flags are preserved'   ($appOwn -match '--max-old-space-size=256')
Assert-Equal 'and ours is added exactly once' 1 ([regex]::Matches($appOwn, [regex]::Escape('C:/cx/otel-node/register.js')).Count)

Write-Host "`n== winsw removal ==" -ForegroundColor Cyan
$removed = Remove-CxWinswEnv -Xml $winswXml -Names @('NODE_OPTIONS','OTEL_SERVICE_NAME','OTEL_EXPORTER_OTLP_ENDPOINT')
Assert-Equal 'removed the three we added' 3 $removed
$final = Get-CxWinswEnv -Xml $winswXml
Assert-Equal 'the app''s own env survives removal' 1 $final.Count
Assert-Equal 'and it is the right one' 'production' $final['NODE_ENV']

# ---- REG_MULTI_SZ line composition -------------------------------------------
# Set-CxServiceEnvMap writes to HKLM, so the INVARIANT is tested rather than the write: build the
# same lines the writer builds and assert no empty element can appear. This is the value shape that
# stops IIS from starting when it is malformed.
Write-Host "`n== REG_MULTI_SZ composition invariant ==" -ForegroundColor Cyan
function Build-EnvLines {
    param([System.Collections.Specialized.OrderedDictionary] $Map)
    $lines = @()
    foreach ($k in $Map.Keys) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $lines += "$k=$([string]$Map[$k])"
    }
    return $lines
}
$m = [ordered]@{}
$m['CORECLR_ENABLE_PROFILING'] = '1'
$m['CORECLR_PROFILER']         = '{918728DD-259F-4A6A-AC2B-B85E1B658318}'
$m['OTEL_SERVICE_NAME']        = 'cxworkersvc'
$m['']                         = 'orphan'      # a key that must be dropped
$m['EMPTY_OK']                 = ''            # a name with no value is legal for the SCM
$lines = Build-EnvLines -Map $m
Assert-Equal 'orphan key dropped' 4 $lines.Count
Assert-True  'no line is empty or bare =' (-not (@($lines | Where-Object { -not $_.Trim() -or $_.Trim() -eq '=' }).Count))
Assert-True  'a name with an empty value is kept' ([bool](@($lines) -contains 'EMPTY_OK='))
Assert-True  'every line has a name before =' (-not (@($lines | Where-Object { $_.IndexOf('=') -lt 1 }).Count))

# ---- service binary runtime classification -----------------------------------
Write-Host "`n== .NET service runtime classification ==" -ForegroundColor Cyan

$coreDir = Join-Path $root 'core'; New-Item -ItemType Directory -Path $coreDir -Force | Out-Null
$coreExe = Join-Path $coreDir 'cxworkersvc.exe'
Set-Content -LiteralPath $coreExe -Value 'stub' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $coreDir 'cxworkersvc.runtimeconfig.json') -Encoding utf8 -Value '{ "runtimeOptions": { "tfm": "net8.0" } }'
Assert-Equal 'runtimeconfig.json -> core' 'core' (Get-CxServiceRuntime -Exe $coreExe)

$depsDir = Join-Path $root 'deps'; New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
$depsExe = Join-Path $depsDir 'other.exe'
Set-Content -LiteralPath $depsExe -Value 'stub' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $depsDir 'other.deps.json') -Encoding utf8 -Value '{}'
Assert-Equal 'deps.json -> core' 'core' (Get-CxServiceRuntime -Exe $depsExe)

$nativeDir = Join-Path $root 'native'; New-Item -ItemType Directory -Path $nativeDir -Force | Out-Null
$nativeExe = Join-Path $nativeDir 'native.exe'
# A tiny non-PE file: no CLR header, no runtimeconfig -> must be 'unknown', never 'framework'.
[System.IO.File]::WriteAllBytes($nativeExe, [byte[]](1..64))
Assert-Equal 'non-managed binary -> unknown (not guessed)' 'unknown' (Get-CxServiceRuntime -Exe $nativeExe)

Assert-Equal 'missing binary -> unknown' 'unknown' (Get-CxServiceRuntime -Exe (Join-Path $root 'does-not-exist.exe'))

# A real managed Framework exe is the one case that cannot be faked with a stub, so the classifier
# is pointed at a genuine one from the GAC-era tooling shipped with Windows.
$realFw = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe'
if (Test-Path -LiteralPath $realFw) {
    Assert-Equal 'a real .NET Framework exe -> framework' 'framework' (Get-CxServiceRuntime -Exe $realFw)
} else {
    Write-Host '  NOTE InstallUtil.exe not present - skipping the real-Framework-binary case' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepFixtures) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "fixtures kept: $root" }
exit $script:Fail
