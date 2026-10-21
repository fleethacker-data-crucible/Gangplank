@echo off
setlocal
cd /d "%~dp0" || (echo ERROR: cannot open Keystone folder & pause & exit /b 1)

if not defined ARC_PATH (
  if exist "%~dp0..\arc\pm.ps1" set "ARC_PATH=%~dp0..\arc"
  if exist "%~dp0..\..\arc\pm.ps1" set "ARC_PATH=%~dp0..\..\arc"
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
where powershell >nul 2>&1 || (echo ERROR: Windows PowerShell 5.1 not found & pause & exit /b 1)

if /i "%~1"=="-Cli" (
  powershell.exe -NoProfile -NoLogo -File "%~dp0Keystone.ps1"
) else (
  powershell.exe -NoProfile -NoLogo -File "%~dp0Start-KeystoneWeb.ps1"
)
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo.
  echo Keystone stopped with code %ERR%.
  echo Check execution policy, script signing and localhost permissions with your administrator.
  pause
)
exit /b %ERR%
