@echo off
REM Keystone was renamed to Gangplank. This stub keeps existing shortcuts working.
REM Use Launch-Gangplank.bat directly; this file may be removed in a later release.
echo Keystone is now Gangplank. Starting Launch-Gangplank.bat ...
call "%~dp0Launch-Gangplank.bat" %*
exit /b %ERRORLEVEL%
