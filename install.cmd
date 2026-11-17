@echo off
rem  balena-plus installer, for people who would rather double-click.
rem
rem  This is a launcher, not the installer. The real one is
rem  windows\install.ps1 -- readable PowerShell that explains each step and
rem  asks before taking it. All this does is start Windows PowerShell with
rem  the flags a double-click cannot supply, chiefly -ExecutionPolicy
rem  Bypass, since the default policy refuses to run a .ps1 from disk.
rem
rem  Switches are forwarded, so from a console you can still say:
rem      install.cmd -Yes
rem      install.cmd -Uninstall
rem
rem  Branches are goto labels rather than if/else blocks on purpose: the
rem  remote command below contains parentheses, and cmd mis-parses those
rem  inside a parenthesised block even when they are quoted.

setlocal

rem  The full path, so a broken PATH cannot send this somewhere strange.
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

set "LOCAL=%~dp0windows\install.ps1"
if exist "%LOCAL%" goto run_local
goto run_remote

:run_local
rem  The normal case: run from a checkout. install.ps1 prefers the files
rem  next to it, so this installs THIS copy, not whatever is on main.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%LOCAL%" %*
goto finished

:run_remote
rem  This file on its own, away from a checkout. Fetch the installer.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1').Content))" %*
goto finished

:finished
set "RC=%ERRORLEVEL%"

rem  A double-click opens a console that closes the instant this returns,
rem  taking every error message with it. Pausing only when no switches were
rem  passed keeps that safe without making scripted use wait on a keypress.
if not "%~1"=="" goto quit
echo.
if not "%RC%"=="0" echo The installer exited with code %RC%.
echo Press any key to close this window.
pause >nul

:quit
exit /b %RC%
