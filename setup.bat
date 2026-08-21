@echo off
setlocal
rem Check the environment - and install Python / dependencies if anything is
rem missing - without launching IME Lock. Useful on a fresh machine.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" -Force
set "RC=%errorlevel%"
echo.
pause
exit /b %RC%
