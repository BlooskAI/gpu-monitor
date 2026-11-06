@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0service\install.ps1"
if errorlevel 1 (
  echo.
  echo Installation failed. Review the message above.
  pause
)

