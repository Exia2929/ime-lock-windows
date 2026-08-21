@echo off
setlocal
rem Same as run.bat, but launches IME Lock elevated so it can also push
rem messages at windows owned by administrator-level processes.
rem Always goes through bootstrap.ps1 - the UAC prompt dwarfs the startup cost.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" -Launch -Elevated
exit /b %errorlevel%
