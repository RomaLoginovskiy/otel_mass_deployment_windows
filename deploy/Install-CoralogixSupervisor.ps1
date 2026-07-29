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
  machine env var CX_ENVIRONMENT, which the base config's resource/environment
  processor stamps onto all signals (tags.cx_environment, tags.cx_env,
  deployment.environment.name) so Coralogix can split telemetry by environment.

.PARAMETER Application
  Optional Coralogix APPLICATION name for this host. Persisted as the machine env var
  CX_APPLICATION, which the base config's transform/appname processor stamps as
  service.namespace (the exporter maps it to the application name).
  OMIT IT to get the default: the application name falls back to the host's own name
  (host.name). Use it only when several hosts must report under one shared application.

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
    # config's resource/environment processor).
    [string] $Environment = $null,
    # Coralogix application name -> machine env var CX_APPLICATION (read by the base
    # config's transform/appname processor). Unset = fall back to host.name.
    [string] $Application = $null,
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
      A value as the ONE scalar form the OpAMP Supervisor round-trips correctly:
      single-quoted, with every backslash in the value DOUBLED.

      The doubling looks wrong and is not. The supervisor does not merely parse its config.yaml
      once: it re-serializes AgentDescription values into the merged config text WITHOUT
      escaping backslashes, then parses that text again. One level of backslash escaping is
      consumed per pass, so what the first parse yields has to still be valid YAML on the
      second. Measured on a real supervisor (Windows VM, poc\Run-SupervisorVmLoop.ps1), for
      workload.pm2.home = C:\ProgramData\pm2:

        file: "C:\\ProgramData\\pm2"    1st parse -> C:\ProgramData\pm2
                                        2nd parse -> \p is not an escape
                                        => SERVICE DEAD: 'could not compose initial merged
                                           config: yaml: line 49: found unknown escape character'

        file: "NT AUTHORITY\\LocalService"  2nd parse -> \L IS an escape (U+2028 LINE SEP)
                                        => service starts, value SILENTLY CORRUPTED to
                                           'NT AUTHORITY<U+2028>       ocalService'

        file: 'C:\\ProgramData\\pm2'    1st parse -> C:\\ProgramData\\pm2
                                        2nd parse -> C:\ProgramData\pm2
                                        => service starts AND the value is exact. <-- this form

      Single quotes are preferred over the equivalent "C:\\\\ProgramData\\\\pm2" purely for
      legibility: inside single quotes the only other escape is '' for an apostrophe.
    #>
    param([string] $Value)

    $doubled = ([string]$Value) -replace '\\', '\\'
    return "'" + ($doubled -replace "'", "''") + "'"
}

function Get-SupervisorAttrValue {
    <#
      The YAML value a scalar already on disk denotes, so a line can be re-canonicalized
      without changing what it means. Only the two quotings we ever encounter are decoded:
      double (escapes processed) and single (literal, '' -> '). An unquoted scalar is literal.
    #>
    param([string] $Raw)

    $r = ([string]$Raw).Trim()
    if ($r.Length -ge 2 -and $r.StartsWith('"') -and $r.EndsWith('"')) {
        # Scanned character by character rather than with a chain of -replace calls: a
        # sequential replace has to hide already-decoded backslashes behind a sentinel, and any
        # sentinel is also a regex pattern (PS 5.1 has no `u{...} escape, so `u{0001} becomes
        # the quantifier u{1} and silently eats a literal 'U' - which is exactly the bug this
        # decoder is meant to prevent elsewhere).
        $inner = $r.Substring(1, $r.Length - 2)
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $inner.Length; $i++) {
            if ($inner[$i] -ne '\' -or $i -eq $inner.Length - 1) { [void]$sb.Append($inner[$i]); continue }
            $i++
            switch ($inner[$i]) {
                '\'     { [void]$sb.Append('\') }
                '"'     { [void]$sb.Append('"') }
                '/'     { [void]$sb.Append('/') }
                't'     { [void]$sb.Append("`t") }
                'n'     { [void]$sb.Append("`n") }
                'r'     { [void]$sb.Append("`r") }
                '0'     { [void]$sb.Append([char]0) }
                default { [void]$sb.Append($inner[$i]) }   # unknown escape: keep the character
            }
        }
        return $sb.ToString()
    }
    if ($r.Length -ge 2 -and $r.StartsWith("'") -and $r.EndsWith("'")) {
        return ($r.Substring(1, $r.Length - 2) -replace "''", "'")
    }
    return $r
}

function Test-SupervisorAttrScalarCanonical {
    <#
      Whether a line's scalar is already the round-trip-safe form: every backslash in the YAML
      value doubled. Anything else is rewritten - including forms that are perfectly valid YAML
      but do not survive the supervisor's second parse, which is the whole trap.
    #>
    param([string] $Raw)

    $v = Get-SupervisorAttrValue -Raw $Raw
    if ($v -notmatch '\\') { return $true }
    # Walk the value: every backslash must come in a pair.
    for ($i = 0; $i -lt $v.Length; $i++) {
        if ($v[$i] -ne '\') { continue }
        if ($i + 1 -ge $v.Length -or $v[$i + 1] -ne '\') { return $false }
        $i++
    }
    return $true
}

function Set-SupervisorDescriptionAttributes {
    <#
      Inject the detected selector attributes (cx.host.role, workload.*) into the OpAMP
      Supervisor's config.yaml `agent.description.non_identifying_attributes`, so they show
      up in the Coralogix Fleet Management AgentDescription. The vendor installer writes
      only static service.name/cx.agent.type there. Best-effort: never fails the install.

      Values go through ConvertTo-SupervisorAttrScalar - read its notes before changing the
      quoting, because the obvious choices are the broken ones.
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
    # The same pass RE-CANONICALIZES any existing value whose backslashes are not doubled. Two
    # reasons it has to happen here rather than only for keys we add:
    #   * a host written by an earlier version of this function is already broken - its
    #     supervisor will not start - and a key that is present is skipped below, so without
    #     this a re-deploy would "succeed" and leave the host dead
    #   * a value can be valid YAML, start the service, and still be wrong (\L decodes to
    #     U+2028 on the supervisor's second parse), which no service-status check would catch
    $existing = @{}; $repaired = @()
    for ($j = $anchor + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*#') { continue }
        if ($lines[$j] -notmatch ("^" + [regex]::Escape($itemIndent) + "\S")) { break }
        if ($lines[$j] -match '^(\s*)([^:\s]+)\s*:\s*(\S.*?)\s*$') {
            $ind = $Matches[1]; $key = $Matches[2]; $raw = $Matches[3]
            if (-not (Test-SupervisorAttrScalarCanonical -Raw $raw)) {
                $trueVal = Get-SupervisorAttrValue -Raw $raw
                $lines[$j] = '{0}{1}: {2}' -f $ind, $key, (ConvertTo-SupervisorAttrScalar -Value $trueVal)
                $repaired += $key
            }
        }
        if ($lines[$j] -match '^\s*([^:\s]+)\s*:') { $existing[$Matches[1]] = $true }
    }

    $insert = @(); $added = @()
    foreach ($k in $pairs.Keys) {
        if ($existing.ContainsKey($k)) { continue }
        $insert += ('{0}{1}: {2}' -f $itemIndent, $k, (ConvertTo-SupervisorAttrScalar -Value $pairs[$k]))
        $added += $k
    }
    if ($repaired.Count -gt 0) {
        Write-Warning "[supervisor] re-quoted AgentDescription values that the supervisor cannot round-trip (backslashes were not doubled): $($repaired -join ', ')"
    }
    if ($insert.Count -eq 0 -and $repaired.Count -eq 0) {
        Write-Host "[supervisor] AgentDescription already carries the selector attributes"; return
    }

    $new = @($lines[0..$anchor]) + $insert
    if (($anchor + 1) -le ($lines.Count - 1)) { $new += $lines[($anchor + 1)..($lines.Count - 1)] }
    Set-Content -Path $ConfigPath -Value $new -Encoding utf8
    Write-Host "[supervisor] published selector attributes to AgentDescription ($($insert.Count) added, $($repaired.Count) re-quoted): $($added -join ', ')"
}

function Restart-SupervisorVerified {
    <#
      Restart opampsupervisor and answer whether it is actually Running afterwards.
      Restart-Service reports success as soon as the SCM accepts the start, and a config the
      supervisor cannot load makes the process exit immediately after that - so the status is
      re-read, twice, with a settle gap.
    #>
    param([int] $TimeoutSeconds = 25)

    try { Restart-Service -Name 'opampsupervisor' -Force -ErrorAction Stop }
    catch { return $false }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $svc = Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Start-Sleep -Seconds 3
            $svc.Refresh()
            if ($svc.Status -eq 'Running') { return $true }
        }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-SupervisorStartError {
    <#
      The one line from the supervisor's own event-log entries that says WHY it refused to
      start. Without it an operator sees only StartServiceFailed from the SCM; the actual cause
      ('yaml: line 49: found unknown escape character') is written nowhere else.
    #>
    try {
        $e = Get-EventLog -LogName Application -Source 'opampsupervisor' -EntryType Error -Newest 15 -ErrorAction Stop |
                Where-Object { $_.Message -match 'failed to start service' } |
                Select-Object -First 1
        if (-not $e) { return $null }
        $m = [regex]::Match([string]$e.Message, 'failed to start service:[^''"]*')
        if ($m.Success) { return $m.Value.Trim() }
        return ([string]$e.Message -split "`n" | Select-Object -First 1).Trim()
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

# ---- Persist deployment environment (read by resource/environment processor) --
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
    # ---- Publish selector attributes to the OpAMP AgentDescription ----------------
    # The vendor installer writes only static service.name/cx.agent.type into the supervisor
    # config's agent.description. Inject the detected cx.host.role/workload.* so Coralogix
    # Fleet Management can group / assign config by them, then restart to apply.
    $supervisorConfig = Join-Path ${env:ProgramFiles} 'OpenTelemetry OpAMP Supervisor\config.yaml'
    if ($Session) { Backup-DeployFile -Session $Session -Path $supervisorConfig | Out-Null }

    # A rollback copy taken immediately before OUR edit, independent of -Session (which exists
    # only to reverse an uninstall): this edit is the last thing standing between a working
    # supervisor and a dead one, so the undo has to exist on a plain install too.
    $preEditCopy = "$supervisorConfig.pre-agentdesc"
    if (Test-Path $supervisorConfig) { Copy-Item $supervisorConfig $preEditCopy -Force -ErrorAction SilentlyContinue }

    Set-SupervisorDescriptionAttributes -ConfigPath $supervisorConfig -Attributes $ResourceAttributes
    try {
        if (Get-Service -Name 'opampsupervisor' -ErrorAction SilentlyContinue) {
            # The vendor installer registers the service with StartType=Manual. After a reboot the
            # supervisor stays Stopped -> the agent silently drops off Fleet Management and no
            # telemetry ships until someone starts it by hand. Force Automatic so it survives reboots.
            Set-Service -Name 'opampsupervisor' -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Host "[supervisor] set opampsupervisor StartType=Automatic (survives reboot)"

            # VERIFIED, not fire-and-forget. This used to be Restart-Service with
            # -ErrorAction SilentlyContinue followed by an unconditional "restarted" message, so
            # an edit that made config.yaml unloadable left the service dead while the install
            # reported success - the failure surfaced only when an operator next ran
            # Restart-Service by hand. A config we just wrote that the supervisor refuses is our
            # bug, so put the old one back rather than leave the host with no agent.
            if (-not (Restart-SupervisorVerified)) {
                $reason = Get-SupervisorStartError
                Write-Warning "[supervisor] opampsupervisor did not start after the AgentDescription edit$(if ($reason) { ": $reason" })"
                if (Test-Path $preEditCopy) {
                    Copy-Item $preEditCopy $supervisorConfig -Force
                    if (Restart-SupervisorVerified) {
                        Write-Warning "[supervisor] rolled back $supervisorConfig; service is Running WITHOUT the selector attributes (Fleet Management grouping by cx.host.role/workload.* will not work on this host)"
                    } else {
                        Write-Warning "[supervisor] rollback did not start the service either - the failure predates our edit. Inspect: Get-EventLog -LogName Application -Source opampsupervisor -Newest 20"
                    }
                }
            } else {
                Write-Host "[supervisor] restarted opampsupervisor and confirmed Running (AgentDescription attributes applied)"
                Remove-Item $preEditCopy -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { Write-Warning "[supervisor] could not configure/restart opampsupervisor: $_" }
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
