@echo off
rem  balena-plus uninstaller, for people who would rather double-click.
rem
rem  A launcher, like install.cmd. The removal logic lives in
rem  windows\install.ps1 -Uninstall -- one place, so install and uninstall
rem  can never disagree about where things were put.
rem
rem  install.cmd -Uninstall does exactly the same thing. This exists so the
rem  option is visible to someone looking at a folder rather than a flag.
rem
rem  Branches are goto labels rather than if/else blocks because the remote
rem  command below contains parentheses, which cmd mis-parses inside a
rem  parenthesised block even when they are quoted.

setlocal

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

set "LOCAL=%~dp0windows\install.ps1"
if exist "%LOCAL%" goto run_local
goto run_remote

:run_local
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%LOCAL%" -Uninstall %*
goto finished

:run_remote
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1').Content)) -Uninstall" %*
goto finished

:finished
set "RC=%ERRORLEVEL%"

rem  Pause on a double-click, so the window does not close over the output.
if not "%~1"=="" goto quit
echo.
if not "%RC%"=="0" echo The uninstaller exited with code %RC%.
echo Press any key to close this window.
pause >nul

:quit
exit /b %RC%
