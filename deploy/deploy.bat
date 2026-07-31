@echo off
REM ===========================================================================
REM  BatchPatch remote-command entry point.
REM
REM  BatchPatch copies this whole folder to the target server (e.g. via
REM  "Deploy software/patches/scripts") and then runs this .bat as the remote
REM  command. It launches the orchestrator under Windows PowerShell 5.1 (the
REM  version the .NET auto-instrumentation module requires) with the execution
REM  policy bypassed for this process only, and propagates the exit code so
REM  BatchPatch marks the row failed on any error.
REM
REM  Run by hand instead of through BatchPatch? Every Install-Agent.ps1 flag can be
REM  passed straight through:
REM      deploy.bat -Domain eu2.coralogix.com -KeyFile C:\secrets\SendDataKey.txt
REM      deploy.bat -Region eu2 -Environment staging
REM  Arguments and the environment variables below are EXCLUSIVE: typing any argument
REM  skips the env-var block entirely (see the note above the block for why).
REM
REM  Optional: set the key and/or the deployment environment out-of-band before
REM  running instead of shipping SendDataKey.txt, e.g. in the BatchPatch remote
REM  command:
REM      set CX_ENVIRONMENT=staging && set CORALOGIX_PRIVATE_KEY=cxtp_xxx && deploy.bat
REM  CX_ENVIRONMENT labels this host's telemetry (production/staging/dev/...) so
REM  Coralogix can split it by environment in Infra Explorer.
REM
REM      set CX_REGION=eu2 && deploy.bat          ship to the eu2 account
REM  Coralogix region code (eu1/eu2/us1/us2/us3/ap1/ap2/ap3). It becomes the collector's
REM  ingress domain <region>.coralogix.com AND the OpAMP endpoint, so it must match the
REM  account the Send-Your-Data key belongs to - a key from another region authenticates
REM  nowhere and the host reports healthy while sending nothing. An unknown code fails
REM  the install. For a private or non-standard ingress domain use CX_DOMAIN instead:
REM      set CX_DOMAIN=my-ingress.example.com && deploy.bat
REM  CX_DOMAIN is the full ingress domain, taken verbatim (a scheme and trailing slash are
REM  stripped), and it is NOT checked against the published region list - so it also wins
REM  over CX_REGION when both are set. With neither set the region is taken from region.txt
REM  in this folder (baked in by Build-DeploymentPackage.ps1 -Region), then from whatever a
REM  previous install persisted, and finally eu1.
REM
REM      set CX_NO_SUPERVISOR=1 && deploy.bat     collector without the OpAMP Supervisor
REM      set CX_SKIP_INSTRUMENT=1 && deploy.bat   collector only, leave IIS/Node alone
REM
REM      set CX_RUNTIME_OVERRIDES_JSON=C:\path\runtimes.json && deploy.bat
REM  Force the runtime of IIS apps the installer cannot classify, e.g.
REM      { "Wallet/api": "AspNetCore", "Legacy/": "AspNetFramework", "Static/": "NonDotNet" }
REM  Keyed by "<Site><virtual path>" with root apps ending in '/' - the same string the
REM  doctor prints in its Target column. Not added to ARGS below on purpose: the scripts
REM  read this variable directly (like CX_OTEL_DOTNET_ARCHIVE), so the SAME file is picked
REM  up by the install AND by doctor.bat. If only one of them saw it they would disagree
REM  about which apps belong in CX_IIS_SERVICES and report drift forever.
REM ===========================================================================
REM Plain setlocal, NOT enabledelayedexpansion. Nothing in this file uses !VAR! syntax,
REM and leaving delayed expansion on silently ate any '!' out of every value forwarded
REM below: CX_ENVIRONMENT=prod!x reached Install-Agent.ps1 as "prodx". The loss happened
REM on the launch line, where %ARGS% is substituted, so quoting the values could not
REM prevent it. Measured across '!', '&', '^' and embedded spaces - all survive now. A
REM value containing a literal double quote still cannot survive this quoting scheme.
setlocal
cd /d "%~dp0"

REM Always launch the 64-bit PowerShell on 64-bit Windows.
REM
REM PROCESSOR_ARCHITEW6432 is defined only inside a 32-bit process running on
REM 64-bit Windows - which is what you get when a 32-bit BatchPatch/RMM agent,
REM a 32-bit scheduled task, or a 32-bit cmd launches this .bat. In that process
REM %SystemRoot%\System32 is redirected to SysWOW64, so the line below would
REM start the 32-bit PowerShell and the whole install would inherit WOW64:
REM   * appcmd still works (SysWOW64\inetsrv\appcmd.exe exists and the IIS config
REM     COM API is bitness-agnostic), so pool env vars ARE written - but
REM   * SysWOW64\inetsrv has no applicationHost.config (its config\ folder holds
REM     only Schema\ and Export\), so the config cannot be backed up or read
REM     back, and
REM   * %ProgramFiles% resolves to "Program Files (x86)", so the .NET
REM     auto-instrumentation would install to the wrong tree.
REM Sysnative is the un-redirected view of the real System32; it exists only
REM from WOW64, hence the "if exist" guard.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

REM Build optional args from env vars (each independent; any combination).
REM
REM   CX_NO_SUPERVISOR=1  install the collector WITHOUT the OpAMP Supervisor. This
REM                       changes ONLY the arguments handed to the Coralogix vendor
REM                       installer (-Config instead of -Supervisor
REM                       -SupervisorCollectorBaseConfig). Instrumentation and the
REM                       diagnostics are identical in both modes.
REM   CX_SKIP_INSTRUMENT=1  install the collector but do NOT touch IIS / Node.
REM   CX_REGION           which Coralogix account region receives the data.
REM   CX_DOMAIN           full ingress domain for a private / non-standard endpoint;
REM                       forwarded as -Domain, which outranks -Region.
REM
REM CORALOGIX_DOMAIN is deliberately NOT forwarded as -Domain. A previous install
REM persisted it at machine scope, so this cmd.exe inherits it and cannot tell a value
REM someone just exported from that leftover - passing it as an explicit flag would make
REM the leftover outrank a baked-in region.txt forever. Install-CoralogixSupervisor.ps1
REM reads the variable directly instead and compares it with the machine value to tell
REM the two apart (same "read it, do not flag it" pattern as CX_RUNTIME_OVERRIDES_JSON).
REM CX_DOMAIN is the flagged form that exists precisely because CORALOGIX_DOMAIN cannot be
REM one: nothing we install ever persists CX_DOMAIN machine-wide, so its presence is
REM unambiguously a decision made for THIS run and needs no leftover comparison.
REM
REM Two ways in, and they are mutually exclusive by design (same shape as doctor.bat):
REM
REM   deploy.bat -Domain eu2.coralogix.com -KeyFile C:\k.txt
REM                                     command-line args win; env vars ignored
REM   set CX_DOMAIN=eu2.coralogix.com && deploy.bat
REM                                     for BatchPatch, which generally cannot pass
REM                                     arguments to a remote command
REM
REM They must NOT be combined into one invocation. Passing -Domain twice is not "last
REM one wins" - PowerShell fails parameter binding outright ("parameter 'Domain' is
REM specified more than once"), the script never runs, and BatchPatch shows a red row
REM with no diagnostics at all. So if any argument was typed, the env-var block is
REM skipped entirely. Note the arguments go to Install-Agent.ps1, which accepts -Region
REM and -Domain but ALSO -KeyFile / -Application / -InstrumentVersion that no env var
REM below exposes; run `powershell -File Install-Agent.ps1 -?` for the full set.
REM
REM Skipping that block used to be silent, which made it a trap rather than a rule:
REM `set CX_ENVIRONMENT=prod && deploy.bat -Region eu2` deployed with no environment
REM label at all, and every signal from the host came out labelled 'unspecified' with
REM nothing in the output to say why. Each variable that is being ignored is now named
REM on stderr, so the operator can re-run with it as an argument.
set ARGS=
if not "%~1"=="" goto :argsgiven

if defined CORALOGIX_PRIVATE_KEY set ARGS=%ARGS% -PrivateKey "%CORALOGIX_PRIVATE_KEY%"
if defined CX_REGION set ARGS=%ARGS% -Region "%CX_REGION%"
if defined CX_DOMAIN set ARGS=%ARGS% -Domain "%CX_DOMAIN%"
if defined CX_ENVIRONMENT set ARGS=%ARGS% -Environment "%CX_ENVIRONMENT%"
if defined CX_NO_SUPERVISOR set ARGS=%ARGS% -NoSupervisor
if defined CX_SKIP_INSTRUMENT set ARGS=%ARGS% -SkipInstrument
goto :runargs

:argsgiven
REM Arguments win, so the block above was skipped. Name every variable it would have
REM consumed. Warn only - never fail - because a host that meant to pass arguments and
REM happens to have a stale variable set still deserves its deploy.
set "IGNORED="
if defined CORALOGIX_PRIVATE_KEY set "IGNORED=%IGNORED% CORALOGIX_PRIVATE_KEY"
if defined CX_REGION set "IGNORED=%IGNORED% CX_REGION"
if defined CX_DOMAIN set "IGNORED=%IGNORED% CX_DOMAIN"
if defined CX_ENVIRONMENT set "IGNORED=%IGNORED% CX_ENVIRONMENT"
if defined CX_NO_SUPERVISOR set "IGNORED=%IGNORED% CX_NO_SUPERVISOR"
if defined CX_SKIP_INSTRUMENT set "IGNORED=%IGNORED% CX_SKIP_INSTRUMENT"
if defined IGNORED echo WARNING: command-line arguments were given, so these environment variables are IGNORED:%IGNORED% 1>&2
if defined IGNORED echo WARNING: pass them as arguments instead - see the usage header of this file. 1>&2

:runargs
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Agent.ps1"%ARGS% %*

set "RC=%ERRORLEVEL%"
echo deploy.bat exit code: %RC%
exit /b %RC%
