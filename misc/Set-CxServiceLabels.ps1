<#
.SYNOPSIS
  Isolated, self-contained setup + diagnostics for the CX_IIS_SERVICES machine environment
  variable that drives Coralogix Infrastructure-Explorer "Service ownership" on a Windows host.
  Covers BOTH workload types: IIS sites/applications and Node.js apps managed by PM2.

.DESCRIPTION
  Coralogix resolves the Service(s) that own a host from resource attributes on infrastructure
  telemetry. The collector's `transform/iis_service_labels` processor reads the MACHINE env var
  CX_IIS_SERVICES, splits it on ',' and stamps 7 attribute keys (service, tags.{service,cx_svc,
  CX_SERVICE_NAME}, cx.infra.labels.{service,cx_svc,CX_SERVICE_NAME}) as an OTel array.

  On the fleet hosts that variable is written as a side effect of the full installer
  (deploy\Instrument-IIS.ps1 / deploy\Instrument-NodePM2.ps1), which also installs the
  auto-instrumentation runtime, edits applicationHost.config / web.config, restarts PM2 apps and
  recycles IIS. When ownership labels do not show up there is no small, safe way to answer the
  three questions that matter:

      1. What SHOULD the value be on this host?
      2. Was it actually set?
      3. If it was set, why has it not taken effect?

  This script answers all three, changes nothing by default, and logs a specific cause + fix for
  every degraded step. It is deliberately STANDALONE - it does not dot-source anything from
  deploy\, so it can be copied to a problem host on its own.

  WHAT IT WRITES (only with -Apply):
    CX_IIS_SERVICES   = distinct UNION of the IIS service names AND the PM2 service names.
    CX_NODE_SERVICES  = the PM2 service names only.

  WHY THE UNION: the collector config in this repo (deploy\config.supervisor.yaml) reads
  CX_IIS_SERVICES only - no collector YAML references CX_NODE_SERVICES. Writing Node names into
  CX_IIS_SERVICES as well is what makes PM2 apps appear as host Service ownership TODAY.
  CX_NODE_SERVICES is still written (matching deploy\Instrument-NodePM2.ps1) so a future
  Node-specific transform has the split value available. Both are logged explicitly.
  Use -NoUnion to keep the two sets strictly separate (deploy-script parity).

  NAMING RULES - kept byte-identical to the deploy path on purpose. If they drift, this script
  would "fix" a host into a value the real installer later overwrites.
    IIS  (deploy\Resolve-IISServiceNames.ps1):
           root application of a site -> "<SiteName>"          e.g. "Wallet"
           application at /path       -> "<SiteName><path>"    e.g. "Wallet/api"
    PM2  (deploy\Resolve-NodeServiceNames.ps1):
           service name = the PM2 app name; cluster workers collapse to that one name.
  Names are de-duplicated preserving first-seen order and joined with ','.

.PARAMETER Apply
  Perform the machine environment writes (and the collector restart). Without it the script is a
  read-only diagnostic that prints the exact writes it WOULD make.

.PARAMETER RestartCollector
  With -Apply, restart the collector so it re-reads the machine environment. Default $true.
  Suppress with -RestartCollector:$false.

.PARAMETER NoUnion
  Keep CX_IIS_SERVICES = IIS names only (deploy-script parity). The script then reports, loudly,
  that Node names will not reach Coralogix with the current collector configuration.

.PARAMETER SkipIis
  Do not enumerate IIS. The IIS contribution to the values is treated as empty.

.PARAMETER SkipNode
  Do not enumerate PM2. The Node contribution to the values is treated as empty.

.PARAMETER ServiceNameOverrides
  Hashtable keyed by the auto-derived service name, value = replacement. Same shape as the
  -ServiceNameOverrides parameter of the deploy scripts, e.g. @{ 'Wallet/api' = 'wallet-api' }.

.PARAMETER OverridesJson
  Path to a JSON file of the same { autoName = overrideName } shape. Merged UNDER the hashtable.

.PARAMETER LogPath
  Log file path. Default: <script dir>\Set-CxServiceLabels.<yyyyMMdd-HHmmss>.log

.OUTPUTS
  Exit code 0 = no failures, 1 = at least one FAIL, 2 = preflight abort (cannot run at all).

.EXAMPLE
  PS> .\Set-CxServiceLabels.ps1
  Read-only. Prints what it would set and why any step degraded.

.EXAMPLE
  PS> .\Set-CxServiceLabels.ps1 -Apply
  Writes CX_IIS_SERVICES / CX_NODE_SERVICES and restarts the collector.

.NOTES
  Windows PowerShell 5.1 compatible. Run elevated (machine-scope env write + IIS enumeration).
  For PM2, run as the SAME user that owns the PM2 daemon - PM2 is per-user on Windows.
#>
[CmdletBinding()]
param(
    [switch]    $Apply,
    [bool]      $RestartCollector     = $true,
    [switch]    $NoUnion,
    [switch]    $SkipIis,
    [switch]    $SkipNode,
    [hashtable] $ServiceNameOverrides = @{},
    [string]    $OverridesJson,
    [string]    $LogPath
)

# 'Continue', deliberately. Native commands (pm2) write chatter to stderr, which under 'Stop'
# becomes a terminating NativeCommandError in Windows PowerShell 5.1 and would abort a
# diagnostic whose whole job is to survive broken hosts. Real failures are caught explicitly.
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------------------------

$script:Counts    = @{ OK = 0; INFO = 0; DRYRUN = 0; APPLY = 0; WARN = 0; FAIL = 0 }
$script:StartedAt = Get-Date

if (-not $LogPath) {
    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $LogPath = Join-Path $dir ("Set-CxServiceLabels.{0}.log" -f $script:StartedAt.ToString('yyyyMMdd-HHmmss'))
}

function Write-Log {
    # Append one raw line to the log file. Never throws - a diagnostic that dies because it
    # cannot write its own log is worse than one that prints to the console only.
    param([string] $Line)
    try { Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Write-Step {
    <#
      One structured line: [<stage>] <LEVEL> <message>
      Levels: OK / INFO / DRYRUN / APPLY / WARN / FAIL.
      -Cause and -Fix add the indented explanation lines. WARN/FAIL without a cause is a bug in
      this script: the entire point is that every degraded step says why and what to do.
    #>
    param(
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][ValidateSet('OK','INFO','DRYRUN','APPLY','WARN','FAIL')][string] $Level,
        [Parameter(Mandatory)][string] $Message,
        [string] $Cause,
        [string] $Fix
    )
    if ($script:Counts.ContainsKey($Level)) { $script:Counts[$Level]++ }

    $color = switch ($Level) {
        'OK'     { 'Green' }
        'INFO'   { 'Gray' }
        'DRYRUN' { 'Cyan' }
        'APPLY'  { 'Green' }
        'WARN'   { 'Yellow' }
        'FAIL'   { 'Red' }
    }
    $line = "[{0,-9}] {1,-6} {2}" -f $Stage, $Level, $Message
    Write-Host $line -ForegroundColor $color
    Write-Log ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $line)

    if ($Cause) {
        $c = "              -> cause: $Cause"
        Write-Host $c -ForegroundColor DarkGray; Write-Log $c
    }
    if ($Fix) {
        $f = "              -> fix:   $Fix"
        Write-Host $f -ForegroundColor DarkGray; Write-Log $f
    }
}

function Write-Detail {
    # Indented continuation line (tables, enumerations). Counts toward nothing.
    param([string] $Text)
    $t = "              $Text"
    Write-Host $t -ForegroundColor DarkGray
    Write-Log $t
}

function Format-EnvValue {
    param([string] $Value)
    if ($null -eq $Value -or $Value -eq '') { return '<unset>' }
    return $Value
}

# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------

function Join-DistinctNames {
    <#
      De-duplicate preserving first-seen order and join with ','. This is the exact contract the
      collector's Split("${env:CX_IIS_SERVICES}", ",") expects.
    #>
    param([string[]] $Names)
    $seen = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($n in $Names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if (-not $seen.Contains($n)) { $seen.Add($n, $true) }
    }
    $out = @()
    foreach ($k in $seen.Keys) { $out += [string]$k }
    return ($out -join ',')
}

function Test-NameSafe {
    <#
      A service name containing ',' would mis-split into several ownership items; one containing
      '"' would break the double-quoted OTTL string literal in the collector config. Neither is
      supported by the transform, so flag them rather than silently produce garbage labels.
    #>
    param([string] $Name)
    return -not ($Name -match '[,"]')
}

function Resolve-Overrides {
    # JSON file first, -ServiceNameOverrides on top (same precedence as the deploy scripts).
    param([hashtable] $Table, [string] $JsonPath)
    $merged = @{}
    if ($JsonPath) {
        if (-not (Test-Path -LiteralPath $JsonPath)) {
            Write-Step -Stage 'preflight' -Level 'WARN' -Message "overrides JSON not found: $JsonPath" `
                -Cause 'the -OverridesJson path does not exist' `
                -Fix   'correct the path, or drop -OverridesJson to use auto-derived names'
        } else {
            try {
                $obj = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
                foreach ($p in $obj.PSObject.Properties) { $merged[$p.Name] = [string]$p.Value }
                Write-Step -Stage 'preflight' -Level 'OK' -Message "loaded $($merged.Count) override(s) from $JsonPath"
            } catch {
                Write-Step -Stage 'preflight' -Level 'WARN' -Message "could not parse overrides JSON: $JsonPath" `
                    -Cause $_.Exception.Message `
                    -Fix   'the file must be a flat JSON object: { "AutoName": "OverrideName" }'
            }
        }
    }
    if ($Table) { foreach ($k in $Table.Keys) { $merged[[string]$k] = [string]$Table[$k] } }
    return $merged
}

# ---------------------------------------------------------------------------------------------
# Registry last-write time (used to decide whether a running collector predates the env change)
# ---------------------------------------------------------------------------------------------

$script:EnvKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function Get-EnvKeyLastWriteTime {
    <#
      There is no managed API for a registry key's last-write timestamp, so call RegQueryInfoKey.
      Returns $null (not an exception) when unavailable - the caller then falls back to a weaker
      but honest heuristic and says so in the log.
    #>
    try {
        if (-not ('CxRegInfo' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CxRegInfo {
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegQueryInfoKey(
        IntPtr hKey, IntPtr lpClass, IntPtr lpcchClass, IntPtr lpReserved,
        IntPtr lpcSubKeys, IntPtr lpcbMaxSubKeyLen, IntPtr lpcbMaxClassLen,
        IntPtr lpcValues, IntPtr lpcbMaxValueNameLen, IntPtr lpcbMaxValueLen,
        IntPtr lpcbSecurityDescriptor, out long lpftLastWriteTime);

    public static DateTime LastWriteTime(IntPtr hKey) {
        long ft;
        int rc = RegQueryInfoKey(hKey, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                 IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                 IntPtr.Zero, IntPtr.Zero, out ft);
        if (rc != 0) { throw new System.ComponentModel.Win32Exception(rc); }
        return DateTime.FromFileTime(ft);
    }
}
'@
        }
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:EnvKeyPath)
        if (-not $key) { return $null }
        try   { return [CxRegInfo]::LastWriteTime($key.Handle.DangerousGetHandle()) }
        finally { $key.Close() }
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------------------------
# Stage 0 - preflight
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '=== Coralogix service-ownership labels: CX_IIS_SERVICES / CX_NODE_SERVICES ===' -ForegroundColor Cyan
Write-Log  "=== Set-CxServiceLabels started $($script:StartedAt.ToString('u')) ==="
Write-Log  "mode=$(if ($Apply) { 'APPLY' } else { 'DRY-RUN' }) union=$(-not $NoUnion) skipIis=$SkipIis skipNode=$SkipNode"
Write-Host ("mode: {0}   log: {1}" -f $(if ($Apply) { 'APPLY (will write)' } else { 'DRY-RUN (no changes)' }), $LogPath) -ForegroundColor Cyan
Write-Host ''

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Step -Stage 'preflight' -Level 'INFO' -Message "identity=$($identity.Name) host=$env:COMPUTERNAME ps=$($PSVersionTable.PSVersion)"

if (-not $isAdmin) {
    Write-Step -Stage 'preflight' -Level 'FAIL' -Message 'not elevated' `
        -Cause 'writing a Machine-scope environment variable and enumerating IIS both require Administrator' `
        -Fix   'right-click PowerShell -> Run as administrator, then re-run this script'
    Write-Host ''
    Write-Host 'ABORTED (preflight).' -ForegroundColor Red
    exit 2
}
Write-Step -Stage 'preflight' -Level 'OK' -Message 'running elevated'

if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Step -Stage 'preflight' -Level 'WARN' -Message "running PowerShell $($PSVersionTable.PSVersion), not Windows PowerShell 5.1" `
        -Cause 'the WebAdministration module is a Windows PowerShell component; under PS 7 it loads through the compatibility layer and Get-Website can behave differently' `
        -Fix   'if IIS enumeration looks wrong, re-run under powershell.exe (5.1)'
}

# Machine vs Process scope. A process-scope value inherited from an old shell is the classic
# false "it is already set" - the collector reads the MACHINE value, not this shell's copy.
$curIisMachine  = [Environment]::GetEnvironmentVariable('CX_IIS_SERVICES',  'Machine')
$curNodeMachine = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
$curIisProcess  = $env:CX_IIS_SERVICES
$curNodeProcess = $env:CX_NODE_SERVICES

Write-Step -Stage 'preflight' -Level 'INFO' -Message "current CX_IIS_SERVICES  (machine) = $(Format-EnvValue $curIisMachine)"
Write-Step -Stage 'preflight' -Level 'INFO' -Message "current CX_NODE_SERVICES (machine) = $(Format-EnvValue $curNodeMachine)"

if ($curIisMachine -ne $curIisProcess) {
    Write-Step -Stage 'preflight' -Level 'WARN' -Message "CX_IIS_SERVICES differs between machine and this process ('$(Format-EnvValue $curIisProcess)')" `
        -Cause 'this shell inherited its environment when it started, before the machine value changed' `
        -Fix   'ignore the process value; only the machine value matters to the collector'
}
if ($curNodeMachine -ne $curNodeProcess) {
    Write-Step -Stage 'preflight' -Level 'WARN' -Message "CX_NODE_SERVICES differs between machine and this process ('$(Format-EnvValue $curNodeProcess)')" `
        -Cause 'this shell inherited its environment when it started, before the machine value changed' `
        -Fix   'ignore the process value; only the machine value matters to the collector'
}

$overrides = Resolve-Overrides -Table $ServiceNameOverrides -JsonPath $OverridesJson
if ($overrides.Count -gt 0) {
    Write-Step -Stage 'preflight' -Level 'INFO' -Message "$($overrides.Count) service-name override(s) active"
    foreach ($k in $overrides.Keys) { Write-Detail ("{0} -> {1}" -f $k, $overrides[$k]) }
}

# ---------------------------------------------------------------------------------------------
# Stage 1 - IIS discovery
# ---------------------------------------------------------------------------------------------

function Get-CxStandaloneAppRuntime {
    <#
      Which runtime is behind this IIS application - and can .NET OpenTelemetry automatic
      instrumentation do anything for it?

      Returns 'AspNetCore' | 'AspNetFramework' | 'NonDotNet' | 'Unknown'.

      INLINED, not dot-sourced, because this script is deliberately standalone: it is the tool
      you copy onto a host whose deploy package is missing or broken. That is the same trade
      misc\Test-CxInstrumentation.ps1 makes. Keep the RULES here in step with
      deploy\Resolve-IISAppRuntime.ps1 - if the two disagree, running this tool after the
      installer silently re-introduces the over-claim it exists to repair.

      Why this matters here specifically: this script's whole job is rebuilding
      CX_IIS_SERVICES. Before classification it built the label from EVERY IIS application, so
      running it on a host with a static Default Web Site put a service into the label that no
      APM telemetry ever arrives for - and because the doctor compares the variable against
      the apps it believes are instrumented, that drift could never clear.

      Deliberately NOT reimplemented in full: no ancestor/<location> inheritance walk (a child
      app inheriting <aspNetCore> from its parent classifies Unknown here, not AspNetCore).
      That errs toward "leave it out of the label", which is the safe direction for a repair
      tool - under-claiming loses an ownership item, over-claiming poisons it permanently.
    #>
    param([string] $PhysicalPath)

    if (-not $PhysicalPath) { return 'Unknown' }

    $wc  = Join-Path $PhysicalPath 'web.config'
    $raw = $null
    $absent = $false
    try {
        $raw = [System.IO.File]::ReadAllText($wc)
    } catch [System.IO.DirectoryNotFoundException] {
        return 'NonDotNet'          # the folder is gone; IIS cannot serve this app at all
    } catch [System.IO.FileNotFoundException] {
        $absent = $true
    } catch {
        return 'Unknown'            # ACL or similar - could not look, which is not "nothing there"
    }

    if (-not $absent) {
        $x = $null
        try { [xml]$x = $raw } catch { return 'Unknown' }   # malformed XML: unreadable, not absent

        if ($x.SelectSingleNode('//aspNetCore')) { return 'AspNetCore' }

        # POSITIVE .NET Framework evidence only - never the pool's managedRuntimeVersion. That
        # attribute is absent by default and defaults to v4.0, so keying off it would classify
        # every static site on DefaultAppPool as Framework.
        $meaningful = @('compilation','httpHandlers','httpModules','authentication','authorization',
                        'pages','sessionState','machineKey','globalization','customErrors',
                        'membership','roleManager','profile','siteMap','webServices','trust','identity')
        try {
            foreach ($sw in @($x.SelectNodes('//system.web'))) {
                foreach ($c in @($sw.ChildNodes)) {
                    if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $meaningful -contains $c.LocalName) { return 'AspNetFramework' }
                }
            }
            foreach ($n in @($x.SelectNodes('//system.webServer/handlers/add')) + @($x.SelectNodes('//system.webServer/modules/add'))) {
                $t = [string]$n.GetAttribute('type')
                if ($t -and $t -notmatch 'AspNetCoreModule') { return 'AspNetFramework' }
                if (([string]$n.GetAttribute('path')) -match '\.(aspx|asmx|ashx|axd)$') { return 'AspNetFramework' }
            }
            if ($x.SelectSingleNode('//runtime/assemblyBinding') -or
                $x.SelectSingleNode('//system.web.extensions') -or
                $x.SelectSingleNode('//system.serviceModel')) { return 'AspNetFramework' }
        } catch { return 'Unknown' }
    }

    # No decisive web.config evidence. Probe the app root - non-recursive, one level only.
    try {
        if (-not [System.IO.Directory]::Exists($PhysicalPath)) { return 'NonDotNet' }
        foreach ($pat in @('Global.asax','*.aspx','*.asmx','*.ashx')) {
            if (@([System.IO.Directory]::EnumerateFiles($PhysicalPath, $pat, [System.IO.SearchOption]::TopDirectoryOnly) | Select-Object -First 1).Count -gt 0) {
                return 'AspNetFramework'
            }
        }
        # Managed assemblies with nothing wiring them to a pipeline. NOT promoted to Framework:
        # static sites carry stray bin folders and an out-of-process Core publish puts DLLs in
        # the app root. Ambiguous is the honest answer.
        $bin = Join-Path $PhysicalPath 'bin'
        if ([System.IO.Directory]::Exists($bin) -and
            @([System.IO.Directory]::EnumerateFiles($bin, '*.dll', [System.IO.SearchOption]::TopDirectoryOnly) | Select-Object -First 1).Count -gt 0) {
            return 'Unknown'
        }
        if (@([System.IO.Directory]::EnumerateFiles($PhysicalPath, '*.runtimeconfig.json', [System.IO.SearchOption]::TopDirectoryOnly) | Select-Object -First 1).Count -gt 0) {
            return 'Unknown'
        }
    } catch { return 'Unknown' }

    return 'NonDotNet'
}

$iisRecords  = @()
$iisPresent  = $false   # IIS is installed on this host
$iisExpected = $false   # IIS is installed AND should have yielded names

if ($SkipIis) {
    Write-Step -Stage 'iis' -Level 'INFO' -Message '-SkipIis: IIS enumeration skipped'
} else {
    $w3svc = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
    if (-not $w3svc) {
        Write-Step -Stage 'iis' -Level 'INFO' -Message 'IIS not present (no W3SVC service) - nothing to enumerate' `
            -Cause 'the World Wide Web Publishing Service is not installed on this host' `
            -Fix   'expected on a Node-only host; if this host is supposed to run IIS, install the Web-Server role'
    } else {
        $iisPresent = $true
        Write-Step -Stage 'iis' -Level 'OK' -Message "W3SVC present, status=$($w3svc.Status)"
        if ($w3svc.Status -ne 'Running') {
            Write-Step -Stage 'iis' -Level 'WARN' -Message 'W3SVC is not Running' `
                -Cause 'IIS configuration is still readable while stopped, so names can still be derived, but no IIS telemetry is being produced' `
                -Fix   'Start-Service W3SVC'
        }

        $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
        if (-not (Test-Path -LiteralPath $appcmd)) {
            Write-Step -Stage 'iis' -Level 'WARN' -Message 'appcmd.exe not found' `
                -Cause 'the IIS management tools feature (Web-Mgmt-Console / IIS management scripts) is not installed' `
                -Fix   'Install-WindowsFeature Web-Scripting-Tools   (the WebAdministration module ships with it)'
        }

        $modOk = $false
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $modOk = $true
            Write-Step -Stage 'iis' -Level 'OK' -Message 'WebAdministration module loaded'
        } catch {
            Write-Step -Stage 'iis' -Level 'FAIL' -Message 'cannot load the WebAdministration module' `
                -Cause $_.Exception.Message `
                -Fix   'Install-WindowsFeature Web-Scripting-Tools, then re-run (elevated, Windows PowerShell 5.1)'
        }

        if ($modOk) {
            $sites = @()
            try {
                $sites = @(Get-Website)
            } catch {
                Write-Step -Stage 'iis' -Level 'FAIL' -Message 'Get-Website failed' `
                    -Cause $_.Exception.Message `
                    -Fix   'verify applicationHost.config is readable and not corrupt: %windir%\System32\inetsrv\config\applicationHost.config'
            }

            if ($sites.Count -eq 0) {
                Write-Step -Stage 'iis' -Level 'WARN' -Message 'IIS is installed but has no sites' `
                    -Cause 'no site is defined in applicationHost.config, so there is no service name to derive' `
                    -Fix   'create the site(s), or pass -SkipIis if this host is intentionally IIS-less'
            } else {
                $iisExpected = $true
                foreach ($site in $sites) {
                    $siteName = [string]$site.Name

                    # Root application (virtual path '/') IS the site; Get-WebApplication returns
                    # only the non-root applications.
                    $rootPhys = ''
                    try { $rootPhys = [Environment]::ExpandEnvironmentVariables([string]$site.physicalPath) } catch {}
                    $iisRecords += [pscustomobject]@{
                        Site         = $siteName
                        AppPath      = '/'
                        Pool         = [string]$site.applicationPool
                        ServiceName  = $siteName
                        State        = [string]$site.State
                        PhysicalPath = $rootPhys
                        Runtime      = (Get-CxStandaloneAppRuntime -PhysicalPath $rootPhys)
                    }

                    $apps = @()
                    try {
                        $apps = @(Get-WebApplication -Site $siteName)
                    } catch {
                        Write-Step -Stage 'iis' -Level 'WARN' -Message "could not enumerate applications under site '$siteName'" `
                            -Cause $_.Exception.Message `
                            -Fix   'nested applications of this site will be missing from the label set; check the site configuration'
                    }
                    foreach ($app in $apps) {
                        $appPath = [string]$app.path            # e.g. '/api'
                        $phys    = [string]$app.PhysicalPath
                        if (-not $phys) {
                            $vdir = Get-WebVirtualDirectory -Site $siteName -Application $appPath.TrimStart('/') -Name '/' -ErrorAction SilentlyContinue
                            if ($vdir) { $phys = [string]$vdir.PhysicalPath }
                        }
                        try { $phys = [Environment]::ExpandEnvironmentVariables($phys) } catch {}
                        $iisRecords += [pscustomobject]@{
                            Site         = $siteName
                            AppPath      = $appPath
                            Pool         = [string]$app.applicationPool
                            ServiceName  = "$siteName$appPath"   # 'Wallet' + '/api' -> 'Wallet/api'
                            State        = [string]$site.State
                            PhysicalPath = $phys
                            Runtime      = (Get-CxStandaloneAppRuntime -PhysicalPath $phys)
                        }
                    }
                }

                # Overrides are keyed by the auto-derived name, applied after auto-naming.
                foreach ($r in $iisRecords) {
                    if ($overrides.ContainsKey($r.ServiceName)) {
                        $old = $r.ServiceName
                        $r.ServiceName = [string]$overrides[$old]
                        Write-Step -Stage 'iis' -Level 'INFO' -Message "override: '$old' -> '$($r.ServiceName)'"
                    }
                }

                Write-Step -Stage 'iis' -Level 'OK' -Message "$($iisRecords.Count) IIS application(s) across $($sites.Count) site(s)"
                Write-Detail ("{0,-28} {1,-12} {2,-22} {3,-10} {4,-16} {5}" -f 'SITE','APPPATH','POOL','STATE','RUNTIME','SERVICENAME')
                foreach ($r in $iisRecords) {
                    Write-Detail ("{0,-28} {1,-12} {2,-22} {3,-10} {4,-16} {5}" -f $r.Site, $r.AppPath, $r.Pool, $r.State, $r.Runtime, $r.ServiceName)
                }

                $notDotNet = @($iisRecords | Where-Object { @('AspNetCore','AspNetFramework') -notcontains $_.Runtime })
                if ($notDotNet.Count -gt 0) {
                    Write-Step -Stage 'iis' -Level 'INFO' -Message "$($notDotNet.Count) application(s) excluded from the label: $(@($notDotNet | ForEach-Object { "$($_.ServiceName)[$($_.Runtime)]" }) -join ', ')" `
                        -Cause 'CX_IIS_SERVICES advertises OpenTelemetry SERVICES, and .NET auto-instrumentation produces none for a static, native, PHP/Node, reverse-proxied or undeterminable app - claiming one would point Service ownership at telemetry that never arrives' `
                        -Fix   'no action needed for static or proxied sites; if one of these IS a .NET app the detection missed, give it a web.config that declares <aspNetCore> or classic <system.web>'
                }

                foreach ($r in $iisRecords) {
                    if (-not (Test-NameSafe $r.ServiceName)) {
                        Write-Step -Stage 'iis' -Level 'FAIL' -Message "service name '$($r.ServiceName)' contains a comma or a double quote" `
                            -Cause 'the collector splits CX_IIS_SERVICES on "," inside a double-quoted OTTL literal, so this name would mis-split or break the config' `
                            -Fix   "rename the IIS site/app path, or map it with -ServiceNameOverrides @{ '$($r.ServiceName)' = 'safe-name' }"
                    }
                }
                $stopped = @($iisRecords | Where-Object { $_.State -and $_.State -ne 'Started' })
                if ($stopped.Count -gt 0) {
                    Write-Step -Stage 'iis' -Level 'INFO' -Message "$($stopped.Count) application(s) belong to a stopped site - still labelled" `
                        -Cause 'ownership is derived from configuration, not from live traffic' `
                        -Fix   'no action needed unless the site should be running'
                }
            }
        }
    }
}

# INSTRUMENTABLE apps only. Same membership rule as Instrument-IIS.ps1 and Test-Agent.ps1: a
# name belongs in CX_IIS_SERVICES only if something actually reports under it. Including the
# rest is what made this tool undo the installer's fix when it was run afterwards.
$iisNames = @($iisRecords |
    Where-Object { @('AspNetCore','AspNetFramework') -contains $_.Runtime } |
    ForEach-Object { $_.ServiceName } | Where-Object { $_ })

# ---------------------------------------------------------------------------------------------
# Stage 2 - Node / PM2 discovery
# ---------------------------------------------------------------------------------------------

function Get-PM2ProcessList {
    <#
      One object per PM2 process: @{ Name; Pid; ExecMode; Status }. Cluster workers repeat Name.

      `pm2 jlist` emits JSON with DUPLICATE keys and Windows PowerShell 5.1's ConvertFrom-Json
      throws DuplicateKeysInJsonString on it - so this deliberately does NOT use ConvertFrom-Json.
      The array is split into per-process chunks (each top-level object starts with '{"pid":')
      and the fields are pulled by regex. The top-level "name" is the one right after the pid.
      Same approach as deploy\Resolve-NodeServiceNames.ps1.
    #>
    param([ref] $Reason, [int] $TimeoutSec = 60)
    $Reason.Value = ''
    $ErrorActionPreference = 'Continue'

    if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
        $Reason.Value = 'pm2 is not on PATH'
        return @()
    }

    # Is the God daemon up? `pm2 jlist` would SPAWN it when it is not - unacceptable twice over:
    # a read-only diagnostic must not start a background daemon, and the daemon it spawns inherits
    # the console pipe, which hangs the caller (reproducible under docker exec). Detect the daemon
    # by its command line instead, and report its absence rather than fixing it.
    $daemonUp = $false
    try {
        $daemonUp = [bool](@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
                             Where-Object { $_.CommandLine -match 'pm2' -and $_.CommandLine -match 'Daemon|God' }).Count)
    } catch {
        # CIM unavailable: fall back to assuming it is up and let the bounded call below decide.
        $daemonUp = $true
    }
    if (-not $daemonUp) {
        $Reason.Value = 'the PM2 God daemon is not running (no matching node.exe process); not starting it - a diagnostic must not spawn daemons'
        return @()
    }
    # Bounded call. `pm2 jlist` has to spawn the God daemon when it is not running, and that can
    # block indefinitely if the spawned daemon inherits the console pipe (reliably reproducible
    # inside a Windows container). A diagnostic must report that, not hang on it.
    # Invoked through cmd.exe because `pm2` on PATH is usually pm2.ps1/pm2.cmd, and Start-Process
    # cannot launch a .ps1 directly; cmd resolves the right shim itself.
    $raw = ''
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList '/c','pm2','jlist' -NoNewWindow -PassThru `
                              -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            $Reason.Value = "pm2 jlist did not return within ${TimeoutSec}s (killed); the PM2 daemon is likely wedged or being spawned"
            return @()
        }
        $raw = ([string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)).Trim()
    } catch {
        $Reason.Value = $_.Exception.Message
        return @()
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $raw) {
        $Reason.Value = 'pm2 jlist produced no output'
        return @()
    }
    if (-not $raw.StartsWith('[')) {
        $Reason.Value = "pm2 jlist did not return a JSON array (first 60 chars: '$($raw.Substring(0, [Math]::Min(60, $raw.Length)))')"
        return @()
    }

    # Plain array via foreach - do NOT use Generic.List here: PS 5.1 throws "Argument types do not
    # match" when such a list is later wrapped with @(...).
    $out = foreach ($chunk in ($raw -split '\{"pid":')) {
        if ($chunk -notmatch '^\s*\d') { continue }
        $procPid = $null; $name = $null; $mode = $null; $status = $null
        if ($chunk -match '^\s*(\d+)')                  { $procPid = [int]$matches[1] }
        if ($chunk -match '"name"\s*:\s*"([^"]*)"')     { $name    = $matches[1] }
        if ($chunk -match '"exec_mode"\s*:\s*"([^"]*)"'){ $mode    = $matches[1] }
        if ($chunk -match '"status"\s*:\s*"([^"]*)"')   { $status  = $matches[1] }
        if (-not $name) { continue }
        [pscustomobject]@{ Name = $name; Pid = $procPid; ExecMode = $mode; Status = $status }
    }
    return @($out)
}

$nodeRecords  = @()
$nodePresent  = $false
$nodeExpected = $false

if ($SkipNode) {
    Write-Step -Stage 'node' -Level 'INFO' -Message '-SkipNode: PM2 enumeration skipped'
} else {
    $pm2Cmd = Get-Command pm2 -ErrorAction SilentlyContinue
    if (-not $pm2Cmd) {
        Write-Step -Stage 'node' -Level 'INFO' -Message 'PM2 not present (pm2 not on PATH) - nothing to enumerate' `
            -Cause 'the pm2 CLI could not be resolved for this user' `
            -Fix   'expected on an IIS-only host; if this host runs Node under PM2, ensure the npm global prefix is on PATH for THIS user'
    } else {
        $nodePresent = $true
        Write-Step -Stage 'node' -Level 'OK' -Message "pm2 found: $($pm2Cmd.Source)"

        $reason = ''
        $procs  = Get-PM2ProcessList -Reason ([ref]$reason)

        if ($procs.Count -eq 0) {
            Write-Step -Stage 'node' -Level 'WARN' -Message 'pm2 reported no managed apps' `
                -Cause "$(if ($reason) { $reason } else { 'the daemon returned an empty list' }); note PM2 is PER-USER on Windows - this script sees only the daemon owned by $($identity.Name)" `
                -Fix   "run 'pm2 list' as the account that owns the apps (often a service account, not SYSTEM/Administrator) and re-run this script as that same user"
        } else {
            # Collapse cluster workers: one record per app name, instance tally kept.
            $byName = New-Object System.Collections.Specialized.OrderedDictionary
            foreach ($p in $procs) {
                $n = [string]$p.Name
                if (-not $n) { continue }
                if ($byName.Contains($n)) { $byName[$n].Instances++; continue }
                $byName.Add($n, [pscustomobject]@{
                    Name        = $n
                    ServiceName = $n
                    ExecMode    = [string]$p.ExecMode
                    Instances   = 1
                    Status      = [string]$p.Status
                })
            }
            foreach ($k in $byName.Keys) { $nodeRecords += $byName[$k] }
            $nodeExpected = $true

            foreach ($r in $nodeRecords) {
                if ($overrides.ContainsKey($r.ServiceName)) {
                    $old = $r.ServiceName
                    $r.ServiceName = [string]$overrides[$old]
                    Write-Step -Stage 'node' -Level 'INFO' -Message "override: '$old' -> '$($r.ServiceName)'"
                }
            }

            Write-Step -Stage 'node' -Level 'OK' -Message "$($nodeRecords.Count) PM2 app(s) from $($procs.Count) process(es)"
            Write-Detail ("{0,-24} {1,-14} {2,-10} {3,-10} {4}" -f 'NAME','EXECMODE','INSTANCES','STATUS','SERVICENAME')
            foreach ($r in $nodeRecords) {
                Write-Detail ("{0,-24} {1,-14} {2,-10} {3,-10} {4}" -f $r.Name, $r.ExecMode, $r.Instances, $r.Status, $r.ServiceName)
            }

            foreach ($r in $nodeRecords) {
                if (-not (Test-NameSafe $r.ServiceName)) {
                    Write-Step -Stage 'node' -Level 'FAIL' -Message "service name '$($r.ServiceName)' contains a comma or a double quote" `
                        -Cause 'the collector splits the label value on "," inside a double-quoted OTTL literal, so this name would mis-split or break the config' `
                        -Fix   "rename the PM2 app, or map it with -ServiceNameOverrides @{ '$($r.ServiceName)' = 'safe-name' }"
                }
            }
            $stoppedApps = @($nodeRecords | Where-Object { $_.Status -and $_.Status -ne 'online' })
            if ($stoppedApps.Count -gt 0) {
                Write-Step -Stage 'node' -Level 'WARN' -Message "$($stoppedApps.Count) PM2 app(s) not online" `
                    -Cause 'a stopped/errored app still contributes its name to the label set but produces no APM telemetry, so ownership would point at a service with no spans' `
                    -Fix   "pm2 restart <name> --update-env, or pm2 delete <name> if it is retired"
            }
        }
    }
}

$nodeNames = @($nodeRecords | ForEach-Object { $_.ServiceName } | Where-Object { $_ })

# ---------------------------------------------------------------------------------------------
# Stage 3 - compose desired values and compare
# ---------------------------------------------------------------------------------------------

$desiredIis  = if ($NoUnion) { Join-DistinctNames -Names $iisNames }
               else          { Join-DistinctNames -Names (@($iisNames) + @($nodeNames)) }
$desiredNode = Join-DistinctNames -Names $nodeNames

if ($NoUnion) {
    Write-Step -Stage 'compose' -Level 'INFO' -Message '-NoUnion: CX_IIS_SERVICES carries IIS names only (deploy-script parity)'
} else {
    Write-Step -Stage 'compose' -Level 'INFO' -Message "union mode: CX_IIS_SERVICES = $($iisNames.Count) IIS name(s) + $($nodeNames.Count) Node name(s)" `
        -Cause 'no collector YAML reads CX_NODE_SERVICES, so Node names only reach Coralogix through CX_IIS_SERVICES' `
        -Fix   'pass -NoUnion to keep the sets separate once the collector config gains a CX_NODE_SERVICES statement'
}

function Get-ChangeVerdict {
    param([string] $Current, [string] $Desired)
    $c = if ($null -eq $Current) { '' } else { $Current }
    $d = if ($null -eq $Desired) { '' } else { $Desired }
    if ($c -ceq $d)                     { return 'UNCHANGED' }
    if ($c -eq '' -and $d -ne '')       { return 'WILL SET' }
    if ($c -ne '' -and $d -eq '')       { return 'WILL CLEAR' }
    return 'WILL CHANGE'
}

$verdictIis  = Get-ChangeVerdict -Current $curIisMachine  -Desired $desiredIis
$verdictNode = Get-ChangeVerdict -Current $curNodeMachine -Desired $desiredNode

Write-Step -Stage 'compose' -Level 'INFO' -Message "CX_IIS_SERVICES  : $verdictIis"
Write-Detail ("current: {0}" -f (Format-EnvValue $curIisMachine))
Write-Detail ("desired: {0}" -f (Format-EnvValue $desiredIis))
Write-Step -Stage 'compose' -Level 'INFO' -Message "CX_NODE_SERVICES : $verdictNode"
Write-Detail ("current: {0}" -f (Format-EnvValue $curNodeMachine))
Write-Detail ("desired: {0}" -f (Format-EnvValue $desiredNode))

# An empty result is only a failure when a workload WAS present and should have produced names.
if ($desiredIis -eq '' -and ($iisExpected -or $nodeExpected)) {
    Write-Step -Stage 'compose' -Level 'FAIL' -Message 'workloads were found but the label value is empty' `
        -Cause 'every discovered service name was blank or filtered out' `
        -Fix   'check the IIS/PM2 tables above; this is the bug that leaves a busy host with no Service ownership'
} elseif ($desiredIis -eq '') {
    Write-Step -Stage 'compose' -Level 'INFO' -Message 'no IIS or PM2 workloads on this host - the label value is legitimately empty' `
        -Cause 'neither IIS sites nor PM2 apps were discovered' `
        -Fix   'nothing to do; the collector guard leaves the ownership attributes unset'
}

# ---------------------------------------------------------------------------------------------
# Stage 4 - apply
# ---------------------------------------------------------------------------------------------

function Set-MachineEnv {
    <#
      Write a machine-scope variable and mirror it into this process, matching the deploy scripts.
      An empty desired value is written as $null, i.e. the variable is REMOVED (same as the
      stale-clear branch in deploy\Instrument-IIS.ps1) - leaving an empty string behind would
      still satisfy the collector's '!= ""' guard on some versions.
    #>
    param([string] $Name, [string] $Value)
    $toWrite = if ([string]::IsNullOrEmpty($Value)) { $null } else { $Value }
    [Environment]::SetEnvironmentVariable($Name, $toWrite, 'Machine')
    # Mirror into this process via the same API - Set-Item Env:<name> rejects an empty string,
    # so it cannot express "remove the variable".
    [Environment]::SetEnvironmentVariable($Name, $toWrite, 'Process')
}

$changedAny = $false

foreach ($item in @(
    @{ Name = 'CX_IIS_SERVICES';  Desired = $desiredIis;  Current = $curIisMachine;  Verdict = $verdictIis  },
    @{ Name = 'CX_NODE_SERVICES'; Desired = $desiredNode; Current = $curNodeMachine; Verdict = $verdictNode }
)) {
    if ($item.Verdict -eq 'UNCHANGED') {
        Write-Step -Stage 'apply' -Level 'OK' -Message "$($item.Name) already correct - no write"
        continue
    }
    if (-not $Apply) {
        Write-Step -Stage 'apply' -Level 'DRYRUN' -Message "would set $($item.Name)=$(Format-EnvValue $item.Desired)  (was: $(Format-EnvValue $item.Current))"
        continue
    }
    try {
        Set-MachineEnv -Name $item.Name -Value $item.Desired
        $changedAny = $true
        Write-Step -Stage 'apply' -Level 'APPLY' -Message "$($item.Name)=$(Format-EnvValue $item.Desired)  (was: $(Format-EnvValue $item.Current))"
    } catch {
        Write-Step -Stage 'apply' -Level 'FAIL' -Message "could not write $($item.Name)" `
            -Cause $_.Exception.Message `
            -Fix   'confirm the shell is elevated and that group policy is not locking HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    }
}

if (-not $Apply) {
    Write-Step -Stage 'apply' -Level 'INFO' -Message 'dry-run: nothing was written' `
        -Cause 'the -Apply switch was not supplied' `
        -Fix   're-run with -Apply once the values above look right'
}

# ---------------------------------------------------------------------------------------------
# Stage 5 - verify
# ---------------------------------------------------------------------------------------------

# 5a. Read the machine values back - catches a write that silently did not land.
$afterIis  = [Environment]::GetEnvironmentVariable('CX_IIS_SERVICES',  'Machine')
$afterNode = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')

if ($Apply) {
    foreach ($chk in @(
        @{ Name = 'CX_IIS_SERVICES';  Actual = $afterIis;  Want = $desiredIis  },
        @{ Name = 'CX_NODE_SERVICES'; Actual = $afterNode; Want = $desiredNode }
    )) {
        $actual = if ($null -eq $chk.Actual) { '' } else { $chk.Actual }
        if ($actual -ceq $chk.Want) {
            Write-Step -Stage 'verify' -Level 'OK' -Message "$($chk.Name) readback matches: $(Format-EnvValue $actual)"
        } else {
            Write-Step -Stage 'verify' -Level 'FAIL' -Message "$($chk.Name) readback is '$(Format-EnvValue $actual)', expected '$(Format-EnvValue $chk.Want)'" `
                -Cause 'the machine-scope write did not take effect' `
                -Fix   'check for a policy/registry restriction on the Session Manager\Environment key, or another process rewriting the variable'
        }
    }
} else {
    Write-Step -Stage 'verify' -Level 'INFO' -Message "machine values unchanged by this run: CX_IIS_SERVICES=$(Format-EnvValue $afterIis)"
}

# 5b. Collector process staleness. A process reads the machine environment ONCE, at start; a
# collector started before the write keeps stamping the old value. Probe services first, then
# bare processes - in the docker-win test image the collector is a foreground child process, not
# a Windows service, and the same is true of any manually-launched collector.
$collectorNames = @('opampsupervisor','otelcol-contrib')
$collectorFound = @()

foreach ($n in $collectorNames) {
    $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($svc) {
        $svcPid = $null
        try { $svcPid = (Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction Stop).ProcessId } catch { }
        $collectorFound += [pscustomobject]@{ Name = $n; Kind = 'service'; Status = [string]$svc.Status; Pid = $svcPid }
        continue
    }
    foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
        $collectorFound += [pscustomobject]@{ Name = $n; Kind = 'process'; Status = 'Running'; Pid = $p.Id }
    }
}

if ($collectorFound.Count -eq 0) {
    Write-Step -Stage 'verify' -Level 'INFO' -Message 'no collector service or process found on this host' `
        -Cause 'neither opampsupervisor nor otelcol-contrib is installed or running' `
        -Fix   'the label is set for whenever the collector starts; install it with deploy\Install-CoralogixSupervisor.ps1 if it is missing'
} else {
    $envKeyTime = Get-EnvKeyLastWriteTime
    if ($envKeyTime) {
        Write-Step -Stage 'verify' -Level 'INFO' -Message "environment registry key last written $($envKeyTime.ToString('u')) (method: RegQueryInfoKey)"
    } else {
        Write-Step -Stage 'verify' -Level 'INFO' -Message 'registry last-write time unavailable (method: changed-this-run heuristic)' `
            -Cause 'RegQueryInfoKey could not be called on this host' `
            -Fix   'staleness below is inferred from whether this run changed a value; restart the collector if in doubt'
    }

    foreach ($c in $collectorFound) {
        if ($c.Status -ne 'Running' -and $c.Kind -eq 'service') {
            Write-Step -Stage 'verify' -Level 'WARN' -Message "$($c.Name) ($($c.Kind)) is $($c.Status)" `
                -Cause 'a stopped collector stamps nothing at all' `
                -Fix   "Start-Service $($c.Name)"
            continue
        }

        $startTime = $null
        if ($c.Pid) { try { $startTime = (Get-Process -Id $c.Pid -ErrorAction Stop).StartTime } catch { } }

        $stale = $null
        if ($startTime -and $envKeyTime) { $stale = ($startTime -lt $envKeyTime) }
        elseif ($changedAny)             { $stale = $true }

        if ($stale -eq $true) {
            $fix = if ($c.Kind -eq 'service') { "Restart-Service $($c.Name) -Force" }
                   else                       { "restart the $($c.Name) process (PID $($c.Pid)) so it re-reads the machine environment" }
            Write-Step -Stage 'verify' -Level 'WARN' -Message "$($c.Name) ($($c.Kind), PID $($c.Pid)) is STALE - started $(if ($startTime) { $startTime.ToString('u') } else { 'unknown' })" `
                -Cause 'the process started before the environment variable was last written, so it still holds the OLD value and keeps stamping it' `
                -Fix   $fix
        } elseif ($stale -eq $false) {
            Write-Step -Stage 'verify' -Level 'OK' -Message "$($c.Name) ($($c.Kind), PID $($c.Pid)) started $($startTime.ToString('u')) - after the last environment change, value is current"
        } else {
            Write-Step -Stage 'verify' -Level 'WARN' -Message "$($c.Name) ($($c.Kind), PID $($c.Pid)) staleness unknown" `
                -Cause 'neither the process start time nor the registry timestamp could be read' `
                -Fix   'restart the collector anyway if the label is not appearing in Coralogix'
        }
    }

    # 5c. Restart on request.
    if ($Apply -and $RestartCollector -and $changedAny) {
        foreach ($c in $collectorFound) {
            if ($c.Kind -ne 'service') {
                Write-Step -Stage 'verify' -Level 'WARN' -Message "$($c.Name) runs as a bare process (PID $($c.Pid)) - not restarted automatically" `
                    -Cause 'this script only restarts Windows services; killing an arbitrary process could take down whatever supervises it' `
                    -Fix   'restart it by the means that started it (container entrypoint, scheduled task, console session)'
                continue
            }
            try {
                Restart-Service -Name $c.Name -Force -ErrorAction Stop
                Write-Step -Stage 'verify' -Level 'APPLY' -Message "restarted service $($c.Name) - it now reads the new value"
            } catch {
                Write-Step -Stage 'verify' -Level 'FAIL' -Message "could not restart $($c.Name)" `
                    -Cause $_.Exception.Message `
                    -Fix   "restart it manually: Restart-Service $($c.Name) -Force"
            }
        }
    } elseif ($Apply -and -not $RestartCollector -and $changedAny) {
        Write-Step -Stage 'verify' -Level 'WARN' -Message 'collector NOT restarted (-RestartCollector:$false)' `
            -Cause 'the new value only reaches the collector when its process restarts' `
            -Fix   'Restart-Service opampsupervisor -Force   (or otelcol-contrib) during your maintenance window'
    }
}

# 5d. Does the collector configuration on this host actually consume the variable?
# Covers all four shapes this fleet uses: the supervisor's base + effective config, the
# local-mode collector config dir, the legacy C:\otel staging dir, and the container/test layout.
# See misc\installation.md "Install locations & service" for where each one comes from.
$configRoots = @(
    'C:\Program Files\OpenTelemetry OpAMP Supervisor',   # base collector.yaml (supervisor mode)
    'C:\ProgramData\opampsupervisor',                    # state\effective.yaml (merged remote config)
    'C:\Program Files\OpenTelemetry Collector',
    'C:\ProgramData\OpenTelemetry\Collector',            # local-mode service config
    'C:\otel',
    'C:\cx'
)
$configFiles = @()
foreach ($root in $configRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
        # -Depth 3 on purpose: every real config sits within three levels of these roots
        # (e.g. ...\opampsupervisor\state\effective.yaml), while an unbounded recurse would walk
        # node_modules trees under a shared root and stall the diagnostic.
        $configFiles += @(Get-ChildItem -LiteralPath $root -Recurse -Depth 3 -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
                          Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
                          Select-Object -First 40)
    } catch { }
}
$configFiles = @($configFiles | Sort-Object FullName -Unique)

if ($configFiles.Count -eq 0) {
    Write-Step -Stage 'config' -Level 'WARN' -Message 'no collector YAML found in the usual locations' `
        -Cause "searched $($configRoots -join ', '); in supervisor mode the effective config is pulled from remote Fleet Management, so a local file may legitimately be absent" `
        -Fix   'verify in the Coralogix Fleet Management UI that the assigned config contains the transform/iis_service_labels processor (reference template: deploy\config.supervisor.yaml)'
} else {
    $refIis  = @()
    $refNode = @()
    $logOnly = @()
    foreach ($f in $configFiles) {
        $text = ''
        try { $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
        if ($text -match 'CX_IIS_SERVICES') {
            $refIis += $f.FullName
            # Scope the statement-kind check to the transform/iis_service_labels BLOCK. A collector
            # config has many transform processors; testing the whole file would see another
            # processor's trace_statements/metric_statements and wrongly conclude spans are tagged.
            # The block runs from its key to the next 2-space-indented key (or end of file).
            $blockMatch = [regex]::Match($text, '(?ms)^\s{2}transform/iis_service_labels:\s*$.*?(?=^\s{2}\S|\z)')
            if ($blockMatch.Success) {
                # Drop comment lines: a comment inside the block may name statement kinds it does
                # not actually define (the reference template's own comment does exactly that).
                $block = ($blockMatch.Value -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                if (($block -match 'log_statements') -and -not ($block -match 'trace_statements') -and -not ($block -match 'metric_statements')) {
                    $logOnly += $f.FullName
                }
            }
        }
        if ($text -match 'CX_NODE_SERVICES') { $refNode += $f.FullName }
    }

    if ($refIis.Count -eq 0) {
        # Severity depends on whether a collector is actually running here. With one running, a
        # config that never reads CX_IIS_SERVICES is a genuine break (exit 1). With no collector
        # at all, the YAMLs found are most likely stale leftovers and must not fail the run -
        # otherwise every not-yet-instrumented host reports a false failure.
        if ($collectorFound.Count -gt 0) {
            Write-Step -Stage 'config' -Level 'FAIL' -Message "found $($configFiles.Count) collector YAML file(s), none references CX_IIS_SERVICES" `
                -Cause 'a collector is running but no config it could be using stamps the label, so the variable is set and never reaches telemetry' `
                -Fix   'add the transform/iis_service_labels processor from deploy\config.supervisor.yaml to the config this host actually uses (local base config, or the remote Fleet config)'
        } else {
            Write-Step -Stage 'config' -Level 'WARN' -Message "found $($configFiles.Count) collector YAML file(s), none references CX_IIS_SERVICES" `
                -Cause 'no collector is installed or running on this host, so these files are probably stale leftovers rather than the config that will be used' `
                -Fix   'when the collector is installed, make sure its config (local base or remote Fleet) carries the transform/iis_service_labels processor from deploy\config.supervisor.yaml'
        }
    } else {
        Write-Step -Stage 'config' -Level 'OK' -Message "CX_IIS_SERVICES referenced by $($refIis.Count) config file(s)"
        foreach ($p in $refIis) { Write-Detail $p }
        if ($logOnly.Count -gt 0) {
            Write-Step -Stage 'config' -Level 'INFO' -Message 'the transform defines log_statements only' `
                -Cause 'the processor is wired into the logs / logs-resource_catalog pipelines, which is what drives Infrastructure-Explorer Service ownership; spans and metrics are not tagged' `
                -Fix   'expected with the current template - add trace_statements / metric_statements only if you also want the labels on APM spans and metrics'
        }
    }

    if ($nodeNames.Count -gt 0 -and $refNode.Count -eq 0) {
        Write-Step -Stage 'config' -Level 'WARN' -Message 'no collector config references CX_NODE_SERVICES' `
            -Cause 'CX_NODE_SERVICES is written for forward-compatibility only; nothing consumes it today' `
            -Fix   "$(if ($NoUnion) { 'this host runs PM2 apps and -NoUnion was used, so Node services will NOT appear as host ownership - drop -NoUnion, or add a CX_NODE_SERVICES statement to the collector config' } else { 'no action - the union already carries the Node names in CX_IIS_SERVICES' })"
    }
}

# 5e. Workload restart reminders - explicitly scoped so nobody recycles IIS for no reason.
if ($iisPresent) {
    $w3 = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
    Write-Step -Stage 'verify' -Level 'INFO' -Message "W3SVC status: $(if ($w3) { $w3.Status } else { 'absent' })" `
        -Cause 'CX_IIS_SERVICES is read by the COLLECTOR, not by IIS' `
        -Fix   'no iisreset is needed for this label; recycle IIS only when per-app OTEL_SERVICE_NAME changes (that is deploy\Instrument-IIS.ps1 territory)'
}
if ($nodeRecords.Count -gt 0) {
    Write-Step -Stage 'verify' -Level 'INFO' -Message "$($nodeRecords.Count) PM2 app(s) untouched by this script" `
        -Cause 'CX_NODE_SERVICES / CX_IIS_SERVICES are read by the COLLECTOR, not by the Node apps' `
        -Fix   'no pm2 restart is needed for this label; use deploy\Instrument-NodePM2.ps1 to change per-app OTEL_SERVICE_NAME'
}

# ---------------------------------------------------------------------------------------------
# Stage 6 - summary
# ---------------------------------------------------------------------------------------------

$elapsed = (Get-Date) - $script:StartedAt
Write-Host ''
Write-Host '=== summary ===' -ForegroundColor Cyan
Write-Log  '=== summary ==='

$summary = @(
    "mode              : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN' })",
    "iis services      : $(if ($iisNames.Count)  { $iisNames  -join ', ' } else { '<none>' })",
    "node services     : $(if ($nodeNames.Count) { $nodeNames -join ', ' } else { '<none>' })",
    "CX_IIS_SERVICES   : $(Format-EnvValue $afterIis)   [$verdictIis]",
    "CX_NODE_SERVICES  : $(Format-EnvValue $afterNode)   [$verdictNode]",
    "counts            : OK=$($script:Counts.OK) INFO=$($script:Counts.INFO) DRYRUN=$($script:Counts.DRYRUN) APPLY=$($script:Counts.APPLY) WARN=$($script:Counts.WARN) FAIL=$($script:Counts.FAIL)",
    "elapsed           : $([int]$elapsed.TotalSeconds)s",
    "log               : $LogPath"
)
foreach ($s in $summary) { Write-Host "  $s"; Write-Log "  $s" }

$exitCode = if ($script:Counts.FAIL -gt 0) { 1 } else { 0 }
Write-Host ''
if ($exitCode -eq 0) { Write-Host 'RESULT: OK'     -ForegroundColor Green }
else                 { Write-Host 'RESULT: FAILED' -ForegroundColor Red }
Write-Log "RESULT: $(if ($exitCode -eq 0) { 'OK' } else { 'FAILED' }) (exit $exitCode)"

exit $exitCode
