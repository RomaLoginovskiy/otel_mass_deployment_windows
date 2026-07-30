<#
.SYNOPSIS
  Enumerate the Node.js apps PM2 manages on the local host and resolve a distinct
  OpenTelemetry service name for each. The Node/PM2 analog of Resolve-IISServiceNames.ps1.

.DESCRIPTION
  Dot-source this file to expose the helpers used by the Node/PM2 instrumentation, detection
  and uninstall scripts:

    Get-CxPm2Topology        - HOW PM2 is hosted on this host (user daemon vs Windows service),
                               which account owns it, and where its PM2_HOME is. Works even when
                               the daemon belongs to another account.
    Get-CxPm2DumpApps        - the app set read from dump.pm2 (no daemon needed).
    Invoke-CxPm2             - run the pm2 CLI with PM2_HOME pinned.
    Invoke-CxPm2AsOwner      - run pm2 AS the account that owns the daemon (service-hosted PM2).
    Get-PM2ServiceMap        - enumeration + naming (no side effects). One record per app.
    Get-NodeServiceLabelValue - comma-joined distinct service names for CX_NODE_SERVICES.
    Remove-NodeInstrumentation - uninstall inverse: clear NODE_OPTIONS/OTEL_* off each app.

  Naming convention:
    * OTEL_SERVICE_NAME = the PM2 app name (the .name field in `pm2 jlist`).
      In CLUSTER mode PM2 runs N workers under ONE app name / one PID each; they all share
      this single name so they roll up as one service in Coralogix, while the OTel process
      resource detector still separates the workers by process.pid. This matches the design
      intent: identical service name across workers, per-worker telemetry underneath.

  Overrides: a hashtable keyed by the auto-derived service name (the PM2 app name) whose value
  is the desired replacement name. Applied after auto-naming, mirroring Resolve-IISServiceNames.

.NOTES
  Windows PowerShell 5.1 compatible.

  PM2 IS NOT ALWAYS PER-USER. The original version of this file assumed it was: it ran
  `pm2 jlist` as the caller and treated an empty answer as "no apps". On a host where PM2 was
  installed as a Windows SERVICE (the `pm2-installer` / `pm2-windows-service` / node-windows
  layout - PM2_HOME=C:\ProgramData\pm2, daemon owned by NT AUTHORITY\LOCAL SERVICE) that
  assumption makes every caller silently no-op: the daemon's IPC pipe belongs to the service
  account, so no other identity - not even SYSTEM - can see or restart the apps. Observed on a
  production host running 26 apps with zero Node telemetry as a result.

  So every probe here has a machine-wide path that does not depend on the caller's daemon:
  Win32_Process command lines for the topology, Win32_Service for the owning account, and
  dump.pm2 on disk for the app set.
#>

# PM2's own bookkeeping apps. They are real PM2 apps and will show up in every enumeration,
# but instrumenting them puts PM2's log rotator and metrics exporter into APM as services,
# which is noise no one asked for. Excluded by default; pass -ExcludeApps @() to include them.
$script:CxPm2UtilityApps = @('pm2-logrotate','pm2-prometheus-exporter','pm2-server-monit','pm2-auto-pull')

function Convert-CxJsonEscapes {
    <#
      Unescape a JSON string body pulled out by regex/tokeniser, in ONE left-to-right pass.

      A chain of .Replace() calls cannot do this correctly, however the order is arranged: the
      sequence `\n` appears INSIDE every escaped Windows path whose next segment starts with n, so
      `C:\\node_modules` becomes `C:\<newline>ode_modules` and the path silently stops existing.
      That mangling defeated the ESM probe (it could no longer find the app's package.json, so an
      ESM app running on --require was reported healthy) and would produce a false
      NODE_REGISTER_PATH_STALE for any bootstrap under `\node_modules\`. Consume `\\` as one
      backslash, as a parser does, and the problem disappears.
    #>
    [CmdletBinding()]
    param([string] $Value)

    if (-not $Value) { return $Value }
    $sb = New-Object System.Text.StringBuilder
    $i  = 0
    while ($i -lt $Value.Length) {
        $c = $Value[$i]
        if ($c -ne '\' -or $i -eq $Value.Length - 1) { [void]$sb.Append($c); $i++; continue }
        $n = $Value[$i + 1]
        switch ($n) {
            'n'  { [void]$sb.Append("`n"); $i += 2 }
            'r'  { [void]$sb.Append("`r"); $i += 2 }
            't'  { [void]$sb.Append("`t"); $i += 2 }
            '"'  { [void]$sb.Append('"');  $i += 2 }
            '/'  { [void]$sb.Append('/');  $i += 2 }
            '\'  { [void]$sb.Append('\');  $i += 2 }
            default { [void]$sb.Append($n); $i += 2 }
        }
    }
    return $sb.ToString()
}

function Get-CxRegisterPathFromNodeOptions {
    <#
      Extract the --require target from a NODE_OPTIONS value. Handles both the quoted and
      unquoted forms.

      Canonical copy. Test-NodeInstrumentation.ps1 and Test-IISInstrumentation.ps1 both need it -
      the PM2 doctor reads it off an app's environment, the IIS doctor off an app POOL's - and
      each keeps a fallback definition for the case where this library is not next to it.
    #>
    [CmdletBinding()]
    param([string] $NodeOptions)

    if (-not $NodeOptions) { return $null }
    $m = [regex]::Match($NodeOptions, '--require(?:=|\s+)(?:"([^"]+)"|(\S+))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

function ConvertTo-CxNodeHookKey {
    <#
      One normal form for a --require/--import/--experimental-loader target, so
      `file:///C:/x/hook.mjs`, `C:\x\hook.mjs` and `C:/x/hook.mjs` all compare equal.

      A plain TrimStart of the characters in 'file:/' would corrupt a path on drive F:, hence the
      anchored regex.
    #>
    [CmdletBinding()]
    param([string] $Value)
    if (-not $Value) { return '' }
    $v = $Value.Trim('"') -replace '\\', '/'
    $v = $v -replace '^file:/+', ''
    return $v.ToLowerInvariant()
}

function Remove-CxNodeOptionsBootstrap {
    <#
      Strip OUR bootstrap out of a NODE_OPTIONS value and return what is left - which may be ''.

      This is the uninstall half of Merge-CxNodeOptions, and it exists as its own function because
      the IIS/iisnode path cannot use the PM2 trick of blanking the whole variable. An app pool's
      NODE_OPTIONS is a single merged string that may also carry the application's own flags
      (--max-old-space-size, --tls-*, --icu-data-dir), so blanking it would silently change the
      app's heap ceiling during an uninstall and nothing would report it. Merge-CxNodeOptions calls
      this too, so install and uninstall share ONE definition of "ours".

      -OwnedTargets are the paths/URLs this tooling owns. Values written by an older version of the
      tooling, whose exact prefix we can no longer reconstruct, are still recognised by the package
      markers - otherwise an upgrade would strand a hook forever.
    #>
    [CmdletBinding()]
    param(
        [string]   $Existing,
        [string[]] $OwnedTargets = @()
    )

    if (-not $Existing) { return '' }

    $ourTargets = @{}
    foreach ($t in $OwnedTargets) {
        $k = ConvertTo-CxNodeHookKey -Value $t
        if ($k) { $ourTargets[$k] = $true }
    }

    function Test-CxIsOurHookTarget {
        param([string] $Target)
        if (-not $Target) { return $false }
        $k = ConvertTo-CxNodeHookKey -Value $Target
        if ($ourTargets.ContainsKey($k)) { return $true }
        return [bool]($k -match 'auto-instrumentations-node|opentelemetry')
    }

    $kept = @()
    # Tokenise on whitespace, honouring quoted paths, then drop our own hooks.
    # @() is load-bearing: a SINGLE match pipes out as a bare string, whose .Count is 1 and whose
    # [0] is the first CHARACTER - so a lone '--max-old-space-size=512' silently became '-'. The
    # array wrapper is the difference between preserving the app's flag and corrupting it.
    $tokens = @([regex]::Matches($Existing, '"[^"]*"|\S+') | ForEach-Object { $_.Value })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        # Our ESM loader hook, in the `--experimental-loader=<url>` form. An app's own loader is kept.
        if ($t -match '^--experimental-loader=(.*)$' -and (Test-CxIsOurHookTarget -Target $matches[1])) { continue }
        if ($t -match '^--(require|import)(=(.*))?$') {
            $target = $matches[3]
            if (-not $target -and ($i + 1) -lt $tokens.Count) { $target = $tokens[$i + 1]; $i++ }
            # Only OUR bootstrap is removed; an app's own --require of its own module stays.
            if (Test-CxIsOurHookTarget -Target $target) { continue }
            $kept += $t
            if ($target -and $t -notmatch '=') { $kept += $target }
            continue
        }
        $kept += $t
    }
    return (($kept | Where-Object { $_ }) -join ' ').Trim()
}

function Merge-CxNodeOptions {
    <#
      Combine an app's EXISTING NODE_OPTIONS with our bootstrap flag, preserving its own flags.

      Overwriting the variable is the obvious implementation and it is wrong: an app that sets
      `--max-old-space-size=512` for a reason loses its heap limit the moment it is instrumented,
      and nothing anywhere reports that its memory ceiling just changed. Real apps use NODE_OPTIONS
      for heap size, TLS behaviour, ICU data and stack traces.

      Any PREVIOUS bootstrap for the same package is dropped first, so re-running the instrumenter
      (or switching an app between --require and --import when its module system changes) cannot
      accumulate two hooks - loading the SDK twice is its own failure mode.
    #>
    [CmdletBinding()]
    param(
        [string] $Existing,
        [Parameter(Mandatory)][string] $Bootstrap,
        # Paths/URLs this tooling owns, beyond whatever appears in $Bootstrap itself. Needed because
        # the two artifacts are not always both present in the new value: switching an app from ESM
        # back to CommonJS produces a bootstrap with only register.js, and without being told that
        # hook.mjs is also ours the stale ESM loader stays behind forever. Callers already know both
        # (Resolve-CxNodeBootstrap returns RegisterPath and HookUrl), so this is stated, not guessed
        # from filenames - an app with its own register.js must not be touched.
        [string[]] $OwnedTargets = @()
    )

    # Recognising a PREVIOUS bootstrap by exact target is what makes this idempotent for any install
    # prefix: the older rule matched only paths containing 'opentelemetry' or
    # 'auto-instrumentations-node', which is true of the default prefix by coincidence, so a
    # vendored or differently-prefixed copy (C:/otel/register.js) was not recognised and the SDK
    # ended up loaded TWICE on every re-run.
    #
    # The targets inside $Bootstrap are ours by definition, so they join $OwnedTargets rather than
    # being matched by pattern. Removal itself is Remove-CxNodeOptionsBootstrap, shared with
    # uninstall so the two can never disagree about what belongs to us.
    $bootstrapTargets = @(
        [regex]::Matches($Bootstrap, '(?:--(?:require|import)(?:=|\s+)|--experimental-loader=)("[^"]*"|\S+)') |
            ForEach-Object { $_.Groups[1].Value }
    )
    $kept = Remove-CxNodeOptionsBootstrap -Existing $Existing -OwnedTargets (@($bootstrapTargets) + @($OwnedTargets))
    return ((@($kept, $Bootstrap) | Where-Object { $_ }) -join ' ').Trim()
}

function Resolve-CxNodeBootstrap {
    <#
      Resolve the OTel Node bootstrap flags for an already-installed instrumentation package, and
      return BOTH forms: the CommonJS one and the ESM one.

      This lives here, rather than inline in one instrumenter, because there are now two callers -
      PM2-managed apps and Node running as a plain Windows service - and the ESM half of it is a set
      of measured facts that must not be re-derived per caller:

        --import C:/.../register.js          app CRASHES: Node's ESM resolver reads `C:` as a URL
                                             scheme (ERR_UNSUPPORTED_ESM_URL_SCHEME)
        --import file:///C:/.../register.js  starts cleanly, SDK loads, ZERO spans - nothing
                                             patches ESM imports
        --experimental-loader=file:///.../hook.mjs --require C:/.../register.js
                                             works (17 spans against a real ESM app)

      So the ESM form needs the loader hook as a file:// URL *and* --require for the CommonJS
      register. A missing hook is REPORTED (EsmSupported=$false), never silently accepted: an ESM
      app instrumented without it looks perfectly healthy and emits nothing.

      Returns: RegisterPath, HookUrl, NodeOptionsCjs, NodeOptionsEsm, EsmSupported, Reason.
      Never throws - a caller that cannot instrument should say why, not blow up a deploy.
    #>
    [CmdletBinding()]
    param(
        [string] $InstallPrefix = 'C:\cx\otel-node',
        [string] $Package       = '@opentelemetry/auto-instrumentations-node'
    )

    $result = [pscustomobject]@{
        RegisterPath   = $null
        HookUrl        = $null
        NodeOptionsCjs = $null
        NodeOptionsEsm = $null
        EsmSupported   = $false
        Reason         = $null
    }

    $nodeModules = Join-Path $InstallPrefix 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModules)) {
        $result.Reason = "no node_modules under $InstallPrefix (install the package first, or pass -InstallPrefix)"
        return $result
    }

    # Prefer Node's own require.resolve; fall back to a file search so the package's internal
    # build layout is never hard-coded.
    $env:NODE_PATH = $nodeModules
    $registerPath = $null
    try { $registerPath = (& node -e "console.log(require.resolve('$Package/register'))" 2>$null | Out-String).Trim() } catch { }
    if (-not $registerPath -or -not (Test-Path -LiteralPath $registerPath)) {
        $pkgDir = Join-Path $nodeModules ($Package -replace '/', '\')
        $registerPath = Get-ChildItem -Path $pkgDir -Recurse -Filter 'register.js' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $registerPath -or -not (Test-Path -LiteralPath $registerPath)) {
        $result.Reason = "could not resolve '$Package/register' under $nodeModules"
        return $result
    }

    # NODE_OPTIONS parses backslashes awkwardly; forward slashes are safe on Windows Node.
    $registerFwd = $registerPath -replace '\\', '/'
    $result.RegisterPath   = $registerFwd
    $result.NodeOptionsCjs = "--require $registerFwd"

    $hookPath = $null
    try {
        $instrDir = Join-Path $nodeModules '@opentelemetry\instrumentation'
        $hookPath = Get-ChildItem -Path $instrDir -Filter 'hook.mjs' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    } catch { }

    if ($hookPath) {
        $result.HookUrl        = 'file:///' + ($hookPath -replace '\\', '/')
        $result.NodeOptionsEsm = "--experimental-loader=$($result.HookUrl) --require $registerFwd"
        $result.EsmSupported   = $true
    } else {
        $result.Reason = "no @opentelemetry/instrumentation/hook.mjs under $nodeModules - ESM apps cannot be instrumented (the SDK would load and emit nothing); CommonJS apps are unaffected"
    }

    return $result
}

function Test-CxNodeAppIsEsm {
    <#
      Is this PM2 app an ES module entry point?

      It matters because the bootstrap flag differs and getting it wrong fails SILENTLY:
      `--require` cannot load an ESM graph's instrumentation hooks, so the app starts
      perfectly and emits nothing. ESM needs `--import` (Node >= 18.19 / 20.6).

      Signals, cheapest first: an .mjs entry, then the nearest package.json (script directory,
      then cwd) declaring "type": "module". Returns $false when nothing can be read - the
      CommonJS default is also the common case, and Test-NodeInstrumentation reports the
      mismatch if that guess turns out wrong.
    #>
    [CmdletBinding()]
    param([string] $Script, [string] $Cwd)

    if ($Script -and $Script -match '\.mjs$') { return $true }

    $dirs = @()
    if ($Script) { try { $dirs += (Split-Path -Parent $Script) } catch { } }
    if ($Cwd)    { $dirs += $Cwd }

    foreach ($d in $dirs) {
        if (-not $d) { continue }
        # [IO.Path]::Combine, not Join-Path: an app path on a drive this account cannot see
        # (D:\apps\... on a host where D: is not mounted for us) makes Join-Path raise
        # DriveNotFoundException, which under a caller's Stop preference would take the whole
        # doctor down over a path it only wanted to look at.
        $pkg = $null
        try { $pkg = [System.IO.Path]::Combine($d, 'package.json') } catch { continue }
        if (-not $pkg) { continue }
        if (-not (Test-Path -LiteralPath $pkg -ErrorAction SilentlyContinue)) { continue }
        try {
            $txt = Get-Content -LiteralPath $pkg -Raw -ErrorAction Stop
            # Regex, not ConvertFrom-Json: a package.json can carry case-colliding keys in
            # dependency maps, which throws in 5.1 (see Get-CxPm2DumpApps).
            if ($txt -match '"type"\s*:\s*"module"') { return $true }
            return $false
        } catch { continue }
    }
    return $false
}

function Get-CxPm2CommandPath {
    <#
      Absolute path of a LAUNCHABLE pm2 CLI, or $null.

      Resolved rather than relying on PATH because the two identities that matter here often
      have different ones: `pm2-installer` sets the npm prefix to C:\ProgramData\npm (machine
      scope, may not be in an interactive admin's PATH), and a task running as LOCAL SERVICE
      gets a minimal PATH of its own. Callers pass this absolute path into generated scripts.

      IT MUST BE THE .cmd. npm installs three shims side by side - `pm2` (a shell script),
      `pm2.ps1` and `pm2.cmd` - and `Get-Command pm2` happily returns the .ps1. That is fine for
      `& pm2`, which PowerShell resolves itself, but every caller here hands the path to
      Start-Process or writes it into a generated script, and CreateProcess cannot execute a .ps1
      or an extensionless shell script. The failure is silent: pm2 never runs, the output is
      empty, and the tooling reports "PM2 manages no apps" on a host running two dozen of them.
      So a non-.cmd resolution is converted to its .cmd sibling.
    #>
    [CmdletBinding()]
    param()

    $cmd = Get-Command pm2 -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $src = [string]$cmd.Source
        if ($src -match '\.(cmd|bat|exe)$') { return $src }
        # .ps1 / extensionless: take the .cmd next to it.
        $sibling = [System.IO.Path]::ChangeExtension($src, 'cmd')
        if ($sibling -and (Test-Path -LiteralPath $sibling -ErrorAction SilentlyContinue)) { return $sibling }
        $sibling = "$src.cmd"
        if (Test-Path -LiteralPath $sibling -ErrorAction SilentlyContinue) { return $sibling }
    }

    $candidates = @(
        (Join-Path $env:ProgramData 'npm\pm2.cmd'),
        (Join-Path $env:APPDATA     'npm\pm2.cmd'),
        (Join-Path $env:ProgramFiles 'nodejs\pm2.cmd')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue)) { return $c }
    }
    return $null
}

function Get-CxPm2Home {
    <#
      First existing PM2_HOME candidate, MACHINE scope first.

      Order matters: a service-hosted PM2 keeps its home under ProgramData and belongs to a
      service account, so the per-user ~\.pm2 default is the LAST place to look. Checking it
      first is what made the old detection miss this layout entirely.
    #>
    [CmdletBinding()]
    param()

    $machinePm2Home = $null
    try { $machinePm2Home = [Environment]::GetEnvironmentVariable('PM2_HOME','Machine') } catch { }

    $candidates = @(
        $env:PM2_HOME,
        $machinePm2Home,
        (Join-Path $env:ProgramData 'pm2'),
        (Join-Path $env:ALLUSERSPROFILE 'pm2'),
        (Join-Path $env:USERPROFILE '.pm2')
    )
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue) { return [string]$c }
    }
    return $null
}

function Get-CxPm2Processes {
    <#
      One record per node.exe on the host, classified by command line:

        wrapper - the node-windows service shim that launches the daemon
                  (node-windows\lib\wrapper.js --file ...\pm2\service\index.js)
        daemon  - the PM2 God daemon itself (pm2\lib\Daemon.js|God.js, or
                  ...\pm2\service\index.js when pm2-installer wrapped it as a service)
        worker  - a PM2-managed app (pm2\lib\ProcessContainerFork.js)

      This is the probe that works regardless of who owns the daemon: Win32_Process is
      machine-wide where `pm2 jlist` is per-identity. Owner comes from GetOwner, and is the
      value Invoke-CxPm2AsOwner needs.
    #>
    [CmdletBinding()]
    param()

    $procs = @()
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop)
    } catch {
        # Get-WmiObject for hosts where the CIM/WinRM stack is unhappy but WMI still answers.
        try { $procs = @(Get-WmiObject -Class Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop) } catch { return @() }
    }

    $out = foreach ($p in $procs) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }

        $kind = $null
        if ($cl -match 'node-windows[\\/]lib[\\/]wrapper\.js' -and $cl -match 'pm2') { $kind = 'wrapper' }
        elseif ($cl -match 'pm2[\\/]service[\\/]index\.js')                          { $kind = 'daemon'  }
        elseif ($cl -match 'pm2[\\/]lib[\\/](Daemon|God)\.js')                       { $kind = 'daemon'  }
        elseif ($cl -match 'ProcessContainerFork\.js')                               { $kind = 'worker'  }
        if (-not $kind) { continue }

        $owner = $null
        try {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($o -and $o.User) {
                $owner = if ($o.Domain) { "$($o.Domain)\$($o.User)" } else { [string]$o.User }
            }
        } catch {
            try {
                $o = $p.GetOwner()
                if ($o -and $o.User) { $owner = if ($o.Domain) { "$($o.Domain)\$($o.User)" } else { [string]$o.User } }
            } catch { }
        }

        [pscustomobject]@{
            Kind        = $kind
            Pid         = [int]$p.ProcessId
            ParentPid   = [int]$p.ParentProcessId
            Owner       = $owner
            CommandLine = $cl
        }
    }
    return @($out)
}

function Get-CxPm2Service {
    <#
      The Windows service hosting PM2, or $null.

      StartName is the point of the whole probe: it is the account the daemon runs as, i.e. the
      identity `pm2 restart` has to be run under for the apps to actually hear it.
    #>
    [CmdletBinding()]
    param()

    $svcs = @()
    try {
        $svcs = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    } catch {
        try { $svcs = @(Get-WmiObject -Class Win32_Service -ErrorAction Stop) } catch { return $null }
    }

    foreach ($s in $svcs) {
        $path = [string]$s.PathName
        $name = [string]$s.Name
        # 'pm2' in the image path OR in the service name. It must NOT also require 'node':
        # pm2-installer registers a renamed winsw as `<PM2_HOME>\service\pm2.exe`, so the image path
        # is a bare exe with no mention of node anywhere - and requiring both words meant the probe
        # missed the exact layout it was written for, reporting hosting=none on a host whose PM2 is
        # plainly a service. Verified against a real pm2-installer service layout.
        if (($path -notmatch 'pm2') -and ($name -notmatch 'pm2')) { continue }
        return [pscustomobject]@{
            Name        = [string]$s.Name
            DisplayName = [string]$s.DisplayName
            StartName   = [string]$s.StartName
            State       = [string]$s.State
            PathName    = $path
        }
    }
    return $null
}

function Get-CxPm2Topology {
    <#
      How PM2 is hosted here, who owns it, and whether the CALLER can talk to it:

        Hosting        - 'service' | 'user' | 'none'
        Owner          - account owning the daemon (Win32_Service.StartName, else the daemon
                         process owner)
        Home           - PM2_HOME (inferred from the daemon's own command line when possible,
                         so it is the home the RUNNING daemon uses, not a stale directory)
        ServiceName    - hosting service name, when service-hosted
        DaemonPid      - God daemon pid, when running
        WorkerCount    - number of ProcessContainerFork.js children (a floor on the app count)
        Identity       - the account this process is running as
        OwnerMismatch  - $true when Identity != Owner, i.e. `pm2 jlist` here will NOT see the
                         apps and every pm2 write would be a no-op. This is the condition that
                         has to be reported rather than silently absorbed.
    #>
    [CmdletBinding()]
    param()

    $procs   = @(Get-CxPm2Processes)
    $svc     = Get-CxPm2Service
    $daemon  = @($procs | Where-Object { $_.Kind -eq 'daemon'  }) | Select-Object -First 1
    $wrapper = @($procs | Where-Object { $_.Kind -eq 'wrapper' }) | Select-Object -First 1
    $workers = @($procs | Where-Object { $_.Kind -eq 'worker'  })

    $hosting = 'none'
    if ($svc -or $wrapper) { $hosting = 'service' }
    elseif ($daemon)       { $hosting = 'user'    }

    $owner = $null
    if ($svc -and $svc.StartName) { $owner = $svc.StartName }
    elseif ($daemon)              { $owner = $daemon.Owner }
    elseif ($wrapper)             { $owner = $wrapper.Owner }
    # LocalSystem is Win32_Service's spelling of the SYSTEM account; normalise so the
    # comparison against WindowsIdentity.Name below is meaningful.
    if ($owner -eq 'LocalSystem') { $owner = 'NT AUTHORITY\SYSTEM' }
    # `.\name` is how Win32_Service.StartName reports a LOCAL account, and that literal is not
    # resolvable by LookupAccountName - so icacls, New-ScheduledTaskPrincipal and sc.exe all reject
    # it with Win32 1332 (ERROR_NONE_MAPPED). Seen exactly that: the run-as-owner path failed for a
    # service-hosted PM2 owned by an ordinary local account, with 1332 and nothing else to go on.
    # The machine name is what those APIs accept.
    if ($owner -match '^\.\\(.+)$') { $owner = "$env:COMPUTERNAME\$($matches[1])" }

    # Prefer the home implied by the daemon's command line: '<home>\service\index.js' for the
    # service layout. Falls back to the directory probe.
    #
    # NOT named $home: that is a read-only automatic variable, and assigning it throws
    # "Cannot overwrite variable HOME" while leaving the caller reading the user profile path.
    $pm2HomePath = $null
    if ($daemon -and $daemon.CommandLine -match '([A-Za-z]:[\\/][^"]*?)[\\/]service[\\/]index\.js') {
        $candidate = $matches[1]
        if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { $pm2HomePath = $candidate }
    }
    if (-not $pm2HomePath) { $pm2HomePath = Get-CxPm2Home }

    $identity = $null
    try { $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }

    $mismatch = $false
    if ($owner -and $identity -and ($owner -ne $identity)) { $mismatch = $true }

    [pscustomobject]@{
        Hosting       = $hosting
        Owner         = $owner
        Home          = $pm2HomePath
        ServiceName   = if ($svc) { $svc.Name } else { $null }
        ServiceState  = if ($svc) { $svc.State } else { $null }
        DaemonPid     = if ($daemon) { $daemon.Pid } else { $null }
        WorkerCount   = @($workers).Count
        Identity      = $identity
        OwnerMismatch = $mismatch
    }
}

function Get-CxPm2DumpApps {
    <#
      The app set from "<PM2_HOME>\dump.pm2" - the file `pm2 save` writes and `pm2 resurrect`
      replays. On a service-hosted host this is the only readable source of truth for the app
      list: the file is on disk, the daemon's pipe is not reachable.

      Returns one record per entry: Name / ExecMode / Instances.

      NOT parsed with ConvertFrom-Json: dump.pm2 embeds the captured process environment, whose
      case-differing keys (Path/PATH, Temp/TEMP) collide in PowerShell 5.1's case-insensitive
      JSON dictionary and make it throw outright.

      NOT parsed with a plain '"name":"..."' regex either: dump entries carry nested objects
      that also have a `name` key, so a flat match invents apps that do not exist. Instead the
      blob is tokenised and only keys at the ENTRY's own depth (array -> depth 1, entry object
      -> depth 2) are read.
    #>
    [CmdletBinding()]
    param([string] $Pm2Home)

    if (-not $Pm2Home) { $Pm2Home = Get-CxPm2Home }
    if (-not $Pm2Home) { return @() }

    $dump = Join-Path $Pm2Home 'dump.pm2'
    if (-not (Test-Path -LiteralPath $dump -ErrorAction SilentlyContinue)) { return @() }

    $json = ''
    try { $json = Get-Content -LiteralPath $dump -Raw -ErrorAction Stop } catch { return @() }
    if (-not $json) { return @() }

    # Strings, scalars and structural punctuation. Strings are matched first so a brace or a
    # bare word INSIDE a string value can never be read as structure.
    $tokens = [regex]::Matches($json, '"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|true|false|null|[\{\}\[\]:,]')

    $entries     = @()
    $current     = $null
    $depth       = 0
    $pendingKey  = $null
    $expectValue = $false

    foreach ($m in $tokens) {
        $t = $m.Value

        if ($t -eq '{' -or $t -eq '[') {
            $depth++
            if ($depth -eq 2 -and $t -eq '{') { $current = @{} }
            $pendingKey = $null; $expectValue = $false
            continue
        }
        if ($t -eq '}' -or $t -eq ']') {
            if ($depth -eq 2 -and $t -eq '}' -and $null -ne $current) {
                $entries += ,$current
                $current = $null
            }
            $depth--
            $pendingKey = $null; $expectValue = $false
            continue
        }
        if ($t -eq ':') { $expectValue = $true; continue }
        if ($t -eq ',') { $pendingKey = $null; $expectValue = $false; continue }

        # A value or a key. Only the entry's own level is of interest.
        if ($depth -ne 2 -or $null -eq $current) { continue }

        if ($expectValue) {
            if ($pendingKey) { $current[$pendingKey] = $t.Trim('"') }
            $pendingKey = $null; $expectValue = $false
        } elseif ($t.StartsWith('"')) {
            $pendingKey = $t.Trim('"')
        }
    }

    $out = foreach ($e in $entries) {
        $name = [string]$e['name']
        if (-not $name) { continue }
        $inst = 1
        if ($e.ContainsKey('instances')) {
            $parsed = 0
            if ([int]::TryParse([string]$e['instances'], [ref]$parsed) -and $parsed -gt 0) { $inst = $parsed }
        }
        # script/cwd feed the ESM probe (Test-CxNodeAppIsEsm): an ESM entry point needs
        # --import, not --require. pm2 records the resolved path as pm_exec_path and the
        # configured one as script; either will do.
        $script = [string]$e['pm_exec_path']
        if (-not $script) { $script = [string]$e['script'] }
        [pscustomobject]@{
            Name      = $name
            ExecMode  = [string]$e['exec_mode']
            Instances = $inst
            Script    = (Convert-CxJsonEscapes $script)
            Cwd       = (Convert-CxJsonEscapes ([string]$e['cwd']))
        }
    }
    return @($out)
}

function Get-CxPm2LogApps {
    <#
      Last-resort app set: the basenames of "<PM2_HOME>\logs\<app>-out.log".

      Used only when there is no reachable daemon AND no dump.pm2 (an app started with
      `pm2 start` and never `pm2 save`d). Log files outlive the app that wrote them, so this
      can over-report - callers mark the source so a stale name is attributable.
    #>
    [CmdletBinding()]
    param([string] $Pm2Home)

    if (-not $Pm2Home) { $Pm2Home = Get-CxPm2Home }
    if (-not $Pm2Home) { return @() }

    $logs = Join-Path $Pm2Home 'logs'
    if (-not (Test-Path -LiteralPath $logs -ErrorAction SilentlyContinue)) { return @() }

    $names = @()
    try {
        $names = @(Get-ChildItem -LiteralPath $logs -Filter '*-out.log' -ErrorAction Stop |
                   ForEach-Object { $_.BaseName -replace '-out$','' } |
                   Where-Object { $_ } | Select-Object -Unique)
    } catch { return @() }

    $out = foreach ($n in $names) {
        [pscustomobject]@{ Name = $n; ExecMode = ''; Instances = 1 }
    }
    return @($out)
}

function Invoke-CxPm2 {
    <#
      Run the pm2 CLI with PM2_HOME pinned to $Pm2Home for the duration of the call, bounded by a
      timeout, and return its stdout as a single string ('' on any failure or timeout).

      PM2_HOME selects which daemon the CLI talks to, so leaving it to the caller's profile is
      how a correct app list gets missed. The prior value is restored afterwards - this runs
      inside long-lived install scripts.

      BOUNDED, and not by preference. A pm2 command that has to SPAWN the God daemon can block
      forever when its stdout is a pipe the daemon then inherits and holds open - reproducible
      under `docker exec`, and possible under any remote-execution tool that pipes output
      (BatchPatch included). An unbounded `& pm2 jlist` therefore turns the read-only doctor into
      a command that never returns, which is worse than any wrong answer it could have given.
      Start-Process with a real timeout is the only way to get output AND a deadline in 5.1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Pm2Args,
        [string] $Pm2Home,
        [int]    $TimeoutSec = 60
    )

    # Local Continue: callers run under $ErrorActionPreference=Stop, where pm2's stderr chatter
    # becomes a terminating NativeCommandError in PowerShell 5.1.
    $ErrorActionPreference = 'Continue'

    $exe = Get-CxPm2CommandPath
    if (-not $exe) { return '' }

    $stem  = Join-Path ([System.IO.Path]::GetTempPath()) ('cx-pm2-' + [guid]::NewGuid().ToString('N'))
    $outF  = "$stem.out"
    $errF  = "$stem.err"
    $had   = $null -ne $env:PM2_HOME
    $prior = $env:PM2_HOME
    if ($Pm2Home) { $env:PM2_HOME = $Pm2Home }
    try {
        try {
            $p = Start-Process -FilePath $exe -ArgumentList $Pm2Args -NoNewWindow -PassThru `
                     -RedirectStandardOutput $outF -RedirectStandardError $errF
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                try { $p.Kill() } catch { }
                Write-Verbose "pm2 $($Pm2Args -join ' ') exceeded ${TimeoutSec}s and was killed"
                return ''
            }
        } catch { return '' }
        $raw = ''
        if (Test-Path -LiteralPath $outF) {
            try { $raw = (Get-Content -LiteralPath $outF -Raw -ErrorAction Stop) } catch { }
        }
        if ($null -eq $raw) { return '' }
        return ([string]$raw).Trim()
    } finally {
        Remove-Item -LiteralPath $outF, $errF -Force -ErrorAction SilentlyContinue
        if ($Pm2Home) {
            if ($had) { $env:PM2_HOME = $prior } else { Remove-Item Env:\PM2_HOME -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-CxPm2AsOwner {
    <#
    .SYNOPSIS
      Run pm2 commands AS the account that owns the PM2 daemon, with a given env applied.

    .DESCRIPTION
      Required on hosts where PM2 runs as a Windows service. The daemon's IPC pipe belongs to
      the service account, so `pm2 restart <app> --update-env` issued by anyone else - SYSTEM
      included - cannot reach it: pm2 either starts a SECOND daemon for the caller or reports
      success against an empty app list. Either way the production apps never pick up the
      instrumentation env, which is exactly the silent failure this whole file exists to end.

      TWO MECHANISMS, tried in order, because neither is universally available:

        1. a transient SCHEDULED TASK. Preferred: Task Scheduler's ServiceAccount principal logs
           on LOCAL SERVICE / NETWORK SERVICE / SYSTEM / a gMSA with no password, which an
           impersonation API cannot do.
        2. a transient WINDOWS SERVICE (sc.exe). Needed because Task Scheduler is not always
           there to use - it is disabled by policy on some hardened fleet hosts, and unusable in
           some container images. The SCM logs on the same passwordless accounts.

      Neither can log on an ORDINARY user account without its password. When the daemon belongs to
      one, pass -OwnerCredential; without it this reports precisely that, rather than failing with
      a logon error that looks like a bug in the tooling.

      The generated script pins PM2_HOME, applies -Env, then splats each argv at the pm2 CLI by
      absolute path (the service account's PATH will not have it). It writes a `.done` sentinel
      carrying pm2's exit code as its last act, which is how completion is detected: under the
      service mechanism the SCM kills the launcher after ~30s for never calling
      StartServiceCtrlDispatcher, so the work is deliberately detached from it (`start /b`) and
      cannot be observed through the SCM's own status. Output is captured to a file and echoed by
      the caller's transcript, so a failure inside the task/service is visible rather than being
      swallowed with it.

    .PARAMETER Pm2ArgSets
      Array of argv arrays, run in order - e.g. @( @('restart','my-app','--update-env'), @('save') ).

    .PARAMETER OwnerCredential
      Credential for -Owner, required only when it is an ordinary user account.

    .OUTPUTS
      [pscustomobject] Ok / ExitCode / Output / Reason / Mechanism
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]   $Owner,
        [Parameter(Mandatory)][object[]] $Pm2ArgSets,
        [string]       $Pm2Home,
        [hashtable]    $Env = @{},
        [int]          $TimeoutSec = 300,
        [pscredential] $OwnerCredential
    )

    $fail = { param($reason, $mech) [pscustomobject]@{ Ok = $false; ExitCode = -1; Output = ''; Reason = $reason; Mechanism = $mech } }

    $exe = Get-CxPm2CommandPath
    if (-not $exe) { return (& $fail 'the pm2 CLI could not be located on this host' 'none') }

    $isServiceAccount = Test-CxIsServiceAccount -Account $Owner
    if (-not $isServiceAccount -and -not $OwnerCredential) {
        return (& $fail ("the PM2 daemon belongs to '$Owner', an ordinary account. Neither Task Scheduler nor the SCM " +
                         "can log it on without its password - re-run with -OwnerCredential, or run the instrumenter " +
                         "while signed in as that account.") 'none')
    }

    # A dedicated directory with an EXPLICIT grant to the owner - not $env:TEMP (which belongs to
    # us, not to them) and not C:\Windows\Temp.
    #
    # C:\Windows\Temp looks like the obvious choice and is wrong: its ACL grants SYSTEM,
    # Administrators and Users, and NT AUTHORITY\LOCAL SERVICE is in none of those. A task running as
    # LOCAL SERVICE therefore starts, cannot create its log or its sentinel, and exits - so the wait
    # sees no completion, times out, and reports nothing that explains why. Observed exactly that: a
    # task that reached state Ready having written no output at all. Which would have meant this
    # whole run-as-owner path failing on the commonest service identity there is.
    $workDir  = Join-Path $env:ProgramData 'CoralogixDeploy\pm2-owner'
    $stamp    = [guid]::NewGuid().ToString('N')
    $scriptPs = Join-Path $workDir "cx-pm2-$stamp.ps1"
    $logFile  = Join-Path $workDir "cx-pm2-$stamp.log"
    $doneFile = "$logFile.done"
    try {
        New-Item -ItemType Directory -Force -Path $workDir -ErrorAction Stop | Out-Null
        # Modify, not Full: the owner needs to write the log and the sentinel and read the script.
        $null = & icacls.exe $workDir /grant "${Owner}:(OI)(CI)M" /T /C /Q 2>&1
    } catch {
        return (& $fail "could not prepare the working directory $workDir : $($_.Exception.Message)" 'none')
    }

    # Single-quoted PS literals with '' escaping: values (register paths, app names) are taken
    # verbatim, never re-parsed as PowerShell.
    $q = { param([string]$s) "'" + ([string]$s).Replace("'","''") + "'" }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = ''Continue''')
    $lines.Add('$code = 0')
    if ($Pm2Home) { $lines.Add('$env:PM2_HOME = ' + (& $q $Pm2Home)) }
    foreach ($k in $Env.Keys) {
        $lines.Add(('$env:{0} = {1}' -f $k, (& $q ([string]$Env[$k]))))
    }
    foreach ($argv in $Pm2ArgSets) {
        $items = @($argv | ForEach-Object { & $q $_ }) -join ','
        $lines.Add('$a = @(' + $items + ')')
        $lines.Add('& ' + (& $q $exe) + ' @a')
        $lines.Add('if ($LASTEXITCODE -ne 0) { $code = $LASTEXITCODE }')
    }
    # The sentinel is the completion signal for both mechanisms - written last, and always.
    $lines.Add('Set-Content -LiteralPath ' + (& $q $doneFile) + ' -Value ([string]$code) -Encoding ASCII')
    $lines.Add('exit $code')

    try {
        Set-Content -LiteralPath $scriptPs -Value ($lines -join "`r`n") -Encoding ASCII -ErrorAction Stop
    } catch {
        return (& $fail "could not write the helper script to $scriptPs : $($_.Exception.Message)" 'none')
    }

    $attempts = @()
    $result   = $null
    try {
        foreach ($mech in @('scheduledTask', 'transientService')) {
            $r = switch ($mech) {
                'scheduledTask'    { Invoke-CxOwnerViaScheduledTask    -Owner $Owner -ScriptPath $scriptPs -LogFile $logFile -DoneFile $doneFile -TimeoutSec $TimeoutSec -OwnerCredential $OwnerCredential }
                'transientService' { Invoke-CxOwnerViaTransientService -Owner $Owner -ScriptPath $scriptPs -LogFile $logFile -DoneFile $doneFile -TimeoutSec $TimeoutSec -OwnerCredential $OwnerCredential }
            }
            $r | Add-Member -NotePropertyName Mechanism -NotePropertyValue $mech -Force
            if ($r.Ok) { $result = $r; break }
            $attempts += "$mech`: $($r.Reason)"
            Write-Verbose "[node-instr] $mech could not run pm2 as $Owner - $($r.Reason)"
        }
        if (-not $result) {
            $result = & $fail ("could not run pm2 as ${Owner}. " + ($attempts -join ' ; ')) 'none'
        }
    } finally {
        Remove-Item -LiteralPath $scriptPs -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $logFile  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $doneFile -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Test-CxIsServiceAccount {
    <#
      Can Windows log this account on WITHOUT a password? True for the built-in service
      identities and for a group managed service account (trailing '$'), false for an ordinary
      user - which is the difference between -LogonType ServiceAccount working and failing with a
      logon error.
    #>
    [CmdletBinding()]
    param([string] $Account)

    if (-not $Account) { return $false }
    $a = $Account.Trim()
    if ($a -match '\$$') { return $true }   # gMSA
    $wellKnown = @(
        'LocalSystem', 'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\LOCAL SERVICE', 'NT AUTHORITY\NETWORK SERVICE',
        'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'NT AUTHORITY\LOCALSERVICE', 'NT AUTHORITY\NETWORKSERVICE'
    )
    foreach ($w in $wellKnown) { if ($a -eq $w) { return $true } }
    return $false
}

function Invoke-CxOwnerViaScheduledTask {
    <# Mechanism 1: a transient scheduled task. See Invoke-CxPm2AsOwner. #>
    [CmdletBinding()]
    param(
        [string] $Owner, [string] $ScriptPath, [string] $LogFile, [string] $DoneFile,
        [int] $TimeoutSec, [pscredential] $OwnerCredential
    )
    $out = { param($ok, $code, $reason) [pscustomobject]@{ Ok = $ok; ExitCode = $code; Output = (Get-CxOwnerLog $LogFile); Reason = $reason } }

    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        return (& $out $false -1 'the ScheduledTasks module is not available on this host')
    }
    $taskName = 'cx-pm2-' + [IO.Path]::GetFileNameWithoutExtension($ScriptPath).Replace('cx-pm2-','')
    try {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" > "{1}" 2>&1' -f $ScriptPath, $LogFile
        # cmd.exe hosts the redirection: ScheduledTaskAction has no stdout capture of its own.
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument ('/c powershell.exe ' + $arg)
        $principal = if ($OwnerCredential) {
            New-ScheduledTaskPrincipal -UserId $Owner -LogonType Password -RunLevel Highest
        } else {
            New-ScheduledTaskPrincipal -UserId $Owner -LogonType ServiceAccount -RunLevel Highest
        }
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::FromSeconds([Math]::Max($TimeoutSec, 60)))

        # Built as an object first, then registered: Register-ScheduledTask puts -Principal and
        # -User/-Password in DIFFERENT parameter sets, so passing both is a binding error. Only
        # -InputObject accepts a principal alongside a password.
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
        $reg  = @{ TaskName = $taskName; InputObject = $task; Force = $true; ErrorAction = 'Stop' }
        if ($OwnerCredential) { $reg['User'] = $Owner; $reg['Password'] = $OwnerCredential.GetNetworkCredential().Password }
        Register-ScheduledTask @reg | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        $tn = $taskName
        $w = Wait-CxOwnerDone -DoneFile $DoneFile -TimeoutSec $TimeoutSec -IsAlive {
                 ((Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue).State -eq 'Running')
             }
        if ($w.State -eq 'done') {
            if ($w.Code -eq 0) { return (& $out $true 0 '') }
            return (& $out $false $w.Code "pm2 exited $($w.Code) as $Owner")
        }
        # Not running and no sentinel: ask the SCM why, so the reason names the cause.
        $info = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
        $rc = if ($info) { [int]$info.LastTaskResult } else { -1 }
        $why = if ($w.State -eq 'dead') { "the task stopped without completing" } else { "the task did not complete within ${TimeoutSec}s" }
        return (& $out $false $rc "$why (LastTaskResult=$rc)")
    } catch {
        return (& $out $false -1 $_.Exception.Message)
    } finally {
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-CxOwnerViaTransientService {
    <#
      Mechanism 2: a short-lived Windows service running as the owner.

      The launcher is `cmd /c start "" /b powershell -File <script>` on purpose. A service binary
      that never calls StartServiceCtrlDispatcher is terminated by the SCM after
      ServicesPipeTimeout (~30s by default), which would kill a pm2 restart mid-flight; detaching
      the real work means the SCM can time the launcher out (error 1053, expected and ignored)
      while the work continues. Completion is therefore read from the script's own sentinel, never
      from the service's status.
    #>
    [CmdletBinding()]
    param(
        [string] $Owner, [string] $ScriptPath, [string] $LogFile, [string] $DoneFile,
        [int] $TimeoutSec, [pscredential] $OwnerCredential
    )
    $out = { param($ok, $code, $reason) [pscustomobject]@{ Ok = $ok; ExitCode = $code; Output = (Get-CxOwnerLog $LogFile); Reason = $reason } }

    # Service names may not contain characters sc.exe treats specially; keep it short and alnum.
    $svcName = 'cxpm2' + ([IO.Path]::GetFileNameWithoutExtension($ScriptPath) -replace '[^0-9a-zA-Z]', '').Substring(0, 12)

    # The quoted command lives in a generated .cmd, and binPath points at THAT with no quotes of its
    # own. sc.exe re-parses its own command line, and a binPath value containing embedded quotes
    # makes it print its usage text and create nothing - reporting no error the caller can see,
    # which would silently disable this entire fallback. Verified against sc.exe directly.
    $launcher = [IO.Path]::ChangeExtension($ScriptPath, 'cmd')
    $launchBody = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath" > "$LogFile" 2>&1
"@
    try { Set-Content -LiteralPath $launcher -Value $launchBody -Encoding ASCII -ErrorAction Stop }
    catch { return (& $out $false -1 "could not write the service launcher to $launcher : $($_.Exception.Message)") }

    $bin = '{0}\System32\cmd.exe /c start /b {1}' -f $env:SystemRoot, $launcher
    try {
        $null = & sc.exe delete $svcName 2>&1
        $createArgs = @('create', $svcName, 'binPath=', $bin, 'type=', 'own', 'start=', 'demand', 'obj=', $Owner)
        if ($OwnerCredential) { $createArgs += @('password=', $OwnerCredential.GetNetworkCredential().Password) }
        $cr = & sc.exe @createArgs 2>&1 | Out-String
        if ($cr -notmatch 'SUCCESS') { return (& $out $false -1 ("sc create failed: " + ($cr.Trim() -replace "`r?`n", ' '))) }

        # Expected to "fail" with 1053; the work is detached and already running.
        $null = & sc.exe start $svcName 2>&1

        # Liveness proxy: the `>` redirect creates the log the instant cmd.exe runs, so no log after
        # the grace period means the SCM never launched anything (a refused logon, most likely).
        $lf = $LogFile
        $w = Wait-CxOwnerDone -DoneFile $DoneFile -TimeoutSec $TimeoutSec -IsAlive { Test-Path -LiteralPath $lf }
        if ($w.State -eq 'done') {
            if ($w.Code -eq 0) { return (& $out $true 0 '') }
            return (& $out $false $w.Code "pm2 exited $($w.Code) as $Owner")
        }
        $why = if ($w.State -eq 'dead') { "the SCM never launched it (check that '$Owner' may log on as a service)" }
               else { "it did not complete within ${TimeoutSec}s" }
        return (& $out $false -1 "the transient service failed: $why")
    } catch {
        return (& $out $false -1 $_.Exception.Message)
    } finally {
        $null = & sc.exe delete $svcName 2>&1
        Remove-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
    }
}

function Wait-CxOwnerDone {
    <#
      Wait for the sentinel the generated script writes last.

      Returns @{ State = 'done'|'dead'|'timeout'; Code = <pm2 exit code, when done> }.

      -IsAlive matters more than it looks. Without it, a mechanism that accepted the work but never
      actually ran it (a task that fails to launch, a service the SCM refused) is indistinguishable
      from one still working, so the caller waits out the FULL timeout - and then does it again for
      the next app. On a host with two dozen apps that is hours of a deploy doing nothing. So once
      a short grace has passed, a mechanism that is demonstrably not running is reported dead
      immediately, and the caller can fall through to the other mechanism while the change window
      is still open.

      The grace period exists because the opposite mistake is just as bad: a task that finishes
      quickly is already back to 'Ready' by the time we look, microseconds before its sentinel
      lands. An unreadable liveness check counts as alive - guessing "dead" would abandon work that
      is running.
    #>
    [CmdletBinding()]
    param([string] $DoneFile, [int] $TimeoutSec, [scriptblock] $IsAlive, [int] $GraceSec = 20)

    $start    = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $DoneFile) {
            $raw = ''
            try { $raw = (Get-Content -LiteralPath $DoneFile -Raw -ErrorAction Stop).Trim() } catch { }
            $n = 0
            if ([int]::TryParse($raw, [ref]$n)) { return @{ State = 'done'; Code = $n } }
            return @{ State = 'done'; Code = 0 }
        }
        if ($IsAlive -and ((Get-Date) - $start).TotalSeconds -ge $GraceSec) {
            $alive = $true
            try { $alive = [bool](& $IsAlive) } catch { $alive = $true }
            if (-not $alive) { return @{ State = 'dead'; Code = -1 } }
        }
        Start-Sleep -Milliseconds 500
    }
    return @{ State = 'timeout'; Code = -1 }
}

function Get-CxOwnerLog {
    [CmdletBinding()]
    param([string] $LogFile)
    if (-not $LogFile -or -not (Test-Path -LiteralPath $LogFile)) { return '' }
    try { return (Get-Content -LiteralPath $LogFile -Raw -ErrorAction Stop) } catch { return '' }
}

function Get-PM2ProcessList {
    <#
      One object per PM2 process as [pscustomobject]@{ Name; Pid; ExecMode; Status; Source },
      or @() when nothing could be learned. Cluster workers repeat the same Name.

      Sources, in order of authority:
        'jlist' - the live daemon answered (PM2_HOME pinned to $Pm2Home).
        'dump'  - dump.pm2 on disk. Used when the daemon is unreachable from this identity,
                  which is the normal case for a service-hosted PM2.
        'logs'  - "<home>\logs\<app>-out.log" basenames. Can over-report; see Get-CxPm2LogApps.

      IMPORTANT: `pm2 jlist` emits JSON with DUPLICATE keys, and Windows PowerShell 5.1's
      ConvertFrom-Json throws `DuplicateKeysInJsonString` on it - so we do NOT use ConvertFrom-Json.
      Instead we split the array into per-process chunks (each top-level object starts with
      `{"pid":`) and pull the fields we need by regex. The top-level "name" is the one immediately
      after the pid, which is exactly the app name we want.
    #>
    [CmdletBinding()]
    param([string] $Pm2Home)

    # Force Continue locally: callers (Instrument-NodePM2.ps1) run under $ErrorActionPreference=Stop,
    # where redirecting pm2's stderr (`2>$null`) turns its chatter into a terminating
    # NativeCommandError in Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'

    if (-not $Pm2Home) {
        $topo = Get-CxPm2Topology
        $Pm2Home = $topo.Home
    }

    $raw = Invoke-CxPm2 -Pm2Args @('jlist') -Pm2Home $Pm2Home
    if ($raw -and $raw.StartsWith('[')) {
        # Collect via foreach (plain array) - do NOT use System.Collections.Generic.List here: PS 5.1
        # throws "Argument types do not match" when that list is later wrapped with @(...).
        $out = foreach ($chunk in ($raw -split '\{"pid":')) {
            if ($chunk -notmatch '"name":"') { continue }   # skip the leading '[' fragment
            $name = if ($chunk -match '"name":"([^"]+)"')      { $matches[1] } else { $null }
            if (-not $name) { continue }
            $ppid = if ($chunk -match '^\s*(\d+)')             { [int]$matches[1] } else { $null }
            $mode = if ($chunk -match '"exec_mode":"([^"]+)"') { $matches[1] } else { '' }
            $stat = if ($chunk -match '"status":"([^"]+)"')    { $matches[1] } else { '' }
            $scr  = if ($chunk -match '"pm_exec_path":"((?:[^"\\]|\\.)*)"') { Convert-CxJsonEscapes $matches[1] } else { '' }
            $cwd  = if ($chunk -match '"cwd":"((?:[^"\\]|\\.)*)"')          { Convert-CxJsonEscapes $matches[1] } else { '' }
            # The app's CURRENT NODE_OPTIONS, so instrumenting can preserve its own flags rather
            # than replacing them (Merge-CxNodeOptions).
            $nopt = if ($chunk -match '"NODE_OPTIONS":"((?:[^"\\]|\\.)*)"')  { Convert-CxJsonEscapes $matches[1] } else { '' }
            [pscustomobject]@{ Name = $name; Pid = $ppid; ExecMode = $mode; Status = $stat; Source = 'jlist'
                               Script = $scr; Cwd = $cwd; NodeOptions = $nopt }
        }
        if (@($out).Count -gt 0) { return @($out) }
    }

    # The daemon told us nothing. Fall back to disk rather than concluding "no apps" - on a
    # service-hosted host that conclusion is wrong and costs the customer all Node telemetry.
    foreach ($fallback in @('dump','logs')) {
        $apps = if ($fallback -eq 'dump') { Get-CxPm2DumpApps -Pm2Home $Pm2Home } else { Get-CxPm2LogApps -Pm2Home $Pm2Home }
        if (@($apps).Count -eq 0) { continue }
        $out = foreach ($a in $apps) {
            [pscustomobject]@{ Name = $a.Name; Pid = $null; ExecMode = $a.ExecMode; Status = ''
                               Source = $fallback; Instances = $a.Instances
                               Script = [string]$a.Script; Cwd = [string]$a.Cwd }
        }
        return @($out)
    }
    return @()
}

function Get-PM2ServiceMap {
    <#
      One record per PM2-managed app (deduped by name, since cluster workers repeat the name):
        Name        - PM2 app name
        ServiceName - OTEL_SERVICE_NAME to assign (Name, unless overridden)
        ExecMode    - 'fork_mode' | 'cluster_mode'
        Instances   - worker count PM2 reports for the app
        Source      - 'jlist' | 'dump' | 'logs' (where the app was learned from)
        Hosting     - 'service' | 'user' | 'none'
        Owner       - account owning the PM2 daemon
        Pm2Home     - PM2_HOME the daemon uses

      -ExcludeApps defaults to PM2's own utility apps ($script:CxPm2UtilityApps); pass @() to
      instrument those too.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Overrides = @{},
        [string]    $Pm2Home,
        [object[]]  $ExcludeApps,
        $Topology = $null
    )

    if (-not $Topology) { $Topology = Get-CxPm2Topology }
    if (-not $Pm2Home)  { $Pm2Home  = $Topology.Home }
    # An explicitly-passed empty array must be honoured, so test for the bound parameter
    # rather than for emptiness.
    if (-not $PSBoundParameters.ContainsKey('ExcludeApps')) { $ExcludeApps = $script:CxPm2UtilityApps }
    $excluded = @($ExcludeApps | Where-Object { $_ })

    $list = Get-PM2ProcessList -Pm2Home $Pm2Home
    $byName = [ordered]@{}
    foreach ($p in $list) {
        $name = [string]$p.Name
        if (-not $name) { continue }
        if ($excluded -contains $name) { continue }
        if ($byName.Contains($name)) {
            # Additional cluster worker of an app already seen: bump the instance tally.
            $byName[$name].Instances++
            continue
        }
        $mode = [string]$p.ExecMode
        # dump/logs records carry an Instances count of their own; jlist records are counted
        # by repetition above.
        $inst = 1
        if ($p.PSObject.Properties['Instances'] -and $p.Instances) { $inst = [int]$p.Instances }
        $script = if ($p.PSObject.Properties['Script'])      { [string]$p.Script }      else { '' }
        $cwd    = if ($p.PSObject.Properties['Cwd'])         { [string]$p.Cwd }         else { '' }
        $nopt   = if ($p.PSObject.Properties['NodeOptions']) { [string]$p.NodeOptions } else { '' }
        $byName[$name] = [pscustomobject]@{
            Name        = $name
            ServiceName = $name
            ExecMode    = $mode
            Instances   = $inst
            Source      = [string]$p.Source
            Hosting     = $Topology.Hosting
            Owner       = $Topology.Owner
            Pm2Home     = $Pm2Home
            Script      = $script
            Cwd         = $cwd
            NodeOptions = $nopt
            IsEsm       = [bool](Test-CxNodeAppIsEsm -Script $script -Cwd $cwd)
        }
    }

    # Extract values by key (avoid @($orderedDict.Values), which can also trip the PS 5.1
    # "Argument types do not match" wrapping bug).
    $records = foreach ($k in $byName.Keys) { $byName[$k] }

    # Apply overrides keyed by the auto-derived service name (the PM2 app name).
    if ($Overrides -and $Overrides.Count -gt 0) {
        foreach ($r in $records) {
            if ($Overrides.ContainsKey($r.ServiceName)) { $r.ServiceName = [string]$Overrides[$r.ServiceName] }
        }
    }
    return $records
}

function Get-NodeServiceLabelValue {
    <#
    .SYNOPSIS
      Comma-joined distinct Node service name(s) for the CX_NODE_SERVICES machine env var.

    .DESCRIPTION
      The Node analog of Get-IISServiceLabelValue: feeds CX_NODE_SERVICES so the collector can
      stamp the host's Node service ownership onto infrastructure telemetry, aligned with the
      per-app OTEL_SERVICE_NAME. Pass the SAME $Map used to assign each app's OTEL_SERVICE_NAME
      to keep that alignment. When -Map is omitted it re-enumerates (standalone use); an
      explicitly-passed empty array is honored (returns '').

      Names are joined with ','; a name containing a comma would mis-split into multiple
      ownership items - avoid commas in PM2 app names and override values.
    #>
    [CmdletBinding()]
    param(
        [object[]]  $Map,
        [hashtable] $Overrides = @{}
    )
    if (-not $PSBoundParameters.ContainsKey('Map')) { $Map = Get-PM2ServiceMap -Overrides $Overrides }
    $names = @($Map | ForEach-Object { $_.ServiceName } | Where-Object { $_ } | Select-Object -Unique)
    return ($names -join ',')
}

function Remove-NodeInstrumentation {
    <#
      Inverse of Instrument-NodePM2.ps1 - used by Uninstall-Agent.ps1.

      For each PM2 app, disable the OTel bootstrap by clearing NODE_OPTIONS (and the OTEL_*
      vars), then `pm2 restart <name> --update-env` so the app's runtime env is refreshed
      WITHOUT the --require hook. An empty NODE_OPTIONS reliably prevents the instrumentation
      from loading regardless of PM2's env-merge semantics. Finishes with `pm2 save` so the
      cleaned env persists across a daemon restart / resurrect.

      Mirrors the install path's ownership handling: when PM2 is service-hosted and this
      identity does not own the daemon, the restarts are issued through
      Invoke-CxPm2AsOwner. Without that, uninstall silently no-ops on exactly the hosts
      where install had to work that way - leaving apps instrumented against a register
      path the uninstall just deleted.

      Best-effort: if PM2 is absent or has no apps, it is a no-op.
    #>
    [CmdletBinding()]
    param([object[]] $Map, [pscredential] $OwnerCredential)

    # See Get-PM2ProcessList: keep pm2's stderr non-fatal under a caller's Stop preference.
    $ErrorActionPreference = 'Continue'

    $topo = Get-CxPm2Topology
    if (-not (Get-CxPm2CommandPath) -and $topo.Hosting -eq 'none') {
        Write-Host "[node-uninstall] pm2 not found - nothing to revert."
        return
    }
    if (-not $PSBoundParameters.ContainsKey('Map')) { $Map = Get-PM2ServiceMap -Topology $topo }
    if (-not $Map -or @($Map).Count -eq 0) {
        Write-Host "[node-uninstall] no PM2 apps - nothing to revert."
        return
    }

    # A SPACE, not an empty string.
    #
    # On Windows, setting an environment variable to '' DELETES it, and `pm2 restart --update-env`
    # merges the caller's environment OVER the app's - so a deleted variable is not an override, it
    # is an absence, and the app keeps the NODE_OPTIONS it already had. Uninstall therefore reported
    # success while leaving every app instrumented, which is what the shape matrix caught by reading
    # the app's env back afterwards. (The original `$env:NODE_OPTIONS = ''` had the same effect, so
    # this predates the service-hosting work.)
    #
    # A single space is a present, non-empty value that propagates through the merge, and Node parses
    # it as no options at all - so the bootstrap is gone and nothing else changes. The OTEL_* vars get
    # the same treatment for the same reason; with no --require/--import there is no SDK to read them
    # anyway.
    $blank   = ' '
    $cleared = [ordered]@{
        NODE_OPTIONS                = $blank
        OTEL_SERVICE_NAME           = $blank
        OTEL_EXPORTER_OTLP_ENDPOINT = $blank
        OTEL_EXPORTER_OTLP_PROTOCOL = $blank
        OTEL_TRACES_EXPORTER        = $blank
        OTEL_METRICS_EXPORTER       = $blank
        OTEL_LOGS_EXPORTER          = $blank
    }

    if ($topo.Hosting -eq 'service' -and $topo.OwnerMismatch -and $topo.Owner) {
        $argSets = @()
        foreach ($r in $Map) { $argSets += ,@('restart', [string]$r.Name, '--update-env') }
        $argSets += ,@('save')
        $ownerArgs = @{ Owner = $topo.Owner; Pm2Home = $topo.Home; Env = $cleared; Pm2ArgSets = $argSets }
        if ($OwnerCredential) { $ownerArgs['OwnerCredential'] = $OwnerCredential }
        $res = Invoke-CxPm2AsOwner @ownerArgs
        if ($res.Output) { Write-Host $res.Output }
        if ($res.Ok) {
            Write-Host "[node-uninstall] NODE_OPTIONS cleared on $(@($Map).Count) app(s) as $($topo.Owner)"
        } else {
            Write-Warning "[node-uninstall] could not clear NODE_OPTIONS as $($topo.Owner): $($res.Reason). The apps are still instrumented - re-run this as that account."
        }
        return
    }

    # Clear the instrumentation env in THIS process so --update-env refreshes each app without it.
    #
    # SetEnvironmentVariable, NOT `Set-Item Env:\X -Value ''`. Set-Item REFUSES an empty value
    # ("Cannot bind argument to parameter 'Value' because it is an empty string") - and with
    # -ErrorAction SilentlyContinue that refusal is invisible, so NODE_OPTIONS kept its old value,
    # `pm2 restart --update-env` re-applied it, and uninstall reported success while leaving every
    # app instrumented. Caught by the shape matrix reading the app's env back afterwards.
    # $cleared[$k], not a hardcoded '' - the values are a single SPACE for the reason documented
    # above, and writing '' here instead deletes the variable, which `pm2 restart --update-env` then
    # has nothing to override with. That is precisely how this path kept reporting success while
    # leaving the bootstrap in place, even after the values were changed. Verified against pm2:
    # a space-valued NODE_OPTIONS propagates, an empty one does not.
    foreach ($k in $cleared.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$cleared[$k], 'Process') }

    foreach ($r in $Map) {
        try {
            Invoke-CxPm2 -Pm2Args @('restart', [string]$r.Name, '--update-env') -Pm2Home $topo.Home | Out-Null
            Write-Host "[node-uninstall] $($r.Name): NODE_OPTIONS cleared (instrumentation off)"
        } catch { Write-Warning "[node-uninstall] pm2 restart $($r.Name) failed: $_" }
    }
    Invoke-CxPm2 -Pm2Args @('save') -Pm2Home $topo.Home | Out-Null
}
