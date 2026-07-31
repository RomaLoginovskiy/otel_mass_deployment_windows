<#
.SYNOPSIS
  Read-only host diagnostic for the Coralogix fleet agent: why is telemetry or
  config not what you expect on THIS machine?

.DESCRIPTION
  Standalone. NOT called by Install-Agent.ps1. Runs nine checks and grades the
  host:

    1. env                machine env vars (CX_IIS_SERVICES, CX_ENVIRONMENT,
                          CORALOGIX_*, OTEL_RESOURCE_ATTRIBUTES, ...)
    2. iisServiceName     per-app OTEL_SERVICE_NAME actually readable back from
                          the app pool / web.config, vs what IIS looks like now
    3. services           opampsupervisor / otelcol-contrib + StartType
    4. health             collector health endpoint 13133
    5. exportCounters     collector internal metrics 8888 - is anything leaving?
    6. ports              OTLP receivers 4318 / 4317 listening
    7. effectiveConfig    transform/iis_service_labels present AND wired into the
                          logs + logs/resource_catalog pipelines. Reads whichever
                          collector config this host actually has: the supervisor's
                          merged effective.yaml, else its base collector.yaml, else
                          the plain service's ProgramData config.yaml.
    8. iisInstrumentation  (delegated to Test-IISInstrumentation.ps1)
    9. nodeInstrumentation (delegated to Test-NodeInstrumentation.ps1)

  Use -Only to run any subset manually, e.g.
      .\Test-Agent.ps1 -Only env,iisServiceName
  Checks 8 and 9 are also runnable entirely on their own:
      .\Test-IISInstrumentation.ps1
      .\Test-NodeInstrumentation.ps1

  READ-ONLY INVARIANT: never sets an env var, never runs appcmd, never runs
  iisreset, never starts/stops a service, never downloads. The only writes are
  its own report files (suppress with -NoFileOutput).

  Exit codes are GRADED so BatchPatch can triage a fleet run:
    0 = pass       every check passed (or was legitimately N/A for this host)
    1 = hard fail  not elevated, no private key, or the collector is down
    2 = degraded   collector is up but something is misconfigured

  Note that BatchPatch shows BOTH 1 and 2 as failed rows - the distinction is in
  the Exit Code column and in doctor.bat's echoed exit code. Triage 2s in bulk
  and 1s individually.

.NOTES
  Windows PowerShell 5.1. MUST run elevated - applicationHost.config is readable
  by Administrators only, so a non-elevated run would falsely report every IIS
  app as unconfigured. That is why "not elevated" is a hard fail, not a warning.
#>
# PositionalBinding=$false is deliberate. Under `powershell -File`, an array
# parameter only binds the NEXT token, so `-Only env iisServiceName` would bind
# 'env' to -Only and then silently bind 'iisServiceName' to the first positional
# parameter ($JsonPath) - a wrong run AND a garbage report path, with no error.
# With positional binding off, that mistake is rejected outright and the user is
# told to use the comma form.
[CmdletBinding(PositionalBinding = $false)]
param(
    # --- output ---------------------------------------------------------------
    # Default <scriptdir>\agent-doctor.json - the same "next to the scripts"
    # convention as install-agent-status.json / detect-workloads.json, which
    # poc/Deploy-FromHost.ps1 already harvests.
    [string]   $JsonPath        = $null,
    [switch]   $NoFileOutput,
    [switch]   $Quiet,
    [switch]   $PassThru,

    # Run only these checks. Anything omitted reports SKIP and does not affect the
    # exit code. Accepts either form, because both occur in practice:
    #     -Only env iisServiceName        (space-separated, native array binding)
    #     -Only env,iisServiceName        (ONE string under `powershell -File`,
    #                                      which is what doctor.bat forwards)
    #
    # Deliberately NO [ValidateSet]. Under -File a comma-joined list arrives as a
    # single string and ValidateSet rejects it outright; worse, a typo would fail
    # parameter binding before any output exists, giving BatchPatch a red row with
    # no diagnostics at all. Normalised and validated below with a readable error.
    [string[]] $Only,

    # --- probe targets (parameterised so every failure path is testable) -------
    [string]   $HealthUrl           = 'http://127.0.0.1:13133',
    [string]   $MetricsUrl          = 'http://127.0.0.1:8888/metrics',
    [int]      $OtlpHttpPort        = 4318,
    [int]      $OtlpGrpcPort        = 4317,
    [string]   $EffectiveConfig     = 'C:\ProgramData\opampsupervisor\state\effective.yaml',
    [string]   $BaseCollectorConfig = 'C:\Program Files\OpenTelemetry OpAMP Supervisor\collector.yaml',
    # Where the plain collector service keeps its config when it was installed
    # WITHOUT the supervisor. Searched last, so a supervisor host is unaffected.
    [string]   $LocalCollectorConfig = 'C:\ProgramData\OpenTelemetry\Collector\config.yaml',
    [string[]] $RequiredProcessors  = @('transform/iis_service_labels'),
    [string[]] $RequiredPipelines   = @('logs','logs/resource_catalog'),
    # The environment stamp is checked separately from $RequiredProcessors, for two
    # reasons: it applies to EVERY host rather than only the IIS ones (so it must sit
    # outside the IIS gate below), and it has to reach the app signals as well - a
    # processor wired into logs but not traces is exactly how spans end up with no
    # environment label while every other check still reports a pass.
    [string]   $EnvironmentProcessor = 'transform/environment',
    [string[]] $EnvironmentPipelines = @('logs','metrics','traces'),
    [string]   $ExpectedOtlpEndpoint = 'http://127.0.0.1:4318',

    # Pass the SAME overrides the install used, or the service-name comparison
    # will report false drift on every app.
    [hashtable] $ServiceNameOverrides = @{},
    [string]    $OverridesJson,

    # Likewise for runtime classification: CX_IIS_SERVICES membership depends on it, so a
    # doctor run with different runtime overrides than the install will report drift that
    # is not there. Note the DIFFERENT key space - app identity ("Site/", "Site/api"), not
    # the derived service name. See Resolve-IISAppRuntime.ps1.
    [hashtable] $RuntimeOverrides = @{},
    # Reads the env var by default, exactly as Instrument-IIS.ps1 does, so a fleet that stages
    # one overrides file gets the same classification on both sides without threading a flag
    # through deploy.bat and doctor.bat.
    [string]    $RuntimeOverridesJson = $env:CX_RUNTIME_OVERRIDES_JSON,

    # --- tuning ----------------------------------------------------------------
    # Install-Agent.ps1 retries 12x5s because it JUST restarted the supervisor.
    # The doctor restarts nothing, so a long wait only slows a fleet sweep.
    # 3 tries with the first immediate: a healthy host costs ~50ms, a host
    # mid-relaunch still gets ~10s of grace before it is called down.
    [int]      $HealthRetries   = 3,
    [int]      $HealthDelaySec  = 5,
    [int]      $TimeoutSec      = 8,

    [string]   $NodeInstallPrefix = 'C:\cx\otel-node'
)

# Native probes (netstat fallback) write to stderr; under 'Stop' that becomes a
# terminating NativeCommandError in PS 5.1.
$ErrorActionPreference = 'Continue'

# $PSScriptRoot is empty under `powershell -File <relative>`.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# ---------------------------------------------------------------------------
# Dependencies - every one guarded, so a partial package degrades to UNKNOWN
# rather than crashing.
# ---------------------------------------------------------------------------
# Each dot-source is written out inline, NOT wrapped in a helper function.
# Dot-sourcing INSIDE a function puts the definitions in that function's scope,
# which is discarded the moment it returns - the files appear to load and every
# function they define is then missing. Only a dot-source at script scope makes
# them available to the rest of this script.
$script:CxMissingDeps = @()

$dep = Join-Path $here 'Write-DeployLog.ps1'          # finding model + formatters
if (Test-Path -LiteralPath $dep -ErrorAction SilentlyContinue) { . $dep }
else { $script:CxMissingDeps += 'Write-DeployLog.ps1' }

$dep = Join-Path $here 'Detect-Workloads.ps1'         # probe helpers; its dot-source guard prevents a scan
if (Test-Path -LiteralPath $dep -ErrorAction SilentlyContinue) { . $dep }
else { $script:CxMissingDeps += 'Detect-Workloads.ps1' }

$dep = Join-Path $here 'Resolve-IISServiceNames.ps1'  # Get-IISServiceMap (pure library)
if (Test-Path -LiteralPath $dep -ErrorAction SilentlyContinue) { . $dep }
else { $script:CxMissingDeps += 'Resolve-IISServiceNames.ps1' }

$dep = Join-Path $here 'Test-IISInstrumentation.ps1'
if (Test-Path -LiteralPath $dep -ErrorAction SilentlyContinue) { . $dep }
else { $script:CxMissingDeps += 'Test-IISInstrumentation.ps1' }

$dep = Join-Path $here 'Test-NodeInstrumentation.ps1'
if (Test-Path -LiteralPath $dep -ErrorAction SilentlyContinue) { . $dep }
else { $script:CxMissingDeps += 'Test-NodeInstrumentation.ps1' }

$dep = Join-Path $here 'Resolve-CxRegion.ps1'         # region <-> domain table (display only here)
if (Test-Path -LiteralPath $dep -ErrorAction SilentlyContinue) { . $dep }
else { $script:CxMissingDeps += 'Resolve-CxRegion.ps1' }

# Availability is decided by the function actually being callable, not by the
# file existing - that is what the bug above taught.
$hasIisInstr  = [bool](Get-Command Test-IISInstrumentation  -ErrorAction SilentlyContinue)
$hasNodeInstr = [bool](Get-Command Test-NodeInstrumentation -ErrorAction SilentlyContinue)

# Canonical implementation lives in Test-IISInstrumentation.ps1. This fallback
# only fires when that file is missing, so the doctor still resolves the inetsrv
# path correctly under WOW64 while degraded. See Get-CxInetsrvDir there for why
# hardcoding System32 breaks a 32-bit run.
if (-not (Get-Command Get-CxInetsrvDir -ErrorAction SilentlyContinue)) {
    function Get-CxInetsrvDir {
        if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
            return (Join-Path $env:windir 'Sysnative\inetsrv')
        }
        return (Join-Path $env:windir 'System32\inetsrv')
    }
}
if (-not (Get-Command Get-CxAppHostConfigPath -ErrorAction SilentlyContinue)) {
    function Get-CxAppHostConfigPath { Join-Path (Get-CxInetsrvDir) 'config\applicationHost.config' }
}

if (-not (Get-Command New-Finding -ErrorAction SilentlyContinue)) {
    function New-Finding {
        param([string]$Check, [string]$Severity, [string]$Code = '', [string]$Message = '', [string]$Target = '', $Data = $null)
        [pscustomobject]@{ check = $Check; severity = $Severity; code = $Code; target = $Target; message = $Message; data = $Data }
    }
    function Get-GradedExitCode {
        param([object[]]$Findings)
        $f = @($Findings) | Where-Object { $_ }
        if (@($f | Where-Object { $_.severity -eq 'fail' }).Count -gt 0) { return 1 }
        if (@($f | Where-Object { $_.severity -eq 'warn' }).Count -gt 0) { return 2 }
        return 0
    }
    function Write-FindingTable {
        param([object[]]$Findings, [string]$Title, [switch]$Quiet)
        if ($Title) { Write-Host ''; Write-Host "== $Title ==" }
        foreach ($f in @($Findings)) {
            if (-not $f) { continue }
            if ($Quiet -and ($f.severity -eq 'pass' -or $f.severity -eq 'skip')) { continue }
            Write-Host ("  [{0,-7}] {1} {2} {3}" -f $f.severity.ToUpperInvariant(), $f.check, $f.target, $f.message)
        }
    }
    function Write-FindingSummary {
        param([object[]]$Findings, [string]$Label = 'RESULT', [int]$ExitCode = -1)
        if ($ExitCode -lt 0) { $ExitCode = Get-GradedExitCode -Findings $Findings }
        Write-Host "=== $Label RESULT: exit=$ExitCode ==="
    }
    function Get-FindingCounts {
        param([object[]]$Findings)
        $c = [ordered]@{ pass=0; warn=0; fail=0; info=0; skip=0; unknown=0 }
        foreach ($f in @($Findings)) { if ($f -and $c.Contains([string]$f.severity)) { $c[[string]$f.severity]++ } }
        $c
    }
}

$AllChecks = @('env','iisServiceName','services','health','exportCounters',
               'ports','effectiveConfig','iisInstrumentation','nodeInstrumentation')

$selected = $AllChecks
if ($Only) {
    # Flatten both accepted forms into one list, then match case-insensitively
    # against the canonical names so -Only ENV works too.
    $wanted = @($Only) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $resolved = @()
    $unknown  = @()
    foreach ($w in $wanted) {
        $hit = @($AllChecks | Where-Object { $_ -ieq $w }) | Select-Object -First 1
        if ($hit) { $resolved += $hit } else { $unknown += $w }
    }
    if ($unknown.Count -gt 0) {
        Write-Host ''
        Write-Host "  unknown check name(s): $($unknown -join ', ')" -ForegroundColor Red
        Write-Host "  valid names: $($AllChecks -join ', ')"
        Write-Host '=== DOCTOR RESULT: HARD FAIL (BAD_ARGUMENT)  exit=1 ==='
        exit 1
    }
    $selected = @($resolved | Select-Object -Unique)
}

$findings = New-Object System.Collections.ArrayList
function Add-F { param($f) if ($f) { [void]$findings.Add($f) } }
function Add-Many { param($fs) foreach ($f in @($fs)) { Add-F $f } }
function Use-Check { param([string]$Name) return ($selected -contains $Name) }

# ---------------------------------------------------------------------------
# Gate: elevation. Before any check - a non-elevated run would confidently
# report the exact symptom under investigation.
# ---------------------------------------------------------------------------
function Test-CxAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

Write-Host ''
Write-Host "Coralogix agent doctor - $env:COMPUTERNAME  ($(Get-Date -Format 's'))"
if ($Only) { Write-Host "  running only: $($selected -join ', ')" }
if ($script:CxMissingDeps.Count -gt 0) {
    Write-Host "  missing helpers: $($script:CxMissingDeps -join ', ')" -ForegroundColor Yellow
}

if (-not (Test-CxAdmin)) {
    Write-Host ''
    Write-Host '  [FAIL   ] elevation  NOT running as Administrator.'
    Write-Host '            applicationHost.config and the collector service state are readable'
    Write-Host '            by Administrators only, so a non-elevated run would report EVERY IIS'
    Write-Host '            app as unconfigured. Re-run from an elevated Windows PowerShell 5.1'
    Write-Host '            prompt, or via doctor.bat.'
    Write-Host ''
    Write-Host '=== DOCTOR RESULT: HARD FAIL (NOT_ELEVATED)  exit=1 ==='
    exit 1
}

$iisPresent = (Test-Path -LiteralPath (Join-Path (Get-CxInetsrvDir) 'appcmd.exe') -ErrorAction SilentlyContinue) -or
              [bool](Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue)

# ---------------------------------------------------------------------------
# 1. Machine environment variables
# ---------------------------------------------------------------------------
function Get-MachineVar { param([string]$Name) try { [Environment]::GetEnvironmentVariable($Name, 'Machine') } catch { $null } }

$cxIisServices = Get-MachineVar 'CX_IIS_SERVICES'

if (Use-Check 'env') {
    $privateKey = Get-MachineVar 'CORALOGIX_PRIVATE_KEY'
    if (-not $privateKey) {
        Add-F (New-Finding -Check 'env' -Severity 'fail' -Code 'PRIVATE_KEY_MISSING' -Target 'CORALOGIX_PRIVATE_KEY' `
            -Message 'not set at machine scope - the collector cannot authenticate and nothing reaches Coralogix')
    } else {
        # Never print the key. Length only, as proof of presence.
        Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'CORALOGIX_PRIVATE_KEY' `
            -Message "present ($($privateKey.Length) chars)" -Data @{ length = $privateKey.Length })
    }

    # CORALOGIX_DOMAIN is the region. The recommended config resolves it as
    # ${env:CORALOGIX_DOMAIN:-eu1.coralogix.com}, so an unset variable is not "the
    # config decides" - it is "this host silently ships to eu1".
    $domain = Get-MachineVar 'CORALOGIX_DOMAIN'
    if (-not $domain) {
        Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'DOMAIN_MISSING' -Target 'CORALOGIX_DOMAIN' `
            -Message 'not set - the config default applies and this host ships to eu1. Re-deploy with -Region <code> (or CX_REGION), or -Domain / CX_DOMAIN for a private ingress, if that is not the account.')
    } else {
        # Name the region when the domain is one Coralogix publishes; flag it when it is
        # not, because a typo'd domain and a private ingress look identical from here and
        # the collector reports healthy either way.
        $regionCode = if (Get-Command Get-CxRegionForDomain -ErrorAction SilentlyContinue) { Get-CxRegionForDomain -Domain $domain } else { $null }
        if ($regionCode) {
            Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'CORALOGIX_DOMAIN' `
                -Message "$domain (region $regionCode)" -Data @{ domain = $domain; region = $regionCode })
        } else {
            Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'DOMAIN_NOT_A_KNOWN_REGION' -Target 'CORALOGIX_DOMAIN' `
                -Message "$domain is not a published Coralogix region domain - data goes to ingress.$domain. Expected for a private ingress (-Domain / CX_DOMAIN); a typo in that value otherwise." `
                -Data @{ domain = $domain })
        }
    }

    $environment = Get-MachineVar 'CX_ENVIRONMENT'
    if (-not $environment) {
        Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_ENVIRONMENT_MISSING' -Target 'CX_ENVIRONMENT' `
            -Message "not set - all telemetry from this host is labelled 'unspecified'")
    } else {
        Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'CX_ENVIRONMENT' -Message $environment)
    }

    $attrs = Get-MachineVar 'OTEL_RESOURCE_ATTRIBUTES'
    if (-not $attrs) {
        Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'RESOURCE_ATTRS_MISSING' -Target 'OTEL_RESOURCE_ATTRIBUTES' `
            -Message 'not set - Fleet Management agent-selector attributes (cx.host.role / workload.*) will be absent')
    } else {
        Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'OTEL_RESOURCE_ATTRIBUTES' -Message $attrs)
    }

    # The environment label is persisted TWICE, by two different scripts: machine
    # CX_ENVIRONMENT (what the collector stamps host and infra signals from) and
    # deployment.environment.name inside OTEL_RESOURCE_ATTRIBUTES (what the app SDKs and
    # the Fleet agent-selector read). Nothing above compares them, so a host carrying two
    # different environment identities passed every check individually - which is exactly
    # how one turned up in the field reporting 'qa' in one store and a different
    # environment in the other, with no finding to point at.
    if ($attrs) {
        $envAttrMatch = [regex]::Match($attrs, '(?:^|,)\s*deployment\.environment\.name\s*=\s*([^,]*)')
        if ($envAttrMatch.Success) {
            $attrEnv = $envAttrMatch.Groups[1].Value.Trim()
            if (-not $environment) {
                Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_ENVIRONMENT_MISMATCH' -Target 'deployment.environment.name' `
                    -Message "OTEL_RESOURCE_ATTRIBUTES says '$attrEnv' but CX_ENVIRONMENT is not set - app signals keep '$attrEnv' while host and infrastructure signals are labelled 'unspecified'. Re-deploy with -Environment to label the whole host." `
                    -Data @{ resourceAttributes = $attrEnv; machineVar = '' })
            } elseif ($attrEnv -ne $environment) {
                Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_ENVIRONMENT_MISMATCH' -Target 'deployment.environment.name' `
                    -Message "two environment identities on one host: CX_ENVIRONMENT='$environment' but OTEL_RESOURCE_ATTRIBUTES says '$attrEnv'. Re-deploy with -Environment to bring both stores back into step." `
                    -Data @{ resourceAttributes = $attrEnv; machineVar = $environment })
            } else {
                Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'deployment.environment.name' `
                    -Message "$attrEnv (agrees with CX_ENVIRONMENT)")
            }
        }
    }

    # CX_IIS_SERVICES: the variable this whole exercise started with.
    if (-not $iisPresent) {
        if ($cxIisServices) {
            Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_IIS_SERVICES_STALE' -Target 'CX_IIS_SERVICES' `
                -Message "set to '$cxIisServices' but this host has no IIS - a stale value from a prior deploy is being stamped on its telemetry" `
                -Data @{ value = $cxIisServices })
        } else {
            Add-F (New-Finding -Check 'env' -Severity 'skip' -Code 'IIS_ABSENT' -Target 'CX_IIS_SERVICES' `
                -Message 'no IIS on this host, so no IIS service label is expected')
        }
    } elseif (-not $cxIisServices) {
        # Deliberately not graded here - check 2 knows whether apps exist and can
        # say whether this is a real problem or a legitimately empty host.
        Add-F (New-Finding -Check 'env' -Severity 'info' -Target 'CX_IIS_SERVICES' `
            -Message 'not set (see the iisServiceName check for whether that is expected on this host)')
    } else {
        Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'CX_IIS_SERVICES' -Message $cxIisServices `
            -Data @{ value = $cxIisServices })
    }

    # CX_SERVICES is what the collector's transform/iis_service_labels reads FIRST; the per-runtime
    # variables are only its inputs. A host that publishes CX_NODE_SERVICES or CX_DOTNET_SERVICES but
    # no union silently falls back to IIS names, so those services are never claimed by the host
    # entity - the exact failure that looks like "APM has spans, Infra Explorer shows no ownership".
    # Unlike the per-runtime checks below, this one is deliberately case-INSENSITIVE on both sides:
    # Install-Agent.ps1 de-duplicates the union with an OrdinalIgnoreCase comparer and keeps the
    # first-seen spelling, so an IIS 'MyApp' and a Node 'myapp' legitimately collapse to one entry and
    # a case-sensitive comparison here would report drift on a correct host. Sort-Object -Unique is
    # case-insensitive (Select-Object -Unique is not), which is why it is used. What this check owns is
    # MEMBERSHIP - is every instrumented service in the union; the exact spelling that ends up on the
    # telemetry is graded against the app names by the CX_IIS_SERVICES / CX_NODE_SERVICES checks.
    $cxServices = Get-MachineVar 'CX_SERVICES'
    $unionSet = @(@($cxIisServices, (Get-MachineVar 'CX_NODE_SERVICES'), (Get-MachineVar 'CX_DOTNET_SERVICES')) |
        Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { "$_".Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)
    if (-not $unionSet.Count) {
        Add-F (New-Finding -Check 'env' -Severity 'info' -Target 'CX_SERVICES' `
            -Message 'not set, and no IIS/Node/.NET service names are published either - nothing is instrumented on this host to claim')
    } elseif (-not $cxServices) {
        Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_SERVICES_MISSING' -Target 'CX_SERVICES' `
            -Message "not set, but $($unionSet.Count) service name(s) are published across CX_IIS_SERVICES/CX_NODE_SERVICES/CX_DOTNET_SERVICES. The collector falls back to IIS names only, so non-IIS services are not claimed for host ownership. Re-deploy: Install-Agent.ps1 publishes the union." `
            -Data @{ expected = $unionSet })
    } else {
        $haveSet = @($cxServices -split ',' | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
        if (Compare-Object -ReferenceObject $unionSet -DifferenceObject $haveSet) {
            Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_SERVICES_DRIFT' -Target 'CX_SERVICES' `
                -Message "set to '$cxServices', which is not the union of the per-runtime variables ($($unionSet -join ',')) - a partial or stale deploy. Re-run the installer to republish it." `
                -Data @{ cxServices = $haveSet; expected = $unionSet })
        } else {
            Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'CX_SERVICES' -Message $cxServices `
                -Data @{ value = $haveSet })
        }

        # MEMBERSHIP is not enough - the variable only does anything if the RUNNING config reads it.
        #
        # This gap was found on a real host: CX_SERVICES was set, correct, and graded pass, and the
        # collector process even had it in its environment - but the effective config predated
        # CX_SERVICES support and stamped ownership from CX_IIS_SERVICES alone. So a Node service
        # was published in every variable, appeared in APM, and was never claimed by the host
        # entity, with nothing anywhere reporting a problem. The config template in this repo reads
        # CX_SERVICES (transform/iis_service_labels) and falls back to CX_IIS_SERVICES; a host whose
        # remote Fleet config or staged base config is older silently gets the fallback.
        #
        # Only worth reporting when the union actually has names the IIS fallback would MISS: on an
        # IIS-only host the fallback is equivalent and there is nothing to fix.
        $iisSet   = @($cxIisServices -split ',' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $beyondIis = @($haveSet | Where-Object { $iisSet -notcontains $_ })
        if ($cxServices -and $beyondIis.Count) {
            # THE EFFECTIVE CONFIG DECIDES ALONE when it exists.
            #
            # Not "any config that mentions it", which is what this check did first and why it
            # passed on the very host that has the problem: the supervisor's BASE collector.yaml
            # had been updated and reads CX_SERVICES, while the effective config - the merge of
            # base and REMOTE, and literally otelcol's --config - is the older remote Fleet
            # version that reads CX_IIS_SERVICES only. The remote config wins, so consulting the
            # base masks the live behaviour exactly when it matters. Base/local are consulted only
            # when there is no effective config to read (local, non-supervisor mode).
            $readCfg  = $null
            $consumes = $false
            $fromEffective = $false
            $order = @($EffectiveConfig) + @($BaseCollectorConfig, $LocalCollectorConfig)
            foreach ($cfg in ($order | Where-Object { $_ })) {
                if (-not (Test-Path -LiteralPath $cfg -ErrorAction SilentlyContinue)) { continue }
                try {
                    # Ignore commented lines so a mention in a comment is not mistaken for a use.
                    $live = (Get-Content -LiteralPath $cfg -ErrorAction Stop | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                } catch { continue }
                $readCfg  = $cfg
                $consumes = [bool]($live -match 'CX_SERVICES')
                $fromEffective = ($cfg -eq $EffectiveConfig)
                break   # first READABLE config in precedence order is the verdict, match or not
            }

            if (-not $readCfg) {
                Add-F (New-Finding -Check 'env' -Severity 'unknown' -Code 'CX_SERVICES_CONSUMER_UNKNOWN' -Target 'CX_SERVICES' `
                    -Message "no collector config could be read, so whether the running config stamps host Service ownership from CX_SERVICES could not be determined. $($beyondIis.Count) non-IIS service(s) depend on it: $($beyondIis -join ', ')." `
                    -Data @{ beyondIis = $beyondIis })
            } elseif (-not $consumes) {
                $where = if ($fromEffective) {
                    'That file is the EFFECTIVE config - the merge of the staged base with the config Fleet Management sends - so this is what the collector is running right now. A newer base config on disk does not change it: the remote config wins. Fix it in Fleet Management (the remote config for this host), using the current template as the reference'
                } else {
                    'No effective config was readable, so this is the base/local config the collector starts from. Fix: re-deploy the current template'
                }
                Add-F (New-Finding -Check 'env' -Severity 'warn' -Code 'CX_SERVICES_NOT_CONSUMED' -Target 'CX_SERVICES' `
                    -Message "the collector config in force ($readCfg) does not read `${env:CX_SERVICES} - it stamps host Service ownership from CX_IIS_SERVICES only, which is the pre-CX_SERVICES fallback. So $($beyondIis.Count) service(s) published here are NOT claimed by this host however correct the variables look: $($beyondIis -join ', '). They still report in APM, which is why this reads as a Coralogix-side problem rather than a config one. $where - deploy\config.supervisor.yaml's transform/iis_service_labels reads CX_SERVICES and keeps CX_IIS_SERVICES as a fallback." `
                    -Data @{ config = $readCfg; fromEffectiveConfig = $fromEffective; beyondIis = $beyondIis; cxServices = $haveSet })
            } else {
                Add-F (New-Finding -Check 'env' -Severity 'pass' -Target 'CX_SERVICES consumer' `
                    -Message "the $(if ($fromEffective) { 'effective' } else { 'base' }) config in force reads `${env:CX_SERVICES}, so all $($haveSet.Count) service(s) - including $($beyondIis.Count) non-IIS - are claimed for host ownership" `
                    -Data @{ config = $readCfg; fromEffectiveConfig = $fromEffective })
            }
        }
    }
} else {
    Add-F (New-Finding -Check 'env' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 2. IIS per-app OTEL_SERVICE_NAME readback
# ---------------------------------------------------------------------------
function Get-WebConfigServiceName {
    <#
      Read OTEL_SERVICE_NAME back out of an app's web.config. NOTHING else in the
      repo does this - Set-WebConfigServiceName writes it and
      Remove-WebConfigServiceName deletes it, but no reader existed.

      //aspNetCore because the publish output commonly wraps the node in
      <location path="." ...> rather than placing it under <system.webServer>.

      Returns:
        $null   unknowable (no path / no web.config / unreadable / not Core)
        ''      the app IS ASP.NET Core but carries no OTEL_SERVICE_NAME
        <name>  the value
    #>
    param([string] $PhysicalPath)

    if (-not $PhysicalPath) { return $null }
    try {
        $wc = Join-Path $PhysicalPath 'web.config'
        if (-not (Test-Path -LiteralPath $wc -ErrorAction SilentlyContinue)) { return $null }
        [xml]$x = Get-Content -LiteralPath $wc -Raw -ErrorAction Stop
        $core = $x.SelectSingleNode('//aspNetCore')
        if (-not $core) { return $null }
        foreach ($n in @($core.SelectNodes('environmentVariables/environmentVariable'))) {
            if (([string]$n.GetAttribute('name')) -ieq 'OTEL_SERVICE_NAME') {
                return [string]$n.GetAttribute('value')
            }
        }
        return ''
    } catch { return $null }
}

if (Use-Check 'iisServiceName') {
    if (-not $iisPresent) {
        Add-F (New-Finding -Check 'iisServiceName' -Severity 'skip' -Code 'IIS_ABSENT' `
            -Message 'no IIS on this host')
    } elseif (-not (Get-Command Get-CxAppHostModel -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'iisServiceName' -Severity 'unknown' -Code 'HELPER_MISSING' `
            -Message 'Test-IISInstrumentation.ps1 is not present, so applicationHost.config cannot be parsed')
    } else {
        $model = Get-CxAppHostModel -Path (Get-CxAppHostConfigPath)

        if (-not $model.Ok) {
            $code = if ($model.Denied) { 'APPHOST_ACCESS_DENIED' } else { 'APPHOST_UNREADABLE' }
            Add-F (New-Finding -Check 'iisServiceName' -Severity 'unknown' -Code $code -Message $model.Error)
        } elseif (@($model.Apps).Count -eq 0) {
            Add-F (New-Finding -Check 'iisServiceName' -Severity 'skip' -Code 'IIS_NO_APPS' `
                -Message 'IIS is installed but hosts no applications')
            if ($cxIisServices) {
                Add-F (New-Finding -Check 'iisServiceName' -Severity 'warn' -Code 'CX_IIS_SERVICES_STALE' -Target 'CX_IIS_SERVICES' `
                    -Message "set to '$cxIisServices' but IIS hosts no applications - re-run Instrument-IIS.ps1 to clear it" `
                    -Data @{ value = $cxIisServices })
            }
        } else {
            # Runtime overrides first, and resolved ONCE. Two reasons to do it here rather
            # than at the point of use: the hashtable and the JSON file have to be merged
            # before either consumer sees them (passing only the hashtable to
            # Get-IISServiceMap would classify the map without the file's entries while the
            # loop below used both), and a bad VALUE throws - inside the try around
            # Get-IISServiceMap that would surface as WEBADMINISTRATION_MISSING, which is the
            # wrong diagnosis for an operator typo.
            $rtCapable = [bool](Get-Command Resolve-IISAppRuntime -ErrorAction SilentlyContinue)
            $rtOverrides = $null
            if ($rtCapable) {
                try { $rtOverrides = Resolve-IISRuntimeOverrides -Table $RuntimeOverrides -JsonPath $RuntimeOverridesJson }
                catch {
                    Add-F (New-Finding -Check 'iisServiceName' -Severity 'fail' -Code 'BAD_ARGUMENT' `
                        -Message "-RuntimeOverrides could not be parsed: $($_.Exception.Message)")
                }
            } else {
                Add-F (New-Finding -Check 'iisServiceName' -Severity 'unknown' -Code 'HELPER_MISSING' `
                    -Message 'Resolve-IISAppRuntime.ps1 is not present, so non-.NET apps cannot be told apart from uninstrumented ones. Every named app is counted toward CX_IIS_SERVICES, which is the pre-classification behaviour and may report drift against an installer that filtered them out.')
            }

            # Expected names. Prefer the authoritative library (it owns the naming
            # convention and the overrides); fall back to deriving them from
            # applicationHost.config when WebAdministration is unavailable - which
            # is itself one of the failure modes this tool exists to surface.
            $expectedMap = $null
            $derived     = $false
            if (Get-Command Get-IISServiceMap -ErrorAction SilentlyContinue) {
                try {
                    if ($OverridesJson -and (Test-Path -LiteralPath $OverridesJson -ErrorAction SilentlyContinue)) {
                        $fromFile = Get-Content -LiteralPath $OverridesJson -Raw | ConvertFrom-Json
                        foreach ($p in $fromFile.PSObject.Properties) {
                            if (-not $ServiceNameOverrides.ContainsKey($p.Name)) { $ServiceNameOverrides[$p.Name] = $p.Value }
                        }
                    }
                    $mapArgs = @{ Overrides = $ServiceNameOverrides }
                    if ($rtOverrides) { $mapArgs['RuntimeOverrides'] = $rtOverrides }
                    $expectedMap = @(Get-IISServiceMap @mapArgs)
                } catch {
                    Add-F (New-Finding -Check 'iisServiceName' -Severity 'unknown' -Code 'WEBADMINISTRATION_MISSING' `
                        -Message "Get-IISServiceMap failed ($($_.Exception.Message)) - falling back to deriving names from applicationHost.config")
                }
            }
            if (-not $expectedMap) {
                $derived = $true
                $expectedMap = @($model.Apps | ForEach-Object {
                    $n = if ($_.AppPath -eq '/') { $_.Site } else { "$($_.Site)$($_.AppPath)" }
                    if ($ServiceNameOverrides.ContainsKey($n)) { $n = [string]$ServiceNameOverrides[$n] }
                    [pscustomobject]@{ Site = $_.Site; AppPath = $_.AppPath; Pool = $_.Pool; PhysicalPath = $_.PhysicalPath; ServiceName = $n }
                })
            }

            # Classification below runs from $model.Apps rather than from $expectedMap: the
            # fallback path above builds $expectedMap without Get-IISServiceMap, and both
            # paths have to reach the same verdict or the two halves of this check disagree.
            $actualNames = @()
            foreach ($app in $model.Apps) {
                $label = "$($app.Site)$($app.AppPath)"

                # What IS this app? CX_IIS_SERVICES membership depends on the answer, and it
                # has to be computed with the SAME rule Instrument-IIS.ps1 used - otherwise
                # one side claims a name the other does not and the drift never clears.
                $rt = $null
                if ($rtCapable) {
                    try {
                        $anc       = @(Get-CxAncestorApps -Model $model -App $app)
                        $rt = Resolve-IISAppRuntime -PhysicalPath $app.PhysicalPath `
                            -PoolManagedRuntimeVersion $(if ($model.Pools[$app.Pool]) { $model.Pools[$app.Pool].ManagedRuntimeVersion } else { $null }) `
                            -PoolFound ([bool]$model.Pools[$app.Pool]) `
                            -AncestorPhysicalPaths @($anc | ForEach-Object { [string]$_.PhysicalPath }) `
                            -InheritedFromLabels @($anc | ForEach-Object { "$($_.Site)$($_.AppPath)" }) `
                            -Override (Get-IISRuntimeOverrideFor -Overrides $rtOverrides -Site $app.Site -AppPath $app.AppPath)
                    } catch { $rt = $null }
                }
                # Instrumentable = the installer would have written a name for it. Unknown
                # counts as NOT instrumentable, matching the installer's refusal to guess.
                $instrumentable = if ($rt) { @('AspNetCore','AspNetFramework') -contains $rt.DotNetRuntime } else { $true }
                $exp = @($expectedMap | Where-Object { $_.Site -eq $app.Site -and $_.AppPath -eq $app.AppPath }) |
                       Select-Object -First 1
                $expectedName = if ($exp) { [string]$exp.ServiceName } else { $null }

                # Pool scope: the value on the pool's own environmentVariables.
                $pool = $model.Pools[$app.Pool]
                $poolValue = $null
                if ($pool -and $pool.Env.ContainsKey('OTEL_SERVICE_NAME')) { $poolValue = [string]$pool.Env['OTEL_SERVICE_NAME'] }

                # web.config scope.
                $wcValue = Get-WebConfigServiceName -PhysicalPath $app.PhysicalPath

                $effective = if ($wcValue) { $wcValue } elseif ($poolValue) { $poolValue } else { $null }
                $scope     = if ($wcValue) { 'webconfig' } elseif ($poolValue) { 'pool' } else { 'none' }

                if (-not $effective -and -not $instrumentable) {
                    # Unnamed ON PURPOSE. Reporting this as IIS_SERVICE_NAME_MISSING (warn)
                    # would pin every host carrying the stock Default Web Site - i.e. nearly
                    # all of them - at exit 2 forever, for a static site that was never going
                    # to emit .NET telemetry.
                    if ($rt.DotNetRuntime -eq 'Unknown') {
                        Add-F (New-Finding -Check 'iisServiceName' -Severity 'unknown' -Code 'RUNTIME_UNKNOWN_NEEDS_OVERRIDE' -Target $label `
                            -Message "$($rt.RuntimeReason). Not named, and not claimed in CX_IIS_SERVICES, rather than guessed. Resolve it with -RuntimeOverrides @{'$(Get-IISAppKey -Site $app.Site -AppPath $app.AppPath)'='AspNetCore'|'AspNetFramework'|'NonDotNet'} on BOTH the install and this check." `
                            -Data @{ pool = $app.Pool; physicalPath = $app.PhysicalPath })
                    } else {
                        Add-F (New-Finding -Check 'iisServiceName' -Severity 'info' -Code 'NON_DOTNET_APP_NOT_INSTRUMENTED' -Target $label `
                            -Message "$($rt.RuntimeReason). The .NET OpenTelemetry automatic instrumentation does not apply, so no OTEL_SERVICE_NAME is expected and the app is deliberately absent from CX_IIS_SERVICES." `
                            -Data @{ pool = $app.Pool; physicalPath = $app.PhysicalPath; dotNetRuntime = $rt.DotNetRuntime })
                    }
                } elseif (-not $effective) {
                    Add-F (New-Finding -Check 'iisServiceName' -Severity 'warn' -Code 'IIS_SERVICE_NAME_MISSING' -Target $label `
                        -Message "no OTEL_SERVICE_NAME on pool '$($app.Pool)' or in web.config - this app's spans land under a default service name" `
                        -Data @{ pool = $app.Pool; expected = $expectedName; physicalPath = $app.PhysicalPath })
                } elseif (-not $instrumentable) {
                    # A name IS present on an app that is not instrumentable: a leftover from
                    # an installer that did not classify runtimes. Deliberately NOT counted
                    # toward the expected set, so CX_IIS_SERVICES_DRIFT fires - which is the
                    # correct verdict (the host claims a service nothing reports) and clears
                    # on a re-run, because the installer now removes such names.
                    # Not reported as a pass either: "OTEL_SERVICE_NAME=x" next to "this app
                    # emits nothing" is the contradiction this whole change exists to remove.
                    Add-F (New-Finding -Check 'iisServiceName' -Severity 'info' -Code 'NON_DOTNET_APP_NOT_INSTRUMENTED' -Target $label `
                        -Message "OTEL_SERVICE_NAME=$effective ($scope) is set, but this app is $($rt.DotNetRuntime) and emits no .NET telemetry - a leftover from an installer that did not classify runtimes. Excluded from the expected CX_IIS_SERVICES set; re-run Instrument-IIS.ps1 to remove it." `
                        -Data @{ value = $effective; scope = $scope; dotNetRuntime = $rt.DotNetRuntime })
                } else {
                    # THE membership filter, and it must stay the same rule the installer uses
                    # to build $namedApps, or the two sets can never agree.
                    $actualNames += $effective
                    if ($expectedName -and $effective -ne $expectedName) {
                        Add-F (New-Finding -Check 'iisServiceName' -Severity 'warn' -Code 'IIS_SERVICE_NAME_DRIFT' -Target $label `
                            -Message "OTEL_SERVICE_NAME is '$effective' ($scope) but the current IIS layout implies '$expectedName' - the site was renamed or moved after instrumentation" `
                            -Data @{ actual = $effective; expected = $expectedName; scope = $scope })
                    } else {
                        Add-F (New-Finding -Check 'iisServiceName' -Severity 'pass' -Target $label `
                            -Message "OTEL_SERVICE_NAME=$effective ($scope)" `
                            -Data @{ value = $effective; scope = $scope })
                    }
                }
            }

            if ($derived) {
                Add-F (New-Finding -Check 'iisServiceName' -Severity 'info' `
                    -Message 'expected names were derived from applicationHost.config (WebAdministration unavailable), so they follow the documented convention rather than Get-IISServiceMap')
            }

            # CX_IIS_SERVICES must equal the SET of per-app names. Compare as sets:
            # adding or removing a site reorders the comma-join and would otherwise
            # look like drift.
            #
            # CASING IS PART OF THE COMPARISON. Select-Object -Unique is case-SENSITIVE (it keeps both
            # 'MyApp' and 'myapp') while Compare-Object defaults to case-INSENSITIVE, so a casing-only
            # mismatch used to dedupe into two entries and then compare as equal - reported as a pass.
            # It is not one: the collector stamps this literal string for Infrastructure Service
            # ownership, and it has to match the APM service name character for character or the
            # correlation the label exists to provide silently does not resolve. Hence -CaseSensitive.
            $expSet = @($actualNames | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
            $varSet = @()
            if ($cxIisServices) {
                $varSet = @($cxIisServices -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
            }

            if ($varSet.Count -eq 0 -and $expSet.Count -gt 0) {
                Add-F (New-Finding -Check 'iisServiceName' -Severity 'warn' -Code 'CX_IIS_SERVICES_MISSING' -Target 'CX_IIS_SERVICES' `
                    -Message "not set at machine scope, but $($expSet.Count) instrumented app(s) exist - host Service ownership in Infrastructure Explorer will be BLANK. Re-run Instrument-IIS.ps1 (elevated) and restart the collector." `
                    -Data @{ appServiceNames = $expSet })
            } elseif ($varSet.Count -gt 0 -and $expSet.Count -gt 0 -and (Compare-Object $expSet $varSet -CaseSensitive)) {
                Add-F (New-Finding -Check 'iisServiceName' -Severity 'warn' -Code 'CX_IIS_SERVICES_DRIFT' -Target 'CX_IIS_SERVICES' `
                    -Message "does not match the apps on this host. var=[$($varSet -join ', ')] apps=[$($expSet -join ', ')] - re-run Instrument-IIS.ps1 and restart the collector. apps[] lists only INSTRUMENTABLE applications (ASP.NET Core or ASP.NET Framework); static, native, reverse-proxied and undeterminable apps are excluded by design, so a name here that is missing from apps[] is usually a leftover the re-run will remove." `
                    -Data @{ cxIisServices = $varSet; appServiceNames = $expSet })
            } elseif ($varSet.Count -gt 0) {
                Add-F (New-Finding -Check 'iisServiceName' -Severity 'pass' -Target 'CX_IIS_SERVICES' `
                    -Message "matches the apps on this host: $($varSet -join ', ')" -Data @{ value = $varSet })
            }
        }
    }
} else {
    Add-F (New-Finding -Check 'iisServiceName' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 3. Services + StartType
# ---------------------------------------------------------------------------
if (Use-Check 'services') {
    # In Supervisor mode there is NO otelcol-contrib service - the collector runs
    # as a CHILD PROCESS of opampsupervisor. Checking for it unconditionally
    # produces a false failure on every fleet host.
    $sup = Get-Service -Name 'opampsupervisor'  -ErrorAction SilentlyContinue
    $col = Get-Service -Name 'otelcol-contrib'  -ErrorAction SilentlyContinue

    if (-not $sup -and -not $col) {
        Add-F (New-Finding -Check 'services' -Severity 'fail' -Code 'COLLECTOR_SERVICE_MISSING' `
            -Message 'neither opampsupervisor nor otelcol-contrib is installed - no collector on this host')
    } else {
        foreach ($svc in @($sup, $col)) {
            if (-not $svc) { continue }
            if ($svc.Status -ne 'Running') {
                Add-F (New-Finding -Check 'services' -Severity 'fail' -Code 'COLLECTOR_SERVICE_STOPPED' -Target $svc.Name `
                    -Message "service is '$($svc.Status)', not Running - no telemetry is being collected" `
                    -Data @{ status = "$($svc.Status)" })
            } else {
                Add-F (New-Finding -Check 'services' -Severity 'pass' -Target $svc.Name -Message 'Running')
            }

            # StartType is set to Automatic at install and never re-verified;
            # a Manual service silently fails to come back after a reboot.
            $st = $null
            try { $st = (Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue).StartMode } catch { }
            if ($st -and $st -notmatch '^Auto') {
                Add-F (New-Finding -Check 'services' -Severity 'warn' -Code 'STARTTYPE_NOT_AUTOMATIC' -Target $svc.Name `
                    -Message "StartType is '$st', not Automatic - this service will not return after a reboot" `
                    -Data @{ startMode = $st })
            }
        }

        # In supervisor mode, confirm the collector CHILD PROCESS is actually up.
        if ($sup -and $sup.Status -eq 'Running' -and -not $col) {
            $childs = @(Get-Process -Name 'otelcol-contrib','otelcol' -ErrorAction SilentlyContinue)
            if ($childs.Count -eq 0) {
                Add-F (New-Finding -Check 'services' -Severity 'fail' -Code 'COLLECTOR_PROCESS_MISSING' `
                    -Message 'opampsupervisor is Running but no otelcol process exists - the collector is crash-looping or failed to start. Check the Application event log, source otelcol-contrib.')
            } else {
                Add-F (New-Finding -Check 'services' -Severity 'pass' -Target 'otelcol (child process)' `
                    -Message "$($childs.Count) process(es) running" -Data @{ pids = @($childs | ForEach-Object { $_.Id }) })
            }
        }
    }
} else {
    Add-F (New-Finding -Check 'services' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 4. Health endpoint
# ---------------------------------------------------------------------------
if (Use-Check 'health') {
    $ok = $false; $status = $null; $lastErr = $null
    for ($i = 0; $i -lt [Math]::Max(1, $HealthRetries); $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds $HealthDelaySec }
        try {
            $r = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec $TimeoutSec
            $status = $r.StatusCode
            if ($status -eq 200) { $ok = $true; break }
        } catch {
            $lastErr = $_.Exception.Message
            # A 503 arrives as an exception but is meaningful: the collector is up
            # and deliberately reporting unhealthy (commonly a crash-loop).
            try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        }
    }

    if ($ok) {
        Add-F (New-Finding -Check 'health' -Severity 'pass' -Target $HealthUrl -Message 'HTTP 200')
    } elseif ($status) {
        Add-F (New-Finding -Check 'health' -Severity 'fail' -Code 'HEALTH_UNHEALTHY' -Target $HealthUrl `
            -Message "health endpoint returned HTTP $status - the collector is running but reporting unhealthy" `
            -Data @{ status = $status })
    } else {
        Add-F (New-Finding -Check 'health' -Severity 'fail' -Code 'HEALTH_UNREACHABLE' -Target $HealthUrl `
            -Message "no response after $HealthRetries attempt(s): $lastErr" -Data @{ error = $lastErr })
    }
} else {
    Add-F (New-Finding -Check 'health' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 5. Export counters (8888)
# ---------------------------------------------------------------------------
if (Use-Check 'exportCounters') {
    $metrics = $null
    try { $metrics = (Invoke-WebRequest -Uri $MetricsUrl -UseBasicParsing -TimeoutSec $TimeoutSec).Content } catch { }

    if (-not $metrics) {
        Add-F (New-Finding -Check 'exportCounters' -Severity 'warn' -Code 'METRICS_UNREACHABLE' -Target $MetricsUrl `
            -Message 'collector internal metrics endpoint did not respond - cannot tell whether anything is being exported')
    } else {
        # Split on \r?\n, NOT "`n": a CRLF payload leaves a trailing \r on every
        # line, which breaks a ' 0$' style match and would silently reclassify
        # healthy zero counters as failures. Compare numerically instead.
        $lines = $metrics -split "`r?`n"

        $sent = [ordered]@{}
        foreach ($sig in 'spans','metric_points','log_records') {
            $total = 0.0; $found = $false
            foreach ($l in $lines) {
                if ($l -match ('^otelcol_exporter_sent_' + $sig + '(?:_total)?\{')) {
                    $parts = $l -split '\s+'
                    $v = 0.0
                    if ([double]::TryParse($parts[-1], [ref]$v)) { $total += $v; $found = $true }
                }
            }
            $sent[$sig] = if ($found) { $total } else { $null }
        }

        $any = @($sent.Values | Where-Object { $_ -ne $null -and $_ -gt 0 }).Count -gt 0
        $desc = (@($sent.Keys | ForEach-Object { "$_=$(if ($null -eq $sent[$_]) { 'n/a' } else { $sent[$_] })" }) -join ' ')

        if ($any) {
            Add-F (New-Finding -Check 'exportCounters' -Severity 'pass' -Message "exporting: $desc" -Data $sent)
        } else {
            Add-F (New-Finding -Check 'exportCounters' -Severity 'warn' -Code 'EXPORT_COUNTERS_ZERO' `
                -Message "nothing has been exported to Coralogix yet ($desc). Normal for a collector restarted moments ago; otherwise the exporter is not reaching the endpoint." `
                -Data $sent)
        }

        # Non-zero failure counters only - matching the bare metric name would
        # print every healthy zero.
        $failed = @()
        foreach ($l in $lines) {
            if ($l -match '^otelcol_exporter_(send_failed|enqueue_failed)_') {
                $parts = $l -split '\s+'
                $v = 0.0
                if ([double]::TryParse($parts[-1], [ref]$v) -and $v -gt 0) { $failed += $l.Trim() }
            }
        }
        if ($failed.Count -gt 0) {
            Add-F (New-Finding -Check 'exportCounters' -Severity 'warn' -Code 'EXPORT_SEND_FAILED' `
                -Message "$($failed.Count) non-zero export failure counter(s) - telemetry is being produced but rejected or dropped" `
                -Data @{ counters = $failed })
        }
    }
} else {
    Add-F (New-Finding -Check 'exportCounters' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 6. OTLP receiver ports
# ---------------------------------------------------------------------------
if (Use-Check 'ports') {
    if (-not (Get-Command Test-PortListening -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'ports' -Severity 'unknown' -Code 'HELPER_MISSING' `
            -Message 'Detect-Workloads.ps1 is not present, so the port probe is unavailable')
    } else {
        # 4318 (HTTP) is what the IIS and Node instrumentation actually use.
        if (Test-PortListening @($OtlpHttpPort)) {
            Add-F (New-Finding -Check 'ports' -Severity 'pass' -Target "$OtlpHttpPort/http" -Message 'listening')
        } else {
            Add-F (New-Finding -Check 'ports' -Severity 'warn' -Code 'PORT_4318_NOT_LISTENING' -Target "$OtlpHttpPort/http" `
                -Message "nothing is listening on $OtlpHttpPort - instrumented apps have nowhere to send OTLP")
        }
        # 4317 (gRPC) is informational: the shipped config enables it, but nothing
        # in this repo's instrumentation path uses it.
        if (Test-PortListening @($OtlpGrpcPort)) {
            Add-F (New-Finding -Check 'ports' -Severity 'pass' -Target "$OtlpGrpcPort/grpc" -Message 'listening')
        } else {
            Add-F (New-Finding -Check 'ports' -Severity 'info' -Target "$OtlpGrpcPort/grpc" `
                -Message 'not listening (only matters if something here exports over gRPC)')
        }
    }
} else {
    Add-F (New-Finding -Check 'ports' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 7. Effective config: are the label-stamping processors actually in play?
#    7a. transform/iis_service_labels (IIS hosts only)
#    7b. transform/environment        (every host)
# ---------------------------------------------------------------------------
if (Use-Check 'effectiveConfig') {
    # This is the check that explains "CX_IIS_SERVICES is set but Service
    # ownership is still blank": a remote Fleet config that redefines the logs
    # pipelines REPLACES the base's processor list, so the processor has to be
    # present in the REMOTE config, not just the local base.
    # Search order is most-authoritative first:
    #   1. the supervisor's MERGED effective config (base + Fleet remote)
    #   2. the supervisor's base collector config
    #   3. the plain collector service's own config
    # (3) is what exists when the collector was installed WITHOUT the supervisor
    # (deploy.bat CX_NO_SUPERVISOR=1 -> the vendor installer's -Config mode, which
    # copies the config into %ProgramData%\OpenTelemetry\Collector). Nothing here
    # keys off an install flag - the doctor reports whatever is on the host.
    $cfgPath = $null
    $searched = @($EffectiveConfig, $BaseCollectorConfig, $LocalCollectorConfig) | Where-Object { $_ }
    foreach ($p in $searched) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { $cfgPath = $p; break }
    }

    if (-not $cfgPath) {
        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'unknown' -Code 'EFFECTIVE_CONFIG_NOT_FOUND' `
            -Message "no collector config found (looked at: $($searched -join '; '))")
    } else {
        $text = $null
        try { $text = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop } catch { }

        if (-not $text) {
            Add-F (New-Finding -Check 'effectiveConfig' -Severity 'unknown' -Code 'EFFECTIVE_CONFIG_UNREADABLE' -Target $cfgPath `
                -Message 'config file could not be read')
        } else {
            # No YAML parser is available in PS 5.1, so this is a text match.
            # Comment lines are stripped first so a mention inside a comment is
            # not counted as a live definition. Known limits, stated plainly:
            # it cannot prove the processor is semantically wired, only that the
            # name appears both as a definition and inside each pipeline block.
            $live = ($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            # Pipeline blocks have to be looked up INSIDE service.pipelines. Searching
            # the whole file for a four-space 'logs:' key matches an exporter's own logs
            # section hundreds of lines earlier instead - the processor is legitimately
            # absent there, so the wiring check could report NOT_WIRED against a config
            # that was in fact wired correctly. Fall back to the whole text if the
            # pipelines block cannot be located, so a shape change degrades to the old
            # behaviour rather than silently checking nothing.
            $pipesText = [regex]::Match($live, '(?ms)^  pipelines:\s*$.*?(?=^  \S|\z)').Value
            if (-not $pipesText) { $pipesText = $live }

            # -- 7a. IIS service labels -------------------------------------------
            # Only meaningful where IIS is in play. On a non-IIS host, say so and check
            # nothing here - but do NOT skip the whole section, because 7b below applies
            # to every host. Emptying the list is what keeps the loop body untouched.
            $iisProcs = if ($iisPresent -or $cxIisServices) { @($RequiredProcessors) } else { @() }
            if (-not $iisProcs) {
                Add-F (New-Finding -Check 'effectiveConfig' -Severity 'skip' -Code 'IIS_ABSENT' `
                    -Message 'no IIS on this host, so the IIS service-label processor is not expected')
            }

            foreach ($proc in $iisProcs) {
                if ($live -notmatch [regex]::Escape($proc)) {
                    Add-F (New-Finding -Check 'effectiveConfig' -Severity 'warn' -Code 'EFFECTIVE_PROCESSOR_MISSING' -Target $proc `
                        -Message "not present in $cfgPath - CX_IIS_SERVICES is never stamped onto telemetry, so Service ownership stays blank however correct the env var is. Add the processor to the REMOTE Fleet Management config." `
                        -Data @{ config = $cfgPath })
                    continue
                }

                # Present. Now: is it wired into each required pipeline?
                foreach ($pipe in @($RequiredPipelines)) {
                    $block = [regex]::Match($pipesText, "(?ms)^\s{4}$([regex]::Escape($pipe)):\s*$.*?(?=^\s{4}\S|\z)")
                    if (-not $block.Success) {
                        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'unknown' -Code 'EFFECTIVE_PIPELINE_NOT_FOUND' -Target "$pipe" `
                            -Message "could not locate the '$pipe' pipeline block in $cfgPath to confirm the processor is wired into it")
                    } elseif ($block.Value -match [regex]::Escape($proc)) {
                        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'pass' -Target "$pipe" `
                            -Message "$proc is wired into the $pipe pipeline")
                    } else {
                        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'warn' -Code 'EFFECTIVE_PROCESSOR_NOT_WIRED' -Target "$pipe" `
                            -Message "$proc is defined but NOT listed in the '$pipe' pipeline's processors - it therefore never runs for that signal" `
                            -Data @{ config = $cfgPath })
                    }
                }
            }

            # -- 7b. Environment stamp --------------------------------------------
            # Every host, IIS or not. This is the check the env-var section cannot make:
            # CX_ENVIRONMENT reads 'pass' there purely because the variable exists, while
            # a remote Fleet config that redefines these pipelines drops the processor
            # and the label never reaches a single signal.
            if ($live -notmatch [regex]::Escape($EnvironmentProcessor)) {
                Add-F (New-Finding -Check 'effectiveConfig' -Severity 'warn' -Code 'ENV_PROCESSOR_MISSING' -Target $EnvironmentProcessor `
                    -Message "not present in $cfgPath - CX_ENVIRONMENT is never stamped onto telemetry, so this host's signals arrive with no environment label however correct the env var is. Add the processor to the REMOTE Fleet Management config." `
                    -Data @{ config = $cfgPath })
            } else {
                foreach ($pipe in @($EnvironmentPipelines)) {
                    $block = [regex]::Match($pipesText, "(?ms)^\s{4}$([regex]::Escape($pipe)):\s*$.*?(?=^\s{4}\S|\z)")
                    if (-not $block.Success) {
                        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'unknown' -Code 'ENV_PIPELINE_NOT_FOUND' -Target "$pipe" `
                            -Message "could not locate the '$pipe' pipeline block in $cfgPath to confirm $EnvironmentProcessor is wired into it")
                    } elseif ($block.Value -match [regex]::Escape($EnvironmentProcessor)) {
                        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'pass' -Target "$pipe" `
                            -Message "$EnvironmentProcessor is wired into the $pipe pipeline")
                    } else {
                        Add-F (New-Finding -Check 'effectiveConfig' -Severity 'warn' -Code 'ENV_PROCESSOR_NOT_WIRED' -Target "$pipe" `
                            -Message "$EnvironmentProcessor is defined but NOT listed in the '$pipe' pipeline's processors - $pipe therefore carries no environment label" `
                            -Data @{ config = $cfgPath })
                    }
                }
            }

            Add-F (New-Finding -Check 'effectiveConfig' -Severity 'info' -Target $cfgPath `
                -Message 'checked by text match (no YAML parser in PS 5.1); comment lines were excluded')
        }
    }
} else {
    Add-F (New-Finding -Check 'effectiveConfig' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# 8 / 9. Delegated instrumentation validators
# ---------------------------------------------------------------------------
if (Use-Check 'iisInstrumentation') {
    if (-not $hasIisInstr -or -not (Get-Command Test-IISInstrumentation -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'iisInstrumentation' -Severity 'unknown' -Code 'HELPER_MISSING' `
            -Message 'Test-IISInstrumentation.ps1 is not present next to this script')
    } else {
        # Forward the runtime overrides. Without this the aggregator silently ignores them and
        # reports RUNTIME_UNKNOWN_NEEDS_OVERRIDE for an app the operator has already decided -
        # i.e. `doctor.bat -Only iisInstrumentation` would contradict both the install and the
        # standalone validator, which is exactly the drift group C of the doctor test exists
        # to catch.
        $iisArgs = @{ ExpectedOtlpEndpoint = $ExpectedOtlpEndpoint }
        if ($RuntimeOverrides -and $RuntimeOverrides.Count -gt 0) { $iisArgs['RuntimeOverrides'] = $RuntimeOverrides }
        if ($RuntimeOverridesJson) { $iisArgs['RuntimeOverridesJson'] = $RuntimeOverridesJson }
        try { Add-Many (Test-IISInstrumentation @iisArgs) }
        catch {
            Add-F (New-Finding -Check 'iisInstrumentation' -Severity 'unknown' -Code 'CHECK_ERRORED' `
                -Message "Test-IISInstrumentation failed: $($_.Exception.Message)")
        }
    }
} else {
    Add-F (New-Finding -Check 'iisInstrumentation' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

if (Use-Check 'nodeInstrumentation') {
    if (-not $hasNodeInstr -or -not (Get-Command Test-NodeInstrumentation -ErrorAction SilentlyContinue)) {
        Add-F (New-Finding -Check 'nodeInstrumentation' -Severity 'unknown' -Code 'HELPER_MISSING' `
            -Message 'Test-NodeInstrumentation.ps1 is not present next to this script')
    } else {
        try {
            Add-Many (Test-NodeInstrumentation -InstallPrefix $NodeInstallPrefix `
                                               -ExpectedOtlpEndpoint $ExpectedOtlpEndpoint `
                                               -EffectiveConfig $EffectiveConfig)
        } catch {
            Add-F (New-Finding -Check 'nodeInstrumentation' -Severity 'unknown' -Code 'CHECK_ERRORED' `
                -Message "Test-NodeInstrumentation failed: $($_.Exception.Message)")
        }
    }
} else {
    Add-F (New-Finding -Check 'nodeInstrumentation' -Severity 'skip' -Code 'NOT_SELECTED' -Message 'not selected by -Only')
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$all      = @($findings.ToArray())
$exitCode = Get-GradedExitCode -Findings $all
$counts   = Get-FindingCounts  -Findings $all

Write-FindingTable   -Findings $all -Title "diagnostics" -Quiet:$Quiet
Write-FindingSummary -Findings $all -Label 'DOCTOR' -ExitCode $exitCode

$report = [ordered]@{
    host      = $env:COMPUTERNAME
    timestamp = (Get-Date).ToString('o')
    checks    = $selected
    counts    = $counts
    exitCode  = $exitCode
    findings  = $all
}

if (-not $NoFileOutput) {
    if (-not $JsonPath) { $JsonPath = Join-Path $here 'agent-doctor.json' }
    try {
        $report | ConvertTo-Json -Depth 8 | Out-File -FilePath $JsonPath -Encoding utf8
        Write-Host "report: $JsonPath"
    } catch {
        Write-Host "could not write $JsonPath : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($PassThru) { $report }
exit $exitCode
