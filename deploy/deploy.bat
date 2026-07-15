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
REM  Optional: set the key out-of-band before running instead of shipping
REM  SendDataKey.txt, e.g. in the BatchPatch remote command:
REM      set CORALOGIX_PRIVATE_KEY=cxtp_xxx && deploy.bat
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if defined CORALOGIX_PRIVATE_KEY (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Agent.ps1" -PrivateKey "%CORALOGIX_PRIVATE_KEY%"
) else (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Agent.ps1"
)

set "RC=%ERRORLEVEL%"
echo deploy.bat exit code: %RC%
exit /b %RC%
