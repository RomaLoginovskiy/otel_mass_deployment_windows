<#
.SYNOPSIS
  Zero-code OpenTelemetry for .NET apps that run as a WINDOWS SERVICE, outside IIS.

.DESCRIPTION
  Everything the existing tooling instruments lives under w3wp: the injection point is the app
  pool's environment, and the CLR profiler itself is attached by the vendor module's
  Register-OpenTelemetryForIIS, which writes CORECLR_* / COR_* into the W3SVC and WAS service
  Environment values. A plain Windows service has no pool and is not W3SVC, so it gets nothing -
  a .NET worker service on a fully "instrumented" host emits exactly zero spans today.

  This closes that gap using the same mechanism the SCM already provides: the target service's own
  Environment value (REG_MULTI_SZ), which Windows applies to that service's process only.

  The profiler variables are COPIED FROM W3SVC rather than hard-coded here. That is deliberate:

    * the profiler GUID, the DLL path and OTEL_DOTNET_AUTO_HOME are decided by whichever version
      of the vendor module ran, and hard-coding them means this script silently rots the next time
      the pinned version changes,
    * and if IIS was never instrumented on this host there is nothing to copy, which is a REASON
      to report - not a set of paths to invent. -AutoHome covers the no-IIS host explicitly.

  Framework vs Core is decided per service from its binary, because the two need different
  variable names (COR_* vs CORECLR_*) and setting the wrong pair attaches nothing at all.

  SAFETY: an Environment REG_MULTI_SZ containing an EMPTY element is what stops IIS from starting -
  the doctor grades that as PROFILER_REGISTRY_MALFORMED, act-now severity. This writes the same
  value type on other services, so the writer refuses to emit an empty element, and -Remove takes
  out only the names it added.

.PARAMETER Services
  Service names to instrument. No default enumeration on purpose: unlike Node, "every .NET service
  on the box" includes Windows' own services, and attaching a profiler to those is not something a
  deploy script should decide by itself.

.PARAMETER AutoHome
  OTEL_DOTNET_AUTO_HOME to use when W3SVC carries no profiler variables (a host with no IIS).
  The profiler paths are derived from it the same way the vendor module lays them out.

.PARAMETER Remove
  Take the OTel variables back out and restart, leaving anything the service already had.

.NOTES
  Run elevated. Exit 0 = every requested service instrumented or already correct; 1 = at least one
  refused or failed, with the reason printed.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string[]] $Services,
    [string]   $OtlpEndpoint          = 'http://127.0.0.1:4318',
    [string]   $AutoHome              = $null,
    [hashtable] $ServiceNameOverrides = @{},
    [switch]   $Remove
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
# Runtime classification is shared with the IIS path rather than re-derived: "is this Framework or
# Core" is the same question there, and it has already been got wrong in both directions.
$runtimeHelper = Join-Path $here 'Resolve-IISAppRuntime.ps1'
if (Test-Path $runtimeHelper) { . $runtimeHelper }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated (Administrator).'
    }
}

function Get-CxServiceEnvMap {
    param([string] $Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $map = [ordered]@{}
    $malformed = $false
    try {
        $v = (Get-ItemProperty -LiteralPath $key -Name 'Environment' -ErrorAction Stop).Environment
        foreach ($line in @($v)) {
            if ([string]::IsNullOrWhiteSpace($line)) { $malformed = $true; continue }
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { $malformed = $true; continue }
            $map[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
        }
    } catch { }
    return [pscustomobject]@{ Map = $map; Malformed = $malformed }
}

function Set-CxServiceEnvMap {
    <#
      Write a service's Environment REG_MULTI_SZ from a map, refusing to emit an empty element.
      Returns the lines written.
    #>
    param([string] $Name, [System.Collections.Specialized.OrderedDictionary] $Map)

    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { throw "service key not found: $key" }

    $lines = @()
    foreach ($k in $Map.Keys) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $val = [string]$Map[$k]
        # A name with no value is still a valid entry for the SCM, but an entirely empty LINE is the
        # corruption that breaks service startup - so only the line is guarded, not the value.
        $lines += "$k=$val"
    }
    if ($lines.Count -eq 0) {
        Remove-ItemProperty -LiteralPath $key -Name 'Environment' -ErrorAction SilentlyContinue
        return @()
    }
    Set-ItemProperty -LiteralPath $key -Name 'Environment' -Value ([string[]]$lines) -Type MultiString
    return $lines
}

function Get-CxProfilerTemplate {
    <#
      The profiler variable set to copy onto a target service, taken from W3SVC (i.e. from whatever
      the vendor module actually wrote), or synthesised from -AutoHome on a host without IIS.

      Returns Core/Framework variable maps separately, because a service is one or the other.
    #>
    param([string] $AutoHomeOverride)

    $w3 = (Get-CxServiceEnvMap -Name 'W3SVC').Map
    $home = if ($AutoHomeOverride) { $AutoHomeOverride } elseif ($w3.Contains('OTEL_DOTNET_AUTO_HOME')) { [string]$w3['OTEL_DOTNET_AUTO_HOME'] } else { $null }
    if (-not $home) {
        return [pscustomobject]@{ Ok = $false
            Reason = 'no OTEL_DOTNET_AUTO_HOME on W3SVC and no -AutoHome given - install the .NET auto-instrumentation first (Install-OpenTelemetryCore), or pass -AutoHome' }
    }
    if (-not (Test-Path -LiteralPath $home)) {
        return [pscustomobject]@{ Ok = $false; Reason = "OTEL_DOTNET_AUTO_HOME does not exist on disk: $home" }
    }

    # Prefer the exact values already on W3SVC; fall back to the vendor's documented layout under
    # OTEL_DOTNET_AUTO_HOME when a host has the payload but never registered IIS.
    $coreGuid = if ($w3.Contains('CORECLR_PROFILER')) { [string]$w3['CORECLR_PROFILER'] } else { '{918728DD-259F-4A6A-AC2B-B85E1B658318}' }
    $fwGuid   = if ($w3.Contains('COR_PROFILER'))     { [string]$w3['COR_PROFILER'] }     else { $coreGuid }
    $corePath = if ($w3.Contains('CORECLR_PROFILER_PATH')) { [string]$w3['CORECLR_PROFILER_PATH'] } else { Join-Path $home 'win-x64\OpenTelemetry.AutoInstrumentation.Native.dll' }
    $fwPath   = if ($w3.Contains('COR_PROFILER_PATH'))     { [string]$w3['COR_PROFILER_PATH'] }     else { $corePath }

    foreach ($p in @($corePath, $fwPath)) {
        if ($p -and -not (Test-Path -LiteralPath $p)) {
            return [pscustomobject]@{ Ok = $false; Reason = "profiler DLL missing on disk: $p (the payload was removed after registration)" }
        }
    }

    $common = [ordered]@{ OTEL_DOTNET_AUTO_HOME = $home }
    # Anything else the module put on W3SVC that a service also needs (additional deps / store
    # paths vary by version) is carried over verbatim rather than second-guessed.
    foreach ($k in @('DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','DOTNET_STARTUP_HOOKS','OTEL_DOTNET_AUTO_PLUGINS')) {
        if ($w3.Contains($k)) { $common[$k] = [string]$w3[$k] }
    }

    $core = [ordered]@{ CORECLR_ENABLE_PROFILING = '1'; CORECLR_PROFILER = $coreGuid; CORECLR_PROFILER_PATH = $corePath }
    $fw   = [ordered]@{ COR_ENABLE_PROFILING     = '1'; COR_PROFILER     = $fwGuid;   COR_PROFILER_PATH     = $fwPath }

    return [pscustomobject]@{ Ok = $true; Home = $home; Common = $common; Core = $core; Framework = $fw
                              FromW3svc = [bool]$w3.Contains('CORECLR_PROFILER'); Reason = $null }
}

function Get-CxServiceBinary {
    param([string] $Name)
    try {
        $svc  = Get-CimInstance Win32_Service -Filter "Name='$($Name -replace "'","''")'" -ErrorAction Stop
        $path = [string]$svc.PathName
        $exe  = if ($path -match '^"([^"]+)"') { $Matches[1] } else { ($path -split ' ')[0] }
        return [pscustomobject]@{ Name = $svc.Name; Exe = $exe; Path = $path; State = [string]$svc.State; StartName = [string]$svc.StartName }
    } catch { return $null }
}

function Get-CxServiceRuntime {
    <#
      Core or Framework, decided from the binary and what sits next to it:

        * a .deps.json / runtimeconfig.json next to the exe  -> .NET Core / .NET 5+
        * apphost exe whose name matches a managed dll       -> Core
        * otherwise, a managed assembly built against the desktop CLR -> Framework

      Unknown is a real answer and is refused rather than guessed, for the same reason the IIS
      classifier refuses: attaching the wrong profiler pair produces silence that looks like a
      collector problem.
    #>
    param([string] $Exe)

    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return 'unknown' }
    $dir  = Split-Path -Parent $Exe
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Exe)

    if (Test-Path -LiteralPath (Join-Path $dir "$base.runtimeconfig.json")) { return 'core' }
    if (Test-Path -LiteralPath (Join-Path $dir "$base.deps.json"))          { return 'core' }
    if (Get-ChildItem -LiteralPath $dir -Filter '*.runtimeconfig.json' -ErrorAction SilentlyContinue | Select-Object -First 1) { return 'core' }

    # A Framework service is a managed exe with no runtimeconfig. Reading the CLR header is the
    # reliable test; a missing/native exe is 'unknown', not 'framework'.
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Exe)
        if ($bytes.Length -gt 0x100) {
            $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
            if ($peOffset -gt 0 -and ($peOffset + 0x18) -lt $bytes.Length) {
                # CLI header directory lives at optional-header offset 0xE8 (PE32+) / 0xD8 (PE32).
                $magic = [BitConverter]::ToUInt16($bytes, $peOffset + 0x18)
                $cliRva = if ($magic -eq 0x20b) { [BitConverter]::ToInt32($bytes, $peOffset + 0x18 + 0xE0) }
                          else                  { [BitConverter]::ToInt32($bytes, $peOffset + 0x18 + 0xD0) }
                if ($cliRva -ne 0) { return 'framework' }
            }
        }
    } catch { }
    return 'unknown'
}

function Restart-CxServiceVerified {
    param([string] $Name, [int] $TimeoutSeconds = 60)

    try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { }
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
        Start-Sleep -Milliseconds 500
    }
    try { Start-Service -Name $Name -ErrorAction Stop } catch { return $false }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            # A profiler that fails to attach can take the process down a few seconds in, which is
            # precisely the case a naive check would call success.
            Start-Sleep -Seconds 4
            $s.Refresh()
            if ($s.Status -eq 'Running') { return $true }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

# ---- main ---------------------------------------------------------------------
Assert-Admin

$ourNames = @('CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH',
              'COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH',
              'OTEL_DOTNET_AUTO_HOME','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE',
              'DOTNET_STARTUP_HOOKS','OTEL_DOTNET_AUTO_PLUGINS',
              'OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_SERVICE_NAME')

$template = $null
if (-not $Remove) {
    $template = Get-CxProfilerTemplate -AutoHomeOverride $AutoHome
    if (-not $template.Ok) {
        Write-Error "[dotnet-svc] cannot instrument: $($template.Reason)"
        exit 1
    }
    Write-Host "[dotnet-svc] OTEL_DOTNET_AUTO_HOME = $($template.Home)$(if (-not $template.FromW3svc) { '  (derived; W3SVC carries no profiler vars)' } else { '  (copied from W3SVC)' })"
}

$failed = 0
$done   = @()

foreach ($name in $Services) {
    $svc = Get-CxServiceBinary -Name $name
    Write-Host ''
    if (-not $svc) {
        Write-Warning "[dotnet-svc] $name REFUSED: service not found"
        $failed++
        continue
    }

    $existing = Get-CxServiceEnvMap -Name $name
    if ($existing.Malformed) {
        # Reported, not silently rewritten: an empty element here means something else already
        # corrupted this value, and the operator needs to know that independently of our change.
        Write-Warning "[dotnet-svc] $name : existing Environment contains a malformed/empty element - it will be dropped when rewritten"
    }
    $map = $existing.Map

    if ($Remove) {
        if (-not $PSCmdlet.ShouldProcess($name, 'remove OTel environment')) { continue }
        $removed = 0
        foreach ($k in $ourNames) { if ($map.Contains($k)) { $map.Remove($k); $removed++ } }
        [void](Set-CxServiceEnvMap -Name $name -Map $map)
        Write-Host "[dotnet-svc] $name : removed $removed OTel entr(y/ies)"
        if (Restart-CxServiceVerified -Name $name) { Write-Host '  service Running after restart' }
        else { Write-Warning "  $name did not come back after restart"; $failed++ }
        continue
    }

    $runtime = Get-CxServiceRuntime -Exe $svc.Exe
    Write-Host "[dotnet-svc] $name : runtime=$runtime exe=$($svc.Exe) state=$($svc.State) account=$($svc.StartName)"
    if ($runtime -eq 'unknown') {
        Write-Warning "[dotnet-svc] $name REFUSED: could not classify the service binary as .NET Core or .NET Framework. Attaching the wrong profiler pair produces no telemetry at all, so nothing was written."
        $failed++
        continue
    }

    $serviceName = if ($ServiceNameOverrides.ContainsKey($name)) { $ServiceNameOverrides[$name] } else { $name }

    foreach ($k in $template.Common.Keys) { $map[$k] = $template.Common[$k] }
    $pair = if ($runtime -eq 'core') { $template.Core } else { $template.Framework }
    foreach ($k in $pair.Keys) { $map[$k] = $pair[$k] }
    # The opposite pair is removed, so a service that changes runtime cannot keep a stale attach.
    $otherPair = if ($runtime -eq 'core') { $template.Framework } else { $template.Core }
    foreach ($k in $otherPair.Keys) { if ($map.Contains($k)) { $map.Remove($k) } }

    $map['OTEL_EXPORTER_OTLP_ENDPOINT'] = $OtlpEndpoint
    $map['OTEL_EXPORTER_OTLP_PROTOCOL'] = 'http/protobuf'
    $map['OTEL_SERVICE_NAME']           = $serviceName

    if (-not $PSCmdlet.ShouldProcess($name, "write $runtime profiler environment and restart")) { continue }

    try {
        $lines = Set-CxServiceEnvMap -Name $name -Map $map
        Write-Host "  wrote $($lines.Count) environment entr(y/ies); OTEL_SERVICE_NAME=$serviceName"
    } catch {
        Write-Warning "[dotnet-svc] $name FAILED to write environment: $($_.Exception.Message)"
        $failed++
        continue
    }

    if (Restart-CxServiceVerified -Name $name) {
        Write-Host '  service Running after restart (instrumented)'
        $done += $serviceName
    } else {
        Write-Warning "[dotnet-svc] $name did not stay Running after the profiler was attached. Check the Application event log - a profiler/runtime mismatch takes the process down shortly after start."
        $failed++
    }
}

# CX_DOTNET_SERVICES: the non-IIS analog of CX_IIS_SERVICES, so the collector can stamp ownership
# for services that have no app pool to be discovered through.
if ($done.Count -and -not $Remove) {
    $existingNames = @()
    $cur = [Environment]::GetEnvironmentVariable('CX_DOTNET_SERVICES', 'Machine')
    if ($cur) { $existingNames = @($cur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $all = @($existingNames + $done | Sort-Object -Unique)
    [Environment]::SetEnvironmentVariable('CX_DOTNET_SERVICES', ($all -join ','), 'Machine')
    Write-Host ''
    Write-Host "[dotnet-svc] CX_DOTNET_SERVICES = $($all -join ',')"
}

Write-Host ''
if ($failed) {
    Write-Warning "[dotnet-svc] $failed service(s) not instrumented (see reasons above)."
    exit 1
}
Write-Host "[dotnet-svc] done: $($done.Count) service(s) instrumented."
exit 0
