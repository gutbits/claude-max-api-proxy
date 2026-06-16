@echo off
REM Portable launcher — works from anywhere (Downloads, Desktop, etc.)
title Claude Max Proxy
setlocal

set "MARKER=%USERPROFILE%\.claude-max-api-proxy.dir"
set "INSTALL_DIR=%USERPROFILE%\claude-max-api-proxy"
set "PORT=3456"
set "LOG=%USERPROFILE%\.claude-max-api-proxy.log"

if exist "%MARKER%" (
    set /p INSTALL_DIR=<"%MARKER%"
)

set "CLAUDE_BIN=%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
set "STANDALONE=%INSTALL_DIR%\dist\server\standalone.js"

if not exist "%STANDALONE%" (
    echo.
    echo  Proxy not installed yet.
    echo  Run setup-and-run.bat first.
    echo.
    pause
    exit /b 1
)

if not exist "%CLAUDE_BIN%" (
    echo.
    echo  Claude CLI not found at:
    echo  %CLAUDE_BIN%
    echo  Run: npm install -g @anthropic-ai/claude-code
    echo.
    pause
    exit /b 1
)

set "PATH=%PATH%;%APPDATA%\npm"
cd /d "%INSTALL_DIR%"

echo.
echo  Starting Claude Max proxy...
echo  Install: %INSTALL_DIR%
echo  URL:     http://127.0.0.1:%PORT%/v1
echo  Log:     %LOG%
echo.

set "CLAUDE_BIN=%CLAUDE_BIN%"
start "claude-max-proxy" /MIN cmd /c "set CLAUDE_BIN=%CLAUDE_BIN%&& set PATH=%PATH%&& cd /d \"%INSTALL_DIR%\"&& node \"dist\server\standalone.js\" %PORT% >> \"%LOG%\" 2>&1"

timeout /t 4 /nobreak >nul

curl -sf http://127.0.0.1:%PORT%/health >nul 2>&1
if errorlevel 1 (
    echo  FAILED — last lines of log:
    echo  ----------------------------------------
    powershell -NoProfile -Command "Get-Content '%LOG%' -Tail 20 -ErrorAction SilentlyContinue"
    echo  ----------------------------------------
    pause
    exit /b 1
)

echo  Proxy is running!
echo.
pause
