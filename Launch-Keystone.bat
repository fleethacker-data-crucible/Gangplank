@echo off
setlocal EnableExtensions
cd /d "%~dp0" || (echo ERROR: cannot open Keystone folder & pause & exit /b 1)

REM Use the same process-scoped PowerShell launcher options as ARC/Cascade.
REM -ExecutionPolicy Bypass applies only to this new process; it does not
REM change machine policy, override Group Policy, or grant elevation.
REM -STA maintains compatibility with any interactive ARC credential dialogs.
set "PS_ARGS=-STA -NoProfile -NoLogo -ExecutionPolicy Bypass"

REM ARC 5 is found by lib\Arc.ps1; older ARC 3/4 installs by pm.ps1.
if not defined ARC_PATH (
  if exist "%~dp0..\arc\pm.ps1" set "ARC_PATH=%~dp0..\arc"
  if exist "%~dp0..\..\arc\pm.ps1" set "ARC_PATH=%~dp0..\..\arc"
  if exist "%~dp0..\arc\lib\Arc.ps1" set "ARC_PATH=%~dp0..\arc"
  if exist "%~dp0..\..\arc\lib\Arc.ps1" set "ARC_PATH=%~dp0..\..\arc"
)

echo.
echo ==============================================
echo    KEYSTONE   -   Development Workspace
echo ==============================================
echo.
echo Starting local browser workspace.
echo To use the classic text menu, run:
echo    Launch-Keystone.bat -Cli
echo.
where powershell.exe >nul 2>&1 || (echo ERROR: Windows PowerShell 5.1 not found & pause & exit /b 1)

if /I "%~1"=="-Cli" goto CLI
if /I "%~1"=="-NoBrowser" goto HEADLESS
goto BROWSER

:CLI
powershell.exe %PS_ARGS% -File "%~dp0Keystone.ps1"
goto FINISH

:HEADLESS
REM Diagnostic/CI mode: no browser window, optional explicit localhost port.
if "%~2"=="" (
  powershell.exe %PS_ARGS% -File "%~dp0Start-KeystoneWeb.ps1" -NoBrowser
) else (
  powershell.exe %PS_ARGS% -File "%~dp0Start-KeystoneWeb.ps1" -NoBrowser -Port "%~2"
)
goto FINISH

:BROWSER
powershell.exe %PS_ARGS% -File "%~dp0Start-KeystoneWeb.ps1"

:FINISH
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo.
  echo Keystone exited with code %ERR%.
  echo If a script is blocked by organization policy, contact IT.
  echo If you see "Access is denied" while starting localhost, check
  echo HttpListener URL reservations and port usage with your administrator.
  pause
)
exit /b %ERR%
