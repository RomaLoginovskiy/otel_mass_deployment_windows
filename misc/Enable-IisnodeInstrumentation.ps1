<#
.SYNOPSIS
  Turn on zero-code OpenTelemetry for iisnode applications - Node hosted BY IIS - on a host that
  is ALREADY deployed, without re-running the full instrumenter.

.DESCRIPTION
  iisnode is a native IIS module that spawns node.exe as a CHILD OF W3WP. The only environment
  that reaches that child is the APP POOL's, which has two consequences that cost real time to
  work out on a live host:

    * Instrument-NodePM2.ps1 can never instrument such an app. PM2 does not manage it, so the app
      does not appear in `pm2 jlist` and no amount of `pm2 restart --update-env` touches it. On the
      host this script was written for, three apps that read as dark PM2 apps in the doctor output
      were iisnode pools all along - `pm2 describe` even answered for same-named PM2 entries.
    * Nothing about the .NET profiler applies. An iisnode app is frequently ALSO an ASP.NET
      Framework app in the same pool (managed modules for some paths, an iisnode handler for
      others); w3wp hosts the CLR and its node.exe child runs the JavaScript. They are two
      processes and two instrumentations.

  So the fix is per-pool environment variables plus a pool recycle. That is all this script does.

  It exists next to the deploy package rather than inside it because re-running
  Instrument-IIS.ps1 on a live host does considerably more than this: it replaces the .NET
  auto-instrumentation files under 'C:\Program Files\OpenTelemetry .NET AutoInstrumentation'
  (which are LOADED by w3wp), rewrites applicationPoolDefaults, republishes the IIS log slots and
  ends with an iisreset. Wanting the iisnode gap closed is not a reason to accept all of that.

  DELIBERATELY OUT OF SCOPE, and reported as such rather than silently skipped:
    * npm install. IIS hosts are frequently offline or proxy-bound; the package must already be
      staged (Instrument-NodePM2.ps1 stages it, or copy a prepared node_modules tree in).
    * PM2. Use Instrument-NodePM2.ps1.
    * The per-runtime label variables CX_IIS_SERVICES / CX_NODE_SERVICES. Deriving those is
      misc\Set-CxServiceLabels.ps1's job, and it owns that shape.
      NOT the same thing as CX_SERVICES: see -RefreshServiceLabels below. Instrumenting an
      application without adding it to the variable the collector reads produces a host that has
      spans in APM and claims no ownership for the service - which reads as a Coralogix problem.
    * The collector's CONFIG. It is restarted (so it re-reads the machine environment) when the
      label refresh runs, but nothing in its configuration is touched - the config is owned
      remotely by Fleet Management.
    * The .NET profiler. On a host running another APM agent this matters: the CLR loads exactly
      ONE ICorProfiler, so if something else already occupies that slot in w3wp, attaching a
      second is not double telemetry - it is a conflict. This script never touches those variables.

  NAMING RULES - byte-identical to deploy\Resolve-IISServiceNames.ps1 on purpose:
        root application of a site -> "<SiteName>"          e.g. "Wallet"
        application at /path       -> "<SiteName><path>"    e.g. "Wallet/api"
  If they drift, this script would "fix" a host into a name the real installer later overwrites,
  and the host would advertise a service that stops matching its own telemetry.

.PARAMETER Apply
  Perform the writes and (unless -Recycle:$false) recycle the affected pools. Without it this is a
  read-only report that prints every write it WOULD make.

.PARAMETER Recycle
  With -Apply, recycle each pool whose environment changed, so its node.exe children come back
  with the bootstrap. Default $true. Suppress with -Recycle:$false to apply in a maintenance
  window - but note that until the recycle happens the host reads as instrumented and emits
  nothing, which is the silent state this tooling exists to remove. NEVER runs iisreset: only pools
  whose BOOTSTRAP write succeeded are recycled. A pool whose NODE_OPTIONS write failed is left
  running and named in the report - restarting it would interrupt the request path and bring its
  node.exe children back just as unable to emit anything.

.PARAMETER RefreshServiceLabels
  With -Apply, add the instrumented application names to machine CX_NODE_SERVICES, republish
  CX_SERVICES (the union the collector actually reads for host Service ownership), and restart the
  collector so it re-reads them. Default $true. Suppress with -RefreshServiceLabels:$false to leave
  every machine variable alone and touch only the app pools.

  Only applications whose bootstrap actually reached their pool are published. A name published for
  an application that emits nothing is worse than no name: the host entity claims a service with no
  telemetry behind it while every variable involved still reads as correct.

  Why on by default: the collector's transform reads `${env:CX_SERVICES}`, not the per-runtime
  slices. An application instrumented without that update reports spans in APM while the HOST
  entity claims no ownership for it - and every variable involved still looks correct, so there is
  nothing to notice. The collector reads its environment at process start, hence the restart.

.PARAMETER Pools
  Only these app pools. This is the staged rollout: prove one app end to end, then widen. A
  recycle is a request-path restart, and restarting every Node app on a host because a script ran
  is not this script's decision to make.

.PARAMETER Apps
  Only these applications, by service name or by '<Site><path>' key (e.g. 'Wallet/api').

.PARAMETER InstallPrefix
  Where the OTel Node instrumentation package is staged. Default: C:\cx\otel-node - the same
  default as Instrument-NodePM2.ps1 -InstallPrefix, because it is the same package.

.PARAMETER OtlpEndpoint
  Local collector OTLP HTTP endpoint. Default http://127.0.0.1:4318.

  The IPv4 literal is deliberate. On a dual-stack host `localhost` resolves to ::1 first, the
  collector listens on IPv4, and the export is dropped with NO exporter error - the app looks
  instrumented and nothing arrives. A `localhost` value passed here is rewritten, not honored.

.PARAMETER ServiceNameOverrides
  Hashtable keyed by the auto-derived service name, value = replacement, e.g.
  @{ 'Wallet/api' = 'wallet-api' }. Same shape as the deploy scripts.

.PARAMETER OverridesJson
  Path to a JSON file of the same { autoName = overrideName } shape. Merged UNDER the hashtable.

.PARAMETER LogPath
  Log file. Default: <script dir>\Enable-IisnodeInstrumentation.<yyyyMMdd-HHmmss>.log

.OUTPUTS
  Exit code 0 = no failures, 1 = at least one FAIL, 2 = preflight abort (cannot run at all).

.EXAMPLE
  PS> .\Enable-IisnodeInstrumentation.ps1
  Read-only. Lists every iisnode application, its module system, and the exact writes it would make.

.EXAMPLE
  PS> .\Enable-IisnodeInstrumentation.ps1 -Apply -Pools synapse-dev-v2.betway
  Instruments one pool and recycles it. Verify telemetry by query, then widen.

.NOTES
  Windows PowerShell 5.1. Run elevated (applicationHost.config write + icacls + recycle).
  Copy this ONE file to a problem host; it degrades to its own applicationHost.config parsing when
  the deploy libraries are not next to it, and says which mode it ran in.
#>
[CmdletBinding()]
param(
    [switch]    $Apply,
    [bool]      $Recycle              = $true,
    [bool]      $RefreshServiceLabels = $true,
    [string[]]  $Pools,
    [string[]]  $Apps,
    [string]    $InstallPrefix        = 'C:\cx\otel-node',
    [string]    $OtlpEndpoint         = 'http://127.0.0.1:4318',
    [hashtable] $ServiceNameOverrides = @{},
    [string]    $OverridesJson,
    [string]    $LogPath
)

# 'Continue', deliberately: native commands (appcmd, icacls) write to stderr, which under 'Stop'
# becomes a terminating NativeCommandError in Windows PowerShell 5.1 and would abort a script whose
# whole job is to survive an imperfect host. Real failures are caught explicitly.
$ErrorActionPreference = 'Continue'

$script:Counts    = @{ OK = 0; INFO = 0; DRYRUN = 0; APPLY = 0; WARN = 0; FAIL = 0 }
$script:StartedAt = Get-Date
$script:Here      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $LogPath) {
    $LogPath = Join-Path $script:Here ("Enable-IisnodeInstrumentation.{0}.log" -f $script:StartedAt.ToString('yyyyMMdd-HHmmss'))
}

function Write-Log {
    param([string] $Text)
    try { Add-Content -LiteralPath $LogPath -Value $Text -Encoding utf8 } catch { }
}

function Write-Step {
    param(
        [ValidateSet('OK','INFO','DRYRUN','APPLY','WARN','FAIL')][string] $Level,
        [string] $Message,
        [string] $Fix
    )
    $script:Counts[$Level]++
    $color = switch ($Level) {
        'OK'     { 'Green' }  'APPLY' { 'Green' }
        'DRYRUN' { 'Cyan'  }  'INFO'  { 'Gray'  }
        'WARN'   { 'Yellow'}  'FAIL'  { 'Red'   }
    }
    Write-Host ("[{0,-6}] {1}" -f $Level, $Message) -ForegroundColor $color
    Write-Log  ("[{0}] {1}" -f $Level, $Message)
    if ($Fix) {
        Write-Host ("          fix: {0}" -f $Fix) -ForegroundColor DarkGray
        Write-Log  ("         fix: {0}" -f $Fix)
    }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------------------------
# Standalone fallbacks
#
# Used only when the deploy libraries are not next to this file. Deliberate duplication, the same
# trade misc\Set-CxServiceLabels.ps1 makes: one file you can copy to a host that has no package
# beats a script that cannot run there. The library versions are PREFERRED whenever present, so a
# host with the full package never executes these.
# ---------------------------------------------------------------------------------------------

function Get-LocalIisnodeEvidence {
    <#
      Does this application's own web.config wire iisnode, and what is its entry script?
      Mirrors the iisnode half of deploy\Resolve-IISAppRuntime.ps1's Get-CxWebConfigRuntimeState.

      An ARR rewrite to 127.0.0.1 is NOT evidence: a reverse proxy says nothing about what the
      backend is or where it runs, and the pool's environment does not reach it.
    #>
    param([string] $PhysicalPath)
    # IsDotNet is the co-tenancy question, not a runtime verdict: it only has to answer "would this
    # application be instrumented by the .NET profiler, and therefore care what OTEL_SERVICE_NAME
    # its pool carries". Mirrors the positive-evidence rules in Get-CxWebConfigRuntimeState.
    $out = [pscustomobject]@{ IsIisnode = $false; Entry = $null; CustomCmdLine = $false; IsDotNet = $false; State = 'nopath' }
    if (-not $PhysicalPath) { return $out }
    $wc = Join-Path $PhysicalPath 'web.config'
    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($wc) }
    catch [System.IO.DirectoryNotFoundException] { $out.State = 'absent'; return $out }
    catch [System.IO.FileNotFoundException]      { $out.State = 'absent'; return $out }
    catch { $out.State = 'unreadable'; return $out }
    try { [xml]$x = $raw } catch { $out.State = 'unreadable'; return $out }
    $out.State = 'ok'
    try {
        foreach ($h in @($x.SelectNodes('//handlers/add'))) {
            $mods = [string]$h.GetAttribute('modules')
            $sp   = [string]$h.GetAttribute('scriptProcessor')
            if (-not (($mods -match '(^|[,\s])iisnode([,\s]|$)') -or ($sp -match 'iisnode\.dll'))) { continue }
            $out.IsIisnode = $true
            $p = [string]$h.GetAttribute('path')
            if (-not $out.Entry -and $p -and $p -notmatch '[\*\?]') { $out.Entry = $p }
        }
        $inode = $x.SelectSingleNode('//iisnode')
        if ($inode) {
            $out.IsIisnode = $true
            if ([string]$inode.GetAttribute('nodeProcessCommandLine')) { $out.CustomCmdLine = $true }
        }
        # .NET, positive evidence only - never the pool's managedRuntimeVersion, which defaults to
        # v4.0 and would make every static site look like a Framework app.
        if ($x.SelectSingleNode('//aspNetCore')) { $out.IsDotNet = $true }
        foreach ($sw in @($x.SelectNodes('//system.web'))) {
            foreach ($child in @($sw.ChildNodes)) {
                if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ('compilation','httpRuntime','httpModules','httpHandlers','authentication','sessionState','pages','customErrors','globalization','identity','machineKey','membership','roleManager','trace' -contains $child.LocalName) {
                    $out.IsDotNet = $true
                }
            }
        }
        foreach ($n in @($x.SelectNodes('//system.webServer/handlers/add')) + @($x.SelectNodes('//system.webServer/modules/add'))) {
            $t = [string]$n.GetAttribute('type')
            if ($t -and $t -notmatch 'AspNetCoreModule') { $out.IsDotNet = $true }
            if (([string]$n.GetAttribute('path')) -match '\.(aspx|asmx|ashx|axd)$') { $out.IsDotNet = $true }
        }
    } catch { }
    return $out
}

function Get-PoolNameConflict {
    <#
      Can a pool-level OTEL_SERVICE_NAME honestly name THIS application? Returns $null when it can,
      or the reason it cannot.

      A pool variable reaches every application in the pool and every process those applications
      start, so there are two ways to get this wrong, and the second is worse than doing nothing:

        * two iisnode applications in one pool - one name cannot name both
        * an iisnode application sharing a pool with an instrumented .NET application - writing the
          Node service name RENAMES the .NET one, corrupting a service that was reporting correctly

      A static or otherwise uninstrumented co-tenant does not read OTEL_SERVICE_NAME, so it does
      not block.

      The last check is the belt-and-braces one: if the pool ALREADY carries a different
      OTEL_SERVICE_NAME, something (very likely Instrument-IIS.ps1, for the .NET app) has claimed
      that pool. Overwriting it is exactly the silent rename above, so refuse regardless of what
      classification concluded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Record,
        [object[]] $All = @(),
        [string]   $ExistingPoolServiceName
    )

    $rivals = @($All | Where-Object {
        $_.Pool -eq $Record.Pool -and $_.Key -ne $Record.Key -and ($_.IsIisnode -or $_.IsDotNet)
    })
    if (@($rivals).Count -gt 0) {
        $kinds = @($rivals | ForEach-Object { "$($_.Key)$(if ($_.IsIisnode) { ' (iisnode)' } else { ' (.NET)' })" }) -join ', '
        return "pool '$($Record.Pool)' also hosts instrumented application(s): $kinds. A pool-level OTEL_SERVICE_NAME reaches all of them, so naming this one would mis-name or rename the others"
    }
    if ($ExistingPoolServiceName -and $ExistingPoolServiceName -ne $Record.ServiceName) {
        return "pool '$($Record.Pool)' already carries OTEL_SERVICE_NAME='$ExistingPoolServiceName', which is not the name for this application - something else has claimed this pool and overwriting it would rename that service"
    }
    return $null
}

function Test-LocalAppIsEsm {
    <#
      ESM or CommonJS? Mirrors Test-CxNodeAppIsEsm: an .mjs entry, else the nearest package.json
      declaring "type": "module". Returns $false when nothing can be read - CommonJS is also the
      common case, and the doctor reports the mismatch if the guess turns out wrong.

      It matters because the bootstrap flag differs and getting it wrong fails SILENTLY: --require
      cannot patch an ESM import graph, so the SDK starts and emits nothing.
    #>
    param([string] $Entry, [string] $Cwd)
    if ($Entry -and $Entry -match '\.mjs$') { return $true }
    $dirs = @()
    if ($Entry -and $Cwd) { $dirs += (Split-Path -Parent (Join-Path $Cwd $Entry)) }
    if ($Cwd) { $dirs += $Cwd }
    foreach ($d in ($dirs | Where-Object { $_ })) {
        $pkg = Join-Path $d 'package.json'
        if (-not (Test-Path -LiteralPath $pkg -ErrorAction SilentlyContinue)) { continue }
        try {
            $txt = Get-Content -LiteralPath $pkg -Raw -ErrorAction Stop
            if ($txt -match '"type"\s*:\s*"module"') { return $true }
            return $false
        } catch { continue }
    }
    return $false
}

function Resolve-LocalNodeBootstrap {
    <#
      Resolve the staged package's register.js and the ESM loader hook. Mirrors
      Resolve-CxNodeBootstrap, including the measured ESM rule:

        --import C:/.../register.js          CRASHES (Node reads `C:` as a URL scheme)
        --import file:///C:/.../register.js  starts, SDK loads, ZERO spans
        --experimental-loader=file:///.../hook.mjs --require C:/.../register.js   works

      A missing hook is reported, never silently accepted.
    #>
    param([string] $Prefix)
    $r = [pscustomobject]@{ RegisterPath = $null; HookUrl = $null; Cjs = $null; Esm = $null; EsmSupported = $false; Reason = $null }
    $nm = Join-Path $Prefix 'node_modules'
    if (-not (Test-Path -LiteralPath $nm)) {
        $r.Reason = "no node_modules under $Prefix - the instrumentation package is not staged on this host"
        return $r
    }
    $reg = Get-ChildItem -Path (Join-Path $nm '@opentelemetry\auto-instrumentations-node') -Recurse -Filter 'register.js' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $reg) {
        $r.Reason = "@opentelemetry/auto-instrumentations-node/register.js was not found under $nm"
        return $r
    }
    # Forward slashes: NODE_OPTIONS parses backslashes awkwardly and they are safe on Windows Node.
    $r.RegisterPath = ($reg -replace '\\', '/')
    $r.Cjs = "--require $($r.RegisterPath)"
    $hook = Get-ChildItem -Path (Join-Path $nm '@opentelemetry\instrumentation') -Recurse -Filter 'hook.mjs' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($hook) {
        $r.HookUrl      = 'file:///' + (($hook -replace '\\', '/'))
        $r.Esm          = "--experimental-loader=$($r.HookUrl) $($r.Cjs)"
        $r.EsmSupported = $true
    } else {
        $r.Reason = "no @opentelemetry/instrumentation/hook.mjs under $nm - ESM applications cannot be instrumented (the SDK would load and emit nothing); CommonJS applications are unaffected"
    }
    return $r
}

function Merge-LocalNodeOptions {
    <#
      Combine an app pool's existing NODE_OPTIONS with our bootstrap, preserving the app's own
      flags and dropping any PREVIOUS bootstrap of ours. Mirrors Merge-CxNodeOptions.

      Overwriting is the obvious implementation and it is wrong: an app that sets
      --max-old-space-size for a reason loses its heap ceiling the moment it is instrumented, and
      nothing reports that its memory limit just changed.
    #>
    param([string] $Existing, [string] $Bootstrap, [string[]] $OwnedTargets = @())
    function Key { param([string]$v) if (-not $v) { return '' }; $k = $v.Trim('"') -replace '\\','/'; $k = $k -replace '^file:/+',''; return $k.ToLowerInvariant() }
    $ours = @{}
    foreach ($m in [regex]::Matches($Bootstrap, '(?:--(?:require|import)(?:=|\s+)|--experimental-loader=)("[^"]*"|\S+)')) { $ours[(Key $m.Groups[1].Value)] = $true }
    foreach ($t in $OwnedTargets) { $k = Key $t; if ($k) { $ours[$k] = $true } }
    function IsOurs { param([string]$t) if (-not $t) { return $false }; $k = Key $t; if ($ours.ContainsKey($k)) { return $true }; return [bool]($k -match 'auto-instrumentations-node|opentelemetry') }

    $kept = @()
    if ($Existing) {
        # @() is load-bearing: a SINGLE regex match pipes out as a bare string whose [0] is the
        # first CHARACTER, which turned a lone '--max-old-space-size=512' into '-'.
        $tokens = @([regex]::Matches($Existing, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $t = $tokens[$i]
            if ($t -match '^--experimental-loader=(.*)$' -and (IsOurs $matches[1])) { continue }
            if ($t -match '^--(require|import)(=(.*))?$') {
                $target = $matches[3]
                if (-not $target -and ($i + 1) -lt $tokens.Count) { $target = $tokens[$i + 1]; $i++ }
                if (IsOurs $target) { continue }
                $kept += $t
                if ($target -and $t -notmatch '=') { $kept += $target }
                continue
            }
            $kept += $t
        }
    }
    $kept += $Bootstrap
    return (($kept | Where-Object { $_ }) -join ' ').Trim()
}

function Test-CxBootstrapInValue {
    <#
      Does a merged NODE_OPTIONS actually preload OUR register.js?

      Asserted rather than assumed because every silent failure this script exists to prevent has the
      same shape: the six OTEL_* variables land, the bootstrap does not, and the host reads as
      instrumented while its applications emit nothing. Measured on a real host, where a foreign
      deploy library returned a bootstrap object this script could not read: the merged value came out
      empty, 35 pools were written and recycled, and the only complaint was a read-back mismatch with
      a guess about file locks attached.
    #>
    param([string] $Value, [string] $RegisterPath)
    if (-not $Value -or -not $RegisterPath) { return $false }
    $v = ($Value -replace '\\','/').ToLowerInvariant()
    $t = ($RegisterPath -replace '\\','/').ToLowerInvariant()
    if (-not $v.Contains($t)) { return $false }
    return [bool]($v -match '--(require|import)')
}

# ---------------------------------------------------------------------------------------------
# Stage 0 - preflight
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '=== iisnode zero-code OpenTelemetry: app pool bootstrap ===' -ForegroundColor Cyan
Write-Log  "=== Enable-IisnodeInstrumentation started $($script:StartedAt.ToString('u')) ==="
Write-Host ("mode: {0}   log: {1}" -f $(if ($Apply) { "APPLY (writes$(if ($Recycle) { ' + recycles pools' } else { ', NO recycle' }))" } else { 'DRY-RUN (no changes)' }), $LogPath) -ForegroundColor Cyan
Write-Log  "mode=$(if ($Apply) { 'APPLY' } else { 'DRY-RUN' }) recycle=$Recycle prefix=$InstallPrefix endpoint=$OtlpEndpoint pools=[$($Pools -join ',')] apps=[$($Apps -join ',')]"
Write-Host ''

if (-not (Test-Elevated)) {
    Write-Step FAIL 'not elevated - applicationHost.config, icacls and a pool recycle all require Administrator' -Fix 'run this from an elevated PowerShell'
    exit 2
}

# WOW64: %windir%\System32 is redirected to SysWOW64 for a 32-bit process, where inetsrv\config
# does not exist.
$inetsrv = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Join-Path $env:windir 'Sysnative\inetsrv'
} else {
    Join-Path $env:windir 'System32\inetsrv'
}
$appcmd        = Join-Path $inetsrv 'appcmd.exe'
$appHostConfig = Join-Path $inetsrv 'config\applicationHost.config'
if (-not (Test-Path -LiteralPath $appcmd)) {
    Write-Step FAIL "appcmd.exe not found at $appcmd - the IIS management tooling is not installed" -Fix 'install the IIS management role, or run this on the right host'
    exit 2
}
Write-Step INFO "appcmd: $appcmd"

# Endpoint: rewrite localhost rather than honor it. ::1 first on a dual-stack host, collector on
# IPv4, export dropped with no exporter error.
if ($OtlpEndpoint -match 'localhost') {
    $rewritten = $OtlpEndpoint -replace 'localhost', '127.0.0.1'
    Write-Step WARN "endpoint '$OtlpEndpoint' uses localhost, which resolves to ::1 first and drops the OTLP export silently - using '$rewritten' instead"
    $OtlpEndpoint = $rewritten
}

# Deploy libraries, preferred over the local fallbacks above.
$libDirs = @($script:Here, (Join-Path $script:Here '..\deploy'), (Join-Path (Split-Path -Parent $script:Here) 'deploy'))
$libMode = 'standalone'
foreach ($d in $libDirs) {
    $rt = Join-Path $d 'Resolve-IISAppRuntime.ps1'
    $nd = Join-Path $d 'Resolve-NodeServiceNames.ps1'
    if ((Test-Path -LiteralPath $rt -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $nd -ErrorAction SilentlyContinue)) {
        try {
            . $nd
            . $rt
            # Also Update-CxServicesUnion / Restart-CxCollector, so the label refresh below uses the
            # same union the deploy path writes rather than a second implementation of it.
            $wd = Join-Path $d 'Write-DeployLog.ps1'
            if (Test-Path -LiteralPath $wd -ErrorAction SilentlyContinue) { . $wd }
            $libMode = "libraries from $((Resolve-Path $d).Path)"
            break
        } catch { }
    }
}
$haveLibs = [bool]((Get-Command Get-CxWebConfigRuntimeState -ErrorAction SilentlyContinue) -and (Get-Command Merge-CxNodeOptions -ErrorAction SilentlyContinue))
Write-Step INFO "classification: $(if ($haveLibs) { $libMode } else { 'standalone (deploy libraries not found next to this script)' })"

# The package. NOT installed here - see .DESCRIPTION.
$boot = if ($haveLibs -and (Get-Command Resolve-CxNodeBootstrap -ErrorAction SilentlyContinue)) {
    $b = Resolve-CxNodeBootstrap -InstallPrefix $InstallPrefix
    [pscustomobject]@{ RegisterPath = $b.RegisterPath; HookUrl = $b.HookUrl; Cjs = $b.NodeOptionsCjs; Esm = $b.NodeOptionsEsm; EsmSupported = $b.EsmSupported; Reason = $b.Reason }
} else {
    Resolve-LocalNodeBootstrap -Prefix $InstallPrefix
}
if (-not $boot.RegisterPath) {
    Write-Step FAIL "the Node instrumentation package is not usable: $($boot.Reason)" `
        -Fix "stage it first (deploy\Instrument-NodePM2.ps1 runs npm install, or copy a prepared node_modules tree to $InstallPrefix), then re-run. This script deliberately does not run npm."
    exit 2
}
Write-Step OK "bootstrap: $($boot.RegisterPath)"
# RegisterPath being present is NOT enough to write anything: the string that reaches the pool is
# $boot.Cjs. When this script runs next to a deploy checkout it takes that string from the library's
# Resolve-CxNodeBootstrap ($b.NodeOptionsCjs), so a library that names the property differently -
# or does not return it at all - leaves Cjs empty while RegisterPath, and therefore the OK line
# above, still reads healthy. Measured on a real host: the run then wrote the six OTEL_* variables
# to 35 pools with an EMPTY NODE_OPTIONS among them and recycled every one of them, producing
# exactly the reads-instrumented-emits-nothing state this tooling exists to remove. Preflight abort,
# because there is no application on this host it could be written correctly for.
if (-not $boot.Cjs) {
    Write-Step FAIL "the bootstrap FLAG came back empty even though register.js was found at $($boot.RegisterPath) - $(if ($haveLibs) { "the deploy libraries in use ($libMode) returned a shape this script could not read" } else { 'the standalone resolver in this file produced no --require flag' })" `
        -Fix $(if ($haveLibs) { "that library's Resolve-CxNodeBootstrap must expose NodeOptionsCjs - check with: . <deploy>\Resolve-NodeServiceNames.ps1 ; Resolve-CxNodeBootstrap -InstallPrefix $InstallPrefix | Format-List * . Or copy this ONE file to a directory with no deploy\ beside or above it, which forces the standalone fallbacks this script's own tests pin against the repository libraries" } else { 'this is a bug in Resolve-LocalNodeBootstrap in this file, not a host problem' })
    exit 2
}
# The ESM loader hook is deliberately NOT required here. It is the fix on the PM2 path, where node
# runs the app directly; under iisnode an ES module cannot start at all (its interceptor require()s
# the entry point), so ESM apps are refused regardless and the hook is only tracked so a stale one
# from an earlier build can be stripped.
if ($boot.HookUrl) { Write-Step INFO "esm loader hook present (not used for iisnode): $($boot.HookUrl)" }

# Overrides: JSON first, hashtable on top - same precedence as the deploy scripts.
if ($OverridesJson) {
    if (-not (Test-Path -LiteralPath $OverridesJson)) {
        Write-Step FAIL "overrides JSON not found: $OverridesJson"
        exit 2
    }
    try {
        $fromFile = Get-Content -LiteralPath $OverridesJson -Raw | ConvertFrom-Json
        foreach ($p in $fromFile.PSObject.Properties) {
            if (-not $ServiceNameOverrides.ContainsKey($p.Name)) { $ServiceNameOverrides[$p.Name] = $p.Value }
        }
        Write-Step INFO "service name overrides loaded from $OverridesJson"
    } catch {
        Write-Step FAIL "overrides JSON could not be parsed: $($_.Exception.Message)"
        exit 2
    }
}

# ---------------------------------------------------------------------------------------------
# Stage 1 - enumerate applications
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '--- applications ---' -ForegroundColor Cyan

function Get-AppHostXml {
    try { [xml]$c = Get-Content -LiteralPath $appHostConfig -Raw -ErrorAction Stop; return $c } catch { return $null }
}

$xml = Get-AppHostXml
if (-not $xml) {
    Write-Step FAIL "applicationHost.config could not be read at $appHostConfig"
    exit 2
}

# Sites and applications straight out of applicationHost.config - no WebAdministration module, so
# this works on a host with the IIS role but no management PowerShell.
$records = New-Object System.Collections.ArrayList
$sitesRoot = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
$siteDefaultPool = ''
if ($sitesRoot) {
    $sd = $sitesRoot.SelectSingleNode('applicationDefaults')
    if ($sd) { $siteDefaultPool = [string]$sd.GetAttribute('applicationPool') }
}
foreach ($site in @($xml.SelectNodes('/configuration/system.applicationHost/sites/site'))) {
    $siteName = [string]$site.GetAttribute('name')
    $perSiteDefault = ''
    $psd = $site.SelectSingleNode('applicationDefaults')
    if ($psd) { $perSiteDefault = [string]$psd.GetAttribute('applicationPool') }
    foreach ($app in @($site.SelectNodes('application'))) {
        $appPath = [string]$app.GetAttribute('path')
        if (-not $appPath) { $appPath = '/' }
        # Pool precedence, as IIS resolves it: the application's own attribute, then the site's
        # applicationDefaults, then the sites-wide applicationDefaults.
        $pool = [string]$app.GetAttribute('applicationPool')
        if (-not $pool) { $pool = $perSiteDefault }
        if (-not $pool) { $pool = $siteDefaultPool }
        $phys = ''
        $vd = $app.SelectSingleNode("virtualDirectory[@path='/']")
        if (-not $vd) { $vd = $app.SelectSingleNode('virtualDirectory') }
        if ($vd) { $phys = [string]$vd.GetAttribute('physicalPath') }
        try { $phys = [Environment]::ExpandEnvironmentVariables($phys) } catch { }

        $auto = if ($appPath -eq '/') { $siteName } else { "$siteName$appPath" }
        $svc  = if ($ServiceNameOverrides.ContainsKey($auto)) { [string]$ServiceNameOverrides[$auto] } else { $auto }

        [void]$records.Add([pscustomobject]@{
            Key          = "$siteName$appPath"
            Site         = $siteName
            AppPath      = $appPath
            Pool         = $pool
            PhysicalPath = $phys
            AutoName     = $auto
            ServiceName  = $svc
            IsIisnode    = $false
            Entry        = $null
            IsEsm        = $false
            CustomCmdLine = $false
            IsDotNet     = $false
            WcState      = 'nopath'
        })
    }
}

if (@($records).Count -eq 0) {
    Write-Step WARN 'no IIS applications are declared on this host - nothing to do'
    exit 0
}

# Classify. The library path also resolves an iisnode handler INHERITED from a parent application;
# the standalone fallback only reads each app's own web.config, and says so below when it matters.
foreach ($r in $records) {
    if ($haveLibs) {
        $st = Get-CxWebConfigRuntimeState -PhysicalPath $r.PhysicalPath
        $r.WcState = $st.State
        if (@($st.NodeEvidence).Count -gt 0) {
            $r.IsIisnode     = $true
            $r.Entry         = $st.NodeEntryScript
            $r.CustomCmdLine = [bool](@($st.NodeEvidence) -match 'nodeProcessCommandLine')
        }
        # Positive .NET evidence from the SAME parsed state - the co-tenancy question below needs
        # it for every app in the pool, not just the iisnode ones.
        $r.IsDotNet = [bool]((@($st.CoreEvidence).Count -gt 0) -or (@($st.FrameworkEvidence).Count -gt 0))
    } else {
        $ev = Get-LocalIisnodeEvidence -PhysicalPath $r.PhysicalPath
        $r.WcState       = $ev.State
        $r.IsIisnode     = $ev.IsIisnode
        $r.Entry         = $ev.Entry
        $r.CustomCmdLine = $ev.CustomCmdLine
        $r.IsDotNet      = $ev.IsDotNet
    }
    if ($r.IsIisnode) {
        $r.IsEsm = if ($haveLibs -and (Get-Command Test-CxNodeAppIsEsm -ErrorAction SilentlyContinue)) {
            $entryFull = if ($r.Entry -and $r.PhysicalPath) { Join-Path $r.PhysicalPath $r.Entry } else { '' }
            [bool](Test-CxNodeAppIsEsm -Script $entryFull -Cwd $r.PhysicalPath)
        } else {
            [bool](Test-LocalAppIsEsm -Entry $r.Entry -Cwd $r.PhysicalPath)
        }
    }
}

$iisnode = @($records | Where-Object { $_.IsIisnode })
Write-Step INFO "$(@($records).Count) application(s) declared, $(@($iisnode).Count) hosted by iisnode"
if (@($iisnode).Count -eq 0) {
    Write-Step INFO 'no iisnode applications found, so there is nothing for this script to do. An IIS site that reverse-proxies to a Node process (ARR to 127.0.0.1) is NOT iisnode: that backend has to be instrumented where it runs - PM2 (deploy\Instrument-NodePM2.ps1) or a Windows service (deploy\Instrument-NodeService.ps1).'
    Write-Host ''
    exit 0
}

# Scope filters. Applied after enumeration so the report still shows what was skipped.
$selected = @($iisnode)
if ($Pools) { $selected = @($selected | Where-Object { $Pools -contains $_.Pool }) }
if ($Apps)  { $selected = @($selected | Where-Object { $Apps -contains $_.ServiceName -or $Apps -contains $_.Key -or $Apps -contains $_.AutoName }) }
foreach ($r in @($iisnode | Where-Object { $selected -notcontains $_ })) {
    Write-Step INFO "skipped by -Pools/-Apps: $($r.Key) (pool '$($r.Pool)')"
}
if (@($selected).Count -eq 0) {
    Write-Step WARN '-Pools/-Apps matched no iisnode application - nothing to do'
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Stage 2 - the plan
# ---------------------------------------------------------------------------------------------

function Get-PoolEnvValue {
    param([string] $Pool, [string] $Name)
    $c = Get-AppHostXml
    if (-not $c) { return $null }
    $n = $c.SelectSingleNode("/configuration/system.applicationHost/applicationPools/add[@name='$Pool']/environmentVariables/add[@name='$Name']")
    if (-not $n) { return $null }
    return [string]$n.GetAttribute('value')
}

function Get-PoolIdentityAccount {
    <#
      The account a pool's worker runs as, in a form icacls accepts. The default,
      ApplicationPoolIdentity, is a virtual account named after the pool - it has no rights to the
      install prefix, and a missing grant produces exactly an uninstrumented app: node fails the
      preload and keeps serving.
    #>
    param([string] $Pool)
    $type = ''
    $user = ''
    try { $type = (& $appcmd list apppool "$Pool" /text:processModel.identityType 2>$null | Out-String).Trim() } catch { }
    try { $user = (& $appcmd list apppool "$Pool" /text:processModel.userName    2>$null | Out-String).Trim() } catch { }
    switch ($type) {
        'ApplicationPoolIdentity' { return "IIS AppPool\$Pool" }
        'LocalService'            { return 'NT AUTHORITY\LOCAL SERVICE' }
        'LocalSystem'             { return 'NT AUTHORITY\SYSTEM' }
        'NetworkService'          { return 'NT AUTHORITY\NETWORK SERVICE' }
        'SpecificUser'            { if ($user) { return $user } else { return $null } }
        default                   { if (-not $type) { return "IIS AppPool\$Pool" } else { return $null } }
    }
}

Write-Host ''
Write-Host '--- plan ---' -ForegroundColor Cyan

$work = New-Object System.Collections.ArrayList
foreach ($r in $selected) {
    $label = "$($r.Key) [pool '$($r.Pool)']"

    # Co-tenancy. Same gate as Instrument-IIS.ps1's $poolRivals check, and it must stay the same:
    # a host patched here and later re-deployed must not flip between instrumented and not.
    $conflict = Get-PoolNameConflict -Record $r -All $records -ExistingPoolServiceName (Get-PoolEnvValue -Pool $r.Pool -Name 'OTEL_SERVICE_NAME')
    if ($conflict) {
        Write-Step WARN "$label - $conflict. Left alone: a name that maps to two services, or that renames a service already reporting, is worse than no name." `
            -Fix 'give this application its own app pool, or set the bootstrap per application via <iisnode nodeProcessCommandLine>'
        continue
    }
    # ESM: refused outright, NOT conditional on the loader hook being staged.
    #
    # Measured on a real host (iisnode 0.2.26, Node 20.11): iisnode's interceptor.js require()s the
    # application's entry point, and a CommonJS require cannot load an ES module - so an ESM app
    # under iisnode returns HTTP 500 / ERR_REQUIRE_ESM on every request, with our bootstrap and
    # without it. The loader hook is the fix on the PM2 path, where node runs the app directly; here
    # the app never gets far enough to load a hook. Instrumenting it would leave a host reporting
    # "instrumented" for an application that cannot serve a request.
    if ($r.IsEsm) {
        Write-Step WARN "$label is an ES module$(if ($r.Entry) { " ($($r.Entry))" }) and iisnode cannot host ES modules - its interceptor.js require()s the entry point, so the app returns HTTP 500 (ERR_REQUIRE_ESM) whether or not it is instrumented. Left alone: there is no working process here to instrument." `
            -Fix 'application-side, unrelated to telemetry: give it a CommonJS entry point that dynamic-import()s the ESM app, or host it under PM2 / a Windows service instead of iisnode'
        continue
    }
    if ($r.CustomCmdLine) {
        Write-Step INFO "$label sets <iisnode nodeProcessCommandLine>, which replaces the node.exe invocation. Pool NODE_OPTIONS still applies, but check that command line does not already preload an OTel bootstrap - two SDKs in one process is its own failure mode."
    }
    if ($r.WcState -eq 'absent' -and -not $haveLibs) {
        Write-Step INFO "$label has no web.config of its own; the iisnode handler is inherited from a parent application. The standalone classifier cannot see that - re-run next to the deploy libraries if this looks wrong."
    }

    # Always the CommonJS form: the ESM branch above refused already. HookUrl stays in $owned so a
    # stale ESM loader from an earlier build is stripped out of the merged value.
    $bootstrap = $boot.Cjs
    $existing  = Get-PoolEnvValue -Pool $r.Pool -Name 'NODE_OPTIONS'
    $owned     = @($boot.RegisterPath, $boot.HookUrl) | Where-Object { $_ }
    $merged    = if ($haveLibs) {
        Merge-CxNodeOptions -Existing $existing -Bootstrap $bootstrap -OwnedTargets $owned
    } else {
        Merge-LocalNodeOptions -Existing $existing -Bootstrap $bootstrap -OwnedTargets $owned
    }

    # The merge is checked, not trusted. $ErrorActionPreference is 'Continue' here (a classifier that
    # cannot read one web.config must not abort a host-wide run), which means a failed call to a
    # drifted library function - a missing -OwnedTargets parameter, say - only writes an error to the
    # console and leaves $merged null. Without this gate the six OTEL_* variables below are still
    # written, and a pool carrying a service name and no --require is an application that reports
    # nothing while every variable on it reads as configured.
    if (-not (Test-CxBootstrapInValue -Value $merged -RegisterPath $boot.RegisterPath)) {
        Write-Step FAIL "$label - the merged NODE_OPTIONS does not carry the bootstrap, so NOTHING is written for this application (its pool is left exactly as it was). Merged value: '$merged'" `
            -Fix $(if ($haveLibs) { "Merge-CxNodeOptions from $libMode returned a value without $($boot.RegisterPath) - check its signature accepts -OwnedTargets: (Get-Command Merge-CxNodeOptions).Parameters.Keys . Or copy this ONE file to a directory with no deploy\ beside or above it to force the fallbacks in this file" } else { 'this is a bug in Merge-LocalNodeOptions in this file, not a host problem' })
        continue
    }

    $vars = [ordered]@{
        NODE_OPTIONS                = $merged
        OTEL_SERVICE_NAME           = $r.ServiceName
        OTEL_EXPORTER_OTLP_ENDPOINT = $OtlpEndpoint
        OTEL_EXPORTER_OTLP_PROTOCOL = 'http/protobuf'
        OTEL_TRACES_EXPORTER        = 'otlp'
        OTEL_METRICS_EXPORTER       = 'otlp'
        OTEL_LOGS_EXPORTER          = 'otlp'
    }

    # Already correct? Then this app needs no write and, importantly, no RECYCLE.
    $changes = [ordered]@{}
    foreach ($k in $vars.Keys) {
        $cur = Get-PoolEnvValue -Pool $r.Pool -Name $k
        if ([string]$cur -ne [string]$vars[$k]) { $changes[$k] = $vars[$k] }
    }

    Write-Host ("  {0,-40} -> {1,-28} {2}" -f $r.Key, $r.ServiceName, $(if ($r.IsEsm) { 'esm loader hook + --require' } else { '--require' }))
    if ($existing) { Write-Host "      preserving the application's own NODE_OPTIONS: $existing" -ForegroundColor DarkGray }
    if ($r.ServiceName -ne $r.AutoName) { Write-Host "      name overridden (auto was '$($r.AutoName)')" -ForegroundColor DarkGray }

    if ($changes.Count -eq 0) {
        Write-Step OK "$label already carries this exact bootstrap and service name - no write, no recycle"
        continue
    }
    foreach ($k in $changes.Keys) {
        Write-Step $(if ($Apply) { 'APPLY' } else { 'DRYRUN' }) "$($r.Pool): $k=$($changes[$k])"
    }
    [void]$work.Add([pscustomobject]@{ Record = $r; Changes = $changes })
}

if (@($work).Count -eq 0) {
    Write-Host ''
    Write-Step INFO 'nothing to change'
    Write-Host ''
    Write-Log  "counts: $(($script:Counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
    exit $(if ($script:Counts.FAIL -gt 0) { 1 } else { 0 })
}

if (-not $Apply) {
    Write-Host ''
    Write-Step INFO "DRY-RUN: $(@($work).Count) application(s) would be instrumented on $(@($work | ForEach-Object { $_.Record.Pool } | Select-Object -Unique).Count) pool(s). Re-run with -Apply to write and recycle."
    Write-Host ''
    Write-Log  "counts: $(($script:Counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
    exit $(if ($script:Counts.FAIL -gt 0) { 1 } else { 0 })
}

# ---------------------------------------------------------------------------------------------
# Stage 3 - apply
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '--- apply ---' -ForegroundColor Cyan

# One backup of applicationHost.config before the first write. Not a manifest - Uninstall-Agent.ps1
# owns that shape - but enough to get a host back by hand.
$backup = Join-Path $script:Here ("applicationHost.config.{0}.bak" -f $script:StartedAt.ToString('yyyyMMdd-HHmmss'))
try {
    Copy-Item -LiteralPath $appHostConfig -Destination $backup -Force
    Write-Step OK "backed up applicationHost.config -> $backup"
} catch {
    Write-Step WARN "could not back up applicationHost.config: $($_.Exception.Message) - continuing, the writes below are individually reversible with appcmd"
}

$grantedPools = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# Pools whose BOOTSTRAP is on disk when this run ends - the only pools worth recycling, and the only
# applications this host may claim. Deliberately NOT "pools where some write succeeded": any one of
# the seven variables landing used to mark a pool as changed, so a run whose NODE_OPTIONS write
# failed still recycled every pool - a request-path restart for applications that came back just as
# unable to emit anything - and still published their names for host ownership.
$bootstrapPools = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$brokenPools    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$claimNames     = New-Object System.Collections.Generic.List[string]
$brokenApps     = New-Object System.Collections.Generic.List[string]

foreach ($w in $work) {
    $r = $w.Record

    # The pool identity must be able to READ the bootstrap. Once per pool.
    if ($grantedPools.Add($r.Pool)) {
        $acct = Get-PoolIdentityAccount -Pool $r.Pool
        if (-not $acct) {
            Write-Step WARN "could not determine the identity of pool '$($r.Pool)', so no read grant was made on $InstallPrefix - if its node.exe cannot read the bootstrap it will run uninstrumented" `
                -Fix "grant read+execute on $InstallPrefix to that pool's identity by hand"
        } else {
            # (OI)(CI) so the grant reaches the files under node_modules, not just the folder.
            $out = & icacls.exe "$InstallPrefix" /grant "${acct}:(OI)(CI)(RX)" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { Write-Step APPLY "$acct granted read+execute on $InstallPrefix" }
            else { Write-Step WARN "icacls could not grant '$acct' read access to ${InstallPrefix}: $($out.Trim())" }
        }
    }

    # NODE_OPTIONS absent from the change set means the pool already carried this exact bootstrap -
    # Stage 2 refuses to plan a value without it - so "landed" is the correct default.
    $bootstrapLanded = $true

    foreach ($k in $w.Changes.Keys) {
        $v = [string]$w.Changes[$k]
        # Idempotent: remove any existing entry, then add. The removal is best-effort - a pool that
        # never had the variable has nothing to remove.
        & $appcmd set config -section:system.applicationHost/applicationPools `
            "/-[name='$($r.Pool)'].environmentVariables.[name='$k']" /commit:apphost 2>$null | Out-Null
        # appcmd's own output on the ADD is KEPT. Discarding it (2>&1 | Out-Null) is what made this
        # failure unreadable on a real host: 35 pools reported "did NOT take" with a guess about file
        # locks attached, while appcmd's actual message - and its exit code - had been thrown away.
        $addOut  = & $appcmd set config -section:system.applicationHost/applicationPools `
            "/+[name='$($r.Pool)'].environmentVariables.[name='$k',value='$v']" /commit:apphost 2>&1 | Out-String
        $addCode = $LASTEXITCODE
        $now     = Get-PoolEnvValue -Pool $r.Pool -Name $k
        if ([string]$now -eq $v) {
            Write-Step APPLY "$($r.Pool): $k set"
        } else {
            # An unreadable config, an absent variable and a wrong value are three different faults
            # with three different fixes. They used to be reported identically, because
            # Get-PoolEnvValue returns $null for both "could not read the file" and "no such
            # variable", and [string]$null renders as '' - so the report read "still reads ''" for a
            # write that may never have been attempted.
            $state = if (-not (Get-AppHostXml)) {
                'applicationHost.config could not be re-read, so this write is UNVERIFIED rather than known-failed'
            } elseif ($null -eq $now) {
                'the variable is absent from applicationHost.config'
            } else {
                "applicationHost.config reads '$now'"
            }
            Write-Step FAIL "$($r.Pool): $k did NOT take - $state. appcmd exit $addCode$(if ($addOut.Trim()) { ": $($addOut.Trim())" } else { ' (appcmd printed nothing)' })" `
                -Fix 'appcmd''s own message is above - work from it. Otherwise check for a configuration lock on system.applicationHost/applicationPools, a read-only applicationHost.config, or a value appcmd rejected'
            if ($k -eq 'NODE_OPTIONS') { $bootstrapLanded = $false }
        }
    }

    if ($bootstrapLanded) {
        [void]$bootstrapPools.Add($r.Pool)
        $claimNames.Add([string]$r.ServiceName)
    } else {
        [void]$brokenPools.Add($r.Pool)
        $brokenApps.Add("$($r.Key) [pool '$($r.Pool)']")
    }
}

# ---------------------------------------------------------------------------------------------
# Stage 3b - host Service ownership labels
#
# Writing pool environment instruments the application; it does NOT make the host claim the
# service. The collector's transform reads ${env:CX_SERVICES} - the union - so an application
# instrumented without updating that variable reports spans in APM while Infrastructure Explorer
# shows no ownership for it, with every variable involved still looking correct. That is a silent
# half-finished state, so this runs by default.
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '--- host ownership labels ---' -ForegroundColor Cyan

# ONLY applications whose bootstrap landed. Publishing a name for an application that emits nothing
# produces the exact confusion this variable exists to remove: the host entity claims a service with
# no telemetry behind it, every variable involved still reads as correct, and the gap presents as a
# Coralogix-side problem. Measured on a real host, where all 35 names were published in a run whose
# 35 NODE_OPTIONS writes had every one of them failed.
$instrumentedNames = @($claimNames | Where-Object { $_ } | Select-Object -Unique)
if (@($brokenApps).Count) {
    Write-Step WARN "$(@($brokenApps).Count) application(s) are NOT being claimed, because their bootstrap did not land: $($brokenApps -join ', '). Their pools carry the OTEL_* variables from this run and no --require, so they still emit nothing." `
        -Fix 'work from the appcmd messages above, then re-run. To put those pools back as they were, restore the applicationHost.config backup named at the start of the apply stage'
}
if (-not $RefreshServiceLabels) {
    Write-Step WARN "-RefreshServiceLabels:`$false - CX_NODE_SERVICES / CX_SERVICES were NOT updated, so this host does not claim $(@($instrumentedNames).Count) newly instrumented service(s): $($instrumentedNames -join ', '). They will report in APM with no host ownership." `
        -Fix 'run misc\Set-CxServiceLabels.ps1 -Apply, or re-run this script without -RefreshServiceLabels:$false'
} elseif (@($instrumentedNames).Count -eq 0) {
    Write-Step INFO 'nothing was instrumented, so the label variables need no change'
} else {
    # CX_NODE_SERVICES, not CX_IIS_SERVICES: the IIS variable is the .NET/profiler claim set and
    # Test-Agent.ps1 rebuilds it with that same filter, so a Node name there reports
    # CX_IIS_SERVICES_DRIFT permanently. UNION with what is there, so PM2 and .NET-service names
    # already published on this host survive.
    $priorNode = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine')
    $existing  = @()
    if ($priorNode) { $existing = @($priorNode -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $union = @(@($existing) + @($instrumentedNames) | Where-Object { $_ } | Select-Object -Unique)
    $nodeValue = ($union -join ',')
    if ($nodeValue -eq [string]$priorNode) {
        Write-Step OK "CX_NODE_SERVICES already lists them: $nodeValue"
    } else {
        [Environment]::SetEnvironmentVariable('CX_NODE_SERVICES', $nodeValue, 'Machine')
        $env:CX_NODE_SERVICES = $nodeValue
        Write-Step APPLY "CX_NODE_SERVICES=$nodeValue"
    }

    # The union the collector actually reads. Prefer the shared helper so this script and the
    # deploy path cannot disagree about ordering or de-duplication; fall back to an inline copy for
    # a host with no deploy package next to this file.
    if (Get-Command Update-CxServicesUnion -ErrorAction SilentlyContinue) {
        $val = Update-CxServicesUnion -RestartCollector -LogPrefix '[labels]'
        Write-Step APPLY "CX_SERVICES=$val (republished via the deploy helper, collector restarted)"
    } else {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $all  = New-Object System.Collections.Generic.List[string]
        foreach ($v in 'CX_IIS_SERVICES','CX_NODE_SERVICES','CX_DOTNET_SERVICES') {
            $raw = [Environment]::GetEnvironmentVariable($v, 'Machine')
            if (-not $raw) { continue }
            foreach ($n in ($raw -split ',')) { $t = "$n".Trim(); if ($t -and $seen.Add($t)) { [void]$all.Add($t) } }
        }
        if ($all.Count) {
            $val = ($all.ToArray() -join ',')
            [Environment]::SetEnvironmentVariable('CX_SERVICES', $val, 'Machine')
            $env:CX_SERVICES = $val
            Write-Step APPLY "CX_SERVICES=$val (standalone union)"
        }
        # The collector reads its environment at process start, so the value above does nothing
        # until it restarts. Supervisor mode has no collector service - the collector is a child of
        # opampsupervisor, so restarting the supervisor is what relaunches it.
        $svc = @(Get-Service -Name 'opampsupervisor','otelcol-contrib' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($svc) {
            try { Restart-Service -Name $svc[0].Name -Force -ErrorAction Stop; Write-Step APPLY "restarted $($svc[0].Name) so it re-reads the machine environment" }
            catch { Write-Step WARN "could not restart $($svc[0].Name): $($_.Exception.Message) - it keeps the OLD environment, so the labels have not taken effect yet" -Fix "restart it by hand: Restart-Service $($svc[0].Name) -Force" }
        } else {
            Write-Step WARN 'no collector service found, so nothing was restarted - the labels apply when one starts'
        }
    }

    # Setting the variable is not the same as the collector USING it: a config that predates
    # CX_SERVICES support stamps ownership from CX_IIS_SERVICES only, and then a Node service is
    # published everywhere and claimed nowhere. Measured on a real host, so it is checked here.
    $cfgs = @(
        'C:\ProgramData\opampsupervisor\state\effective.yaml',
        'C:\Program Files\OpenTelemetry OpAMP Supervisor\collector.yaml',
        'C:\ProgramData\OpenTelemetry\Collector\config.yaml'
    )
    # The FIRST READABLE file in precedence order is the verdict, whether it matches or not - the
    # effective config alone when it exists. Accepting "any config that mentions CX_SERVICES" is
    # wrong and was measured wrong: on a real host the staged base config had been updated and read
    # CX_SERVICES while the effective config (base merged with what Fleet Management sends, and
    # literally otelcol's --config) was the older remote version reading CX_IIS_SERVICES only. The
    # remote config wins, so consulting the base masks the live behaviour exactly when it matters.
    $seenCfg  = $null
    $consumes = $false
    $isEff    = $false
    foreach ($c in $cfgs) {
        if (-not (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue)) { continue }
        try { $live = (Get-Content -LiteralPath $c | Where-Object { $_ -notmatch '^\s*#' }) -join "`n" } catch { continue }
        $seenCfg  = $c
        $consumes = [bool]($live -match 'CX_SERVICES')
        $isEff    = ($c -eq $cfgs[0])
        break
    }
    if (-not $seenCfg) {
        Write-Step INFO 'no collector config was readable here, so whether it stamps ownership from CX_SERVICES could not be checked - deploy\Test-Agent.ps1 grades it'
    } elseif ($consumes) {
        Write-Step OK "the $(if ($isEff) { 'effective' } else { 'base' }) config in force reads CX_SERVICES ($seenCfg), so the host will claim these services"
    } else {
        Write-Step WARN "the collector config in force ($seenCfg) does NOT read `${env:CX_SERVICES} - it stamps host ownership from CX_IIS_SERVICES only (the pre-CX_SERVICES fallback), so these Node services will NOT be claimed by the host no matter how correct the variables are. They still report in APM, which is what makes this look like a Coralogix-side problem." `
            -Fix $(if ($isEff) { 'that file is the EFFECTIVE config (base merged with what Fleet Management sends), so the fix belongs in the REMOTE config for this host - a newer base config on disk will not override it. Use deploy\config.supervisor.yaml transform/iis_service_labels as the reference: it reads CX_SERVICES and keeps CX_IIS_SERVICES as a fallback' } else { 're-deploy the current template: deploy\config.supervisor.yaml transform/iis_service_labels reads CX_SERVICES and keeps CX_IIS_SERVICES as a fallback' })
    }
}

# ---------------------------------------------------------------------------------------------
# Stage 4 - recycle
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '--- recycle ---' -ForegroundColor Cyan

# A pool with a failed bootstrap write is left running on purpose: a recycle is a request-path
# restart, and its node.exe children would come back exactly as unable to emit anything. Only pools
# that actually carry the bootstrap are worth that cost.
$skippedPools = @($brokenPools | Where-Object { -not $bootstrapPools.Contains($_) })

if (@($bootstrapPools).Count -eq 0) {
    if (@($skippedPools).Count) {
        Write-Step WARN "nothing is being recycled: the bootstrap landed on none of the $(@($skippedPools).Count) changed pool(s), so a restart would interrupt the request path and change nothing." `
            -Fix 'work from the appcmd messages above, then re-run - this script recycles only pools whose bootstrap is on disk'
    } else {
        Write-Step INFO 'no pool environment actually changed, so no recycle is needed'
    }
} elseif (-not $Recycle) {
    Write-Step WARN "-Recycle:`$false - $(@($bootstrapPools).Count) pool(s) still run the OLD environment: $(@($bootstrapPools) -join ', '). Until they recycle, this host READS as instrumented and emits nothing." `
        -Fix "recycle them in your window: appcmd recycle apppool `"<pool>`""
} else {
    foreach ($p in @($bootstrapPools)) {
        $out = & $appcmd recycle apppool "$p" 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { Write-Step APPLY "recycled pool '$p' - its node.exe children restart with the bootstrap" }
        else { Write-Step FAIL "could not recycle pool '$p': $($out.Trim())" -Fix "recycle it by hand: appcmd recycle apppool `"$p`"" }
    }
    if (@($skippedPools).Count) {
        Write-Step WARN "left $(@($skippedPools).Count) pool(s) un-recycled on purpose - their bootstrap did not land, so a restart would cost a request-path interruption and change nothing: $(@($skippedPools) -join ', ')"
    }
}

# ---------------------------------------------------------------------------------------------
# Stage 5 - what to do next
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host '--- next ---' -ForegroundColor Cyan
Write-Step INFO 'send a request to each instrumented application - a Node SDK emits its first spans on the first request, so an idle app proves nothing'
Write-Step INFO 'grade the host: deploy\Test-IISInstrumentation.ps1 (iisnode findings) and deploy\Test-NodeInstrumentation.ps1 (PM2 + the CX_NODE_SERVICES set)'
Write-Step INFO 'confirm telemetry by QUERY, not by the UI: scripts\Verify-CoralogixNodeSpans.ps1 for the service names above'
Write-Step INFO 'grade the whole host with deploy\Test-Agent.ps1 - it checks CX_SERVICES membership AND whether the collector config in force actually reads it (CX_SERVICES_NOT_CONSUMED)'

Write-Host ''
$summary = ($script:Counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
Write-Host $summary -ForegroundColor Cyan
Write-Log  "counts: $summary"
Write-Log  "=== finished $(Get-Date -Format u) ==="
Write-Host "log: $LogPath" -ForegroundColor DarkGray
Write-Host ''

exit $(if ($script:Counts.FAIL -gt 0) { 1 } else { 0 })
