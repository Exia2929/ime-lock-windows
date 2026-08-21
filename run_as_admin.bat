@echo off
powershell -NoProfile -Command "Start-Process pythonw.exe -Verb RunAs -ArgumentList @('%~dp0ime_lock.pyw')"
