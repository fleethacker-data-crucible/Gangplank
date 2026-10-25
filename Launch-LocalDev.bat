@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || exit /b 1
where powershell.exe >nul 2>&1 || (echo Windows PowerShell 5.1 is required. & exit /b 1)
echo [KEYSTONE LOCAL DEV] Test mode with a synthetic GitHub (needs Node.js on this dev PC).
echo No ARC, no real credentials. Use fictional data only.
powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "%~dp0dev\Start-LocalDev.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
