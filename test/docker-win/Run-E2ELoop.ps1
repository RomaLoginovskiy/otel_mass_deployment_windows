<#
.SYNOPSIS
  Full deploy loop against a realistically-shaped IIS host in a Windows container:
  install the agent with deploy.bat, instrument, break it on purpose, diagnose with
  doctor.bat, fix, and confirm the telemetry landed in Coralogix.

.DESCRIPTION
  The other harnesses each test one slice. This one tests the operator's actual
  path end to end, and everything it does to the container goes through the real
  entry points:

      docker exec ... deploy.bat        install + instrument
      docker exec ... doctor.bat        diagnose
      docker exec ... break-state.ps1   inject a fault

  Nothing here re-implements what the deploy scripts do. If a step needs a
  PowerShell one-liner to set up a fault, it lives in break-state.ps1, baked into
  the image.

  PHASES

    P0  premises      is the vendor installer reachable from this container at all?
    P1  install       deploy.bat with CX_NO_SUPERVISOR=1, collector healthy
    P2  shapes        every IIS shape named + instrumented as designed
    P3  failures      F1..F7: break -> doctor names it -> fix -> green again
    P4  telemetry     spans / logs / metrics actually in Coralogix
    P5  idempotency   a second deploy.bat changes nothing

  WHAT IS EXPECTED TO BE IMPERFECT, and is asserted as such rather than hidden:
  the `legacy` (ASP.NET Framework) and `nocfg` (shared pool, no web.config) apps
  CANNOT be given a service name by the current design. The loop asserts they are
  reported, not that they work.

.PARAMETER Case
  Run one phase or one failure case (P1, P3, F2, ...) instead of the whole loop.

.PARAMETER SkipTelemetry
  Skip P4. Use when you have no Coralogix keys, or to iterate fast: P4 is the only
  phase that needs network, real keys, and minutes of ingest lag.

.NOTES
  Requires Docker Desktop in WINDOWS-container mode, a Send-Your-Data key
  (SimpleWebApp/coralogix/SendDataKey.txt or -PrivateKey) and, for P4, a query key
  at querydata_key.txt. Both are gitignored.

  Every run uses a UNIQUE hostname so its Coralogix queries cannot match a previous
  run's data - without that, P4 passes on stale telemetry after a regression.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $Image     = 'cx-e2e-test',
    [string] $Container = $null,          # default: cx-e2e-<stamp>, see below
    [string] $HostName  = $null,          # default: same as the container name
    [string] $RepoRoot  = $null,
    [string] $PrivateKey,
    [string] $QueryKeyFile,
    # Region code (eu1/eu2/us1/...) for the account the key belongs to. Resolved through
    # deploy/Resolve-CxRegion.ps1, the same table the installer uses. -Domain still takes
    # a full domain and wins.
    [string] $Region    = $null,
    [string] $Domain    = 'eu1.coralogix.com',
    [string[]] $Case    = @(),
    [switch] $SkipBuild,
    [switch] $SkipTelemetry,
    [switch] $KeepContainer
)
# Native docker/appcmd write to stderr; under 'Stop' that becomes a terminating
# NativeCommandError in PS 5.1. Gate on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) {
    if ($PSCommandPath) { $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) }
    else { $RepoRoot = (Get-Location).Path }
}

# Unique per run: Coralogix keeps old data, so a fixed hostname would let P4 pass
# on the previous run's telemetry even after a regression broke this one.
$stamp = Get-Date -Format 'MMddHHmm'
if (-not $Container) { $Container = "cx-e2e-$stamp" }
if (-not $HostName)  { $HostName  = $Container }
if (-not $QueryKeyFile) { $QueryKeyFile = Join-Path $RepoRoot 'querydata_key.txt' }

# -Region -> domain, unless -Domain was given explicitly (which wins). Resolved from the
# repo's own region table so the harness cannot drift from what the installer accepts.
if ($Region -and -not $PSBoundParameters.ContainsKey('Domain')) {
    . (Join-Path $RepoRoot 'deploy\Resolve-CxRegion.ps1')
    $Domain = Resolve-CxDomain -Region $Region
    Write-Host "[e2e] region $Region -> domain $Domain"
} elseif ($Region) {
    Write-Warning "[e2e] both -Region and -Domain given; using -Domain $Domain"
}
# P4 asks the BACKEND what arrived, so its query endpoint has to follow the region the
# container ships to - a verification pointed at eu1 while the agent ships to eu2 reports
# a regression that is really just the wrong account. eu1 keeps its legacy alias host
# (ng-api-http.coralogix.com) because that is the one the query keys in this repo were
# tested against.
$DpUrl = if ($Domain -eq 'eu1.coralogix.com' -or $Domain -eq 'coralogix.com') {
    'https://ng-api-http.coralogix.com/api/v1/dataprime/query'
} else {
    "https://ng-api-http.$Domain/api/v1/dataprime/query"
}

if ((docker version --format '{{.Server.Os}}') -ne 'windows') {
    throw "Docker is not in Windows-container mode. Switch: & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine"
}

if (-not $PrivateKey) {
    $keyFile = Join-Path $RepoRoot 'SimpleWebApp\coralogix\SendDataKey.txt'
    if (Test-Path -LiteralPath $keyFile) { $PrivateKey = (Get-Content -LiteralPath $keyFile -Raw).Trim() }
}
if (-not $PrivateKey) {
    throw "No Send-Your-Data key. Pass -PrivateKey or provide SimpleWebApp\coralogix\SendDataKey.txt"
}

$script:Pass = 0
$script:Fail = 0
$script:Notes = New-Object System.Collections.ArrayList

function Use-Case {
    <# Should this phase/case run? No -Case means everything. #>
    param([string] $Name)
    if (-not $Case -or @($Case).Count -eq 0) { return $true }
    foreach ($c in $Case) { if ($c -and ($Name -like "$c*" -or $c -like "$Name*")) { return $true } }
    return $false
}

function Note {
    <#
      Record something the run discovered that a human has to act on: an
      unsupported IIS shape, a needed non-default setting, a workaround. These are
      printed at the end and are the raw material for docs/iis-e2e-matrix.md.
    #>
    param([string] $Topic, [string] $Text)
    [void]$script:Notes.Add([pscustomobject]@{ Topic = $Topic; Text = $Text })
    Write-Host "  [NOTE] $Topic - $Text" -ForegroundColor Yellow
}

function Invoke-Exec {
    <# Run a PowerShell command inside the container. #>
    param([string] $Command)
    $out = docker exec $Container powershell -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-Deploy {
    <#
      The thing under test. Runs deploy.bat exactly as BatchPatch would, with the
      same env-var switches an operator would set in the remote command.
    #>
    param([hashtable] $Env = @{})
    $a = @('exec')
    foreach ($k in $Env.Keys) { $a += @('-e', "$k=$($Env[$k])") }
    $a += @('-e', "CORALOGIX_PRIVATE_KEY=$PrivateKey", '-e', "CORALOGIX_DOMAIN=$Domain")
    $a += @($Container, 'cmd', '/c', 'C:\cx\deploy\deploy.bat')
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-Doctor {
    # -Env sets container env vars for this run only, the same way Invoke-Deploy does. Needed
    # to exercise CX_RUNTIME_OVERRIDES_JSON, which the scripts read directly rather than taking
    # as a flag - that is the whole mechanism keeping the install and the doctor on the same
    # classification, so testing it through the flag instead would test the wrong thing.
    param([string[]] $DoctorArgs = @(), [hashtable] $Env = @{})
    $a = @('exec')
    foreach ($k in $Env.Keys) { $a += @('-e', "$k=$($Env[$k])") }
    $a += @($Container, 'cmd', '/c', 'C:\cx\deploy\doctor.bat') + $DoctorArgs
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Invoke-Instrument {
    <#
      Run the real Instrument-IIS.ps1 - with IIS STOPPED first.

      That stop is a workaround for a defect this loop found, not a convenience:
      Install-OpenTelemetryCore replaces the profiler assemblies under
      "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\", and once IIS has
      loaded them a re-run dies with

          Cannot remove item ...\Microsoft.Extensions.DependencyInjection.Abstractions.dll:
          Access to the path ... is denied.

      Instrument-IIS.ps1 only calls iisreset at the END, so the FIRST install on a
      clean host works and every subsequent one fails. Recorded as a Note; the fix
      is a product decision because stopping IIS means downtime.
    #>
    param([switch] $Quiet, [hashtable] $Env = @{})
    $null = Invoke-Exec 'Stop-Service W3SVC,WAS -Force -ErrorAction SilentlyContinue'
    $a = @('exec')

    # Re-download the vendor .psm1 on every run and this loop inherits a coin flip: the
    # container's Invoke-WebRequest fails intermittently with "The decryption operation
    # failed" (the same TLS-stack problem P0 records for the collector MSI, and the reason
    # Instrument-IIS.ps1 has -LocalModule / CX_OTEL_DOTNET_MODULE at all). When it lands on a
    # re-instrument case the script dies before it reaches anything under test, and the case
    # fails for a reason that has nothing to do with what it asserts.
    #
    # Point at the copy Install-OpenTelemetryCore leaves in the install directory. The path
    # does not exist on the first run - Instrument-IIS.ps1 Test-Paths it and falls back to
    # downloading - so the first run still exercises the real download and every run after it
    # is deterministic. Callers can override by passing the key themselves.
    if (-not $Env.ContainsKey('CX_OTEL_DOTNET_MODULE')) {
        $Env = $Env.Clone()
        $Env['CX_OTEL_DOTNET_MODULE'] = 'C:\Program Files\OpenTelemetry .NET AutoInstrumentation\OpenTelemetry.DotNet.Auto.psm1'
    }
    foreach ($k in $Env.Keys) { $a += @('-e', "$k=$($Env[$k])") }
    $a += @($Container, 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', 'C:\cx\deploy\Instrument-IIS.ps1', '-NoReset')
    $out = & docker @a 2>&1 | Out-String
    $code = $LASTEXITCODE
    $null = Invoke-Exec 'Start-Service W3SVC,WAS -ErrorAction SilentlyContinue'
    if (-not $Quiet) { Write-Host '   (instrumented with IIS stopped - see the DLL-lock note)' -ForegroundColor DarkGray }
    return @{ Out = $out; Code = $code }
}

function Invoke-Break {
    param([string] $BreakCase, [string] $Site, [string] $Pool, [string] $LogDir)
    $a = @('exec', $Container, 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
           '-File', 'C:\cx\break-state.ps1', '-Case', $BreakCase)
    if ($Site)   { $a += @('-Site', $Site) }
    if ($Pool)   { $a += @('-Pool', $Pool) }
    if ($LogDir) { $a += @('-LogDir', $LogDir) }
    $out = & docker @a 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Assert-Case {
    param(
        [string]   $Name,
        [hashtable] $Result,
        [string[]] $Expect = @(),
        [string[]] $Reject = @(),
        [int]      $ExpectExit = -1
    )
    $problems = @()
    foreach ($e in $Expect) { if ($Result.Out -notmatch [regex]::Escape($e)) { $problems += "missing '$e'" } }
    foreach ($r in $Reject) { if ($Result.Out -match  [regex]::Escape($r)) { $problems += "unexpected '$r'" } }
    if ($ExpectExit -ge 0 -and $Result.Code -ne $ExpectExit) { $problems += "exit=$($Result.Code) expected $ExpectExit" }

    if ($problems.Count -eq 0) {
        Write-Host ("  [PASS] {0}  (exit={1})" -f $Name, $Result.Code) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ("  [FAIL] {0}  -> {1}" -f $Name, ($problems -join '; ')) -ForegroundColor Red
        $script:Fail++
        Write-Host ($Result.Out -split "`r?`n" | Select-Object -Last 40 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
    }
}

function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:Pass++
    } else {
        Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red; $script:Fail++
    }
}

function Skip-Case {
    <#
      Not applicable HERE for an environmental reason - counts as neither pass nor
      fail. Used only where the container cannot host the thing under test; a
      genuine defect must never take this path or the run would go green while
      testing nothing.
    #>
    param([string] $Name, [string] $Why)
    Write-Host "  [SKIP] $Name  ($Why)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Build + start
# ---------------------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host "== build ($Image) ==" -ForegroundColor Cyan
    Push-Location $RepoRoot
    try { docker build -f test/docker-win/Dockerfile.e2e -t $Image . | Out-Null }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)" }
}

docker rm -f $Container 2>$null | Out-Null
Write-Host "== run ($Container) ==" -ForegroundColor Cyan
docker run -d --name $Container --hostname $HostName -e "CORALOGIX_DOMAIN=$Domain" $Image | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker run failed' }

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 6
    $logs = docker logs $Container 2>&1 | Out-String
} until (($logs -match '\[alive\]') -or (Get-Date) -gt $deadline)
if ($logs -notmatch '\[alive\]') { Write-Host $logs; throw 'container never reached [alive]' }
Write-Host "   IIS provisioned, NOT instrumented (host.name=$HostName)"

# ---------------------------------------------------------------------------
# P0. Premises
# ---------------------------------------------------------------------------
# Always probed, even under -Case: every collector-dependent assertion below is
# gated on it, and a wrong default here would turn an environmental limitation into
# a wall of misleading failures.
Write-Host ''
Write-Host '== P0. premises ==' -ForegroundColor Cyan

# The premise that matters is NOT "can the installer .ps1 be downloaded" - that
# succeeds and tells you nothing. It is "can the vendor installer fetch the
# COLLECTOR MSI", because that is the step that actually installs anything.
#
# Probe both transports. .NET Invoke-WebRequest is what the vendor installer uses;
# curl.exe is the control. If curl works and IWR does not, the blocker is the .NET
# Schannel stack in this container, not the network - and that distinction is the
# difference between "our scripts are broken" and "this image cannot host a
# collector", which is worth knowing before reading any other result.
# Two single-line probes, not one multi-line script. A multi-line command string
# handed to `docker exec ... powershell -Command` loses its quoting on the way
# through argument parsing, and the container ends up trying to run the output
# line as a cmdlet name. Keep every -Command payload to one line, single quotes
# only, with nothing that needs escaping.
$probeCurl = Invoke-Exec "& curl.exe -sL -o C:\probe.msi -w '%{http_code}' 'https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.155.0/otelcol-contrib_0.155.0_windows_x64.msi'"
$probeIwr  = Invoke-Exec "try { Invoke-WebRequest 'https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.155.0/otelcol-contrib_0.155.0_windows_x64.msi' -OutFile C:\probe2.msi -UseBasicParsing -ErrorAction Stop; 'IWR_OK' } catch { 'IWR_FAILED: ' + \$_.Exception.Message }"

# INFORMATIONAL ONLY - deliberately not a gate. Measured here: this probe can
# succeed and the installer's own download of the same URL still fail moments
# later, so the failure is intermittent and a pre-flight check is not a reliable
# predictor of it. Whether a collector actually installed is therefore decided in
# P1 from the real outcome, not from this.
$curlOk = ($probeCurl.Out -match '200')
$iwrOk  = ($probeIwr.Out -match 'IWR_OK')
Write-Host ("   collector MSI reachability: curl.exe={0}  Invoke-WebRequest={1}" -f `
    $(if ($curlOk) { 'HTTP 200' } else { 'failed' }), $(if ($iwrOk) { 'OK' } else { 'failed' }))
if ($curlOk -and -not $iwrOk) {
    Write-Host '   (curl works, .NET does not: a Schannel limitation of this image, not the network)' -ForegroundColor DarkGray
}
# Assume installable until P1 proves otherwise. Assuming the opposite would let a
# genuine install regression hide behind an environmental skip.
$collectorInstallable = $true

# ---------------------------------------------------------------------------
# P1. Install via deploy.bat, no supervisor
# ---------------------------------------------------------------------------
if (Use-Case 'P1') {
    Write-Host ''
    Write-Host '== P1. deploy.bat install (no supervisor) ==' -ForegroundColor Cyan

    # The MSI download is intermittent in this image, so give it a second attempt
    # before concluding anything. Retrying a flaky third-party download is fair;
    # retrying past a real failure is not, hence the narrow match on the vendor
    # installer's own download error and the cap of two tries.
    $envWall = 'The decryption operation failed'
    $r = Invoke-Deploy -Env @{ CX_NO_SUPERVISOR = '1'; CX_ENVIRONMENT = 'e2e' }
    if ($r.Code -ne 0 -and $r.Out -match $envWall) {
        Write-Host '   MSI download failed; retrying once (known intermittent in this image)' -ForegroundColor DarkGray
        $r = Invoke-Deploy -Env @{ CX_NO_SUPERVISOR = '1'; CX_ENVIRONMENT = 'e2e' }
    }

    # True regardless of whether the MSI ever arrives: this is what OUR code did,
    # and it is the entire contract of the -NoSupervisor flag.
    Assert-Case -Name 'installer invoked in regular mode (-Config, not -Supervisor)' -Result $r `
        -Expect @('-Config') -Reject @('-SupervisorCollectorBaseConfig')
    $r2 = Invoke-Exec "Test-Path 'C:\cx\deploy\config.recommended.yaml'"
    Assert-True 'recommended config produced into the script folder' ($r2.Out.Trim() -eq 'True')

    # Decide from the REAL outcome, not the pre-probe. Only the vendor installer's
    # own MSI-download error counts as environmental; anything else is a defect and
    # must fail loudly.
    if ($r.Code -ne 0 -and $r.Out -match $envWall) {
        $collectorInstallable = $false
        # Prove the run got all the way INTO the installer's download step. That
        # separates "this image cannot fetch an MSI" from "our script broke before
        # reaching the installer" - the second must never hide behind the first.
        Assert-Case -Name 'reached the vendor installer''s MSI download before failing' -Result $r `
            -Expect @('Downloading OpenTelemetry Collector', 'Failed to download')
        Skip-Case 'collector service assertions' 'the vendor installer could not fetch the collector MSI in this image'
        Note 'container limitation' 'The vendor installer fetches the collector MSI with Invoke-WebRequest, which fails intermittently in this Server Core container ("The decryption operation failed") while curl.exe fetches the same URL fine. It has no local-MSI option for the collector (-SupervisorMsi is supervisor-only) and its work directory is timestamp+PID suffixed so it cannot be pre-seeded - so a collector install here is not reliably possible. Not a defect in deploy.bat: real Server SKUs and the VirtualBox POC install normally. Run P1/P4/F7 on a VM to exercise them.'
    } else {
        Assert-Case -Name 'deploy.bat completes' -Result $r -ExpectExit 0 -Expect @('=== done:')
        $r3 = Invoke-Exec "(Get-Service otelcol-contrib -ErrorAction SilentlyContinue).Status; '|'; (Get-Service opampsupervisor -ErrorAction SilentlyContinue).Status"
        Assert-True 'otelcol-contrib service is Running' ($r3.Out -match 'Running') $r3.Out.Trim()
        Assert-True 'no opampsupervisor service in this mode' ($r3.Out -notmatch 'Running\s*\|\s*Running') $r3.Out.Trim()
    }
}

# ---------------------------------------------------------------------------
# P2. Every IIS shape
# ---------------------------------------------------------------------------
if (Use-Case 'P2') {
    Write-Host ''
    Write-Host '== P2. IIS shape matrix ==' -ForegroundColor Cyan

    if (-not $collectorInstallable) {
        # Instrumentation touches IIS and env vars only - it needs no collector - so
        # run it directly rather than losing the whole shape matrix to an unrelated
        # environmental limitation. This is the same Instrument-IIS.ps1 that
        # deploy.bat invokes.
        $ins = Invoke-Instrument -Quiet
        Write-Host '   (no collector in this image: ran Instrument-IIS.ps1 directly, IIS stopped)' -ForegroundColor DarkGray
        if ($ins.Out -match 'Access to the path') {
            Note 'profiler DLL lock' 'Install-OpenTelemetryCore replaces the assemblies under "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\", and IIS holds them open once loaded, so a RE-run fails with "Cannot remove item ... Access to the path ... is denied". Instrument-IIS.ps1 only runs iisreset at the END, so the first install on a clean host succeeds and every later one fails - deploy.bat is not re-runnable while IIS is up. Remediation today: stop W3SVC/WAS before re-deploying. A fix in the script would mean deliberate downtime, so it is a product decision.'
        }
    }

    $d = Invoke-Doctor -DoctorArgs @('-Only', 'iisServiceName')

    # 1. Default Web Site: static content (wwwroot ships iisstart.htm and no web.config) on a
    #    dedicated pool. This is THE regression pin for the over-claim this matrix caught:
    #    the installer used to name every dedicated-pool app regardless of runtime, so the
    #    host advertised ownership of a service that emits nothing. The applicationDefaults
    #    pool-resolution pin this case used to carry moved to shape 10, which is a .NET app.
    Assert-Case -Name 'shape 1  Default Web Site is static -> NOT instrumented' -Result $d `
        -Reject @('OTEL_SERVICE_NAME=Default Web Site')
    $dRt = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
    Assert-Case -Name 'shape 1  and it is reported as non-.NET, not as a failure' -Result $dRt `
        -Expect @('NON_DOTNET_APP_NOT_INSTRUMENTED', 'Default Web Site/')
    # 2/3. Dedicated pools: name on the pool, nested app keeps its path.
    Assert-Case -Name 'shape 2  shop named on its pool' -Result $d -Expect @('OTEL_SERVICE_NAME=shop (pool)')
    Assert-Case -Name 'shape 3  nested shop/api named by site+path' -Result $d -Expect @('OTEL_SERVICE_NAME=shop/api')
    # 4. Shared pool: the pool cannot hold two names, so they go to web.config.
    Assert-Case -Name 'shape 4  shared pool apps named in web.config' -Result $d `
        -Expect @('OTEL_SERVICE_NAME=shared/api (webconfig)', 'OTEL_SERVICE_NAME=shared/admin (webconfig)')
    # 6. <aspNetCore> wrapped in <location path="."> - the publish-output shape.
    Assert-Case -Name 'shape 6  <location>-wrapped web.config still named' -Result $d `
        -Expect @('OTEL_SERVICE_NAME=wrapped')
    # 8. A virtual directory is not an application and must not be named.
    Assert-Case -Name 'shape 8  virtual directory is not named as an app' -Result $d `
        -Reject @('shop/assets')

    # 10-14. Runtime classification. "No Managed Code" is a POOL property; what decides
    #        whether .NET auto-instrumentation applies is what the APPLICATION is.
    Assert-Case -Name 'shape 10 defaults-core named despite no explicit applicationPool' -Result $d `
        -Expect @('OTEL_SERVICE_NAME=defaults-core')
    Assert-Case -Name 'shape 10 Core on a managed-CLR pool is still instrumented, and warned about' -Result $dRt `
        -Expect @('POOL_NOT_NO_MANAGED_CODE', 'defaults-core/')
    Assert-Case -Name 'shape 11 staticwc has a web.config but is not .NET' -Result $dRt `
        -Expect @('NON_DOTNET_APP_NOT_INSTRUMENTED', 'staticwc/')
    Assert-Case -Name 'shape 11 and is not named' -Result $d -Reject @('OTEL_SERVICE_NAME=staticwc')
    # The reverse-proxy pair. Same picture from outside - IIS forwards to a dotnet process -
    # and opposite verdicts, because ANCM's child inherits the pool environment and an ARR
    # backend on another port does not.
    Assert-Case -Name 'shape 12 ARR reverse proxy is not instrumentable from IIS' -Result $dRt `
        -Expect @('NON_DOTNET_APP_NOT_INSTRUMENTED', 'arrproxy/')
    Assert-Case -Name 'shape 12 and the message points at the backend process' -Result $dRt `
        -Expect @('instrument that backend where it runs')
    Assert-Case -Name 'shape 13 ANCM out-of-process IS instrumented (contrast with 12)' -Result $d `
        -Expect @('OTEL_SERVICE_NAME=oop-core (pool)')
    Assert-Case -Name 'shape 14 bin\*.dll with no web.config is UNKNOWN, not guessed' -Result $dRt `
        -Expect @('RUNTIME_UNKNOWN_NEEDS_OVERRIDE', 'binonly/')
    Assert-Case -Name 'shape 14 and is not named' -Result $d -Reject @('OTEL_SERVICE_NAME=binonly')

    # No OTEL_SERVICE_NAME may be left on the pools of apps the installer declined. Skipping
    # the WRITE is the claim; this is what verifies it, and it is also the upgrade path -
    # a stale name from a pre-classification install has to be removed, not just ignored.
    $unsup = Invoke-Exec (@'
[xml]$x = Get-Content 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Raw; $x.SelectNodes('//applicationPools/add/environmentVariables/add') | Where-Object { $_.GetAttribute('name') -eq 'OTEL_SERVICE_NAME' } | ForEach-Object { $_.ParentNode.ParentNode.GetAttribute('name') + '=' + $_.GetAttribute('value') }
'@)
    foreach ($p in @('staticwc', 'arrproxy', 'binonly')) {
        Assert-True "no OTEL_SERVICE_NAME on the '$p' pool" ($unsup.Out -notmatch "(?m)^$p=") $unsup.Out.Trim()
    }

    # 9. Brownfield shared pool: it owned an <environmentVariables> block before the
    #    agent was installed, so applicationPoolDefaults never reached it. Regression
    #    pin for a silent-export defect: the shared-pool branch used to skip pool env
    #    entirely, so this pool got no endpoint while the defaults read as correct and
    #    the doctor's own note called the case "rare".
    #    NOTE: single-quoted here-string with NO nested double quotes and no XPath
    #    predicate - a `[@name='...']` predicate needs an outer double quote, and
    #    those do not survive `docker exec ... -Command`. Filter in PowerShell
    #    instead, the same way the duplicate-entry check in P5 does.
    $bf = Invoke-Exec (@'
[xml]$x = Get-Content 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Raw; $x.SelectNodes('//applicationPools/add/environmentVariables/add') | Where-Object { $_.ParentNode.ParentNode.GetAttribute('name') -eq 'BrownfieldPool' } | ForEach-Object { $_.GetAttribute('name') + '=' + $_.GetAttribute('value') }
'@)
    Assert-True 'shape 9  brownfield shared pool got the OTLP endpoint on the pool' `
        ($bf.Out -match 'OTEL_EXPORTER_OTLP_ENDPOINT=http://127\.0\.0\.1:4318') $bf.Out.Trim()
    Assert-True 'shape 9  brownfield shared pool got the OTLP protocol on the pool' `
        ($bf.Out -match 'OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf') $bf.Out.Trim()
    # Uninstall reverses only value-matched installer entries, so the customer's own
    # variable has to still be here for that to be a meaningful guarantee.
    Assert-True 'shape 9  the pre-existing non-OTEL pool variable survived' `
        ($bf.Out -match 'CX_TEST_PREEXISTING=set-before-the-agent') $bf.Out.Trim()
    # Both apps share the pool, so the write must be deduped: two OTEL_SERVICE_NAME
    # entries cannot exist and the OTLP pair must appear once each. (The global
    # duplicate check in P4 covers every pool; this one localises the failure.)
    $bfDupes = @($bf.Out -split "`n" | Where-Object { $_ -match 'OTEL_EXPORTER_OTLP_ENDPOINT' }).Count
    Assert-True 'shape 9  OTLP endpoint written once despite two apps on the pool' `
        ($bfDupes -eq 1) "matched $bfDupes line(s)"
    # And the doctor must now agree: no POOL_LOST_INHERITANCE for this pool.
    $bfDoc = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
    Assert-Case -Name 'shape 9  doctor reports no lost inheritance for BrownfieldPool' -Result $bfDoc `
        -Reject @('POOL_LOST_INHERITANCE')
    # The pool value was stamped from the same $OtlpEndpoint the defaults carry, so it
    # is not a stale snapshot either.
    Assert-Case -Name 'shape 9  pool value matches the defaults (no stale snapshot)' -Result $bfDoc `
        -Reject @('POOL_ENV_STALE')

    # The alignment guarantee in docs/iis-service-ownership.md: every item in
    # CX_IIS_SERVICES is supposed to equal some app's OTEL_SERVICE_NAME. Check it
    # against an app whose name assignment was SKIPPED.
    # Regression pin for a defect this loop found: CX_IIS_SERVICES used to be built
    # from the whole service map, so an app that could NOT be named (shared pool, no
    # web.config) still appeared in it. The host then advertised ownership of a
    # service nothing emits, and since the doctor compares the variable against the
    # names actually present, CX_IIS_SERVICES_DRIFT was reported permanently -
    # re-running could never clear it.
    $svc = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
    Assert-True 'CX_IIS_SERVICES excludes apps that could not be named' `
        ($svc.Out -notmatch 'nocfg') $svc.Out.Trim()

    # EXACT SET, not a list of spot-checks. A `-notmatch` per known-bad name passes for any
    # name nobody thought to list, which is precisely how an over-claim regression would slip
    # through - the original defect was a name that no assertion mentioned.
    $expectedServices = @(
        'shop', 'shop/api',                       # dedicated Core pools
        'shared', 'shared/api', 'shared/admin',   # shared pool -> web.config (root included:
                                                  # entrypoint.e2e.ps1 gives the site root a
                                                  # Core web.config of its own)
        'wrapped',                                # <location>-wrapped <aspNetCore>
        'legacy',                                 # ASP.NET Framework, dedicated v4.0 pool
        'brownfield', 'brownfield/admin',         # shared pool that owned an env block
        'defaults-core',                          # Core, pool via <sites><applicationDefaults>
        'oop-core'                                # Core, out-of-process hosting
    ) | Sort-Object
    # Absent by design: 'Default Web Site' + 'staticwc' + 'arrproxy' (non-.NET), 'binonly'
    # (runtime undetermined), 'nocfg' (shared pool, nowhere to put a name),
    # 'shop/assets' (a virtual directory, not an app).
    $actualServices = @($svc.Out.Trim() -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
    $setDiff = Compare-Object $expectedServices $actualServices
    Assert-True 'CX_IIS_SERVICES is exactly the instrumentable set' (-not $setDiff) `
        ("expected=[{0}] actual=[{1}]" -f ($expectedServices -join ', '), ($actualServices -join ', '))

    # 5/7. The two shapes the current design CANNOT name. Assert they are reported
    #      rather than pretending they work.
    # 5. ASP.NET Framework on a DEDICATED v4.0 pool: fully supported - named on the pool and
    #    claimed. Assert the classification explicitly, not just that the string 'legacy'
    #    appeared somewhere: a bare -match would also pass if the app were reported as
    #    non-.NET, which is the misclassification the pool-CLR-only rule would produce.
    Assert-Case -Name 'shape 5  Framework app classified from <system.web> and named' -Result $d `
        -Expect @('OTEL_SERVICE_NAME=legacy (pool)')
    # Pinned by the evidence string rather than by rejecting POOL_NOT_NO_MANAGED_CODE:
    # 'defaults-core' legitimately raises that code (Core on DefaultAppPool, whose absent
    # attribute means v4.0) and Assert-Case matches the whole output, not one row. Only a
    # <system.web> reading can produce this message, which is the thing being asserted.
    Assert-Case -Name 'shape 5  Framework on a v4.0 pool is Supported, not misconfigured' -Result $dRt `
        -Expect @('FRAMEWORK_POOL_OK', 'legacy/', 'web.config carries classic ASP.NET configuration (system.web/compilation)')
    Note 'ASP.NET Framework' 'A Framework app on a DEDICATED pool is fully supported: it gets OTEL_SERVICE_NAME from the pool and IS claimed in CX_IIS_SERVICES. The limitation is specific to a SHARED pool - Set-WebConfigServiceName needs an <aspNetCore> node, and appSettings is not a workaround there because on .NET Framework the OTEL_* values in web.config are promoted to process-level env vars and the SDK initialises once per worker process, so the first app to start decides for all of them. Left unnamed such an app still reports, under the auto-detected Site\AppPath, and is excluded from CX_IIS_SERVICES so the host under-claims rather than claiming a name we did not set. Give it its own pool to bring it under management. Separately: do NOT "fix" a Framework pool by setting No Managed Code - that stops the app running at all.'
    $nocfg = ($d.Out -match 'nocfg')
    Assert-True 'shape 7  app with no web.config is reported' $nocfg
    if ($nocfg) {
        Note 'no web.config' 'An app on a SHARED pool with no web.config has nowhere to carry a per-app name: the pool is shared and there is no file to write. Give it its own pool or add a web.config.'
    }
}

# ---------------------------------------------------------------------------
# P3. Failure injection: break -> diagnose -> fix -> green
# ---------------------------------------------------------------------------
if (Use-Case 'P3') {
    Write-Host ''
    Write-Host '== P3. failure injection ==' -ForegroundColor Cyan

    # F2. "It didn't work the first time." The collector is fine; the apps are not.
    if (Use-Case 'F2') {
        $null = Invoke-Break -BreakCase 'profilerClear'
        $null = Invoke-Break -BreakCase 'clearIisServices'
        # iisServiceName must be selected too: the `env` check reports an unset
        # CX_IIS_SERVICES as INFO and defers the verdict, because whether it SHOULD
        # be set depends on the IIS layout. CX_IIS_SERVICES_MISSING is raised by
        # iisServiceName, which knows there are apps.
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'env,iisServiceName,iisInstrumentation')
        Assert-Case -Name 'F2 un-instrumented host is diagnosed' -Result $r -ExpectExit 2 `
            -Expect @('PROFILER_NOT_REGISTERED', 'CX_IIS_SERVICES_MISSING')
        $null = Invoke-Instrument -Quiet
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'env')
        Assert-Case -Name 'F2 re-running the instrumenter fixes it' -Result $r -Reject @('CX_IIS_SERVICES_MISSING')
    }

    # F3. A site added AFTER the deploy. Nothing re-runs on its own, so the value
    #     silently stops matching the host.
    if (Use-Case 'F3') {
        # The new site must be a .NET app to test what this case is about. Before runtime
        # classification an empty directory was enough, because naming was decided by pool
        # arity alone; now an app with no web.config is (correctly) non-.NET and would never
        # be named, so the assertion below would fail for a reason that has nothing to do
        # with "a site was added after the deploy". Hence the <aspNetCore> web.config.
        # XML attributes are single-quoted (valid XML) and doubled for PowerShell's own
        # single-quoted string, so the whole command contains no double quote at all - those
        # do not survive `docker exec ... -Command`, the same constraint as the XML probes
        # elsewhere in this file.
        $null = Invoke-Exec "Import-Module WebAdministration; New-Item -ItemType Directory -Force C:\sites\latecomer | Out-Null; Set-Content -LiteralPath C:\sites\latecomer\web.config -Encoding utf8 -Value '<configuration><system.webServer><aspNetCore processPath=''dotnet'' arguments=''.\App.dll'' hostingModel=''inprocess'' /></system.webServer></configuration>'; if (-not (Test-Path 'IIS:\AppPools\latecomer')) { New-WebAppPool -Name latecomer | Out-Null }; Set-ItemProperty 'IIS:\AppPools\latecomer' -Name managedRuntimeVersion -Value ([string]::Empty); if (-not (Test-Path 'IIS:\Sites\latecomer')) { New-Website -Name latecomer -Port 8099 -PhysicalPath C:\sites\latecomer -ApplicationPool latecomer | Out-Null }"
        # A site ADDED after the deploy shows up as IIS_SERVICE_NAME_MISSING on that
        # app, not as CX_IIS_SERVICES_DRIFT. The distinction is real and worth
        # pinning: DRIFT means the variable disagrees with the apps (a site was
        # removed or renamed, so it names something that no longer exists), whereas
        # a brand-new app simply has no name yet and the variable is still accurate
        # for everything it does list.
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'env,iisServiceName')
        Assert-Case -Name 'F3 site added after deploy is caught' -Result $r -ExpectExit 2 `
            -Expect @('IIS_SERVICE_NAME_MISSING', 'latecomer')
        $null = Invoke-Instrument -Quiet
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'env,iisServiceName')
        Assert-Case -Name 'F3 re-running names the new site' -Result $r `
            -Expect @('OTEL_SERVICE_NAME=latecomer') -Reject @('CX_IIS_SERVICES_DRIFT')
    }

    # F4. ASP.NET Core app on a managed-runtime pool. The app still runs and still reports -
    #     Microsoft's own wording is that No Managed Code is "optional but recommended" - so
    #     this is a hygiene warning, and the app stays instrumented and stays claimed.
    if (Use-Case 'F4') {
        # 'managedRuntimeVersion=v4.0' discriminates shop from 'defaults-core', which always
        # raises POOL_NOT_NO_MANAGED_CODE but renders as '<inherited default, v4.0>' because
        # its pool has no attribute at all. Rejecting the bare code after the fix would match
        # defaults-core and fail for the wrong reason.
        $null = Invoke-Break -BreakCase 'poolManagedRuntime' -Pool 'shop'
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F4 pool off No Managed Code is caught' -Result $r -ExpectExit 2 `
            -Expect @('POOL_NOT_NO_MANAGED_CODE', 'managedRuntimeVersion=v4.0')
        # Misconfigured is not Unsupported: dropping the app here would strip its name and
        # produce drift against a service that genuinely still reports.
        $svc = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
        Assert-True 'F4 the app stays claimed in CX_IIS_SERVICES while misconfigured' `
            ($svc.Out -match '(^|,)\s*shop\s*(,|$)') $svc.Out.Trim()
        $null = Invoke-Break -BreakCase 'restorePoolRuntime' -Pool 'shop'
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F4 restoring the pool clears it' -Result $r -Reject @('managedRuntimeVersion=v4.0')
    }

    # F8. The MIRROR of F4, and the reason the pool setting cannot be read on its own: the
    #     same "No Managed Code" that is correct for shape 2 stops shape 5 running at all.
    if (Use-Case 'F8') {
        $null = Invoke-Break -BreakCase 'poolNoManagedCode' -Pool 'legacy'
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F8 Framework app in a No-Managed-Code pool is caught' -Result $r -ExpectExit 2 `
            -Expect @('FRAMEWORK_POOL_NO_MANAGED_CLR', 'legacy/')
        # Still Misconfigured, not Unsupported - so still named, still claimed, and NO drift.
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisServiceName')
        Assert-Case -Name 'F8 a misconfigured Framework app does not produce CX_IIS_SERVICES drift' -Result $r `
            -Reject @('CX_IIS_SERVICES_DRIFT')
        $null = Invoke-Break -BreakCase 'restorePoolRuntimeV4' -Pool 'legacy'
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F8 restoring v4.0 clears it' -Result $r -Reject @('FRAMEWORK_POOL_NO_MANAGED_CLR')
    }

    # F9. Undeterminable runtime, then an operator override. The override travels as
    #     CX_RUNTIME_OVERRIDES_JSON, which is how a fleet would actually set it: deploy.bat
    #     and doctor.bat both read that variable, so the install and the check cannot end up
    #     disagreeing about which apps are instrumentable.
    if (Use-Case 'F9') {
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F9 ambiguous runtime is reported, not guessed' -Result $r `
            -Expect @('RUNTIME_UNKNOWN_NEEDS_OVERRIDE', 'binonly/')

        # Built with ConvertTo-Json from a hashtable: a literal '{ "binonly/": ... }' loses its
        # double quotes crossing `docker exec ... -Command` and arrives as invalid JSON.
        $null = Invoke-Exec "@{ 'binonly/' = 'AspNetCore' } | ConvertTo-Json | Set-Content -LiteralPath C:\cx\runtimes.json -Encoding utf8"
        $ovEnv = @{ CX_NO_SUPERVISOR = '1'; CX_RUNTIME_OVERRIDES_JSON = 'C:\cx\runtimes.json' }
        if ($collectorInstallable) {
            $ins = Invoke-Deploy -Env $ovEnv
        } else {
            # Same as P2: deploy.bat cannot finish in this image, but the half under test -
            # the instrumenter reading CX_RUNTIME_OVERRIDES_JSON - can.
            $ins = Invoke-Instrument -Quiet -Env @{ CX_RUNTIME_OVERRIDES_JSON = 'C:\cx\runtimes.json' }
        }
        # The installer prints one line per app as "<site> <path> pool=<pool> -> <name>
        # [<scope>] <runtime>/<instrumentability>", so the verdict is what to assert here;
        # OTEL_SERVICE_NAME itself is written by appcmd and never echoed. The authoritative
        # check is the env var, immediately below.
        Assert-Case -Name 'F9 deploy with an override instruments the app' -Result $ins `
            -Expect @('binonly', 'AspNetCore/Supported') `
            -Reject @('RUNTIME_UNKNOWN_NEEDS_OVERRIDE')
        $svc = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
        Assert-True 'F9 the overridden app is now claimed in CX_IIS_SERVICES' `
            ($svc.Out -match 'binonly') $svc.Out.Trim()
        # The doctor must reach the same verdict, and it gets there the same way the install
        # did - by reading the env var, not by being handed a flag. If only one side saw the
        # override the two would disagree about membership and drift permanently.
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation') `
            -Env @{ CX_RUNTIME_OVERRIDES_JSON = 'C:\cx\runtimes.json' }
        Assert-Case -Name 'F9 the doctor honours the same override file' -Result $r `
            -Expect @('RUNTIME_OVERRIDE_APPLIED') -Reject @('RUNTIME_UNKNOWN_NEEDS_OVERRIDE')

        # A key that matches nothing is the likeliest operator mistake: wrong key space (the
        # -ServiceNameOverrides shape), a typo, or a decommissioned site. It must move the
        # exit code rather than quietly do nothing.
        $null = Invoke-Exec "@{ 'No Such Site/' = 'AspNetCore' } | ConvertTo-Json | Set-Content -LiteralPath C:\cx\runtimes-bad.json -Encoding utf8"
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation') `
            -Env @{ CX_RUNTIME_OVERRIDES_JSON = 'C:\cx\runtimes-bad.json' }
        Assert-Case -Name 'F9 an override matching no app is a warning' -Result $r -ExpectExit 2 `
            -Expect @('RUNTIME_OVERRIDE_UNMATCHED')

        # Revert, so F9 is self-contained like every other case here. Without this the
        # override is in force for F10 and P5 but only on whichever runs happen to carry the
        # env var, and P5's "CX_IIS_SERVICES unchanged by a repeat deploy" would fail on a
        # difference this case created rather than on a real regression.
        $null = Invoke-Exec "Remove-Item -LiteralPath C:\cx\runtimes.json,C:\cx\runtimes-bad.json -Force -ErrorAction SilentlyContinue"
        $null = Invoke-Instrument -Quiet
        $svc = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
        Assert-True 'F9 dropping the override un-claims the app again' `
            ($svc.Out -notmatch 'binonly') $svc.Out.Trim()
        Note 'runtime overrides' 'Two override key spaces exist and they are one character apart for root apps: -ServiceNameOverrides is keyed by the derived SERVICE name (''Wallet''), -RuntimeOverrides by APP IDENTITY (''Wallet/''). The runtime key is the string the doctor prints in its Target column. The slash-less form is accepted as an alias, and a key matching no app is reported rather than ignored.'
    }

    # F10. Upgrade path. A host instrumented by a PRE-classification build already carries a
    #      name on a static site''s pool. Skipping that app is not enough - the value would sit
    #      there forever and the doctor would keep reporting a name the installer refuses to
    #      claim. The installer has to actively remove it.
    if (Use-Case 'F10') {
        $null = Invoke-Break -BreakCase 'seedStaleServiceName' -Pool 'staticwc' -Site 'staticwc'
        $seeded = Invoke-Exec (@'
[xml]$x = Get-Content 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Raw; $x.SelectNodes('//applicationPools/add/environmentVariables/add') | Where-Object { $_.ParentNode.ParentNode.GetAttribute('name') -eq 'staticwc' } | ForEach-Object { $_.GetAttribute('name') }
'@)
        Assert-True 'F10 precondition: the stale name really was planted' `
            ($seeded.Out -match 'OTEL_SERVICE_NAME') $seeded.Out.Trim()

        $null = Invoke-Instrument -Quiet
        $after = Invoke-Exec (@'
[xml]$x = Get-Content 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Raw; $x.SelectNodes('//applicationPools/add/environmentVariables/add') | Where-Object { $_.ParentNode.ParentNode.GetAttribute('name') -eq 'staticwc' } | ForEach-Object { $_.GetAttribute('name') }
'@)
        Assert-True 'F10 re-running REMOVES the stale name, not just ignores it' `
            ($after.Out -notmatch 'OTEL_SERVICE_NAME') $after.Out.Trim()
        $svc = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
        Assert-True 'F10 and the host does not claim it' ($svc.Out -notmatch 'staticwc') $svc.Out.Trim()
    }

    # F5. Endpoint fixed centrally, pools keep their stale snapshot.
    if (Use-Case 'F5') {
        $null = Invoke-Break -BreakCase 'poolEnvStale'
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F5 stale pool env snapshot is caught' -Result $r -ExpectExit 2 -Expect @('POOL_ENV_STALE')
        $null = Invoke-Instrument -Quiet
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F5 re-running refreshes every pool' -Result $r -Reject @('POOL_ENV_STALE')
    }

    # F6. Logs written where the collector never looks - the silent one.
    if (Use-Case 'F6') {
        $null = Invoke-Break -BreakCase 'clearLogSlots'
        $null = Invoke-Break -BreakCase 'logDirCustom' -Site 'shop' -LogDir 'C:\iislogs\custom'
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F6 uncovered log directory is caught' -Result $r -ExpectExit 2 `
            -Expect @('IIS_LOGDIR_NOT_COVERED')
        # The fix is an env var, published by the instrumenter - not a config edit.
        $null = Invoke-Instrument -Quiet
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
        Assert-Case -Name 'F6 re-running publishes the slot and covers it' -Result $r `
            -Reject @('IIS_LOGDIR_NOT_COVERED')
        Note 'IIS log directories' 'A site with a non-default logFile.directory needs CX_IIS_LOG_DIR_n published AND the collector restarted - the receiver reads its include list only at start.'
        $null = Invoke-Break -BreakCase 'restoreLogDir' -Site 'shop'
    }

    # F7. Collector down: a hard fail, distinct from every "degraded" above.
    if ((Use-Case 'F7') -and -not $collectorInstallable) {
        Skip-Case 'F7 stopped collector' 'no collector can be installed in this image (see P0)'
    }
    if ((Use-Case 'F7') -and $collectorInstallable) {
        $null = Invoke-Exec "Stop-Service otelcol-contrib -Force -ErrorAction SilentlyContinue"
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'services,health')
        Assert-Case -Name 'F7 stopped collector is a HARD fail' -Result $r -ExpectExit 1 `
            -Expect @('COLLECTOR_SERVICE_STOPPED')
        $null = Invoke-Exec "Start-Service otelcol-contrib -ErrorAction SilentlyContinue"
        Start-Sleep -Seconds 10
        $r = Invoke-Doctor -DoctorArgs @('-Only', 'services')
        Assert-Case -Name 'F7 restarting clears it' -Result $r -Reject @('COLLECTOR_SERVICE_STOPPED')
    }
}

# ---------------------------------------------------------------------------
# P4. Telemetry in Coralogix
# ---------------------------------------------------------------------------
if ((Use-Case 'P4') -and -not $SkipTelemetry -and -not $collectorInstallable) {
    Write-Host ''
    Write-Host '== P4. telemetry in Coralogix ==' -ForegroundColor Cyan
    Skip-Case 'Coralogix telemetry gates' 'nothing can export without a collector (see P0) - run this phase on a VM or a real host'
}
if ((Use-Case 'P4') -and -not $SkipTelemetry -and $collectorInstallable) {
    Write-Host ''
    Write-Host '== P4. telemetry in Coralogix ==' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $QueryKeyFile)) {
        Assert-True "query key present ($QueryKeyFile)" $false 'pass -QueryKeyFile or create querydata_key.txt'
    } else {
        # Real requests, so there are spans to export and access-log lines to tail.
        # Single-quoted here-string: nothing is expanded HERE, so the container
        # receives exactly these characters. String concatenation instead of
        # interpolation keeps the payload free of nested double quotes, which do
        # not survive `docker exec ... -Command`.
        Write-Host '   generating load...'
        $null = Invoke-Exec (@'
1..40 | ForEach-Object { foreach ($p in 8081,8082,8083,8084,8085,80) { try { Invoke-WebRequest -Uri ('http://127.0.0.1:' + $p + '/') -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {} } }
'@)

        # On-host gate FIRST: it is instant and, when it fails, tells you the data
        # never left the box - so no amount of waiting on the query API would help.
        $m = Invoke-Exec (@'
(Invoke-WebRequest 'http://127.0.0.1:8888/metrics' -UseBasicParsing).Content -split [char]10 | Where-Object { $_ -match '^otelcol_exporter_sent?_(log_records|spans|metric_points)_total' -or $_ -match '^otelcol_exporter_send_failed' } | Where-Object { $_ -notmatch ' 0$' }
'@)
        Assert-True 'collector is exporting (non-zero sent counters)' ($m.Out -match 'otelcol_exporter_sent') $m.Out.Trim()
        Assert-True 'no send failures' ($m.Out -notmatch 'send_failed') $m.Out.Trim()

        Write-Host '   waiting for ingest...'
        Start-Sleep -Seconds 60

        $verify = Join-Path $RepoRoot 'scripts\Verify-CoralogixInfraLabels.ps1'
        if (Test-Path -LiteralPath $verify) {
            # -MustNotContain is the end-to-end proof of runtime classification: the installer
            # can claim whatever it likes locally, but this asks the BACKEND whether a
            # non-.NET app ended up as a Service on this host. -HostName pins the query to
            # this run (the container hostname is unique per run), so a stale record from an
            # earlier run cannot answer for it.
            # Read the value from the CONTAINER, not this shell: $env:CX_IIS_SERVICES here is
            # the operator's own machine, which has nothing to do with the host under test.
            $cxSvc = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
            $out = & $verify -HostName $HostName -QueryKeyFile $QueryKeyFile `
                -ApiUrl $DpUrl `
                -ExpectedValue $cxSvc.Out.Trim() `
                -MustNotContain @('Default Web Site', 'staticwc', 'arrproxy') 2>&1 | Out-String
            Assert-True 'Coralogix carries this host''s infra labels, and no non-.NET app among them' `
                ($LASTEXITCODE -eq 0) ($out -split "`r?`n" | Select-Object -Last 16 | Out-String)
        } else {
            Assert-True 'Verify-CoralogixInfraLabels.ps1 present' $false $verify
        }
    }
}

# ---------------------------------------------------------------------------
# P5. Idempotency
# ---------------------------------------------------------------------------
if (Use-Case 'P5') {
    Write-Host ''
    Write-Host '== P5. idempotency ==' -ForegroundColor Cyan

    $before = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
    if ($collectorInstallable) {
        $r = Invoke-Deploy -Env @{ CX_NO_SUPERVISOR = '1'; CX_ENVIRONMENT = 'e2e' }
        Assert-Case -Name 'second deploy.bat still exits 0' -Result $r -ExpectExit 0
    } else {
        # deploy.bat cannot finish here, but the instrumentation half - which is
        # what could actually double-apply - can, so still test that.
        $null = Invoke-Instrument -Quiet
        Skip-Case 'second deploy.bat exit code' 'no collector in this image (see P0); re-ran Instrument-IIS.ps1 instead'
    }
    $after = Invoke-Exec "[Environment]::GetEnvironmentVariable('CX_IIS_SERVICES','Machine')"
    Assert-True 'CX_IIS_SERVICES unchanged by a repeat deploy' ($before.Out.Trim() -eq $after.Out.Trim()) `
        "before='$($before.Out.Trim())' after='$($after.Out.Trim())'"

    # A pool must not accumulate duplicate OTEL_* entries across runs.
    $dupes = Invoke-Exec (@'
[xml]$x = Get-Content 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Raw; ($x.SelectNodes('//applicationPools/add/environmentVariables/add') | Group-Object { $_.ParentNode.ParentNode.GetAttribute('name') + '/' + $_.GetAttribute('name') } | Where-Object { $_.Count -gt 1 } | Measure-Object).Count
'@)
    Assert-True 'no duplicate pool env entries after two runs' ($dupes.Out.Trim() -eq '0') $dupes.Out.Trim()

    # Idempotent CLASSIFICATION, not just idempotent writes. The membership rule is now
    # computed on both sides - the installer builds CX_IIS_SERVICES from it, the doctor
    # rebuilds the expected set from it - so a run where those two disagree shows up here as
    # drift that no re-run can clear. That is the specific regression this change risks, and
    # it is invisible to the byte-comparison above (which would pass on two identically
    # WRONG values).
    $r = Invoke-Doctor -DoctorArgs @('-Only', 'iisServiceName')
    Assert-Case -Name 'no CX_IIS_SERVICES drift after a repeat deploy' -Result $r `
        -Reject @('CX_IIS_SERVICES_DRIFT', 'CX_IIS_SERVICES_MISSING')

    # And the verdicts themselves must be stable: same host, same classification, twice.
    $rt1 = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
    $rt2 = Invoke-Doctor -DoctorArgs @('-Only', 'iisInstrumentation')
    $codes1 = (([regex]::Matches($rt1.Out, '\(([A-Z][A-Z0-9_]+)\)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique) -join ','
    $codes2 = (([regex]::Matches($rt2.Out, '\(([A-Z][A-Z0-9_]+)\)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique) -join ','
    Assert-True 'runtime classification is stable across runs' ($codes1 -eq $codes2) "run1=[$codes1] run2=[$codes2]"
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:Notes.Count) {
    Write-Host '== cases needing a fix or non-default configuration ==' -ForegroundColor Yellow
    foreach ($n in $script:Notes) { Write-Host ("  - [{0}] {1}" -f $n.Topic, $n.Text) }
    Write-Host '  (record these in docs/iis-e2e-matrix.md)' -ForegroundColor DarkGray
    Write-Host ''
}
Write-Host ("== RESULT: {0} passed, {1} failed ==" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if (-not $KeepContainer) {
    docker rm -f $Container 2>$null | Out-Null
    Write-Host "   removed $Container"
} else {
    Write-Host "   kept $Container (docker rm -f $Container to clean up)" -ForegroundColor DarkGray
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
