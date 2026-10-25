@echo off
setlocal EnableExtensions
cd /d "%~dp0" || (echo ERROR: cannot open Gangplank folder & pause & exit /b 1)

REM Use the same process-scoped PowerShell launcher options as Lazarette/Halyard.
REM -ExecutionPolicy Bypass applies only to this new process; it does not
REM change machine policy, override Group Policy, or grant elevation.
REM -STA maintains compatibility with any interactive Lazarette credential dialogs.
set "PS_ARGS=-STA -NoProfile -NoLogo -ExecutionPolicy Bypass"

REM Lazarette is optional and opt-in: Gangplank only uses it when Integrations has an
REM Lazarette folder configured (or GANGPLANK_LAZARETTE_PATH is set). Nothing is auto-detected.

echo.
echo ==============================================
echo    GANGPLANK   -   Development Workspace
echo ==============================================
echo.
echo Starting local browser workspace.
echo Gangplank stops by itself shortly after its browser tab closes.
echo Options: --stay (keep running after the tab closes), --replace
echo (stop a running Gangplank without asking), -NoBrowser [port].
echo To use the classic text menu, run:
echo    Launch-Gangplank.bat -Cli
echo.
where powershell.exe >nul 2>&1 || (echo ERROR: Windows PowerShell 5.1 not found & pause & exit /b 1)

if /I "%~1"=="-Cli" goto CLI
if /I "%~1"=="--cli" goto CLI
goto BROWSER

:CLI
powershell.exe %PS_ARGS% -File "%~dp0Gangplank.ps1"
goto FINISH

:BROWSER
REM All options pass through to Start-Gangplank.ps1, for example:
REM   -NoBrowser 19000   diagnostic/CI mode on an explicit localhost port
REM   --stay             keep running after the browser tab closes
REM   --replace          stop a running Gangplank and start fresh without asking
powershell.exe %PS_ARGS% -File "%~dp0Start-Gangplank.ps1" %*

:FINISH
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo.
  echo Gangplank exited with code %ERR%.
  echo If a script is blocked by organization policy, contact IT.
  echo If you see "Access is denied" while starting localhost, check
  echo HttpListener URL reservations and port usage with your administrator.
  pause
)
exit /b %ERR%
