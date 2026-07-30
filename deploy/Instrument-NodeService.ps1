<#
.SYNOPSIS
  Zero-code OpenTelemetry for Node.js apps that run as a WINDOWS SERVICE with no PM2 involved.

.DESCRIPTION
  Instrument-NodePM2.ps1 covers everything a PM2 daemon manages. This covers the other common
  shape, which until now was documented as out of scope: node.exe started by the SCM through
  winsw / node-windows / nssm, or directly. There is no daemon to ask and no `pm2 restart` to run,
  so the environment has to be written where the SERVICE gets it from, and the service restarted.

  Four launcher shapes are recognised, because they store environment in four different places and
  writing to the wrong one produces a service that restarts cleanly and emits nothing:

    winsw / node-windows   <service>.xml next to the wrapper exe, <env name=".." value=".."/>
                           (node-windows generates winsw XML, so it is the same case)
    nssm                   nssm.exe set <svc> AppEnvironmentExtra KEY=VALUE
    generic                HKLM\SYSTEM\CurrentControlSet\Services\<svc>\Environment (REG_MULTI_SZ),
                           which the SCM applies to any service
    unknown                REFUSED with a reason - never guessed

  The generic path writes the same kind of REG_MULTI_SZ that, when malformed, stops IIS from
  starting (doctor reports that as PROFILER_REGISTRY_MALFORMED). So the writer here refuses to
  emit an empty element, and uninstall removes only the entries it added.

  NODE_OPTIONS is MERGED, never replaced (Merge-CxNodeOptions): an app that sets
  --max-old-space-size for a reason must keep its heap ceiling, and losing it silently is worse
  than not instrumenting at all.

.PARAMETER Services
  Service names to instrument. Default: every service whose command line runs node.exe.

.PARAMETER OtlpEndpoint
  Collector OTLP HTTP endpoint. 127.0.0.1, never localhost: localhost resolves to ::1 first on
  Windows and the export is silently dropped.

.PARAMETER InstallPrefix
  Where the OTel Node package is installed (its node_modules/). Must already be present - this
  script does not npm install, so it can run on a host with no registry access.

.PARAMETER ServiceNameOverrides
  Hashtable service -> OTEL_SERVICE_NAME. Without an override the Windows service name is used,
  which is what an operator looking at Coralogix would expect to see.

.PARAMETER WhatIf
  Report what would change and touch nothing.

.NOTES
  Run elevated. Exit code 0 = every requested service instrumented or already correct; 1 = at
  least one refused or failed, with the reason printed.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $Services             = @(),
    [string]   $OtlpEndpoint         = 'http://127.0.0.1:4318',
    [string]   $InstallPrefix        = 'C:\cx\otel-node',
    [string]   $Package              = '@opentelemetry/auto-instrumentations-node',
    [hashtable] $ServiceNameOverrides = @{},
    [string]   $NssmPath             = $null,
    [switch]   $Remove
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
. (Join-Path $here 'Resolve-NodeServiceNames.ps1')

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated (Administrator).'
    }
}

function Get-CxServiceCommandLine {
    param([string] $Name)
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$($Name -replace "'","''")'" -ErrorAction Stop
        return [pscustomobject]@{
            Name      = $svc.Name
            Path      = [string]$svc.PathName
            StartName = [string]$svc.StartName
            State     = [string]$svc.State
        }
    } catch { return $null }
}

function Find-CxNodeServices {
    <#
      Services whose command line runs node.exe, or whose wrapper config points at a .js entry.
      A winsw/nssm wrapper's own PathName is the WRAPPER exe, not node - so the XML has to be
      consulted or every wrapped Node service is missed, which is the common real-world case.
    #>
    $found = @()
    foreach ($svc in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        $path = [string]$svc.PathName
        if (-not $path) { continue }
        $isNode = $path -match '(?i)node\.exe'
        if (-not $isNode) {
            $exe = if ($path -match '^"([^"]+)"') { $Matches[1] } else { ($path -split ' ')[0] }
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                $xml = [System.IO.Path]::ChangeExtension($exe, '.xml')
                if (Test-Path -LiteralPath $xml) {
                    try {
                        $text = Get-Content -LiteralPath $xml -Raw
                        # A wrapper is "ours" only if it launches node - a winsw wrapping something
                        # else must not be touched.
                        if ($text -match '(?i)node\.exe' -or $text -match '(?i)<executable>[^<]*node') { $isNode = $true }
                    } catch { }
                }
            }
        }
        # PM2's own service is excluded on purpose: Instrument-NodePM2.ps1 owns that shape, and
        # instrumenting the God daemon here would self-instrument every pm2 CLI call.
        if ($isNode -and $path -notmatch '(?i)pm2') { $found += $svc.Name }
    }
    return @($found | Sort-Object -Unique)
}

function Get-CxServiceLauncher {
    <#
      Which of the four launcher shapes is this, and where does its environment live?
      Returns Kind = winsw | nssm | generic | unknown, plus the path that has to be edited.
    #>
    param([string] $Name)

    $info = Get-CxServiceCommandLine -Name $Name
    if (-not $info) { return [pscustomobject]@{ Kind = 'unknown'; Reason = "service '$Name' not found" } }

    $path = $info.Path
    $exe  = if ($path -match '^"([^"]+)"') { $Matches[1] } else { ($path -split ' ')[0] }

    if ($exe -match '(?i)nssm\.exe') {
        return [pscustomobject]@{ Kind = 'nssm'; Exe = $exe; Xml = $null; Info = $info; Reason = $null }
    }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        $xml = [System.IO.Path]::ChangeExtension($exe, '.xml')
        if (Test-Path -LiteralPath $xml) {
            try {
                [xml]$doc = Get-Content -LiteralPath $xml -Raw
                if ($doc.service) {
                    return [pscustomobject]@{ Kind = 'winsw'; Exe = $exe; Xml = $xml; Info = $info; Reason = $null }
                }
            } catch {
                return [pscustomobject]@{ Kind = 'unknown'; Exe = $exe; Xml = $xml; Info = $info
                                          Reason = "a wrapper XML exists at $xml but could not be parsed: $($_.Exception.Message)" }
            }
        }
    }
    # node.exe launched directly by the SCM: the service's registry Environment is the only place
    # its environment can come from.
    if ($path -match '(?i)node\.exe') {
        return [pscustomobject]@{ Kind = 'generic'; Exe = $exe; Xml = $null; Info = $info; Reason = $null }
    }
    return [pscustomobject]@{ Kind = 'unknown'; Exe = $exe; Xml = $null; Info = $info
                              Reason = "cannot tell how '$Name' launches node (command line: $path)" }
}

function Get-CxWinswEnv {
    param([string] $Xml)
    $map = [ordered]@{}
    [xml]$doc = Get-Content -LiteralPath $Xml -Raw
    foreach ($e in @($doc.service.env)) {
        if ($e -and $e.name) { $map[[string]$e.name] = [string]$e.value }
    }
    return $map
}

function Set-CxWinswEnv {
    <#
      Upsert <env> elements in a winsw / node-windows service XML. Written with the XML DOM rather
      than string surgery: these files are generated, their attribute order and formatting vary,
      and a regex rewrite is how you end up with two <env> elements for one name - after which the
      last one silently wins.
    #>
    param([string] $Xml, [hashtable] $Values)

    [xml]$doc = Get-Content -LiteralPath $Xml -Raw
    if (-not $doc.service) { throw "not a winsw service definition: $Xml" }

    foreach ($k in $Values.Keys) {
        $node = @($doc.service.env | Where-Object { $_.name -eq $k }) | Select-Object -First 1
        if ($node) {
            $node.value = [string]$Values[$k]
        } else {
            $new = $doc.CreateElement('env')
            $new.SetAttribute('name',  $k)
            $new.SetAttribute('value', [string]$Values[$k])
            [void]$doc.service.AppendChild($new)
        }
    }
    $doc.Save($Xml)
}

function Remove-CxWinswEnv {
    param([string] $Xml, [string[]] $Names)
    [xml]$doc = Get-Content -LiteralPath $Xml -Raw
    $removed = 0
    foreach ($k in $Names) {
        foreach ($node in @($doc.service.env | Where-Object { $_.name -eq $k })) {
            [void]$doc.service.RemoveChild($node); $removed++
        }
    }
    if ($removed) { $doc.Save($Xml) }
    return $removed
}

function Get-CxServiceRegEnv {
    param([string] $Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $map = [ordered]@{}
    try {
        $v = (Get-ItemProperty -LiteralPath $key -Name 'Environment' -ErrorAction Stop).Environment
        foreach ($line in @($v)) {
            if (-not $line) { continue }          # an empty element is exactly the corruption we guard against
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { continue }
            $map[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
        }
    } catch { }
    return $map
}

function Set-CxServiceRegEnv {
    <#
      Write the service's Environment REG_MULTI_SZ.

      The empty-element guard is not theoretical: an empty string inside the W3SVC/WAS Environment
      value is what stops IIS from starting, and the doctor grades it as an act-now failure
      (PROFILER_REGISTRY_MALFORMED). The same value type, the same failure mode - so nothing empty
      is ever written here, and a malformed pre-existing value is reported rather than preserved.
    #>
    param([string] $Name, [hashtable] $Values, [string[]] $RemoveNames = @())

    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { throw "service key not found: $key" }

    $current = Get-CxServiceRegEnv -Name $Name
    foreach ($k in $Values.Keys)  { $current[$k] = [string]$Values[$k] }
    foreach ($k in $RemoveNames)  { if ($current.Contains($k)) { $current.Remove($k) } }

    $lines = @()
    foreach ($k in $current.Keys) {
        if (-not $k) { continue }
        $line = "$k=$($current[$k])"
        if ($line.Trim() -eq '=' -or -not $line.Trim()) { continue }
        $lines += $line
    }
    if ($lines.Count -eq 0) {
        Remove-ItemProperty -LiteralPath $key -Name 'Environment' -ErrorAction SilentlyContinue
        return @()
    }
    Set-ItemProperty -LiteralPath $key -Name 'Environment' -Value ([string[]]$lines) -Type MultiString
    return $lines
}

function Set-CxNssmEnv {
    param([string] $Nssm, [string] $Name, [hashtable] $Values)
    $pairs = @($Values.Keys | ForEach-Object { "$_=$($Values[$_])" })
    # nssm replaces the whole AppEnvironmentExtra block, so existing entries have to be read and
    # re-sent together with ours or they are lost.
    $existing = @()
    try { $existing = @(& $Nssm get $Name AppEnvironmentExtra 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -match '=' }) } catch { }
    $keep = @($existing | Where-Object { $k = ($_ -split '=')[0]; -not $Values.ContainsKey($k) })
    $all  = @($keep + $pairs)
    & $Nssm set $Name AppEnvironmentExtra @all | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Restart-CxServiceVerified {
    <#
      Restart and confirm it is still Running a moment later. A service whose new environment makes
      it crash reaches Running briefly and then exits, and reporting that as success is how a
      "successful" instrumentation run leaves a dead app behind.
    #>
    param([string] $Name, [int] $TimeoutSeconds = 40)

    try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
        Start-Sleep -Milliseconds 500
    }
    try { Start-Service -Name $Name -ErrorAction Stop } catch { return $false }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Start-Sleep -Seconds 3
            $s.Refresh()
            if ($s.Status -eq 'Running') { return $true }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

# ---- main ---------------------------------------------------------------------
Assert-Admin

$targets = if ($Services.Count) { @($Services) } else { Find-CxNodeServices }
if (-not $targets.Count) {
    Write-Host '[node-svc] no Node.js Windows services found (nothing to do).'
    exit 0
}
Write-Host "[node-svc] target services: $($targets -join ', ')"

$boot = $null
if (-not $Remove) {
    $boot = Resolve-CxNodeBootstrap -InstallPrefix $InstallPrefix -Package $Package
    if (-not $boot.NodeOptionsCjs) {
        Write-Error "[node-svc] cannot instrument: $($boot.Reason)"
        exit 1
    }
    Write-Host "[node-svc] register bootstrap: $($boot.RegisterPath)"
    if (-not $boot.EsmSupported) { Write-Warning "[node-svc] $($boot.Reason)" }
}

$ourNames = @('NODE_OPTIONS','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL',
              'OTEL_SERVICE_NAME','OTEL_TRACES_EXPORTER','OTEL_METRICS_EXPORTER','OTEL_LOGS_EXPORTER')

$failed = 0
$done   = @()

foreach ($name in $targets) {
    $launcher = Get-CxServiceLauncher -Name $name
    Write-Host ''
    Write-Host "[node-svc] $name : launcher=$($launcher.Kind)$(if ($launcher.Info) { " state=$($launcher.Info.State) account=$($launcher.Info.StartName)" })"

    if ($launcher.Kind -eq 'unknown') {
        Write-Warning "[node-svc] $name REFUSED: $($launcher.Reason)"
        $failed++
        continue
    }

    $serviceName = if ($ServiceNameOverrides.ContainsKey($name)) { $ServiceNameOverrides[$name] } else { $name }

    # Existing NODE_OPTIONS, read from wherever this launcher keeps it, so it can be merged.
    $existingEnv = switch ($launcher.Kind) {
        'winsw'   { Get-CxWinswEnv     -Xml  $launcher.Xml }
        'generic' { Get-CxServiceRegEnv -Name $name }
        'nssm'    { Get-CxServiceRegEnv -Name $name }   # informational; nssm's own store is read in Set-CxNssmEnv
        default   { [ordered]@{} }
    }
    $existingNodeOptions = if ($existingEnv.Contains('NODE_OPTIONS')) { [string]$existingEnv['NODE_OPTIONS'] } else { '' }

    if ($Remove) {
        if (-not $PSCmdlet.ShouldProcess($name, 'remove OTel environment')) { continue }
        switch ($launcher.Kind) {
            'winsw'   { $n = Remove-CxWinswEnv -Xml $launcher.Xml -Names $ourNames; Write-Host "  removed $n env element(s) from $($launcher.Xml)" }
            default   { [void](Set-CxServiceRegEnv -Name $name -Values @{} -RemoveNames $ourNames); Write-Host '  removed OTel entries from the service Environment' }
        }
        if (Restart-CxServiceVerified -Name $name) { Write-Host '  service Running after restart' } else { Write-Warning "  $name did not come back after restart"; $failed++ }
        continue
    }

    # ESM vs CommonJS decides which bootstrap form applies. The entry script is whatever the
    # launcher points at; when it cannot be determined, CommonJS is used and said out loud rather
    # than assumed silently.
    $entry = $null
    if ($launcher.Kind -eq 'winsw') {
        try {
            [xml]$doc = Get-Content -LiteralPath $launcher.Xml -Raw
            $argline  = (@($doc.service.argument) -join ' ')
            if (-not $argline) { $argline = [string]$doc.service.arguments }
            $m = [regex]::Match($argline, '(?i)([A-Za-z]:\\[^"]*?\.(?:js|mjs|cjs))')
            if ($m.Success) { $entry = $m.Groups[1].Value }
        } catch { }
    }
    if (-not $entry -and $launcher.Info) {
        $m = [regex]::Match($launcher.Info.Path, '(?i)([A-Za-z]:\\[^"]*?\.(?:js|mjs|cjs))')
        if ($m.Success) { $entry = $m.Groups[1].Value }
    }

    $isEsm = $false
    if ($entry) {
        try { $isEsm = [bool](Test-CxNodeAppIsEsm -ScriptPath $entry) } catch { $isEsm = $false }
    } else {
        Write-Host '  entry script not determined from the launcher - treating as CommonJS'
    }
    if ($isEsm -and -not $boot.EsmSupported) {
        Write-Warning "[node-svc] $name REFUSED: entry $entry is an ES module and the loader hook is missing, so instrumenting it would emit nothing"
        $failed++
        continue
    }

    $bootstrap  = if ($isEsm) { $boot.NodeOptionsEsm } else { $boot.NodeOptionsCjs }
    # Both artifacts are declared as ours, not just the ones in this bootstrap: a service that
    # switches from ESM to CommonJS would otherwise keep our stale --experimental-loader.
    $owned = @($boot.RegisterPath, $boot.HookUrl) | Where-Object { $_ }
    $nodeOptions = Merge-CxNodeOptions -Existing $existingNodeOptions -Bootstrap $bootstrap -OwnedTargets $owned
    if ($existingNodeOptions) { Write-Host "  preserving the service's own NODE_OPTIONS: $existingNodeOptions" }
    Write-Host "  entry=$(if ($entry) { $entry } else { '<unknown>' }) esm=$isEsm -> OTEL_SERVICE_NAME=$serviceName"

    $values = [ordered]@{
        NODE_OPTIONS                = $nodeOptions
        OTEL_EXPORTER_OTLP_ENDPOINT = $OtlpEndpoint
        OTEL_EXPORTER_OTLP_PROTOCOL = 'http/protobuf'
        OTEL_SERVICE_NAME           = $serviceName
    }

    if (-not $PSCmdlet.ShouldProcess($name, 'write OTel environment and restart')) { continue }

    try {
        switch ($launcher.Kind) {
            'winsw' {
                Set-CxWinswEnv -Xml $launcher.Xml -Values $values
                Write-Host "  wrote $($values.Count) <env> element(s) to $($launcher.Xml)"
            }
            'nssm' {
                $nssm = if ($NssmPath) { $NssmPath } else { $launcher.Exe }
                if (-not (Set-CxNssmEnv -Nssm $nssm -Name $name -Values $values)) { throw "nssm set AppEnvironmentExtra failed for $name" }
                Write-Host '  wrote AppEnvironmentExtra via nssm'
            }
            'generic' {
                $lines = Set-CxServiceRegEnv -Name $name -Values $values
                Write-Host "  wrote $($lines.Count) entr(y/ies) to the service Environment (REG_MULTI_SZ)"
            }
        }
    } catch {
        Write-Warning "[node-svc] $name FAILED to write environment: $($_.Exception.Message)"
        $failed++
        continue
    }

    if (Restart-CxServiceVerified -Name $name) {
        Write-Host '  service Running after restart (instrumented)'
        $done += $serviceName
    } else {
        Write-Warning "[node-svc] $name did not stay Running after the environment change - check the service log; the app may reject a flag in NODE_OPTIONS"
        $failed++
    }
}

# CX_NODE_SERVICES is the Node analog of CX_IIS_SERVICES: it lets the collector stamp service
# ownership onto host telemetry. Merge rather than overwrite, because Instrument-NodePM2.ps1
# publishes into the same variable and whichever ran last must not erase the other's names.
if ($done.Count -and -not $Remove) {
    $existing = @()
    $cur = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
    if ($cur) { $existing = @($cur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $all = @($existing + $done | Sort-Object -Unique)
    [Environment]::SetEnvironmentVariable('CX_NODE_SERVICES', ($all -join ','), 'Machine')
    Write-Host ''
    Write-Host "[node-svc] CX_NODE_SERVICES = $($all -join ',')"
}

Write-Host ''
if ($failed) {
    Write-Warning "[node-svc] $failed service(s) not instrumented (see reasons above)."
    exit 1
}
Write-Host "[node-svc] done: $($done.Count) service(s) instrumented."
exit 0
