@echo off
title Claude Max Proxy Setup
cd /d "%~dp0"
echo.
echo  Claude Max API Proxy - Setup and Run
echo  =====================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-and-run.ps1" %*
if errorlevel 1 (
    echo.
    echo  Setup failed. See errors above.
    pause
    exit /b 1
)

echo.
pause
