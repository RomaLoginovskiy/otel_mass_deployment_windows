<#
.SYNOPSIS
  Read-only check that the zero-code Node.js/PM2 instrumentation was actually
  APPLIED on this host - the OTel package, NODE_OPTIONS on each PM2 app, and the
  per-app service names.

.DESCRIPTION
  DUAL MODE.
    * Run it directly            -> prints a table and exits 0 / 1 / 2.
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-NodeInstrumentation.ps1
    * Dot-source it              -> defines Test-NodeInstrumentation and returns
                                    findings for an aggregator (Test-Agent.ps1).
        . .\Test-NodeInstrumentation.ps1 ; $f = Test-NodeInstrumentation

  Sub-checks:
    a. nodePackage   the OTel auto-instrumentation package is staged under
                     InstallPrefix and its `register` bootstrap exists
    b. nodeOptions   every PM2 app carries NODE_OPTIONS=--require <register>,
                     and that register path still exists on disk
    c. nodeService   every PM2 app carries OTEL_SERVICE_NAME, and the set of
                     names matches the machine var CX_NODE_SERVICES
    d. nodeOwnership whether any collector config actually CONSUMES
                     CX_NODE_SERVICES (see the note below)

  READ-ONLY. Runs `pm2 jlist` (a query), reads the machine environment and files.
  Never restarts an app, never writes an env var, never calls `pm2 save`.

.NOTES
  Windows PowerShell 5.1.

  TWO TRAPS, both already paid for in this repo:

  1. NEVER `ConvertFrom-Json` the output of `pm2 jlist`. PM2 copies the whole
     process environment into pm2_env, and PowerShell 5.1 deserialises a JSON
     object into a CASE-INSENSITIVE dictionary. Two env keys differing only in
     case - which Windows environments routinely carry (Path/PATH, Temp/TEMP) -
     therefore collide and ConvertFrom-Json throws outright:

         '{"Name":"x","name":"y"}' | ConvertFrom-Json
         -> Cannot convert the JSON string because a dictionary that was
            converted from the string contains the duplicated keys 'Name' and 'name'.

     (Exact same-case duplicates are merely last-wins and do NOT throw, so this
     failure is intermittent across hosts - which is worse than a hard one, and
     the reason for parsing the blob with regex instead. Same approach as
     test/docker-win/entrypoint.ps1.)

  2. PM2 IS PER-USER ON WINDOWS. The daemon this script can see is the one owned
     by the account running it - which, when run elevated, is often NOT the
     account that owns the production apps. When PM2 looks installed but reports
     no apps, this script returns `unknown`, never `fail`. Reporting
     "instrumentation missing" because we queried the wrong daemon would send an
     operator down entirely the wrong path.
#>
# PositionalBinding=$false: reject stray tokens instead of silently binding them
# to the wrong parameter (see Test-Agent.ps1 for the failure this prevents).
[CmdletBinding(PositionalBinding = $false)]
param(
    # Where Instrument-NodePM2.ps1 stages the package (its -InstallPrefix default).
    [string] $InstallPrefix         = 'C:\cx\otel-node',
    [string] $Package               = '@opentelemetry/auto-instrumentations-node',
    [string] $ExpectedOtlpEndpoint  = 'http://127.0.0.1:4318',
    # Used only to answer "does anything consume CX_NODE_SERVICES?".
    [string] $EffectiveConfig       = 'C:\ProgramData\opampsupervisor\state\effective.yaml',
    [switch] $Quiet,
    [switch] $PassThru
)

# pm2 is a native command that writes to stderr; under 'Stop' that becomes a
# terminating NativeCommandError in PS 5.1 (test/docker-win/Run-DockerWinTest.ps1).
$ErrorActionPreference = 'Continue'

$script:CxNodeHere = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

$fmt = Join-Path $script:CxNodeHere 'Write-DeployLog.ps1'
if (Test-Path -LiteralPath $fmt -ErrorAction SilentlyContinue) {
    try { . $fmt } catch { }
}
if (-not (Get-Command New-Finding -ErrorAction SilentlyContinue)) {
    function New-Finding {
        param([string]$Check, [string]$Severity, [string]$Code = '', [string]$Message = '', [string]$Target = '', $Data = $null)
        [pscustomobject]@{ check = $Check; severity = $Severity; code = $Code; target = $Target; message = $Message; data = $Data }
    }
}
if (-not (Get-Command Get-GradedExitCode -ErrorAction SilentlyContinue)) {
    function Get-GradedExitCode {
        param([object[]]$Findings)
        $f = @($Findings) | Where-Object { $_ }
        if (@($f | Where-Object { $_.severity -eq 'fail' }).Count -gt 0) { return 1 }
        if (@($f | Where-Object { $_.severity -eq 'warn' }).Count -gt 0) { return 2 }
        return 0
    }
}
if (-not (Get-Command Write-FindingTable -ErrorAction SilentlyContinue)) {
    function Write-FindingTable {
        param([object[]]$Findings, [string]$Title, [switch]$Quiet)
        if ($Title) { Write-Host ''; Write-Host "== $Title ==" }
        foreach ($f in @($Findings)) {
            if (-not $f) { continue }
            if ($Quiet -and ($f.severity -eq 'pass' -or $f.severity -eq 'skip')) { continue }
            Write-Host ("  [{0,-7}] {1} {2} {3}" -f $f.severity.ToUpperInvariant(), $f.check, $f.target, $f.message)
        }
    }
}
if (-not (Get-Command Write-FindingSummary -ErrorAction SilentlyContinue)) {
    function Write-FindingSummary {
        param([object[]]$Findings, [string]$Label = 'RESULT', [int]$ExitCode = -1)
        if ($ExitCode -lt 0) { $ExitCode = Get-GradedExitCode -Findings $Findings }
        Write-Host "=== $Label RESULT: exit=$ExitCode ==="
    }
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

function Get-CxJsonString {
    <#
      Pull a JSON string value out of a raw blob by key, honouring backslash
      escapes. Returns $null when the key is absent.

      This exists because ConvertFrom-Json cannot be used here (see .NOTES).
    #>
    [CmdletBinding()]
    param([string] $Json, [Parameter(Mandatory)][string] $Key)

    if (-not $Json) { return $null }
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"((?:[^"\\]|\\.)*)"'
    $m = [regex]::Match($Json, $pattern)
    if (-not $m.Success) { return $null }

    # Unescape the JSON string body. Order matters: \\ last would double-process.
    $v = $m.Groups[1].Value
    $v = $v -replace '\\u0026', '&'
    $v = $v.Replace('\/', '/').Replace('\"', '"').Replace('\n', "`n").Replace('\r', "`r").Replace('\t', "`t")
    $v = $v.Replace('\\', '\')
    return $v
}

function Test-CxPm2Available {
    [bool](Get-Command pm2 -ErrorAction SilentlyContinue)
}

function Test-CxNodeWorkloadPresent {
    <#
      Is there Node/PM2 activity on this host at all, regardless of whether THIS
      account's pm2 daemon can see it? Used to tell "no Node here" (skip) apart
      from "wrong daemon" (unknown).
    #>
    $procs = @(Get-Process -Name 'node','pm2','PM2' -ErrorAction SilentlyContinue)
    return ($procs.Count -gt 0)
}

function Get-CxPm2Apps {
    <#
      Query the PM2 daemon and return one record per app.

      Returns:
        $null        - pm2 could not be queried at all (not installed / errored)
        @()          - pm2 answered, and it manages no apps
        @(records)   - one per app

      Parsing: the jlist payload is a JSON array of app objects, each of which
      begins with "pid". Split on that boundary and regex within each chunk.
      Deliberately NOT ConvertFrom-Json - see trap 1 in .NOTES (case-differing
      env keys make 5.1 throw). Where a key appears at both pm2_env level and
      inside pm2_env.env, the first match wins, which is the pm2_env value -
      the one the running process actually inherited.
    #>
    [CmdletBinding()]
    param()

    $raw = $null
    try {
        $raw = (& pm2 jlist 2>$null | Out-String)
    } catch { return $null }

    if ($null -eq $raw) { return $null }
    $raw = $raw.Trim()
    if (-not $raw) { return $null }

    # PM2 sometimes prefixes the JSON with daemon chatter; start at the array.
    $start = $raw.IndexOf('[')
    if ($start -lt 0) { return $null }
    $raw = $raw.Substring($start)

    if ($raw -eq '[]') { return @() }

    $chunks = [regex]::Split($raw, '(?=\{"pid")') | Where-Object { $_ -match '"pid"' }
    if (-not $chunks -or @($chunks).Count -eq 0) {
        # Shape we do not recognise. Do not guess - the caller reports unknown.
        if ($raw -match '"name"') { return $null }
        return @()
    }

    $apps = @()
    foreach ($c in $chunks) {
        $apps += [pscustomobject]@{
            Name           = (Get-CxJsonString -Json $c -Key 'name')
            Status         = (Get-CxJsonString -Json $c -Key 'status')
            ExecMode       = (Get-CxJsonString -Json $c -Key 'exec_mode')
            NodeOptions    = (Get-CxJsonString -Json $c -Key 'NODE_OPTIONS')
            ServiceName    = (Get-CxJsonString -Json $c -Key 'OTEL_SERVICE_NAME')
            OtlpEndpoint   = (Get-CxJsonString -Json $c -Key 'OTEL_EXPORTER_OTLP_ENDPOINT')
        }
    }
    return @($apps | Where-Object { $_.Name })
}

function Get-CxRegisterPathFromNodeOptions {
    <#
      Extract the --require target from a NODE_OPTIONS value. Handles both the
      quoted and unquoted forms.
    #>
    [CmdletBinding()]
    param([string] $NodeOptions)

    if (-not $NodeOptions) { return $null }
    $m = [regex]::Match($NodeOptions, '--require(?:=|\s+)(?:"([^"]+)"|(\S+))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

function Test-NodeInstrumentation {
    [CmdletBinding()]
    param(
        [string] $InstallPrefix        = 'C:\cx\otel-node',
        [string] $Package              = '@opentelemetry/auto-instrumentations-node',
        [string] $ExpectedOtlpEndpoint = 'http://127.0.0.1:4318',
        [string] $EffectiveConfig      = 'C:\ProgramData\opampsupervisor\state\effective.yaml'
    )

    $findings = New-Object System.Collections.ArrayList
    function Add-F { param($f) [void]$findings.Add($f) }

    $cxNodeServices = $null
    try { $cxNodeServices = [Environment]::GetEnvironmentVariable('CX_NODE_SERVICES', 'Machine') } catch { }

    # -- gate: is PM2 even here? ---------------------------------------------
    if (-not (Test-CxPm2Available)) {
        if (Test-CxNodeWorkloadPresent) {
            Add-F (New-Finding -Check 'nodeInstr' -Severity 'unknown' -Code 'NODE_PM2_NOT_ON_PATH' `
                -Message 'node processes are running but pm2 is not on this account PATH - cannot determine whether they are instrumented')
        } else {
            Add-F (New-Finding -Check 'nodeInstr' -Severity 'skip' -Code 'NO_PM2' `
                -Message 'PM2 is not installed on this host - nothing to instrument')
        }
        # A leftover machine var with no PM2 is still worth flagging.
        if ($cxNodeServices) {
            Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_DRIFT' `
                -Message "CX_NODE_SERVICES is set to '$cxNodeServices' but PM2 is not present - this is a stale value from a prior deploy" `
                -Data @{ cxNodeServices = $cxNodeServices })
        }
        return ,@($findings.ToArray())
    }

    $apps = Get-CxPm2Apps

    if ($null -eq $apps) {
        Add-F (New-Finding -Check 'nodeInstr' -Severity 'unknown' -Code 'NODE_PM2_DAEMON_NOT_VISIBLE' `
            -Message 'pm2 is installed but its app list could not be read. PM2 is per-user on Windows: an elevated run often sees a DIFFERENT daemon than the one owning the apps. Re-run as the account that owns them.')
        return ,@($findings.ToArray())
    }

    if (@($apps).Count -eq 0) {
        if (Test-CxNodeWorkloadPresent) {
            Add-F (New-Finding -Check 'nodeInstr' -Severity 'unknown' -Code 'NODE_PM2_DAEMON_NOT_VISIBLE' `
                -Message 'this account''s pm2 daemon manages no apps, yet node processes are running - they are almost certainly owned by another user''s daemon. Re-run as that account.')
        } else {
            Add-F (New-Finding -Check 'nodeInstr' -Severity 'skip' -Code 'NO_PM2_APPS' `
                -Message 'PM2 is installed but manages no apps - nothing to instrument')
        }
        if ($cxNodeServices) {
            Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_DRIFT' `
                -Message "CX_NODE_SERVICES is set to '$cxNodeServices' but PM2 manages no apps - stale value from a prior deploy" `
                -Data @{ cxNodeServices = $cxNodeServices })
        }
        return ,@($findings.ToArray())
    }

    # -- a: the package is staged --------------------------------------------
    $nodeModules = Join-Path $InstallPrefix 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModules -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'nodePackage' -Severity 'warn' -Code 'NODE_PACKAGE_MISSING' -Target $InstallPrefix `
            -Message "no node_modules under the install prefix - the OTel Node package was never staged here" `
            -Data @{ installPrefix = $InstallPrefix })
    } else {
        $registerJs = Join-Path $nodeModules ((($Package -replace '/', '\')) + '\register.js')
        $pkgDir     = Join-Path $nodeModules ($Package -replace '/', '\')
        if (Test-Path -LiteralPath $pkgDir -ErrorAction SilentlyContinue) {
            Add-F (New-Finding -Check 'nodePackage' -Severity 'pass' -Target $InstallPrefix `
                -Message "OTel Node package staged" -Data @{ package = $Package; path = $pkgDir })
        } else {
            Add-F (New-Finding -Check 'nodePackage' -Severity 'warn' -Code 'NODE_PACKAGE_MISSING' -Target $InstallPrefix `
                -Message "node_modules exists but '$Package' is not in it" `
                -Data @{ installPrefix = $InstallPrefix; expected = $pkgDir })
        }
    }

    # -- b/c: per-app NODE_OPTIONS and service name --------------------------
    $seenServiceNames = @()

    foreach ($app in $apps) {
        $label = $app.Name

        if ($app.Status -and $app.Status -ne 'online') {
            Add-F (New-Finding -Check 'nodeInstr' -Severity 'info' -Target $label `
                -Message "app status is '$($app.Status)' - its env may not reflect the last instrument run" `
                -Data @{ status = $app.Status })
        }

        # (b) NODE_OPTIONS
        $reg = Get-CxRegisterPathFromNodeOptions -NodeOptions $app.NodeOptions
        if (-not $app.NodeOptions -or -not $reg) {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'warn' -Code 'NODE_OPTIONS_MISSING' -Target $label `
                -Message "no NODE_OPTIONS=--require <register> on this app - it is NOT instrumented. A plain 'pm2 restart' without --update-env drops it." `
                -Data @{ nodeOptions = $app.NodeOptions })
        } elseif (-not (Test-Path -LiteralPath $reg -ErrorAction SilentlyContinue)) {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'warn' -Code 'NODE_REGISTER_PATH_STALE' -Target $label `
                -Message "NODE_OPTIONS points at a register bootstrap that no longer exists: $reg" `
                -Data @{ register = $reg; nodeOptions = $app.NodeOptions })
        } else {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'pass' -Target $label `
                -Message "--require $reg" -Data @{ register = $reg })
        }

        # (c) OTEL_SERVICE_NAME
        if (-not $app.ServiceName) {
            Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_MISSING' -Target $label `
                -Message 'no OTEL_SERVICE_NAME on this app - its spans land under a default service name')
        } else {
            $seenServiceNames += $app.ServiceName
            Add-F (New-Finding -Check 'nodeService' -Severity 'pass' -Target $label `
                -Message "OTEL_SERVICE_NAME=$($app.ServiceName)" -Data @{ serviceName = $app.ServiceName })
        }

        # endpoint, same localhost trap as IIS
        if ($app.OtlpEndpoint -and $app.OtlpEndpoint -match 'localhost') {
            Add-F (New-Finding -Check 'nodeOptions' -Severity 'warn' -Code 'OTLP_ENDPOINT_LOCALHOST' -Target $label `
                -Message "endpoint uses 'localhost' ($($app.OtlpEndpoint)); that resolves to ::1 first and OTLP export is silently dropped. Use $ExpectedOtlpEndpoint." `
                -Data @{ endpoint = $app.OtlpEndpoint })
        }
    }

    # -- c (continued): CX_NODE_SERVICES must match the app service names ----
    $expected = @($seenServiceNames | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    $actual   = @()
    if ($cxNodeServices) {
        $actual = @($cxNodeServices -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    }

    if ($expected.Count -eq 0) {
        # already reported per app
    } elseif ($actual.Count -eq 0) {
        Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_MISSING' -Target 'CX_NODE_SERVICES' `
            -Message "machine CX_NODE_SERVICES is not set, but $($expected.Count) PM2 app(s) carry a service name - host Service-ownership will be blank" `
            -Data @{ expected = $expected })
    } elseif (Compare-Object $expected $actual) {
        # Set comparison, not string: app add/remove reorders the join and would
        # otherwise look like drift.
        Add-F (New-Finding -Check 'nodeService' -Severity 'warn' -Code 'NODE_SERVICE_NAME_DRIFT' -Target 'CX_NODE_SERVICES' `
            -Message "CX_NODE_SERVICES does not match the running apps. var=[$($actual -join ', ')] apps=[$($expected -join ', ')] - re-run Instrument-NodePM2.ps1" `
            -Data @{ cxNodeServices = $actual; appServiceNames = $expected })
    } else {
        Add-F (New-Finding -Check 'nodeService' -Severity 'pass' -Target 'CX_NODE_SERVICES' `
            -Message "matches the running apps: $($actual -join ', ')" -Data @{ cxNodeServices = $actual })
    }

    # -- d: does anything actually CONSUME CX_NODE_SERVICES? -----------------
    # Determined by looking, not asserted from memory: if a remote Fleet config
    # later adds a processor reading ${env:CX_NODE_SERVICES}, this finding
    # disappears on its own.
    if ($cxNodeServices) {
        $consumed = $false
        $looked   = $false
        foreach ($cfg in @($EffectiveConfig, (Join-Path $script:CxNodeHere 'config.supervisor.yaml'))) {
            if (-not $cfg) { continue }
            if (-not (Test-Path -LiteralPath $cfg -ErrorAction SilentlyContinue)) { continue }
            $looked = $true
            try {
                $txt = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop
                # Ignore commented lines so a mention in a comment is not a match.
                $live = ($txt -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                if ($live -match 'CX_NODE_SERVICES') { $consumed = $true; break }
            } catch { }
        }

        if ($looked -and -not $consumed) {
            Add-F (New-Finding -Check 'nodeOwnership' -Severity 'info' -Code 'NODE_SERVICES_NOT_CONSUMED' `
                -Message 'CX_NODE_SERVICES is set, but no collector config on this host reads ${env:CX_NODE_SERVICES} - unlike CX_IIS_SERVICES there is no transform consuming it, so Node host Service-ownership will stay blank. The env var is not the problem; the missing processor is.' `
                -Data @{ checked = @($EffectiveConfig) })
        } elseif ($consumed) {
            Add-F (New-Finding -Check 'nodeOwnership' -Severity 'pass' `
                -Message 'a collector config on this host consumes CX_NODE_SERVICES')
        }
    }

    return ,@($findings.ToArray())
}

# ---------------------------------------------------------------------------
# Main body - runs ONLY on direct execution, never when dot-sourced.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ''
    Write-Host "Node/PM2 instrumentation check on $env:COMPUTERNAME  ($(Get-Date -Format 's'))"

    $result = Test-NodeInstrumentation -InstallPrefix $InstallPrefix -Package $Package `
                                       -ExpectedOtlpEndpoint $ExpectedOtlpEndpoint `
                                       -EffectiveConfig $EffectiveConfig
    $code = Get-GradedExitCode -Findings $result

    Write-FindingTable   -Findings $result -Title 'Node/PM2 instrumentation' -Quiet:$Quiet
    Write-FindingSummary -Findings $result -Label 'NODE-INSTRUMENTATION' -ExitCode $code

    if ($PassThru) { $result }
    exit $code
}
