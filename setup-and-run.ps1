# Claude Max API Proxy — full setup + run (Windows / Windows Server 2022)
# Usage:
#   .\setup-and-run.ps1
#   .\setup-and-run.ps1 -LoginOnly
#   .\setup-and-run.ps1 -StartOnly

param(
    [switch]$LoginOnly,
    [switch]$StartOnly
)

$ErrorActionPreference = "Stop"

$RepoUrl     = "https://github.com/wende/claude-max-api-proxy.git"
$DefaultDir  = Join-Path $env:USERPROFILE "claude-max-api-proxy"
$InstallMarker = Join-Path $env:USERPROFILE ".claude-max-api-proxy.dir"
$Port        = if ($env:CLAUDE_MAX_PROXY_PORT) { [int]$env:CLAUDE_MAX_PROXY_PORT } else { 3456 }
$PidFile     = Join-Path $env:USERPROFILE ".claude-max-api-proxy.pid"
$LogFile     = Join-Path $env:USERPROFILE ".claude-max-api-proxy.log"
$HermesConfig = @(
    (Join-Path $env:LOCALAPPDATA "hermes\config.yaml"),
    (Join-Path $env:USERPROFILE ".hermes\config.yaml")
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Get-InstallDir {
    if ($env:CLAUDE_MAX_PROXY_DIR) { return $env:CLAUDE_MAX_PROXY_DIR }
    if (Test-Path $InstallMarker) {
        $saved = (Get-Content $InstallMarker -Raw).Trim()
        if ($saved -and (Test-Path $saved)) { return $saved }
    }
    $here = Join-Path $PSScriptRoot "dist\server\standalone.js"
    if (Test-Path $here) { return $PSScriptRoot }
    return $DefaultDir
}

function Save-InstallDir($dir) {
    Set-Content -Path $InstallMarker -Value $dir -NoNewline
}

$InstallDir = Get-InstallDir

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Set-ClaudeBin {
    $exe = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
    if (Test-Path $exe) {
        $env:CLAUDE_BIN = $exe
    }
}

function Write-Info($msg)  { Write-Host "> $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Fail($msg)  { Write-Host "X $msg" -ForegroundColor Red; exit 1 }

function Test-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Fail "Missing '$name'. Install it and re-run."
    }
}

function Stop-Proxy {
    if (Test-Path $PidFile) {
        $proxyPid = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($proxyPid -and (Get-Process -Id $proxyPid -ErrorAction SilentlyContinue)) {
            Write-Info "Stopping existing proxy (PID $proxyPid)..."
            Stop-Process -Id $proxyPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}

function Install-NodeIfNeeded {
    Refresh-Path
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $major = [int]((node -v) -replace '^v', '' -split '\.')[0]
        if ($major -lt 20) { Write-Fail "Node.js 20+ required (found $(node -v)). Install from https://nodejs.org" }
        return
    }
    Write-Warn "Node.js not found. Trying winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        Refresh-Path
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Fail "Node.js not installed. Download from https://nodejs.org and re-run."
    }
}

function Install-ClaudeCli {
    Refresh-Path
    Set-ClaudeBin
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Info "Claude CLI already installed: $(claude --version 2>$null)"
        return
    }
    Write-Info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    Refresh-Path
    Set-ClaudeBin
    Test-Command claude
}

function Update-Repo {
    $script:InstallDir = Get-InstallDir
    $standalone = Join-Path $InstallDir "dist\server\standalone.js"
    $packageJson = Join-Path $InstallDir "package.json"

    if (-not (Test-Path $packageJson)) {
        Test-Command git
        if (Test-Path $InstallDir) {
            $existing = Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue
            if ($existing -and $InstallDir -ne $DefaultDir) {
                Write-Warn "Script folder has no built proxy — installing to $DefaultDir instead."
                $script:InstallDir = $DefaultDir
                $standalone = Join-Path $InstallDir "dist\server\standalone.js"
                $packageJson = Join-Path $InstallDir "package.json"
            }
        }
        if (-not (Test-Path $packageJson)) {
            if (Test-Path $InstallDir) {
                Write-Info "Using install dir: $InstallDir"
            } else {
                Write-Info "Creating install dir: $InstallDir"
                New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            }
            if (-not (Test-Path (Join-Path $InstallDir ".git"))) {
                Write-Info "Cloning proxy from GitHub..."
                git clone $RepoUrl $InstallDir
            }
        }
    } elseif (Test-Path (Join-Path $InstallDir ".git")) {
        Write-Info "Updating proxy at $InstallDir..."
        git -C $InstallDir pull --ff-only
    }

    Save-InstallDir $InstallDir
    Set-Location $InstallDir
    Write-Info "Install dir: $InstallDir"
    Write-Info "Installing npm dependencies..."
    npm install
    Write-Info "Building..."
    npm run build

    if (-not (Test-Path $standalone)) {
        Write-Fail "Build failed — missing $standalone"
    }
}

function Ensure-ClaudeLogin {
    Refresh-Path
    Set-ClaudeBin
    $status = claude auth status 2>&1 | Out-String
    if ($status -match '"loggedIn"\s*:\s*true') {
        Write-Info "Claude CLI already logged in."
        ($status -split "`n") | Where-Object { $_ -match 'subscriptionType|email' } | ForEach-Object { Write-Host "  $_" }
        return
    }
    Write-Warn "Claude CLI not logged in."
    Write-Host ""
    Write-Host "  Sign in with your Claude Max account."
    Write-Host "  A browser window should open (or a URL will print)."
    Write-Host ""
    claude auth login
}

function Patch-HermesConfig {
    if (-not $HermesConfig) {
        Write-Warn "Hermes config not found — skipping patch."
        Write-Warn "Set provider: custom and base_url: http://localhost:${Port}/v1 in your Hermes config."
        return
    }

    Write-Info "Patching Hermes config ($HermesConfig)..."
    $backup = "$HermesConfig.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $HermesConfig $backup

    $baseUrl = "http://localhost:${Port}/v1"
    $text = Get-Content $HermesConfig -Raw

    $text = [regex]::Replace($text, '(?m)^(\s*provider:\s*).*$', '${1}custom', 1)
    $text = [regex]::Replace($text, '(?m)^(\s*base_url:\s*).*$', '${1}' + $baseUrl, 1)
    $text = [regex]::Replace($text, '(?m)^(\s*default:\s*).*$', '${1}claude-sonnet-4', 1)

    $modelBlock = ($text -split 'model:', 2)[1] -split "`n`n", 2 | Select-Object -First 1
    if ($modelBlock -notmatch 'api_key:') {
        $text = [regex]::Replace($text, '(?m)^(\s*base_url:\s*.*)$', '${1}' + "`n  api_key: not-needed", 1)
    }

    if ($text -notmatch 'custom_providers:') {
        $snippet = "`ncustom_providers:`n  - name: claude-max-proxy`n    base_url: $baseUrl`n"
        $text = [regex]::Replace($text, '(?m)(^model:\r?\n(?:  .+\r?\n)+)', {
            param($m)
            $m.Groups[1].Value + $snippet
        })
    }

    Set-Content -Path $HermesConfig -Value $text -NoNewline
    Write-Info "  -> provider: custom, base_url: $baseUrl, model: claude-sonnet-4"
}

function Start-ProxyServer {
    $script:InstallDir = Get-InstallDir
    $standalone = Join-Path $InstallDir "dist\server\standalone.js"
    if (-not (Test-Path $standalone)) {
        Write-Fail "Proxy not built at $standalone — run setup-and-run.bat (full setup, no -StartOnly)."
    }

    Set-Location $InstallDir
    Set-ClaudeBin
    Stop-Proxy

    Write-Info "Starting proxy on http://127.0.0.1:${Port} (log: $LogFile)..."
    Write-Info "From: $InstallDir"
    $nodeCmd = "node `"dist\server\standalone.js`" $Port >> `"$LogFile`" 2>&1"
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", $nodeCmd `
        -WorkingDirectory $InstallDir `
        -WindowStyle Hidden `
        -PassThru

    $proc.Id | Set-Content $PidFile
    Start-Sleep -Seconds 3

    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/health" -TimeoutSec 5
        Write-Info "Proxy is up - http://127.0.0.1:${Port}/v1"
    } catch {
        Write-Fail "Proxy failed to start. Check $LogFile"
    }
}

function Restart-HermesGateway {
    Refresh-Path
    if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
        Write-Warn "hermes CLI not in PATH — start gateway manually: hermes gateway run"
        return
    }
    Write-Info "Restarting Hermes gateway..."
    hermes gateway stop 2>$null | Out-Null
    Start-Sleep -Seconds 1
    $status = hermes gateway status 2>&1 | Out-String
    if ($status -match 'running') {
        Write-Warn "Gateway still running."
    } else {
        $gwLog = Join-Path $env:LOCALAPPDATA "hermes\gateway.log"
        if (-not (Test-Path (Split-Path $gwLog))) { $gwLog = Join-Path $env:USERPROFILE ".hermes\gateway.log" }
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "hermes gateway run >> `"$gwLog`" 2>&1" `
            -WindowStyle Hidden
        Start-Sleep -Seconds 2
        hermes gateway status 2>&1
    }
}

function Show-Done {
    Write-Host ""
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host "  Claude Max proxy ready" -ForegroundColor Green
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Proxy:    http://127.0.0.1:${Port}/v1"
    Write-Host "  Models:   claude-sonnet-4, claude-opus-4, claude-haiku-4"
    Write-Host "  Install:  $InstallDir"
    Write-Host "  Log:      $LogFile"
    Write-Host "  Stop:     double-click stop-proxy.bat"
    Write-Host ""
    Write-Host "  Hermes:   provider custom -> localhost:${Port}"
    Write-Host "  Switch:   /model custom:claude-max-proxy:claude-opus-4"
    Write-Host ""
}

# --- main ---
Write-Host ""
Write-Host "  Claude Max API Proxy - Windows setup"
Write-Host "  ====================================="
Write-Host ""

Refresh-Path
Set-ClaudeBin

if ($LoginOnly) {
    Test-Command claude
    Ensure-ClaudeLogin
    exit 0
}

if ($StartOnly) {
    $script:InstallDir = Get-InstallDir
    $standalone = Join-Path $InstallDir "dist\server\standalone.js"
    if (-not (Test-Path $standalone)) {
        Write-Warn "Proxy not built yet — running full setup first..."
        Test-Command git
        Install-NodeIfNeeded
        Install-ClaudeCli
        Update-Repo
        Ensure-ClaudeLogin
    }
    Start-ProxyServer
    Show-Done
    exit 0
}

Test-Command git
Install-NodeIfNeeded
Install-ClaudeCli
Update-Repo
Ensure-ClaudeLogin
Patch-HermesConfig
Start-ProxyServer
Restart-HermesGateway
Show-Done
