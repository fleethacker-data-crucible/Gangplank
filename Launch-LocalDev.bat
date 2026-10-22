@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || exit /b 1
where powershell.exe >nul 2>&1 || (echo Windows PowerShell 5.1 is required. & exit /b 1)
echo [KEYSTONE LOCAL DEV] No CAC unlock. ARC credentials remain locked.
echo Live Git operations still require valid provider credentials and authorization.
powershell.exe -NoProfile -NoLogo -STA -File "%~dp0Start-KeystoneWeb.ps1" -SkipArcUnlock %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
