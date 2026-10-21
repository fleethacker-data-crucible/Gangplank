@echo off
setlocal
cd /d "%~dp0" || (echo ERROR: cannot cd to tool folder & pause & exit /b 1)

if not defined ARC_PATH (
  if exist "%~dp0..\arc\pm.ps1" set "ARC_PATH=%~dp0..\arc"
  if exist "%~dp0..\..\arc\pm.ps1" set "ARC_PATH=%~dp0..\..\arc"
)

echo.
echo ================================================
echo          Keystone Launcher
echo ================================================
echo.
if defined ARC_PATH echo ARC_PATH=%ARC_PATH%

where powershell >nul 2>&1 || (echo ERROR: powershell not on PATH & pause & exit /b 1)

powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0Keystone.ps1"
set ERR=%ERRORLEVEL%
if not "%ERR%"=="0" (
  echo.
  echo Exit code %ERR%
  pause
)
exit /b %ERR%
