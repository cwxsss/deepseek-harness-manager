@echo off
setlocal
chcp 65001 >nul
title DeepSeek Harness Repair
color 0E
echo.
echo ==========================================================
echo   DeepSeek Harness Repair
echo   Fixing launcher scripts and restarting the local service.
echo ==========================================================
echo.

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DeepSeekHarness.ps1" -Repair
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
  echo Repair completed. See the installation report on your desktop.
) else (
  echo Repair did not complete. Exit code: %RESULT%
  echo See the installation report on your desktop.
)
echo.
echo Press any key to close this window...
pause >nul
endlocal
