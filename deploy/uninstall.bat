@echo off
REM ===========================================================================
REM  BatchPatch remote-command entry point for UNINSTALL.
REM
REM  Counterpart to deploy.bat. BatchPatch copies this folder to the target and
REM  runs this .bat as the remote command; it launches Uninstall-Agent.ps1 under
REM  Windows PowerShell 5.1 (the version the .NET auto-instrumentation module
REM  requires) with the execution policy bypassed for this process only, and
REM  propagates the exit code so BatchPatch marks the row failed on any error.
REM
REM  Optional env vars (set out-of-band before running):
REM      set CX_PURGE=1   -> also delete staged config + vendor binaries (-Purge)
REM      set CX_RESTORE=1 -> restore configs from backup instead of surgical edit
REM  e.g. in the BatchPatch remote command:
REM      set CX_PURGE=1 && uninstall.bat
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM Build optional switches from env vars (each independent).
set ARGS=
if defined CX_PURGE   set ARGS=%ARGS% -Purge
if defined CX_RESTORE set ARGS=%ARGS% -RestoreConfigs

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Agent.ps1"%ARGS%

set "RC=%ERRORLEVEL%"
echo uninstall.bat exit code: %RC%
exit /b %RC%
