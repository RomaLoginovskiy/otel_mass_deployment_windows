<#
.SYNOPSIS
  Install the Coralogix OpenTelemetry Collector - with the OpAMP Supervisor
  (default) or without it (-NoSupervisor).

.DESCRIPTION
  Downloads the vendor installer (coralogix-otel-collector.ps1) and runs it. The
  ONLY difference between the two modes is the arguments handed to that installer:

    supervisor     -Supervisor -SupervisorCollectorBaseConfig <cfg> -EnableDynamicIISParsing
    -NoSupervisor  -Config <cfg> -EnableDynamicIISParsing

  Supervisor mode: the OpAMP Supervisor process owns the OpAMP connection and
  Coralogix Fleet Management can push remote config that is merged on top of the
  local base config.

  -NoSupervisor: the collector runs as the plain 'otelcol-contrib' Windows service
  and the config on disk is authoritative - nothing is merged, nothing is pushed.

  ONE recommended config serves both modes. It is produced into this script's own
  folder as config.recommended.yaml and handed to whichever installer argument the
  mode selects. It must not contain an opamp extension: that is mandatory in
  supervisor mode (the Supervisor owns OpAMP) and is what makes -NoSupervisor
  deterministic.

  Note the vendor installer OWNS config placement in regular mode - it copies what
  -Config points at into %ProgramData%\OpenTelemetry\Collector. This script does not
  write there.

  Sets CORALOGIX_DOMAIN and CORALOGIX_PRIVATE_KEY (persisted as machine env vars so
  the service keeps them across restarts), produces the config, and installs.

.PARAMETER Region
  Coralogix region code: eu1, eu2, us1, us2, us3, ap1, ap2, ap3. Resolved to the
  region's domain (<region>.coralogix.com) by Resolve-CxRegion.ps1 and published as
  CORALOGIX_DOMAIN, which the base config's coralogix exporters and the vendor
  installer's OpAMP endpoint both read. An unknown code is a hard error - it would
  otherwise ship telemetry to the wrong account while looking healthy.

.PARAMETER Domain
  Full Coralogix ingress domain, for a private / non-standard endpoint the region
  table does not cover. Wins over -Region when both are given.

  When NEITHER is given the domain is resolved, in order, from: the CX_DOMAIN environment
  variable (the domain-shaped equivalent of this parameter, which deploy.bat forwards), the
  CX_REGION environment variable, a CORALOGIX_DOMAIN exported for this run, a region.txt
  file next to this script, the CORALOGIX_DOMAIN a previous install persisted on this host,
  and finally eu1.coralogix.com. See the block above the resolution for why the same
  environment variable appears in two different places in that order.

.PARAMETER PrivateKey
  Send-Your-Data API key. If omitted, read from -KeyFile.

.PARAMETER KeyFile
  File containing the Send-Your-Data key. Default: .\SendDataKey.txt (falls back to
  ..\SimpleWebApp\coralogix\SendDataKey.txt when present).

.PARAMETER NoSupervisor
  Install WITHOUT the OpAMP Supervisor: the vendor installer's regular mode, which
  registers the 'otelcol-contrib' service and takes the config via -Config.
  Affects the installer arguments and nothing else.

.PARAMETER BaseConfig
  Source template for the recommended config. Default: .\config.supervisor.yaml
  (the name is historical - the file is opamp-free and serves both modes).

.PARAMETER StageDir
  Where the recommended config is produced. Default: this script's own folder, so
  the config sits next to the scripts that used it and is available for either
  mode. The vendor installer copies it to its own location from there.

.PARAMETER Version
  Optional collector version to pin (passed to the vendor installer -Version).

.PARAMETER Environment
  Optional deployment environment (e.g. production/staging/dev). Persisted as the
  machine env var CX_ENVIRONMENT, which the base config's transform/environment
  processor stamps onto all signals (tags.cx_environment, tags.cx_env,
  deployment.environment.name) so Coralogix can split telemetry by environment.

.PARAMETER Application
  Optional Coralogix APPLICATION name for this host. Persisted as the machine env var
  CX_APPLICATION, which the base config's transform/appname processor stamps as
  service.namespace (the exporter maps it to the application name).
  OMIT IT to get the default: the application name falls back to the host's own name
  (host.name). Use it only when several hosts must report under one shared application.

.PARAMETER Team
  Optional owning team for this host. Persisted as TWO machine env vars with the same
  value: CX_TEAM (the name this package owns) and TEAM (the bare name software already
  on these hosts reads). No processor in the shipped base config reads either one - the
  label is here for a remote Fleet Management config, or the host's own software, to
  consume as ${env:CX_TEAM}. Both prior values are recorded for uninstall, because TEAM
  is a generic name that may well have belonged to something else first.

.PARAMETER ConfigApplyTimeout
  How long the OpAMP Supervisor waits for the collector to report healthy after it
  applies a new remote config, written to the supervisor config as
  agent.config_apply_timeout. The supervisor's own default is 5s; this base config is
  large enough that the collector routinely needs longer than that on Windows, and on
  timeout the supervisor reports RemoteConfigStatus = FAILED to Coralogix Fleet
  Management - so the console showed the config as failed to apply while it had in fact
  applied and telemetry was flowing. Default: 30s.

.NOTES
  Run elevated (Administrator). The base config uses file_storage, so this script
  passes -EnableDynamicIISParsing to the vendor installer (otherwise the service
  can fail to start).
#>
[CmdletBinding()]
param(
    # Region code (eu1/eu2/us1/...) -> domain. Defaults are resolved below, not here,
    # because the fallback chain reads the environment and a file on disk.
    [string] $Region     = $null,
    [string] $Domain     = $null,
    [string] $PrivateKey = $null,
    [string] $KeyFile    = (Join-Path $PSScriptRoot 'SendDataKey.txt'),
    [switch] $NoSupervisor,
    [string] $BaseConfig = (Join-Path $PSScriptRoot 'config.supervisor.yaml'),
    [string] $StageDir   = $PSScriptRoot,
    [string] $Version    = $null,
    # Deployment environment -> machine env var CX_ENVIRONMENT (read by the base
    # config's transform/environment processor).
    [string] $Environment = $null,
    # Coralogix application name -> machine env var CX_APPLICATION (read by the base
    # config's transform/appname processor). Unset = fall back to host.name.
    [string] $Application = $null,
    # Owning team -> machine env vars CX_TEAM and TEAM (same value in both). Read by no
    # processor in the base config; it exists for remote Fleet config / host software.
    [string] $Team = $null,
    # How long the supervisor waits for the collector to become healthy after applying a
    # remote config -> the supervisor config's agent.config_apply_timeout. The supervisor
    # defaults to 5s, which this config cannot meet, and a timeout is reported upstream as
    # a FAILED config apply.
    [string] $ConfigApplyTimeout = '30s',
    # Comma-separated key=value selector attributes (cx.host.role, workload.*) to publish
    # in the OpAMP AgentDescription. Defaults to machine OTEL_RESOURCE_ATTRIBUTES (set by
    # Detect-Workloads.ps1) when omitted.
    [string] $ResourceAttributes = $null,
    # Optional backup/manifest session (from Backup-Config.ps1, created by the
    # orchestrator). When supplied, machine env vars and the supervisor config are
    # recorded/backed up before they are set so uninstall can reverse them.
    $Session = $null
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY under `powershell -File <relative-path>`, which would turn
# every default above into a bare filename resolved against the caller's cwd. Repair
# the ones that matter rather than trusting the param defaults.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $StageDir)   { $StageDir   = $here }
if (-not $BaseConfig) { $BaseConfig = Join-Path $here 'config.supervisor.yaml' }
if (-not $KeyFile)    { $KeyFile    = Join-Path $here 'SendDataKey.txt' }

# Optional backup/manifest recording (shared session from the orchestrator).
$backupHelper = Join-Path $here 'Backup-Config.ps1'
if (Test-Path $backupHelper) { . $backupHelper }

# Region table. NOT Test-Path guarded like the optional helpers: without it a -Region
# cannot be resolved, and defaulting to eu1 in that case would send the fleet's data
# to the wrong account silently. Fail the install instead.
$regionHelper = Join-Path $here 'Resolve-CxRegion.ps1'
if (-not (Test-Path $regionHelper)) { throw "Region table not found: $regionHelper (package is incomplete)" }
. $regionHelper

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run elevated (Administrator)."
    }
}

function ConvertTo-SupervisorAttrScalar {
    <#
      Render one AgentDescription value as the YAML scalar text that survives the supervisor.

      The supervisor does not parse config.yaml once. It re-serializes
      agent.description.non_identifying_attributes into the config text it composes for the
      collector WITHOUT escaping backslashes, and parses that text again - so one level of
      backslash escaping is consumed per pass. Measured against the real binary on a Windows VM,
      for the value C:\ProgramData\pm2:

        "C:\ProgramData\pm2"        DEAD  - "load config: retrieved value (type=string) cannot be
                                    used as a Conf ... found unknown escape character". This is
                                    the reported OTIOMWQA01 failure.
        'C:\ProgramData\pm2'        DEAD  - "could not compose initial merged config ... found
                                    unknown escape character". Quoting style alone is NOT the fix.
        "C:\\ProgramData\\pm2"      DEAD  - valid YAML, still re-emitted unescaped.
        "NT AUTHORITY\\LocalService" STARTS but the value is SILENTLY CORRUPTED: on the second
                                    pass \L is a legal escape (U+2028), giving
                                    NT AUTHORITY<U+2028>ocalService. "Service is Running" is
                                    therefore not a sufficient check.
        'C:/ProgramData/pm2'        STARTS, but the value is lossy - it is no longer the path.
        'C:\\ProgramData\\pm2'      STARTS and the value arrives EXACT. <- canonical form.

      So: double every backslash, then wrap in single quotes (doubling any apostrophe) so a quote
      in a value cannot break the document either.
    #>
    param([string] $Value)
    $v = ([string]$Value).Replace('\', '\\')
    return "'" + ($v -replace "'", "''") + "'"
}

function Expand-CxBackslashEscapes {
    <#
      One lenient backslash-unescaping pass, modelling what the supervisor's SECOND parse does to
      a value. Escapes we honour are collapsed; anything else keeps its backslash, because an
      escape the parser would reject is a backslash the writer meant literally.
    #>
    param([string] $Text)

    $s = [string]$Text
    if (-not $s.Contains('\')) { return $s }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        if ($s[$i] -ne '\' -or $i -eq $s.Length - 1) { [void]$sb.Append($s[$i]); continue }
        switch -CaseSensitive ("$($s[$i + 1])") {
            '\' { [void]$sb.Append('\');      $i++ }
            '"' { [void]$sb.Append('"');      $i++ }
            '/' { [void]$sb.Append('/');      $i++ }
            't' { [void]$sb.Append([char]9);  $i++ }
            'n' { [void]$sb.Append([char]10); $i++ }
            'r' { [void]$sb.Append([char]13); $i++ }
            default { [void]$sb.Append('\') }
        }
    }
    return $sb.ToString()
}

function Get-SupervisorAttrValue {
    <#
      Best-effort recovery of the value the collector would ACTUALLY end up with, given an
      existing scalar's raw text - so a non-canonical line can be rewritten without changing what
      it meant.

      Two passes, because the supervisor parses this field twice:
        1. YAML: a single-quoted scalar is literal apart from '' for an apostrophe; a
           double-quoted scalar gets its escapes decoded.
        2. The supervisor re-emits that text unescaped and parses it again - modelled by
           Expand-CxBackslashEscapes.

      So 'C:\\ProgramData\\pm2' decodes to C:\ProgramData\pm2 (the canonical form round-trips),
      while both 'C:\ProgramData\pm2' and "C:\ProgramData\pm2" also decode to C:\ProgramData\pm2 -
      they carry the same intent but do not survive the second pass.
    #>
    param([string] $Raw)
    return (Expand-CxBackslashEscapes -Text (Get-SupervisorAttrFirstPass -Raw $Raw))
}

function Get-SupervisorAttrFirstPass {
    <# The value after YAML parses this scalar once - i.e. the text the supervisor then re-emits. #>
    param([string] $Raw)

    $t = ([string]$Raw).Trim()
    if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) {
        return $t.Substring(1, $t.Length - 2).Replace("''", "'")
    }
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        return (Expand-CxBackslashEscapes -Text $t.Substring(1, $t.Length - 2))
    }
    return $t   # a plain scalar carries no escapes at all
}

function Test-SupervisorAttrScalarNeedsFix {
    <#
      Must this existing scalar be rewritten? Yes only when a backslash SURVIVES the first parse
      and the scalar is not already canonical - because that is precisely the case the supervisor's
      second parse either rejects (dead service) or silently rewrites (corrupted value).

      A value like "col1\tcol2" is deliberately left alone: its backslash is consumed by the first
      parse, so the second parse sees a tab and cannot damage it. Rewriting it would be churn on a
      line we did not author.
    #>
    param([string] $Raw)

    if (-not ([string]$Raw).Contains('\')) { return $false }
    if (-not (Get-SupervisorAttrFirstPass -Raw $Raw).Contains('\')) { return $false }
    return (-not (Test-SupervisorAttrScalarCanonical -Raw $Raw))
}

function Test-SupervisorAttrScalarCanonical {
    <# Is this raw scalar text already exactly what ConvertTo-SupervisorAttrScalar would write? #>
    param([string] $Raw)
    $decoded = Get-SupervisorAttrValue -Raw $Raw
    return (([string]$Raw).Trim() -ceq (ConvertTo-SupervisorAttrScalar $decoded))
}

function Set-SupervisorDescriptionAttributes {
    <#
      Inject the detected selector attributes (cx.host.role, workload.*) into the OpAMP
      Supervisor's config.yaml `agent.description.non_identifying_attributes`, so they show
      up in the Coralogix Fleet Management AgentDescription. The vendor installer writes
      only static service.name/cx.agent.type there. Best-effort: never fails the install.
    #>
    param([string] $ConfigPath, [string] $Attributes)

    if ([string]::IsNullOrWhiteSpace($Attributes)) {
        Write-Warning "[supervisor] no OTEL_RESOURCE_ATTRIBUTES to publish to AgentDescription; skipping"
        return
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "[supervisor] supervisor config not found at $ConfigPath; cannot publish selector attributes"
        return
    }

    # Parse "k1=v1,k2=v2" -> ordered pairs (split each token on the FIRST '=' only).
    $pairs = [ordered]@{}
    foreach ($tok in ($Attributes -split ',')) {
        $t = $tok.Trim(); if (-not $t) { continue }
        $eq = $t.IndexOf('='); if ($eq -lt 1) { continue }
        $pairs[$t.Substring(0, $eq).Trim()] = $t.Substring($eq + 1).Trim()
    }
    if ($pairs.Count -eq 0) { Write-Warning "[supervisor] no valid key=value pairs parsed; skipping"; return }

    $lines  = Get-Content -Path $ConfigPath
    $anchor = -1; $indent = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)non_identifying_attributes:\s*$') { $anchor = $i; $indent = $Matches[1]; break }
    }
    if ($anchor -lt 0) {
        Write-Warning "[supervisor] 'non_identifying_attributes:' not found in $ConfigPath (vendor template changed?); skipping selector publish"
        return
    }
    $itemIndent = $indent + '  '

    # Keys already present in the block (child lines indented under the anchor).
    #
    # The same pass CANONICALIZES any value CONTAINING A BACKSLASH that is not already in the form
    # ConvertTo-SupervisorAttrScalar would write. Neither half is cosmetic:
    #
    #   * un-doubled backslashes kill the service on the supervisor's second parse, and a key that
    #     is already present is otherwise skipped below - so without this pass a re-deploy is a
    #     no-op on an already-broken host, which is exactly what happened on OTIOMWQA01.
    #   * a value whose second-pass escape happens to be LEGAL (\L, \b, \t, \n) starts fine and
    #     silently rewrites itself, so "the service is Running" cannot be the test. Only "the
    #     scalar is already exactly canonical" can be.
    #
    # Only backslash-bearing values are touched. A value without one cannot be hurt by the second
    # parse, so the vendor's own double-quoted service.name / cx.agent.type lines are left exactly
    # as the installer wrote them rather than churned into our quoting style.
    $existing = @{}; $fixed = @()
    for ($j = $anchor + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*#') { continue }
        if ($lines[$j] -notmatch ("^" + [regex]::Escape($itemIndent) + "\S")) { break }
        if ($lines[$j] -match '^(\s*)([^:\s]+)\s*:\s*(\S.*?)\s*$') {
            $indent0 = $Matches[1]; $key0 = $Matches[2]; $raw = $Matches[3]
            if (Test-SupervisorAttrScalarNeedsFix -Raw $raw) {
                $intended  = Get-SupervisorAttrValue -Raw $raw
                $lines[$j] = "{0}{1}: {2}" -f $indent0, $key0, (ConvertTo-SupervisorAttrScalar $intended)
                $fixed += $key0
            }
        }
        if ($lines[$j] -match '^\s*([^:\s]+)\s*:') { $existing[$Matches[1]] = $true }
    }
    if ($fixed.Count -gt 0) {
        Write-Warning "[supervisor] canonicalized AgentDescription values whose backslashes would not survive the supervisor's second parse: $($fixed -join ', ')"
    }

    $insert = @(); $added = @(); $doubled = @()
    foreach ($k in $pairs.Keys) {
        if ($existing.ContainsKey($k)) { continue }
        $v = [string]$pairs[$k]
        if ($v.Contains('\')) { $doubled += $k }
        $insert += ("{0}{1}: {2}" -f $itemIndent, $k, (ConvertTo-SupervisorAttrScalar $v)); $added += $k
    }
    if ($doubled.Count -gt 0) {
        Write-Host "[supervisor] backslashes doubled in AgentDescription values (the supervisor parses this field twice): $($doubled -join ', ')"
    }
    if ($insert.Count -eq 0 -and $fixed.Count -eq 0) {
        Write-Host "[supervisor] AgentDescription already carries the selector attributes"; return
    }

    $new = @($lines[0..$anchor]) + $insert
    if (($anchor + 1) -le ($lines.Count - 1)) { $new += $lines[($anchor + 1)..($lines.Count - 1)] }
    Set-Content -Path $ConfigPath -Value $new -Encoding utf8
    Write-Host "[supervisor] published selector attributes to AgentDescription ($($insert.Count) added, $($fixed.Count) canonicalized): $($added -join ', ')"
}

function Set-SupervisorAgentSettings {
    <#
      Set the supervisor-side settings that live as DIRECT children of the config's `agent:`
      mapping - config_apply_timeout and passthrough_logs.

      WHY. agent.config_apply_timeout defaults to 5s: after the supervisor applies a new remote
      config it waits that long for the collector to report healthy, and on timeout it reports
      RemoteConfigStatus = FAILED upstream. This base config is large enough (four pipelines,
      dynamic IIS parsing) that the collector routinely needs longer than 5s on Windows - which is
      why the installer sleeps 6 seconds before its own health probe. The result was a FALSE RED:
      Coralogix Fleet Management showed the remote config as failed to apply while it had applied
      and telemetry was flowing. agent.passthrough_logs routes the collector's own stdout/stderr
      through the supervisor, so when an apply really does fail there is something on the host that
      says why instead of nothing at all.

      THESE VALUES DELIBERATELY DO NOT GO THROUGH ConvertTo-SupervisorAttrScalar. That encoder
      exists because the supervisor re-serializes agent.description.non_identifying_attributes into
      the config text it composes for the collector and parses it AGAIN, so one level of backslash
      escaping is consumed per pass (see its docblock for the measured matrix). These two keys are
      supervisor-side settings that are never re-emitted, and neither value contains a backslash.
      Quoting them would be a bug in the other direction: go-yaml has to read `30s` as a duration
      and `true` as a bool, not as strings.

      Matching is scoped to keys at EXACTLY the direct-child indent of `agent:`. That is what keeps
      `description:` and everything nested under it out of scope - including a key that happens to
      share a name with one of ours.

      Best-effort, the same contract as the description writer: a vendor template we do not
      recognise is a warning and no write, never a failed install.
    #>
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        $Settings
    )

    if (-not $Settings -or $Settings.Count -eq 0) { return }
    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "[supervisor] supervisor config not found at $ConfigPath; cannot set agent settings"
        return
    }

    # @() matters: Get-Content on a one-line file returns a STRING, and the splice below would
    # then index characters instead of lines.
    $lines  = @(Get-Content -Path $ConfigPath)
    $anchor = -1; $agentIndent = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)agent:\s*$') { $anchor = $i; $agentIndent = $Matches[1]; break }
    }
    if ($anchor -lt 0) {
        # Also the `agent: {}` case: an inline flow mapping does not match, and rewriting one
        # blind would be a guess at the vendor's intent.
        Write-Warning "[supervisor] no 'agent:' block found in $ConfigPath (vendor template changed?); skipping agent settings"
        return
    }

    # Find where the block ends and what indent its direct children use. The indent is READ from
    # the file rather than assumed to be two spaces - this is the vendor's file, not ours.
    $childIndent = $null
    $end = $lines.Count
    for ($j = $anchor + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*$')  { continue }
        if ($lines[$j] -match '^\s*#')  { continue }
        # A positive match, deliberately: -notmatch DOES populate $Matches when the pattern
        # matches, but depending on that reads like a bug even when it is not.
        if ($lines[$j] -match '^(\s+)\S') {
            $ind = $Matches[1]
            if ($ind.Length -le $agentIndent.Length) { $end = $j; break }
            if (-not $childIndent) { $childIndent = $ind }
        } else {
            $end = $j; break            # a line at column 0 ends the block
        }
    }
    if (-not $childIndent) { $childIndent = $agentIndent + '  ' }

    $insert = @(); $added = @(); $updated = @()
    foreach ($k in @($Settings.Keys)) {
        $want  = [string]$Settings[$k]
        # Anchored at the exact child indent, so a key nested deeper (under description:) or a
        # longer key that merely starts with the same text cannot match.
        $keyRe = '^' + [regex]::Escape($childIndent) + [regex]::Escape($k) + '\s*:\s*(.*?)\s*$'
        $hit = -1; $have = $null
        for ($j = $anchor + 1; $j -lt $end; $j++) {
            if ($lines[$j] -match $keyRe) { $hit = $j; $have = $Matches[1]; break }
        }
        if ($hit -ge 0) {
            if (([string]$have) -ceq $want) { continue }
            $lines[$hit] = "{0}{1}: {2}" -f $childIndent, $k, $want
            $updated += $k
            continue
        }
        $insert += ("{0}{1}: {2}" -f $childIndent, $k, $want)
        $added  += $k
    }

    if ($insert.Count -eq 0 -and $updated.Count -eq 0) {
        Write-Host "[supervisor] agent settings already correct: $(@($Settings.Keys) -join ', ')"
        return
    }

    $new = @($lines[0..$anchor]) + $insert
    if (($anchor + 1) -le ($lines.Count - 1)) { $new += $lines[($anchor + 1)..($lines.Count - 1)] }
    Set-Content -Path $ConfigPath -Value $new -Encoding utf8

    $what = @()
    if ($added.Count)   { $what += ("added "   + ($added   -join ', ')) }
    if ($updated.Count) { $what += ("updated " + ($updated -join ', ')) }
    Write-Host "[supervisor] agent settings written to $($ConfigPath | Split-Path -Leaf): $($what -join '; ')"
}

function Publish-SupervisorAgentDescription {
    <#
      Apply BOTH of our edits to the supervisor's config.yaml - the selector attributes and the
      agent settings - and leave the service RUNNING, or leave the config as it was.

      The two writers share one window on purpose. A single verified restart proves that go-yaml
      accepted both edits, and the single .pre-agentdesc copy rolls both back together. Restarting
      twice would double the time the agent is off the air for no extra information.

      This is a function rather than inline install steps for one reason: it is the only
      place in the deploy that can take a working agent off the air, and the rollback branch
      is the part most likely to rot. Inline, it could only be exercised by a full vendor
      reinstall on a real host, which no harness does; as a function,
      test\Test-SupervisorConfigWriter.ps1 drives it offline, and a VM loop can drive it
      against the real supervisor binary - the only thing that can prove go-yaml accepts
      what we write.

      Returns a result object ($_.Applied / $_.RolledBack / $_.Reason) so a caller - or the
      VM loop - can assert on the outcome instead of parsing host output.

      -Attributes may legitimately be empty (no OTEL_RESOURCE_ATTRIBUTES on this host): the
      description writer warns and returns without writing, and the agent settings are still
      applied and still restarted. They are independent edits that happen to share a window.
    #>
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        [string] $Attributes,
        $AgentSettings
    )

    $result = [pscustomobject]@{ Applied = $false; RolledBack = $false; Reason = $null; ServiceRunning = $false }

    # A rollback copy taken immediately before OUR edit, independent of the -Session
    # (uninstall-time) backup: the edit is the last thing between a working supervisor and a
    # dead one, so the undo has to exist even on a plain install with no session.
    $preEditCopy = "$ConfigPath.pre-agentdesc"
    if (Test-Path $ConfigPath) { Copy-Item $ConfigPath $preEditCopy -Force -ErrorAction SilentlyContinue }

    Set-SupervisorDescriptionAttributes -ConfigPath $ConfigPath -Attributes $Attributes
    Set-SupervisorAgentSettings -ConfigPath $ConfigPath -Settings $AgentSettings

    try {
        if (-not (Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue)) {
            $result.Reason = 'no opampsupervisor service on this host'
            return $result
        }

        # The vendor installer registers the service with StartType=Manual. After a reboot the
        # supervisor stays Stopped -> the agent silently drops off Fleet Management and no
        # telemetry ships until someone starts it by hand. Automatic + delayed start + failure
        # actions together are what actually make it come back (see Set-SupervisorServiceResilience:
        # Automatic alone was measured to be insufficient).
        Set-Service -Name 'opampsupervisor' -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Host "[supervisor] set opampsupervisor StartType=Automatic"
        Set-SupervisorServiceResilience

        # The restart is VERIFIED, not fire-and-forget. It used to run with -ErrorAction
        # SilentlyContinue followed by an unconditional "restarted" message, so an edit that
        # made config.yaml unparseable left the service dead while the install still reported
        # success - the failure only surfaced the next time an operator ran Restart-Service by
        # hand. A config we just wrote that the supervisor will not load is our bug, so roll it
        # back rather than leave the host with no agent.
        if (Restart-SupervisorVerified) {
            Write-Host "[supervisor] restarted opampsupervisor and confirmed Running (AgentDescription attributes and agent settings applied)"
            Remove-Item $preEditCopy -Force -ErrorAction SilentlyContinue
            $result.Applied = $true; $result.ServiceRunning = $true
            return $result
        }

        $result.Reason = Get-SupervisorStartError
        Write-Warning "[supervisor] opampsupervisor did not start after the config.yaml edit$(if ($result.Reason) { ": $($result.Reason)" })"
        if (Test-Path $preEditCopy) {
            Copy-Item $preEditCopy $ConfigPath -Force
            $result.RolledBack = $true
            if (Restart-SupervisorVerified) {
                $result.ServiceRunning = $true
                Write-Warning "[supervisor] rolled back $ConfigPath to the pre-edit copy; service is running WITHOUT the selector attributes (no Fleet Management grouping by cx.host.role/workload.*) and WITHOUT the agent settings (Fleet Management will keep reporting this host's config as failed to apply)"
            } else {
                Write-Warning "[supervisor] rollback did not start the service either - the failure predates our edit. Inspect: Get-EventLog -LogName Application -Source opampsupervisor -Newest 20"
            }
        }
        return $result
    } catch {
        Write-Warning "[supervisor] could not configure/restart opampsupervisor: $_"
        $result.Reason = "$_"
        return $result
    }
}

function Set-SupervisorServiceResilience {
    <#
      Make the supervisor service survive a reboot on its own.

      StartType=Automatic is not enough, and that was measured rather than assumed: on a rebooted
      Server 2025 test host the service started at boot and exited 27 seconds later, and because
      the vendor installer configures no recovery actions (sc qfailure shows RESET_PERIOD 0 and no
      COMMAND_LINE), nothing retried. The host sat with no agent, reporting nothing, until someone
      ran Start-Service by hand - the exact silent-gap this deploy is supposed to close. Starting it
      manually a minute later worked, so the boot-time exit is a race with something that is not
      ready yet, not a bad config.

      Two standard service settings fix it:
        * delayed auto-start - start after the boot-critical services, once networking has settled
        * failure actions - let the SCM restart the process if it exits unexpectedly, with backoff

      Both are idempotent, and both are applied through sc.exe because Set-Service in PowerShell 5.1
      can express neither. Never fatal: a host with a running agent and no recovery actions is worse
      off than one with them, but still better off than a failed install.
    #>
    try {
        # `start= delayed-auto` - the space after each '=' is required by sc.exe.
        $null = & sc.exe config opampsupervisor start= delayed-auto
        if ($LASTEXITCODE -eq 0) { Write-Host "[supervisor] start type = delayed auto-start (starts after networking settles)" }
        else { Write-Warning "[supervisor] could not set delayed auto-start (sc.exe exit $LASTEXITCODE)" }

        # Restart after 30s, then 60s, then every 2 min; forget the failure count after a day.
        $null = & sc.exe failure opampsupervisor reset= 86400 actions= restart/30000/restart/60000/restart/120000
        if ($LASTEXITCODE -eq 0) { Write-Host "[supervisor] failure actions = restart after 30s / 60s / 120s (a boot-time exit no longer leaves the host unmonitored)" }
        else { Write-Warning "[supervisor] could not set failure actions (sc.exe exit $LASTEXITCODE)" }

        # By default the SCM runs those actions only when a service dies with a failure code. The
        # supervisor exits cleanly when it gives up, which counts as a NON-crash failure and would
        # skip recovery entirely - so the flag has to be set as well, or the actions above are
        # decoration on exactly the case that matters.
        $null = & sc.exe failureflag opampsupervisor 1
        if ($LASTEXITCODE -eq 0) { Write-Host "[supervisor] recovery also applies to a clean exit (failureflag=1)" }
        else { Write-Warning "[supervisor] could not set failureflag (sc.exe exit $LASTEXITCODE)" }
    } catch {
        Write-Warning "[supervisor] could not configure service resilience: $_"
    }
}

function Restart-SupervisorVerified {
    <#
      Restart opampsupervisor and answer whether it is actually RUNNING afterwards.
      Restart-Service reports success as soon as the SCM accepts the start, and a config the
      supervisor cannot load makes the process exit right after that - so the status is re-read
      and confirmed to still be Running a moment later.

      Two details are deliberate:

      * stop-then-start instead of Restart-Service. Observed on a Server 2025 test host: a start
        that races the previous process's shutdown intermittently fails with "could not compose
        initial merged config", on a config that loads fine when the binary is run by hand a
        moment later. Waiting for Stopped before starting removes that race.
      * one retry before reporting failure. The caller's response to a failure is to ROLL BACK,
        so a transient start failure would throw away a perfectly good config (and with it this
        host's Fleet Management grouping). Only a second consecutive failure is treated as a
        verdict about the config.
    #>
    param([int] $TimeoutSeconds = 25, [int] $Attempts = 2)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Stop-Service -Name 'opampsupervisor' -Force -ErrorAction SilentlyContinue
            $stopBy = (Get-Date).AddSeconds(15)
            do {
                $s = Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue
                if (-not $s -or $s.Status -eq 'Stopped') { break }
                Start-Sleep -Milliseconds 500
            } while ((Get-Date) -lt $stopBy)

            Start-Sleep -Seconds 2   # let the old process finish writing its state directory
            Start-Service -Name 'opampsupervisor' -ErrorAction Stop
        } catch {
            if ($attempt -lt $Attempts) { Write-Host "[supervisor] start attempt $attempt failed ($($_.Exception.Message.Trim())); retrying once"; Start-Sleep -Seconds 5; continue }
            return $false
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $running  = $false
        do {
            $svc = Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Start-Sleep -Seconds 3; $svc.Refresh()
                if ($svc.Status -eq 'Running') { $running = $true; break }
            }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)

        if ($running) { return $true }
        if ($attempt -lt $Attempts) { Write-Host "[supervisor] service did not stay Running on attempt $attempt; retrying once"; Start-Sleep -Seconds 5 }
    }
    return $false
}

function Get-SupervisorStartError {
    <#
      The one line from the supervisor's own event-log entries that says WHY it refused to
      start. Without this the operator sees only StartServiceFailed from the SCM and has to
      go digging - the actual cause (e.g. 'yaml: line 33: found unknown escape character')
      is only ever written here.
    #>
    try {
        $e = Get-EventLog -LogName Application -Source 'opampsupervisor' -EntryType Error -Newest 10 -ErrorAction Stop |
                Where-Object { $_.Message -match 'failed to start service' } |
                Select-Object -First 1
        if (-not $e) { return $null }
        $m = [regex]::Match($e.Message, 'failed to start service:[^''"]*')
        if ($m.Success) { return $m.Value.Trim() }
        return ($e.Message -split "`n" | Select-Object -First 1).Trim()
    } catch { return $null }
}

Assert-Admin

# ---- Resolve the region / domain ----------------------------------------------
# CORALOGIX_DOMAIN appears twice below because the same variable means two different
# things: a value an operator exported for THIS run is a decision, while the identical
# variable inherited from what a PREVIOUS install of ours persisted machine-wide is
# only a leftover. They are told apart by comparing the process value with the machine
# value - without that, "rebuild the package with -Region eu2 and re-deploy" would be a
# silent no-op on every host that had already been installed against eu1.
#
# Precedence, most explicit first:
#   1. -Domain              a private or non-standard ingress domain, verbatim.
#   2. -Region              region code -> <region>.coralogix.com.
#   3. CX_DOMAIN env        the domain-shaped equivalent of -Domain, e.g. BatchPatch's
#                           `set CX_DOMAIN=my-ingress.example.com && deploy.bat`. Unlike
#                           CORALOGIX_DOMAIN this variable is never persisted by us, so
#                           its presence is always a decision made for this run - which
#                           is why deploy.bat CAN forward it as a flag. It outranks
#                           CX_REGION for the same reason -Domain outranks -Region.
#   4. CX_REGION env        the region-shaped equivalent, e.g. BatchPatch's
#                           `set CX_REGION=eu2 && deploy.bat`.
#   5. CORALOGIX_DOMAIN env when it DIFFERS from the machine value, i.e. exported for
#                           this run: a private ingress chosen at deploy time.
#   6. region.txt           next to this script - Build-DeploymentPackage.ps1 -Region
#                           bakes it in so the remote command stays a bare 'deploy.bat'.
#   7. CORALOGIX_DOMAIN env matching the machine value: no new decision anywhere, so a
#                           re-run keeps the region this host was installed with instead
#                           of dropping back to the eu1 default.
#   8. eu1.coralogix.com    historical default.
$machineDomain = [Environment]::GetEnvironmentVariable('CORALOGIX_DOMAIN', 'Machine')
$envDomain     = Normalize-CxDomainString $env:CORALOGIX_DOMAIN
$envDomainIsNew = $envDomain -and ($envDomain -ne (Normalize-CxDomainString $machineDomain))

$regionSource = $null
if ($Domain) {
    if ($Region) { Write-Warning "[collector] both -Domain and -Region given; -Domain '$Domain' wins" }
    $Domain = Assert-CxDomainNotEmpty (Normalize-CxDomainString $Domain) '-Domain'
    $regionSource = '-Domain'
} elseif ($Region) {
    $Domain = Resolve-CxDomain -Region $Region
    $regionSource = "-Region $Region"
} elseif ($env:CX_DOMAIN) {
    # Deliberately NOT run through Resolve-CxDomain: that validates against the published
    # region table and throws, which is the opposite of what this variable is for.
    if ($env:CX_REGION) { Write-Warning "[collector] both CX_DOMAIN and CX_REGION set; CX_DOMAIN '$env:CX_DOMAIN' wins" }
    $Domain = Assert-CxDomainNotEmpty (Normalize-CxDomainString $env:CX_DOMAIN) 'CX_DOMAIN'
    $regionSource = 'CX_DOMAIN env'
} elseif ($env:CX_REGION) {
    $Domain = Resolve-CxDomain -Region $env:CX_REGION
    $regionSource = "CX_REGION env ($env:CX_REGION)"
} elseif ($envDomainIsNew) {
    $Domain = $envDomain
    $regionSource = 'CORALOGIX_DOMAIN env (set for this run)'
} else {
    $regionFile = Join-Path $here 'region.txt'
    if (Test-Path $regionFile) {
        $fileRegion = (Get-Content -Path $regionFile -Raw).Trim()
        # An empty region.txt means "no region chosen", not "region ''" - fall through.
        if ($fileRegion) {
            $Domain = Resolve-CxDomain -Region $fileRegion
            $regionSource = "region.txt ($fileRegion)"
        }
    }
    if (-not $Domain -and $envDomain) {
        $Domain = $envDomain
        $regionSource = 'CORALOGIX_DOMAIN env (already installed with it)'
    }
    if (-not $Domain) {
        $Domain = 'eu1.coralogix.com'
        $regionSource = 'default'
    }
}
$resolvedRegion = Get-CxRegionForDomain -Domain $Domain
Write-Host ("[collector] region {0} -> domain {1} (from {2})" -f
    $(if ($resolvedRegion) { $resolvedRegion } else { 'custom' }), $Domain, $regionSource)
if (-not $resolvedRegion) {
    # Legitimate for a private ingress; also what a typo'd -Domain looks like. Say so
    # once, loudly, because the collector will report healthy either way.
    Write-Warning "[collector] '$Domain' is not a published Coralogix region domain. Data goes to ingress.$Domain - verify that is intended (regions: $(Format-CxRegionList))."
}

# Default the selector attributes to what Detect-Workloads.ps1 persisted machine-wide.
if (-not $ResourceAttributes) {
    $ResourceAttributes = [Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES', 'Machine')
}

# TLS 1.2 for GitHub downloads on older Windows Server SKUs
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- Resolve the private key --------------------------------------------------
if (-not $PrivateKey) {
    $candidates = @($KeyFile, (Join-Path $here '..\SimpleWebApp\coralogix\SendDataKey.txt'))
    $found = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $found) { throw "No private key: pass -PrivateKey or provide $KeyFile" }
    $PrivateKey = (Get-Content -Path $found -Raw).Trim()
    Write-Host "[supervisor] loaded key from $found"
}
if ([string]::IsNullOrWhiteSpace($PrivateKey) -or $PrivateKey -like '*<*your*key*>*') {
    throw "Private key is empty or a placeholder. Set a real Send-Your-Data key."
}

# ---- Produce the recommended config -------------------------------------------
# ONE config for both modes, written into this script's own folder under a
# mode-neutral name. Supervisor mode passes it as -SupervisorCollectorBaseConfig;
# -NoSupervisor passes the same file as -Config. The source template keeps its
# historical 'config.supervisor.yaml' name (it is referenced by
# Build-DeploymentPackage.ps1 and the docs) - only the produced artifact is renamed.
if (-not (Test-Path $BaseConfig)) { throw "Base config not found: $BaseConfig" }
if (-not (Test-Path $StageDir)) { New-Item -ItemType Directory -Path $StageDir -Force | Out-Null }
$stagedConfig = Join-Path $StageDir 'config.recommended.yaml'
# Producing next to the template means source and destination can be the same file
# when -BaseConfig is already the produced one (a re-run). Copy-Item would throw.
if ((Resolve-Path -LiteralPath $BaseConfig).Path -ne
    (Join-Path (Resolve-Path -LiteralPath $StageDir).Path 'config.recommended.yaml')) {
    Copy-Item -Path $BaseConfig -Destination $stagedConfig -Force
}
Write-Host "[collector] recommended config -> $stagedConfig"

# Guard: the config must NOT contain an opamp extension. Mandatory in supervisor
# mode (the Supervisor owns the OpAMP connection); in -NoSupervisor mode an opamp
# extension would let a remote config silently replace what is on disk, which is
# exactly the determinism that mode exists to provide.
$cfgText = Get-Content -Path $stagedConfig -Raw
if ($cfgText -match '(?m)^\s{2}opamp\s*:') {
    throw "Recommended config contains an 'opamp' extension. Remove it - it is invalid in supervisor mode and defeats -NoSupervisor."
}

# ---- Persist domain + key as machine env vars ---------------------------------
# Record prior values BEFORE overwriting so uninstall deletes what we created and
# restores what was already set.
if ($Session) {
    Record-EnvChange -Session $Session -Name 'CORALOGIX_DOMAIN'      -PriorValue ([Environment]::GetEnvironmentVariable('CORALOGIX_DOMAIN', 'Machine'))
    Record-EnvChange -Session $Session -Name 'CORALOGIX_PRIVATE_KEY' -PriorValue ([Environment]::GetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', 'Machine'))
}
[Environment]::SetEnvironmentVariable('CORALOGIX_DOMAIN', $Domain, 'Machine')
[Environment]::SetEnvironmentVariable('CORALOGIX_PRIVATE_KEY', $PrivateKey, 'Machine')
$env:CORALOGIX_DOMAIN      = $Domain
$env:CORALOGIX_PRIVATE_KEY = $PrivateKey
Write-Host ("[supervisor] CORALOGIX_DOMAIN={0} (machine env set; region {1})" -f
    $Domain, $(if ($resolvedRegion) { $resolvedRegion } else { 'custom' }))

# ---- Persist deployment environment (read by transform/environment processor) -
if ($Environment) {
    if ($Session) {
        Record-EnvChange -Session $Session -Name 'CX_ENVIRONMENT' -PriorValue ([Environment]::GetEnvironmentVariable('CX_ENVIRONMENT', 'Machine'))
    }
    [Environment]::SetEnvironmentVariable('CX_ENVIRONMENT', $Environment, 'Machine')
    $env:CX_ENVIRONMENT = $Environment
    Write-Host "[supervisor] CX_ENVIRONMENT=$Environment (machine env set)"
}

# ---- Persist Coralogix application name (read by transform/appname processor) --
# Unset on purpose = the exporter's application_name_attributes fall through to
# host.name, so the host reports under its own name instead of a shared bucket.
if ($Application) {
    if ($Session) {
        Record-EnvChange -Session $Session -Name 'CX_APPLICATION' -PriorValue ([Environment]::GetEnvironmentVariable('CX_APPLICATION', 'Machine'))
    }
    [Environment]::SetEnvironmentVariable('CX_APPLICATION', $Application, 'Machine')
    $env:CX_APPLICATION = $Application
    Write-Host "[supervisor] CX_APPLICATION=$Application (machine env set)"
} else {
    Write-Host "[supervisor] CX_APPLICATION not set - Coralogix application falls back to host.name ($env:COMPUTERNAME)"
}

# ---- Persist the owning team (CX_TEAM + TEAM) ---------------------------------
# Two names, one value. CX_TEAM is ours; TEAM is the bare name software already on
# these hosts reads, and writing it is the whole point of the pair - so it is set even
# though nothing in this repo consumes it.
# Both prior values are recorded BEFORE the write. That matters more here than for the
# CX_* variables: TEAM is a generic name, so on some hosts it already exists and belongs
# to something else, and uninstall has to put that value back rather than delete it.
# Overwriting it is still what the operator asked for by passing a team - the point is
# that it is reversible, and the prior value is printed so the change is visible in the
# transcript rather than discovered later.
if ($Team) {
    foreach ($teamVar in @('CX_TEAM','TEAM')) {
        $priorTeam = [Environment]::GetEnvironmentVariable($teamVar, 'Machine')
        if ($Session) {
            Record-EnvChange -Session $Session -Name $teamVar -PriorValue $priorTeam
        }
        [Environment]::SetEnvironmentVariable($teamVar, $Team, 'Machine')
        if ($priorTeam -and $priorTeam -ne $Team) {
            Write-Host "[supervisor] $teamVar=$Team (machine env set; replaced prior value '$priorTeam', restored on uninstall)"
        } else {
            Write-Host "[supervisor] $teamVar=$Team (machine env set)"
        }
    }
    $env:CX_TEAM = $Team
    $env:TEAM    = $Team
}

# ---- Download vendor installer ------------------------------------------------
$u = 'https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.ps1'
$f = Join-Path $env:TEMP 'coralogix-otel-collector.ps1'
Write-Host "[supervisor] downloading vendor installer..."
Invoke-WebRequest -Uri $u -OutFile $f -UseBasicParsing

# ---- Install ------------------------------------------------------------------
# THE mode switch. Everything before and after this block is identical in both
# modes. -EnableDynamicIISParsing is valid in both (the config uses file_storage);
# -Config and -Supervisor are mutually exclusive per the vendor installer's own
# help ("-Config: not available with Supervisor mode").
if ($NoSupervisor) {
    $installArgs = @{
        Config                  = $stagedConfig
        EnableDynamicIISParsing = $true
    }
    $shown = "-Config '$stagedConfig' -EnableDynamicIISParsing"
} else {
    $installArgs = @{
        Supervisor                    = $true
        SupervisorCollectorBaseConfig = $stagedConfig
        EnableDynamicIISParsing       = $true
    }
    $shown = "-Supervisor -SupervisorCollectorBaseConfig '$stagedConfig' -EnableDynamicIISParsing"
}
if ($Version) { $installArgs['Version'] = $Version }

Write-Host "[collector] running installer: $shown"
& $f @installArgs
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Vendor installer exited with code $LASTEXITCODE"
}

if ($NoSupervisor) {
    # No AgentDescription to publish - there is no OpAMP connection and no Fleet
    # Management registration in this mode. The selector attributes still reach the
    # telemetry DATA through the machine OTEL_RESOURCE_ATTRIBUTES that
    # Detect-Workloads.ps1 set and the config's resourcedetection/env reads; what is
    # unavailable is targeting this agent by them in Fleet Management.
    if ($ResourceAttributes) {
        Write-Host "[collector] -NoSupervisor: selector attributes stay on the telemetry only (no Fleet Management registration)"
    }
    try {
        if (Get-Service -Name 'otelcol-contrib' -ErrorAction SilentlyContinue) {
            # Same reboot-survival reason as the supervisor branch below.
            Set-Service -Name 'otelcol-contrib' -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Host "[collector] set otelcol-contrib StartType=Automatic (survives reboot)"
        }
    } catch { Write-Warning "[collector] could not configure otelcol-contrib: $_" }
} else {
    # ---- Patch the supervisor's own config.yaml ------------------------------------
    # Two independent edits, one restart:
    #
    #   * The vendor installer writes only static service.name/cx.agent.type into the
    #     supervisor config's agent.description. Inject the detected cx.host.role/workload.*
    #     so Coralogix Fleet Management can group / assign config by them.
    #   * agent.config_apply_timeout / agent.passthrough_logs. The supervisor's 5s default is
    #     shorter than this config's startup, so every apply was reported upstream as FAILED
    #     while it had in fact succeeded; passthrough_logs is what makes a genuine failure
    #     diagnosable on the host instead of invisible.
    #
    # passthrough_logs is not configurable: there is no host on which swallowing the
    # collector's own logs is the better outcome.
    $supervisorConfig = Join-Path ${env:ProgramFiles} 'OpenTelemetry OpAMP Supervisor\config.yaml'
    if ($Session) { Backup-DeployFile -Session $Session -Path $supervisorConfig | Out-Null }
    $agentSettings = [ordered]@{
        'passthrough_logs'     = 'true'
        'config_apply_timeout' = $ConfigApplyTimeout
    }
    Publish-SupervisorAgentDescription -ConfigPath $supervisorConfig `
        -Attributes $ResourceAttributes -AgentSettings $agentSettings | Out-Null
}

# ---- Verify -------------------------------------------------------------------
Start-Sleep -Seconds 6
Write-Host ""
Write-Host "[collector] services:"
Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'otel|coralogix|opamp|supervisor' } |
    Format-Table Name, Status, StartType, DisplayName -AutoSize | Out-String | Write-Host

$health = $false
try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 10
    if ($r.StatusCode -eq 200) { $health = $true }
} catch {}
Write-Host "[collector] health check 127.0.0.1:13133 -> $(if ($health) {'OK (200)'} else {'not responding yet'})"

if (-not $health) {
    Write-Warning "Collector health endpoint not responding. Check the Application event log (source otelcol-contrib) and confirm CORALOGIX_PRIVATE_KEY is set on the service."
}

if ($NoSupervisor) {
    Write-Host "[collector] done (no supervisor). The config on disk is authoritative; there is no Fleet Management registration."
} else {
    Write-Host "[supervisor] done. Assign a remote config to this host in Coralogix Fleet Management."
}
