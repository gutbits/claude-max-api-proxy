@echo off
title Claude Max Proxy - Start
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-and-run.ps1" -StartOnly
echo.
pause
