<#
.SYNOPSIS
  Unit tests for the OpAMP Supervisor AgentDescription writer in
  deploy\Install-CoralogixSupervisor.ps1.

.DESCRIPTION
  Fixture-only. Writes throwaway config.yaml files under the user's TEMP, touches no service, no
  machine environment and no network, and needs no elevation - so unlike the docker-win
  harnesses this one runs anywhere in about a second.

  WHAT IS BEING PINNED, and why it is not the obvious thing:

  The supervisor does not parse its config.yaml once. It re-serializes AgentDescription values
  into the merged config text WITHOUT escaping backslashes, then parses that text again. One
  level of backslash escaping is consumed per pass. Measured against a real supervisor on a
  Windows VM for workload.pm2.home = C:\ProgramData\pm2 and
  workload.pm2.owner = NT AUTHORITY\LocalService:

    on disk                            2nd parse sees   outcome
    ---------------------------------- ---------------- ------------------------------------
    "C:\\ProgramData\\pm2"             C:\ProgramData\  SERVICE DEAD - 'could not compose
                                       pm2  -> \p       initial merged config: yaml: line 49:
                                                        found unknown escape character'
    'C:\ProgramData\pm2'               same             SERVICE DEAD - identical error; the
                                                        quoting style is not what saves you
    "NT AUTHORITY\\LocalService"       \L is a valid    STARTS, VALUE CORRUPTED to
                                       escape (U+2028)  'NT AUTHORITY<U+2028>     ocalService'
    'C:\\ProgramData\\pm2'             C:\\ProgramData  STARTS, value exact  <-- the only
                                       \\pm2            correct form
    "C:/ProgramData/pm2"               no backslash     starts, value slash-ified (lossy)

  So the invariant is NOT "avoid double quotes" and NOT "it parses as YAML" - both are
  satisfied by forms that kill the service or silently mangle the value. It is: every backslash
  in the YAML VALUE must be doubled. That is what these tests assert.

  This file exists because no container harness can catch any of it: every test\docker-win
  runner installs with CX_NO_SUPERVISOR=1 (the vendor installer cannot fetch the collector MSI
  in a Server Core container), so the supervisor branch never executes there. The end-to-end
  proof lives in poc\Run-SupervisorVmLoop.ps1 against a real VM; this suite pins the string
  rules so a regression is caught in a second rather than on a fleet host.

  Covers:
    * a Windows path and a DOMAIN\user are emitted with doubled backslashes, single-quoted
    * apostrophes are doubled; values with no backslash are left plain
    * a re-run adds nothing and re-quotes nothing (idempotent - the canonical form is a
      fixed point, which is what makes the repair pass safe to run on every deploy)
    * BOTH field-observed broken forms are repaired: the service-killing one and the
      valid-YAML-but-corrupting one
    * a correctly doubled value is NOT touched (the repair must not double it again)
    * decode/encode round-trips for double-quoted, single-quoted and unquoted scalars
    * a missing anchor / empty attribute string / missing file writes nothing

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
# region and start installing. The functions under test are lifted out by AST instead. The
# trade-off is deliberate - it keeps the suite elevation-free and side-effect free, at the cost
# of failing loudly if one of them is renamed.
$wanted = @('ConvertTo-SupervisorAttrScalar','Get-SupervisorAttrValue',
            'Test-SupervisorAttrScalarCanonical','Set-SupervisorDescriptionAttributes')
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$null)
foreach ($name in $wanted) {
    $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "$name not found in $installer (renamed?)" }
    Invoke-Expression $fn.Extent.Text
}

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
    $l = @(Get-Content -Path $Path | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Key) + '\s*:') })
    if ($l.Count -ne 1) { return "<$($l.Count) matches>" }
    return $l[0].Trim()
}

Write-Host "`n== scalar encoding ==" -ForegroundColor Cyan
Assert-Equal 'Windows path -> doubled, single-quoted' `
    "'C:\\ProgramData\\pm2'" (ConvertTo-SupervisorAttrScalar -Value 'C:\ProgramData\pm2')
Assert-Equal 'DOMAIN\user -> doubled, single-quoted' `
    "'NT AUTHORITY\\LocalService'" (ConvertTo-SupervisorAttrScalar -Value 'NT AUTHORITY\LocalService')
Assert-Equal 'no backslash -> plain single-quoted' "'iis'" (ConvertTo-SupervisorAttrScalar -Value 'iis')
Assert-Equal 'apostrophe doubled' "'it''s'" (ConvertTo-SupervisorAttrScalar -Value "it's")

Write-Host "`n== scalar decoding (so a repair cannot change meaning) ==" -ForegroundColor Cyan
Assert-Equal 'double-quoted escapes processed' 'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw '"C:\\ProgramData\\pm2"')
Assert-Equal 'single-quoted is literal'        'C:\\ProgramData\\pm2' (Get-SupervisorAttrValue -Raw "'C:\\ProgramData\\pm2'")
Assert-Equal 'single-quoted apostrophe'        "it's" (Get-SupervisorAttrValue -Raw "'it''s'")
Assert-Equal 'unquoted is literal'             'C:\ProgramData\pm2' (Get-SupervisorAttrValue -Raw 'C:\ProgramData\pm2')

Write-Host "`n== canonical predicate: the field-observed forms ==" -ForegroundColor Cyan
Assert-True  'service-killing form is NOT canonical' `
    (-not (Test-SupervisorAttrScalarCanonical -Raw '"C:\\ProgramData\\pm2"'))
Assert-True  'silently-corrupting form is NOT canonical' `
    (-not (Test-SupervisorAttrScalarCanonical -Raw '"NT AUTHORITY\\LocalService"'))
Assert-True  'single-quoted single backslash is NOT canonical (valid YAML, still dead)' `
    (-not (Test-SupervisorAttrScalarCanonical -Raw "'C:\ProgramData\pm2'"))
Assert-True  'doubled single-quoted IS canonical' `
    (Test-SupervisorAttrScalarCanonical -Raw "'C:\\ProgramData\\pm2'")
Assert-True  'backslash-free value IS canonical' (Test-SupervisorAttrScalarCanonical -Raw '"iis"')

# The real attributes this host reports, plus values carrying YAML-significant characters.
$hostileAttrs = @(
    'cx.host.role=iis'
    'workload.pm2.home=C:\ProgramData\pm2'
    'workload.pm2.owner=NT AUTHORITY\LocalService'
    'workload.pm2.apps=28'
    'workload.note=it''s a "quoted" value: with colon # and hash'
) -join ','

Write-Host "`n== fresh insert ==" -ForegroundColor Cyan
$f = New-Fixture 'fresh'
Set-SupervisorDescriptionAttributes -ConfigPath $f -Attributes $hostileAttrs 3>$null
Assert-Equal 'PM2_HOME doubled + single-quoted' "workload.pm2.home: 'C:\\ProgramData\\pm2'"      (Get-AttrLine $f 'workload.pm2.home')
Assert-Equal 'owner doubled + single-quoted'    "workload.pm2.owner: 'NT AUTHORITY\\LocalService'" (Get-AttrLine $f 'workload.pm2.owner')
Assert-Equal 'plain value untouched'            "cx.host.role: 'iis'"                            (Get-AttrLine $f 'cx.host.role')
Assert-True  'apostrophe doubled in file' ((Get-AttrLine $f 'workload.note') -match "it''s")
Assert-Equal 'vendor line left alone' 'service.name: "coralogix-collector"' (Get-AttrLine $f 'service.name')
Assert-True  'inserted under the anchor at child indent' `
    ((Get-Content $f -Raw) -match "(?m)^    non_identifying_attributes:\r?\n      cx\.host\.role: 'iis'")
Assert-True  "agent.executable is not a quoted scalar and is untouched" `
    ((Get-Content $f -Raw) -match [regex]::Escape('executable: C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe'))

Write-Host "`n== idempotent: the canonical form is a fixed point ==" -ForegroundColor Cyan
$before = Get-Content $f -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $f -Attributes $hostileAttrs 3>$null
Assert-Equal 'file unchanged on re-run' $before (Get-Content $f -Raw)
Set-SupervisorDescriptionAttributes -ConfigPath $f -Attributes $hostileAttrs 3>$null
Assert-Equal 'still unchanged on a third run (no runaway doubling)' $before (Get-Content $f -Raw)
Assert-Equal 'no duplicate key' 1 (@(Get-Content $f | Where-Object { $_ -match '^\s*workload\.pm2\.home:' }).Count)

Write-Host "`n== repair of both field-observed broken forms ==" -ForegroundColor Cyan
# Exactly what was found on OTIOMWQA01 and on the VM. Both keys are already PRESENT, so without
# a repair pass the writer skips them, writes nothing, and the host stays broken across
# re-deploys. workload.pm2.owner is the nastier case: that config STARTS.
$broken = New-Fixture 'broken' @'
agent:
  description:
    non_identifying_attributes:
      service.name: "coralogix-collector"
      cx.host.role: "iis"
      workload.pm2.home: "C:\\ProgramData\\pm2"
      workload.pm2.owner: "NT AUTHORITY\\LocalService"
'@
Set-SupervisorDescriptionAttributes -ConfigPath $broken -Attributes $hostileAttrs 3>$null
Assert-Equal 'killer form repaired, value preserved' `
    "workload.pm2.home: 'C:\\ProgramData\\pm2'" (Get-AttrLine $broken 'workload.pm2.home')
Assert-Equal 'corrupting form repaired, value preserved' `
    "workload.pm2.owner: 'NT AUTHORITY\\LocalService'" (Get-AttrLine $broken 'workload.pm2.owner')
Assert-Equal 'backslash-free double-quoted value not rewritten' `
    'service.name: "coralogix-collector"' (Get-AttrLine $broken 'service.name')
Assert-True  'new keys still added alongside the repair' ((Get-AttrLine $broken 'workload.pm2.apps') -match "'28'")
Assert-Equal 'repair did not duplicate a key' 1 (@(Get-Content $broken | Where-Object { $_ -match '^\s*workload\.pm2\.home:' }).Count)

Write-Host "`n== an already-correct config is left byte-identical ==" -ForegroundColor Cyan
$good = New-Fixture 'good' @'
agent:
  description:
    non_identifying_attributes:
      workload.pm2.home: 'C:\\ProgramData\\pm2'
      workload.pm2.owner: 'NT AUTHORITY\\LocalService'
      cx.host.role: 'iis'
      workload.pm2.apps: '28'
      workload.note: 'it''s a "quoted" value: with colon # and hash'
'@
$goodBefore = Get-Content $good -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $good -Attributes $hostileAttrs 3>$null
Assert-Equal 'no rewrite, no re-doubling' $goodBefore (Get-Content $good -Raw)

Write-Host "`n== best-effort contract ==" -ForegroundColor Cyan
$noAnchor = New-Fixture 'noanchor' "server:`n  endpoint: wss://example/opamp/v1`n"
$snap = Get-Content $noAnchor -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $noAnchor -Attributes $hostileAttrs 3>$null
Assert-Equal 'missing anchor -> untouched' $snap (Get-Content $noAnchor -Raw)

$empty = New-Fixture 'emptyattrs'
$snap2 = Get-Content $empty -Raw
Set-SupervisorDescriptionAttributes -ConfigPath $empty -Attributes '' 3>$null
Assert-Equal 'empty attribute string -> untouched' $snap2 (Get-Content $empty -Raw)

$missing = Join-Path $root 'does-not-exist.yaml'
Set-SupervisorDescriptionAttributes -ConfigPath $missing -Attributes $hostileAttrs 3>$null
Assert-True 'missing config -> nothing created, no throw' (-not (Test-Path $missing))

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepFixtures) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "fixtures kept: $root" }
exit $script:Fail
