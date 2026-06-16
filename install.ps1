#Requires -Version 5.1
<#
.SYNOPSIS
  One-file setup for Claude Max API Proxy + Hermes on Windows / Windows Server.

.DESCRIPTION
  Downloads nothing except the proxy repo itself. Safe to run from anywhere.

  Usage:
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -StartOnly
    powershell -ExecutionPolicy Bypass -File install.ps1 -LoginOnly
    powershell -ExecutionPolicy Bypass -File install.ps1 -Stop

  Or one-liner:
    irm https://raw.githubusercontent.com/gutbits/claude-max-api-proxy/main/install.ps1 | iex
#>

param(
    [switch]$LoginOnly,
    [switch]$StartOnly,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

# ── config ────────────────────────────────────────────────────────────────
$RepoUrl       = "https://github.com/gutbits/claude-max-api-proxy.git"
$DefaultDir    = Join-Path $env:USERPROFILE "claude-max-api-proxy"
$InstallMarker = Join-Path $env:USERPROFILE ".claude-max-api-proxy.dir"
$Port          = if ($env:CLAUDE_MAX_PROXY_PORT) { [int]$env:CLAUDE_MAX_PROXY_PORT } else { 3456 }
$PidFile       = Join-Path $env:USERPROFILE ".claude-max-api-proxy.pid"
$LogFile       = Join-Path $env:USERPROFILE ".claude-max-api-proxy.log"

# ── helpers ───────────────────────────────────────────────────────────────
function Write-Info($m)  { Write-Host "> $m" -ForegroundColor Green }
function Write-Warn($m)  { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Fail($m)  { Write-Host "X $m" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path","User")
}

function Get-InstallDir {
    if ($env:CLAUDE_MAX_PROXY_DIR) { return $env:CLAUDE_MAX_PROXY_DIR }
    if (Test-Path $InstallMarker) {
        $s = (Get-Content $InstallMarker -Raw).Trim()
        if ($s -and (Test-Path $s)) { return $s }
    }
    return $DefaultDir
}

function Save-InstallDir($d) { Set-Content $InstallMarker $d -NoNewline }

function Get-ClaudeExe {
    $p = Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"
    if (Test-Path $p) { return $p }
    return $null
}

function Set-ClaudeEnv {
    $exe = Get-ClaudeExe
    if ($exe) {
        $env:CLAUDE_BIN = $exe
        [Environment]::SetEnvironmentVariable("CLAUDE_BIN", $exe, "User")
    }
    return $exe
}

function Test-Cmd($n) {
    if (-not (Get-Command $n -EA SilentlyContinue)) { Write-Fail "Missing '$n'. Install it first." }
}

function Get-HermesConfig {
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA "hermes\config.yaml"),
        (Join-Path $env:USERPROFILE ".hermes\config.yaml")
    )) { if (Test-Path $p) { return $p } }
    return $null
}

function Show-LogTail {
    if (Test-Path $LogFile) {
        Write-Host "--- log ---" -ForegroundColor DarkGray
        Get-Content $LogFile -Tail 25 -EA SilentlyContinue | ForEach-Object { Write-Host $_ }
        Write-Host "-----------" -ForegroundColor DarkGray
    }
}

# ── install steps ─────────────────────────────────────────────────────────
function Install-Node {
    Refresh-Path
    if (Get-Command node -EA SilentlyContinue) {
        $maj = [int]((node -v) -replace '^v','' -split '\.')[0]
        if ($maj -lt 20) { Write-Fail "Need Node 20+ (have $(node -v))" }
        return
    }
    Write-Warn "Node not found — trying winget..."
    if (Get-Command winget -EA SilentlyContinue) {
        winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        Refresh-Path
    }
    if (-not (Get-Command node -EA SilentlyContinue)) {
        Write-Fail "Install Node.js 20+ from https://nodejs.org then re-run."
    }
}

function Install-ClaudeCli {
    Refresh-Path
    if (Get-ClaudeExe) { Write-Info "Claude CLI OK: $(claude --version 2>$null)"; return }
    Write-Info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    Refresh-Path
    if (-not (Get-ClaudeExe)) { Write-Fail "Claude CLI install failed." }
}

function Install-Proxy {
    $dir = Get-InstallDir
    $standalone = Join-Path $dir "dist\server\standalone.js"

    if (-not (Test-Path (Join-Path $dir "package.json"))) {
        Test-Cmd git
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (-not (Test-Path (Join-Path $dir ".git"))) {
            Write-Info "Cloning to $dir ..."
            git clone $RepoUrl $dir
        }
    } elseif (Test-Path (Join-Path $dir ".git")) {
        Write-Info "Updating $dir ..."
        git -C $dir pull --ff-only 2>$null
    }

    Save-InstallDir $dir
    Set-Location $dir
    Write-Info "npm install..."
    npm install --loglevel error
    Write-Info "npm run build..."
    npm run build

    if (-not (Test-Path $standalone)) { Write-Fail "Build failed — no $standalone" }
    return $dir
}

function Ensure-Login {
    Refresh-Path; Set-ClaudeEnv
    $s = claude auth status 2>&1 | Out-String
    if ($s -match '"loggedIn"\s*:\s*true') {
        Write-Info "Claude logged in."
        ($s -split "`n") | ? { $_ -match 'email|subscriptionType' } | % { Write-Host "  $_" }
        return
    }
    Write-Warn "Need Claude Max login..."
    claude auth login
}

function Patch-Hermes {
    $cfg = Get-HermesConfig
    if (-not $cfg) { Write-Warn "No Hermes config found — skip."; return }

    Write-Info "Patching $cfg ..."
    Copy-Item $cfg "$cfg.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
    $url = "http://localhost:${Port}/v1"
    $t = Get-Content $cfg -Raw

    $t = [regex]::Replace($t,'(?m)^(\s*provider:\s*).*$','${1}custom',1)
    $t = [regex]::Replace($t,'(?m)^(\s*base_url:\s*).*$','${1}'+$url,1)
    $t = [regex]::Replace($t,'(?m)^(\s*default:\s*).*$','${1}claude-sonnet-4',1)

    $block = ($t -split 'model:',2)[1] -split "`n`n",2 | Select -First 1
    if ($block -notmatch 'api_key:') {
        $t = [regex]::Replace($t,'(?m)^(\s*base_url:\s*.*)$','${1}'+"`n  api_key: not-needed",1)
    }
    if ($t -notmatch 'custom_providers:') {
        $snip = "`ncustom_providers:`n  - name: claude-max-proxy`n    base_url: $url`n"
        $t = [regex]::Replace($t,'(?m)(^model:\r?\n(?:  .+\r?\n)+)',{ param($m) $m.Groups[1].Value+$snip })
    }
    Set-Content $cfg $t -NoNewline
    Write-Info "  Hermes -> custom @ $url"
}

function Stop-Proxy {
    if (Test-Path $PidFile) {
        $p = Get-Content $PidFile -EA SilentlyContinue
        if ($p -and (Get-Process -Id $p -EA SilentlyContinue)) {
            Stop-Process -Id $p -Force -EA SilentlyContinue
        }
        Remove-Item $PidFile -Force -EA SilentlyContinue
    }
    Get-Process node -EA SilentlyContinue | ForEach-Object {
        try {
            $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
            if ($c -match 'standalone\.js') { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
        } catch {}
    }
    Get-NetTCPConnection -LocalPort $Port -EA SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
    Write-Info "Proxy stopped."
}

function Start-Proxy {
    $dir = Get-InstallDir
    $standalone = Join-Path $dir "dist\server\standalone.js"
    if (-not (Test-Path $standalone)) { Write-Fail "Not built. Run without -StartOnly first." }

    $claude = Set-ClaudeEnv
    if (-not $claude) { Write-Fail "Claude CLI missing. Re-run full install." }

    Stop-Proxy

    # cmd wrapper sets CLAUDE_BIN so node subprocess finds claude.exe on Windows
    $wrapper = Join-Path $env:TEMP "claude-max-run.cmd"
    $lines = @(
        '@echo off'
        "set `"CLAUDE_BIN=$claude`""
        "set `"PATH=$env:Path;$env:APPDATA\npm`""
        "cd /d `"$dir`""
        "node `"dist\server\standalone.js`" $Port 1>> `"$LogFile`" 2>&1"
    )
    Set-Content $wrapper ($lines -join "`r`n") -Encoding ASCII

    Write-Info "Starting proxy on http://127.0.0.1:${Port} ..."
    Write-Info "Install dir: $dir"
    Write-Info "Log: $LogFile"

    $proc = Start-Process cmd.exe -ArgumentList "/c","`"$wrapper`"" -WindowStyle Hidden -PassThru
    $proc.Id | Set-Content $PidFile

    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 1
        if ($proc.HasExited) { break }
        try {
            Invoke-RestMethod "http://127.0.0.1:${Port}/health" -TimeoutSec 2 | Out-Null
            $ok = $true; break
        } catch {}
    }

    if (-not $ok) {
        Show-LogTail
        if ($proc.HasExited) { Write-Fail "Proxy crashed (exit $($proc.ExitCode)). See log above." }
        Write-Fail "Proxy not responding after 30s. See log above."
    }
    Write-Info "Proxy running - http://127.0.0.1:${Port}/v1"
}

function Restart-Hermes {
    Refresh-Path
    if (-not (Get-Command hermes -EA SilentlyContinue)) {
        Write-Warn "hermes not in PATH — start manually: hermes gateway run"; return
    }
    Write-Info "Restarting Hermes gateway..."
    hermes gateway stop 2>$null | Out-Null
    Start-Sleep 2
    $gwLog = Join-Path $env:LOCALAPPDATA "hermes\gateway.log"
    if (-not (Test-Path (Split-Path $gwLog))) { $gwLog = Join-Path $env:USERPROFILE ".hermes\gateway.log" }
    Start-Process cmd.exe -ArgumentList "/c","hermes gateway run >> `"$gwLog`" 2>&1" -WindowStyle Hidden
    Start-Sleep 2
    hermes gateway status 2>&1
}

function Show-Done {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Green
    Write-Host "  Done! Claude Max proxy is ready for Hermes" -ForegroundColor Green
    Write-Host "================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  API:      http://127.0.0.1:${Port}/v1"
    Write-Host "  Model:    claude-sonnet-4  (or claude-opus-4)"
    Write-Host "  Install:  $(Get-InstallDir)"
    Write-Host "  Log:      $LogFile"
    Write-Host "  Stop:     install.ps1 -Stop"
    Write-Host ""
}

# ── main ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Claude Max Proxy - Windows Installer (gutbits)"
Write-Host "  ================================================"
Write-Host ""

Refresh-Path

if ($Stop) { Stop-Proxy; exit 0 }

if ($LoginOnly) { Ensure-Login; exit 0 }

if ($StartOnly) {
    $d = Join-Path (Get-InstallDir) "dist\server\standalone.js"
    if (-not (Test-Path $d)) {
        Install-Node; Install-ClaudeCli; Install-Proxy | Out-Null; Ensure-Login
    }
    Start-Proxy; Show-Done; exit 0
}

Test-Cmd git
Install-Node
Install-ClaudeCli
Install-Proxy | Out-Null
Ensure-Login
Patch-Hermes
Start-Proxy
Restart-Hermes
Show-Done
