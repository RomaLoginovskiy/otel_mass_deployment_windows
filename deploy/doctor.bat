@echo off
REM ===========================================================================
REM  BatchPatch remote-command entry point for the host DIAGNOSTIC (read-only).
REM
REM  Runs Test-Agent.ps1 under Windows PowerShell 5.1 and propagates its GRADED
REM  exit code, so the BatchPatch "Exit Code" column separates the three states:
REM      0 = pass       every check passed (or was N/A for this host)
REM      1 = hard fail  not elevated, no private key, or the collector is down
REM      2 = degraded   the collector is up but something is misconfigured
REM
REM  NOTE: BatchPatch marks ANY non-zero exit as a failed (red) row, so 1 and 2
REM  both show red. Read the Exit Code column - or the line this script echoes -
REM  to tell them apart. Triage 2s in bulk; triage 1s individually.
REM
REM  This changes nothing on the host. It sets no env var, runs no appcmd, runs
REM  no iisreset, and starts/stops no service. Safe to run at any time, and safe
REM  to re-run.
REM
REM  Optional, set out-of-band in the BatchPatch remote command:
REM      set CX_DOCTOR_ONLY=env,iisServiceName && doctor.bat
REM          run only those checks (comma-separated, no spaces)
REM      set CX_DOCTOR_QUIET=1 && doctor.bat
REM          print only the checks that are not passing
REM      set CX_DOCTOR_NOFILE=1 && doctor.bat
REM          print only; do not write agent-doctor.json next to the scripts
REM
REM  The two instrumentation validators can also be run directly, on their own:
REM      powershell -NoProfile -ExecutionPolicy Bypass -File Test-IISInstrumentation.ps1
REM      powershell -NoProfile -ExecutionPolicy Bypass -File Test-NodeInstrumentation.ps1
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM Build optional args from env vars (each independent; any combination).
set ARGS=
if defined CX_DOCTOR_ONLY set ARGS=%ARGS% -Only %CX_DOCTOR_ONLY%
if defined CX_DOCTOR_QUIET set ARGS=%ARGS% -Quiet
if defined CX_DOCTOR_NOFILE set ARGS=%ARGS% -NoFileOutput

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Agent.ps1"%ARGS%

set "RC=%ERRORLEVEL%"
echo doctor.bat exit code: %RC%
exit /b %RC%
