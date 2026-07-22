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
REM  Optional: set the key and/or the deployment environment out-of-band before
REM  running instead of shipping SendDataKey.txt, e.g. in the BatchPatch remote
REM  command:
REM      set CX_ENVIRONMENT=staging && set CORALOGIX_PRIVATE_KEY=cxtp_xxx && deploy.bat
REM  CX_ENVIRONMENT labels this host's telemetry (production/staging/dev/...) so
REM  Coralogix can split it by environment in Infra Explorer.
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM Build optional args from env vars (each independent; either/both/neither).
set ARGS=
if defined CORALOGIX_PRIVATE_KEY set ARGS=%ARGS% -PrivateKey "%CORALOGIX_PRIVATE_KEY%"
if defined CX_ENVIRONMENT set ARGS=%ARGS% -Environment "%CX_ENVIRONMENT%"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Agent.ps1"%ARGS%

set "RC=%ERRORLEVEL%"
echo deploy.bat exit code: %RC%
exit /b %RC%
