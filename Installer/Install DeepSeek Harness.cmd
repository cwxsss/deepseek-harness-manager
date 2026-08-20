@echo off
setlocal
chcp 65001 >nul
title DeepSeek Harness Installer
color 0A
echo.
echo ==========================================================
echo   DeepSeek Harness Installer
echo   Keep this window open. Installation progress is shown here.
echo ==========================================================
echo.

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DeepSeekHarness.ps1"
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
  echo ==========================================================
  echo   Installation completed successfully.
  echo   See DeepSeek Harness installation report on your desktop.
  echo ==========================================================
) else (
  echo ==========================================================
  echo   Installation did not complete. Exit code: %RESULT%
  echo   See DeepSeek Harness installation report on your desktop.
  echo ==========================================================
)
echo.
echo Press any key to close this window...
pause >nul
endlocal
