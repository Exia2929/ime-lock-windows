@echo off
setlocal
rem IME Lock launcher.
rem Fast path: reuse the interpreter that bootstrap.ps1 cached last time.
rem Anything unusual (no cache, cached interpreter gone, requirements.txt
rem present) falls through to bootstrap.ps1, which verifies the environment
rem and installs whatever is missing.

set "HERE=%~dp0"
set "PYW="

if exist "%HERE%requirements.txt" goto bootstrap
if not exist "%HERE%.ime-lock-python" goto bootstrap
set /p PYW=<"%HERE%.ime-lock-python"
if not defined PYW goto bootstrap
if not exist "%PYW%" goto bootstrap

start "" "%PYW%" "%HERE%ime_lock.pyw"
exit /b 0

:bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%bootstrap.ps1" -Launch
exit /b %errorlevel%
