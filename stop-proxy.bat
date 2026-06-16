@echo off
title Stop Claude Max Proxy
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-proxy.ps1"
echo.
pause
