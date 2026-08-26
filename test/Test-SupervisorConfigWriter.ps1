<#
.SYNOPSIS
  Unit tests for the two OpAMP Supervisor config.yaml writers in
  deploy\Install-CoralogixSupervisor.ps1: the AgentDescription writer (the scalar encoder, the
  value decoder, the canonicalize pass, the insert/idempotency behaviour) and the agent-settings
  writer (agent.config_apply_timeout / agent.passthrough_logs).

.DESCRIPTION
  Fixture-only. Writes throwaway config.yaml files under the user's TEMP, touches no service, no
  machine environment and no network, and needs no elevation - so unlike the docker-win harnesses
  this one runs anywhere in about a second.

  WHAT THESE TESTS ENCODE. The supervisor does not parse config.yaml once: it re-serializes
  agent.description.non_identifying_attributes into the config text it composes for the collector
  WITHOUT escaping backslashes, then parses that text again. One level of backslash escaping is
  consumed per pass. Measured against the real binary on a Windows VM
  for the value C:\ProgramData\pm2:

    "C:\ProgramData\pm2"          DEAD   - the reported OTIOMWQA01 failure ("retrieved value
                                  (type=string) cannot be used as a Conf ... found unknown escape
                                  character")
    'C:\ProgramData\pm2'          DEAD   - quoting style alone is NOT the fix
    "C:\\ProgramData\\pm2"        DEAD   - valid YAML, still re-emitted unescaped
    "NT AUTHORITY\\LocalService"  STARTS - and silently corrupts the value, because \L is a legal
                                  second-pass escape (U+2028). This is why "the service is
                                  Running" is not a sufficient check anywhere in this code.
    'C:/ProgramData/pm2'          STARTS - but lossy, it is no longer the path
    'C:\\ProgramData\\pm2'        STARTS and arrives EXACT  <- canonical

  WHY A UNIT TEST AT ALL. Every test\docker-win harness installs with CX_NO_SUPERVISOR=1 (the
  vendor installer cannot fetch the collector MSI in a Server Core container), so the supervisor
  branch never runs there. The container harnesses assert workload.pm2.home=C:\ProgramData\pm2
  where it is PRODUCED, never where it is SERIALIZED. And Coralogix-side checks see the
  collector's own resourcedetection attributes, which say nothing about supervisor config.yaml.
  The VM loop covers the runtime half; this file pins the string rules, which is the half that
  can be checked in a second on any machine.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Test-SupervisorConfigWriter.ps1

.NOTES
  Exit code = number of failed assertions, so CI can gate on it.
#>
[CmdletBinding()]
param([switch] $KeepFixtures)

$ErrorActionPreference = 'Stop'

$here      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$installer = Join-Path $here '..\deploy\Install-CoralogixSupervisor.ps1'
if (-not (Test-Path -LiteralPath $installer)) { throw "not found: $installer" }

# The installer is a SCRIPT, not a module: dot-sourcing it would run Assert-Admin, resolve a
# region and start installing. So the functions under test are lifted out by AST. The trade-off is
# deliberate - it keeps the test elevation-free and side-effect free, at the cost of failing
# loudly if a function is renamed.
$wanted = @('ConvertTo-SupervisorAttrScalar','Expand-CxBackslashEscapes','Get-SupervisorAttrValue',
            'Get-SupervisorAttrFirstPass','Test-SupervisorAttrScalarCanonical',
            'Test-SupervisorAttrScalarNeedsFix','Set-SupervisorDescriptionAttributes',
            'Set-SupervisorAgentSettings')
$ast   = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
$found = @()
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $f.Name) { Invoke-Expression $f.Extent.Text; $found += $f.Name }
}
$missing = @($wanted | Where-Object { $found -notcontains $_ })
if ($missing.Count) { throw "not found in ${installer}: $($missing -join ', ') (renamed?)" }

$script:Pass = 0; $script:Fail = 0
function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { $script:Fail++; Write-Host "  FAIL $Name$(if ($Detail) { " -> $Detail" })" -ForegroundColor Red }
}
function Assert-Equal {
    param([string] $Name, $Expected, $Actual)
    Assert-True $Name ($Expected -ceq $Actual) "expected [$Expected], got [$Actual]"
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cx-supcfg-fx-" + [System.Diagnostics.Process]::GetCurrentProcess().Id)
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null

$vendorBlock = @'
server:
  endpoint: wss://ingress.eu2.coralogix.com/opamp/v1
agent:
  executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
      cx.agent.type: "standalone"
'@

function New-Fixture {
    param([string] $Name, [string] $Content = $vendorBlock)
    $p = Join-Path $root "$Name.yaml"
    Set-Content -Path $p -Value $Content -Encoding utf8
    return $p
}
function Get-AttrLine {
    param([string] $Path, [string] $Key)
    $l = @(Get-Content -Path $Path | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Key) + ":") })
    if ($l.Count) { return $l[0].Trim() }
    return ''
}
# Raw (untrimmed) lines for a key, anywhere in the file. Untrimmed on purpose: the agent-settings
# tests are entirely about which INDENT a key was written at, so trimming would erase the thing
# under test. The count matters too - a duplicate key is a silent config bug.
function Get-KeyLines {
    param([string] $Path, [string] $Key)
    @(Get-Content -Path $Path | Where-Object { $_ -match ("^\s*" + [regex]::Escape($Key) + "\s*:") })
}
# Everything from the first line matching $StartPattern to EOF, as one string - so a test can
# assert a whole subtree came through byte for byte.
function Get-Subtree {
    param([string] $Path, [string] $StartPattern)
    $l = @(Get-Content -Path $Path)
    $i = 0
    while ($i -lt $l.Count -and $l[$i] -notmatch $StartPattern) { $i++ }
    if ($i -ge $l.Count) { return '' }
    return (($l[$i..($l.Count - 1)]) -join "`n")
}
# The invariant: no ATTRIBUTE value may carry a backslash that survives the first parse in
# non-canonical form. Scoped to the 6-space attribute indent on purpose - agent.executable also
# contains backslashes and is not an attribute, so judging it would make this helper lie.
function Get-NonCanonicalLines {
    param([string] $Path)
    @(Get-Content -Path $Path |
        Where-Object { $_ -match '^      [\w\.]+:\s*\S' } |
        Where-Object { Test-SupervisorAttrScalarNeedsFix -Raw (($_ -replace '^\s*[^:]+:\s*', '').Trim()) })
}

Write-Host "`n== the scalar encoder ==" -ForegroundColor Cyan
Assert-Equal 'Windows path: every backslash doubled, single-quoted' `
    "'C:\\ProgramData\\pm2'" (ConvertTo-SupervisorAttrScalar 'C:\ProgramData\pm2')
Assert-Equal 'DOMAIN\user: doubled too (\L would otherwise become U+2028)' `
    "'NT AUTHORITY\\LocalService'" (ConvertTo-SupervisorAttrScalar 'NT AUTHORITY\LocalService')
Assert-Equal 'apostrophe doubled' "'it''s here'" (ConvertTo-SupervisorAttrScalar "it's here")
Assert-Equal 'plain value untouched apart from quoting' "'iis'" (ConvertTo-SupervisorAttrScalar 'iis')
Assert-Equal 'UNC path: leading pair doubled as well' `
    "'\\\\srv\\share'" (ConvertTo-SupervisorAttrScalar '\\srv\share')
Assert-Equal 'empty value is still a valid scalar' "''" (ConvertTo-SupervisorAttrScalar '')

Write-Host "`n== the value decoder (what the collector would ACTUALLY get) ==" -ForegroundColor Cyan
# Two passes, because the supervisor parses this field twice. In a single-quoted YAML scalar `\\`
# is two LITERAL backslashes after pass one; pass two is what collapses them to one.
Assert-Equal 'canonical round trip' 'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw "'C:\\ProgramData\\pm2'")
Assert-Equal 'single-quoted, un-doubled: literal' 'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw "'C:\ProgramData\pm2'")
Assert-Equal 'double-quoted, escaped: unescaped once' 'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw '"C:\\ProgramData\\pm2"')
# The old writer emitted values verbatim inside double quotes, so an escape go-yaml would reject
# (\p) is what that writer meant literally - recovering it as literal is what lets the
# canonicalize pass rewrite an OTIOMWQA01-style line without changing its meaning.
Assert-Equal 'double-quoted, unknown escape: backslash kept literal' 'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw '"C:\ProgramData\pm2"')
Assert-Equal 'apostrophe unescaped' "it's here" (Get-SupervisorAttrValue -Raw "'it''s here'")
Assert-Equal 'plain scalar carries no escapes' 'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw 'C:\ProgramData\pm2')
Assert-Equal 'real \t escape honoured in a double-quoted value' "a$([char]9)b" (Get-SupervisorAttrValue -Raw '"a\tb"')

Write-Host "`n== canonical detection ==" -ForegroundColor Cyan
Assert-True  'canonical scalar recognised'      (Test-SupervisorAttrScalarCanonical -Raw "'C:\\ProgramData\\pm2'")
Assert-True  'un-doubled is NOT canonical'      (-not (Test-SupervisorAttrScalarCanonical -Raw "'C:\ProgramData\pm2'"))
Assert-True  'double-quoted is NOT canonical'   (-not (Test-SupervisorAttrScalarCanonical -Raw '"C:\\ProgramData\\pm2"'))
Assert-True  'legal-but-corrupting \L form is NOT canonical' `
    (-not (Test-SupervisorAttrScalarCanonical -Raw '"NT AUTHORITY\\LocalService"'))

Write-Host "`n== fresh insert with hostile values ==" -ForegroundColor Cyan
$hostileAttrs = @(
    'cx.host.role=iis'
    'workload.pm2.home=C:\ProgramData\pm2'
    'workload.pm2.owner=NT AUTHORITY\LocalService'
    'workload.pm2.apps=28'
    'workload.note=it''s a "quoted" value: with colon # and hash'
) -join ','

$f = New-Fixture 'fresh'
Set-SupervisorDescriptionAttributes -ConfigPath $f -Attributes $hostileAttrs 3>$null
Assert-Equal 'PM2_HOME written in canonical form' "workload.pm2.home: 'C:\\ProgramData\\pm2'" (Get-AttrLine $f 'workload.pm2.home')
Assert-Equal 'daemon owner written in canonical form' "workload.pm2.owner: 'NT AUTHORITY\\LocalService'" (Get-AttrLine $f 'workload.pm2.owner')
Assert-Equal 'no backslash left un-doubled anywhere' 0 (Get-NonCanonicalLines $f).Count
Assert-True  'embedded apostrophe doubled' ((Get-AttrLine $f 'workload.note') -match "^workload\.note: 'it''s a ")
Assert-True  'vendor value without a backslash left exactly as the installer wrote it' `
    ((Get-AttrLine $f 'service.name') -ceq 'service.name: "coralogix-collector"')
Assert-True  "agent.executable's own backslashes untouched (not an attribute)" `
    ((Get-Content $f -Raw) -match [regex]::Escape('executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe'))

Write-Host "`n== re-run is idempotent ==" -ForegroundColor Cyan
$before = Get-Content $f -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $f -Attributes $hostileAttrs 3>$null
Assert-Equal 'file unchanged on re-run' $before (Get-Content $f -Raw)
Assert-Equal 'no duplicate key' 1 (@(Get-Content $f | Where-Object { $_ -match '^\s*workload\.pm2\.home:' }).Count)

Write-Host "`n== canonicalize a host poisoned by the old writer ==" -ForegroundColor Cyan
# Exactly what shipped to OTIOMWQA01. Both keys are already PRESENT, so without a canonicalize
# pass the writer skips them, writes nothing, and a re-deploy leaves the host dead.
$broken = New-Fixture 'broken' @'
agent:
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
      cx.host.role: "iis"
      workload.pm2.home: "C:\ProgramData\pm2"
      workload.pm2.owner: "NT AUTHORITY\LocalService"
'@
Assert-Equal 'fixture starts non-canonical' 2 (Get-NonCanonicalLines $broken).Count
$warn = (Set-SupervisorDescriptionAttributes -ConfigPath $broken -Attributes $hostileAttrs 3>&1) -join "`n"
Assert-Equal 'canonicalized, nothing left un-doubled' 0 (Get-NonCanonicalLines $broken).Count
Assert-Equal 'the dead line is now canonical, same value' "workload.pm2.home: 'C:\\ProgramData\\pm2'" (Get-AttrLine $broken 'workload.pm2.home')
Assert-Equal 'the silently-corrupting line is fixed too' "workload.pm2.owner: 'NT AUTHORITY\\LocalService'" (Get-AttrLine $broken 'workload.pm2.owner')
Assert-True  'operator told the values were canonicalized' ([bool]($warn -match 'canonicaliz')) "warnings: $warn"
Assert-Equal 'no duplicate key after canonicalize' 1 (@(Get-Content $broken | Where-Object { $_ -match '^\s*workload\.pm2\.home:' }).Count)
Assert-True  'new keys still added alongside' ((Get-AttrLine $broken 'workload.pm2.apps') -ceq "workload.pm2.apps: '28'")

Write-Host "`n== an already-canonical host is not churned ==" -ForegroundColor Cyan
$canon = New-Fixture 'canon' @'
agent:
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
      workload.pm2.home: 'C:\\ProgramData\\pm2'
      workload.tab: "col1\tcol2"
'@
$canonBefore = Get-Content $canon -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $canon -Attributes 'workload.pm2.home=C:\ProgramData\pm2' 3>$null
Assert-Equal 'canonical file untouched' $canonBefore (Get-Content $canon -Raw)

Write-Host "`n== best-effort contract: nothing to do, nothing written ==" -ForegroundColor Cyan
$noAnchor = New-Fixture 'noanchor' "server:`n  endpoint: wss://example/opamp/v1`n"
$snapshot = Get-Content $noAnchor -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $noAnchor -Attributes $hostileAttrs 3>$null
Assert-Equal 'missing anchor -> file untouched' $snapshot (Get-Content $noAnchor -Raw)

$empty = New-Fixture 'emptyattrs'
$snapshot2 = Get-Content $empty -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $empty -Attributes '' 3>$null
Assert-Equal 'empty attribute string -> file untouched' $snapshot2 (Get-Content $empty -Raw)

$missingCfg = Join-Path $root 'does-not-exist.yaml'
Set-SupervisorDescriptionAttributes -ConfigPath $missingCfg -Attributes $hostileAttrs 3>$null
Assert-True 'missing config -> no file created, no throw' (-not (Test-Path $missingCfg))

Write-Host "`n== agent settings: fresh insert ==" -ForegroundColor Cyan
# What the installer passes. Ordered, because the insert order below is this order.
$agentSettings = [ordered]@{
    'passthrough_logs'     = 'true'
    'config_apply_timeout' = '30s'
}

$as = New-Fixture 'agentsettings'
$asDescBefore = Get-Subtree -Path $as -StartPattern '^\s*description:'
Set-SupervisorAgentSettings -ConfigPath $as -Settings $agentSettings 3>$null
Assert-Equal 'passthrough_logs written once, at the direct-child indent, UNQUOTED' `
    '  passthrough_logs: true' (@(Get-KeyLines $as 'passthrough_logs') -join '|')
Assert-Equal 'config_apply_timeout written once, at the direct-child indent, UNQUOTED' `
    '  config_apply_timeout: 30s' (@(Get-KeyLines $as 'config_apply_timeout') -join '|')
# The indent is READ from the vendor's file, never assumed - so it must equal the sibling's.
Assert-Equal 'indent matches the sibling agent.executable' `
    (([regex]::Match((Get-KeyLines $as 'executable')[0], '^\s*')).Value) `
    (([regex]::Match((Get-KeyLines $as 'passthrough_logs')[0], '^\s*')).Value)
Assert-True  'agent.executable itself untouched' `
    ((Get-Content $as -Raw) -match [regex]::Escape('executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe'))
Assert-Equal 'the description subtree is byte-identical' $asDescBefore (Get-Subtree -Path $as -StartPattern '^\s*description:')

Write-Host "`n== agent settings: re-run is idempotent ==" -ForegroundColor Cyan
$asBefore = Get-Content $as -Raw
Set-SupervisorAgentSettings -ConfigPath $as -Settings $agentSettings 3>$null
Assert-Equal 'file unchanged on re-run' $asBefore (Get-Content $as -Raw)
Assert-Equal 'still exactly one passthrough_logs' 1 (@(Get-KeyLines $as 'passthrough_logs')).Count
Assert-Equal 'still exactly one config_apply_timeout' 1 (@(Get-KeyLines $as 'config_apply_timeout')).Count

Write-Host "`n== agent settings: upgrade a host that already carries the 5s default ==" -ForegroundColor Cyan
# The path that actually fixes a deployed host. Skip-if-present would leave 5s in place and make
# the re-deploy a no-op - the same class of bug the canonicalize pass above exists for.
$as5 = New-Fixture 'agentsettings5s' @'
agent:
  executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe
  config_apply_timeout: 5s
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
'@
Set-SupervisorAgentSettings -ConfigPath $as5 -Settings $agentSettings 3>$null
Assert-Equal 'the 5s line was rewritten in place, not duplicated' `
    '  config_apply_timeout: 30s' (@(Get-KeyLines $as5 'config_apply_timeout') -join '|')
Assert-Equal 'and the missing key was added alongside' `
    '  passthrough_logs: true' (@(Get-KeyLines $as5 'passthrough_logs') -join '|')

Write-Host "`n== agent settings: a nested key of the same name is NOT ours ==" -ForegroundColor Cyan
# The trap this writer must not fall into. config_apply_timeout under description: is a different
# key at a different level; matching it would move a vendor value and leave the real
# agent.config_apply_timeout unset while still reporting success.
$asNest = New-Fixture 'agentsettingsnested' @'
agent:
  executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
      config_apply_timeout: 5s
'@
Set-SupervisorAgentSettings -ConfigPath $asNest -Settings $agentSettings 3>$null
Assert-True  'the nested 5s value is left exactly as it was' `
    ((Get-KeyLines $asNest 'config_apply_timeout') -contains '      config_apply_timeout: 5s')
Assert-True  'and ours was still added at the agent level' `
    ((Get-KeyLines $asNest 'config_apply_timeout') -contains '  config_apply_timeout: 30s')
Assert-Equal 'so the key appears at two distinct levels, deliberately' 2 (@(Get-KeyLines $asNest 'config_apply_timeout')).Count

Write-Host "`n== agent settings: the child indent is READ, not assumed ==" -ForegroundColor Cyan
# These are the tests that catch a broken indent derivation. The vendor's real file happens to use
# two spaces, which is also the fallback - so a writer that never derives anything still passes
# every assertion above. A four-space file does not let that slide.
$asWide = New-Fixture 'agentsettingswide' @'
agent:
    executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe
    description:
        non_identifying_attributes:
            service.name: "coralogix-collector"
'@
Set-SupervisorAgentSettings -ConfigPath $asWide -Settings $agentSettings 3>$null
Assert-Equal 'four-space file: keys written at four spaces' `
    '    config_apply_timeout: 30s' (@(Get-KeyLines $asWide 'config_apply_timeout') -join '|')
Assert-Equal 'four-space file: indent still matches the sibling executable' `
    (([regex]::Match((Get-KeyLines $asWide 'executable')[0], '^\s*')).Value) `
    (([regex]::Match((Get-KeyLines $asWide 'passthrough_logs')[0], '^\s*')).Value)

# A comment is not a child: its indentation says nothing about the mapping's.
$asComment = New-Fixture 'agentsettingscomment' @'
agent:
        # written by the vendor installer - do not edit
  executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
'@
Set-SupervisorAgentSettings -ConfigPath $asComment -Settings $agentSettings 3>$null
Assert-Equal 'a deeper-indented comment does not define the child indent' `
    '  config_apply_timeout: 30s' (@(Get-KeyLines $asComment 'config_apply_timeout') -join '|')

# An empty mapping has no child to learn from, so the fallback applies - and the result still has
# to be a valid document, with the following top-level key untouched.
$asEmptyBlock = New-Fixture 'agentsettingsemptyblock' @'
agent:
server:
  endpoint: wss://example/opamp/v1
'@
Set-SupervisorAgentSettings -ConfigPath $asEmptyBlock -Settings $agentSettings 3>$null
Assert-Equal 'childless agent: falls back to agent-indent + 2' `
    '  config_apply_timeout: 30s' (@(Get-KeyLines $asEmptyBlock 'config_apply_timeout') -join '|')
Assert-True  'and the next top-level key is still at column 0' `
    ((Get-Content $asEmptyBlock) -contains 'server:')

Write-Host "`n== agent settings: best-effort contract ==" -ForegroundColor Cyan
$noAgent = New-Fixture 'noagent' "server:`n  endpoint: wss://example/opamp/v1`n"
$noAgentSnap = Get-Content $noAgent -Raw
Set-SupervisorAgentSettings -ConfigPath $noAgent -Settings $agentSettings 3>$null
Assert-Equal 'no agent: block -> file untouched' $noAgentSnap (Get-Content $noAgent -Raw)

# An inline flow mapping is a vendor template we do not recognise. Splicing lines into it would
# produce a document that parses as something else entirely, so refuse rather than guess.
$flowAgent = New-Fixture 'flowagent' "agent: {}`n"
$flowSnap = Get-Content $flowAgent -Raw
Set-SupervisorAgentSettings -ConfigPath $flowAgent -Settings $agentSettings 3>$null
Assert-Equal 'agent: {} -> file untouched' $flowSnap (Get-Content $flowAgent -Raw)

$asMissing = Join-Path $root 'agent-does-not-exist.yaml'
Set-SupervisorAgentSettings -ConfigPath $asMissing -Settings $agentSettings 3>$null
Assert-True 'missing config -> no file created, no throw' (-not (Test-Path $asMissing))

$asEmpty = New-Fixture 'agentsettingsempty'
$asEmptySnap = Get-Content $asEmpty -Raw
Set-SupervisorAgentSettings -ConfigPath $asEmpty -Settings ([ordered]@{}) 3>$null
Assert-Equal 'no settings -> file untouched' $asEmptySnap (Get-Content $asEmpty -Raw)

Write-Host "`n== both writers over one file do not corrupt each other ==" -ForegroundColor Cyan
$both = New-Fixture 'both'
Set-SupervisorDescriptionAttributes -ConfigPath $both -Attributes $hostileAttrs 3>$null
Set-SupervisorAgentSettings -ConfigPath $both -Settings $agentSettings 3>$null
Assert-Equal 'attributes still canonical after the settings write' 0 (Get-NonCanonicalLines $both).Count
Assert-Equal 'PM2_HOME still canonical' "workload.pm2.home: 'C:\\ProgramData\\pm2'" (Get-AttrLine $both 'workload.pm2.home')
Assert-Equal 'agent settings present' '  config_apply_timeout: 30s' (@(Get-KeyLines $both 'config_apply_timeout') -join '|')

# Reverse order too: the description writer must walk past the settings lines without disturbing
# them, and its own anchor scan must not mistake them for attributes.
$both2 = New-Fixture 'both2'
Set-SupervisorAgentSettings -ConfigPath $both2 -Settings $agentSettings 3>$null
Set-SupervisorDescriptionAttributes -ConfigPath $both2 -Attributes $hostileAttrs 3>$null
Assert-Equal 'settings survive a later attribute write' '  passthrough_logs: true' (@(Get-KeyLines $both2 'passthrough_logs') -join '|')
Assert-Equal 'and the attributes landed' "workload.pm2.owner: 'NT AUTHORITY\\LocalService'" (Get-AttrLine $both2 'workload.pm2.owner')
Assert-True  'vendor service.name untouched by either writer' `
    ((Get-AttrLine $both2 'service.name') -ceq 'service.name: "coralogix-collector"')

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepFixtures) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "fixtures kept: $root" }
exit $script:Fail
