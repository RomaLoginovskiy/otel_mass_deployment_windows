<#
.SYNOPSIS
  Static tests for the transform/environment processor in every collector config that
  ships one - that it exists, covers all three signal kinds, and cannot clobber an
  app-supplied environment label.

.DESCRIPTION
  Reads the YAML as text and asserts structure. Touches no service, no machine
  environment and no network, needs no elevation, and runs in about a second anywhere.

  WHAT THESE TESTS ENCODE. Two failures this processor is built around, both of which
  shipped before and neither of which produced an error anywhere:

  1. A CLOBBER. The original block was an attributes processor doing
     `action: upsert` with `value: ${env:CX_ENVIRONMENT:-unspecified}`. On a host where
     CX_ENVIRONMENT is unset that overwrote a correct deployment.environment.name -
     one the app had supplied through its own OTEL_RESOURCE_ATTRIBUTES - with the
     literal string "unspecified". resourcedetection/env runs first and is
     deliberately override: false so an app value survives; this processor then threw
     it away regardless. Hence: in the unset branch every set() MUST carry a
     `where ... == nil` guard.

  2. A MISSING SIGNAL KIND. A transform with log_statements and metric_statements but
     no trace_statements leaves every span untagged, silently. That exact omission has
     shipped in this repo before, in transform/iis_service_labels. Hence: all three
     statement kinds are asserted per file, not just the presence of the processor.

  It must also be a transform rather than an attributes/resource processor at all:
  confmap turns a whole-string "${env:X:-}" into nil and the processor then fails to
  start, taking the collector with it. A condition-guarded transform is the only safe
  way to express "only when the variable is set".

  WHY A STATIC TEST. Every test\docker-win harness installs with CX_NO_SUPERVISOR=1
  and none of them reads the emitted attribute back, so nothing in CI notices if a
  statement kind or a nil-guard goes missing from these files. This pins the shape;
  Run-E2ELoop.ps1 P6 covers the env-var plumbing, and only a live collector can prove
  the block starts.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-EnvironmentStamp.ps1

.NOTES
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repo = Resolve-Path (Join-Path $here '..')

# Every config that carries the stamp. A new collector config with an environment
# label belongs in this list, or it is covered by nothing.
$configs = @(
    'deploy\config.supervisor.yaml'
    'deploy\config.recommended.yaml'
    'deploy\templates\rabbitmq.yaml'
    'SimpleWebApp\coralogix\config.yaml'
    'docs\iis-service-ownership.collector.yaml'
)

# The processor has to run for each of these signal pipelines. Same list the doctor
# checks (Test-Agent.ps1 -EnvironmentPipelines), for the same reason: a stamp wired
# into logs but not traces produces spans with no environment.
$pipelines = @('logs', 'metrics', 'traces')

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:Pass++
    } else {
        Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:Fail++
    }
}

function Assert-Equal {
    param([string] $Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:Pass++
    } else {
        Write-Host "  [FAIL] $Name  expected '$Expected', got '$Actual'" -ForegroundColor Red; $script:Fail++
    }
}

foreach ($rel in $configs) {
    $path = Join-Path $repo $rel
    Write-Host ''
    Write-Host "== $rel ==" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $path)) {
        Assert-True "config exists" $false $path
        continue
    }

    $raw = Get-Content -LiteralPath $path -Raw

    # Comment lines are stripped so a mention inside a comment - and these files
    # comment heavily, including quoting the old upsert form - is never counted as a
    # live definition.
    $live = ($raw -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    # The old attributes processor must be gone entirely, name and all: leaving it
    # defined but unreferenced is how a pipeline silently keeps the clobbering version.
    Assert-True 'no resource/environment processor remains' `
        ($live -notmatch 'resource/environment')

    # Processors sit at two-space indent; take this one's block up to the next.
    $blockMatch = [regex]::Match($live, '(?ms)^  transform/environment:\s*$.*?(?=^  \S|\z)')
    Assert-True 'transform/environment is defined' $blockMatch.Success
    if (-not $blockMatch.Success) { continue }
    $block = $blockMatch.Value

    Assert-True 'error_mode: silent' ($block -match 'error_mode:\s*silent')

    # All three signal kinds. Missing one is invisible at runtime.
    foreach ($kind in @('log_statements', 'metric_statements', 'trace_statements')) {
        Assert-True "defines $kind" ($block -match "(?m)^\s+$kind\s*:\s*$")
    }

    # Both guards, once per statement kind.
    Assert-Equal 'set-branch guards (one per statement kind)' 3 `
        ([regex]::Matches($block, [regex]::Escape('!= ""')).Count)
    Assert-Equal 'unset-branch guards (one per statement kind)' 3 `
        ([regex]::Matches($block, [regex]::Escape('== ""')).Count)

    # The clobber invariant. 3 keys x 3 statement kinds = 18 set() calls: 9 in the
    # set branch, unconditional so the host label wins, and 9 in the unset branch,
    # every one of them guarded by == nil so an app value is never destroyed.
    $setLines = @($block -split "`n" | Where-Object { $_ -match '^\s*-\s*set\(' })
    Assert-Equal 'total set() statements' 18 $setLines.Count
    $guarded   = @($setLines | Where-Object { $_ -match '==\s*nil\s*$' })
    $unguarded = @($setLines | Where-Object { $_ -notmatch '==\s*nil\s*$' })
    Assert-Equal 'guarded set() statements (unset branch, nil-checked)' 9 $guarded.Count
    Assert-Equal 'unconditional set() statements (set branch)' 9 $unguarded.Count

    # All three keys, in both branches.
    foreach ($key in @('tags.cx_environment', 'tags.cx_env', 'deployment.environment.name')) {
        Assert-Equal "key $key set once per branch per signal kind" 6 `
            (@($setLines | Where-Object { $_ -match [regex]::Escape("`"$key`"") }).Count)
        Assert-Equal "key $key nil-guarded in the unset branch" 3 `
            (@($guarded | Where-Object { $_ -match [regex]::Escape("`"$key`"") }).Count)
    }

    # Wired in, not merely defined. Scope to service.pipelines first: a four-space
    # 'logs:' key also occurs in the exporter section hundreds of lines earlier, and
    # matching that one reports NOT_WIRED against a correctly wired config. Within the
    # block, the trailing colon-then-EOL keeps 'metrics' from matching 'metrics/compact'.
    $pipesText = [regex]::Match($live, '(?ms)^  pipelines:\s*$.*?(?=^  \S|\z)').Value
    Assert-True 'service.pipelines block found' ([bool]$pipesText)

    foreach ($pipe in $pipelines) {
        $pm = [regex]::Match($pipesText, "(?ms)^\s{4}$([regex]::Escape($pipe)):\s*$.*?(?=^\s{4}\S|\z)")
        if (-not $pm.Success) {
            Assert-True "pipeline '$pipe' block found" $false 'could not locate the block'
            continue
        }
        Assert-True "transform/environment wired into the '$pipe' pipeline" `
            ($pm.Value -match [regex]::Escape('transform/environment'))
    }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
