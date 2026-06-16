#Requires -Version 5.1
<#
.SYNOPSIS
  One-file setup for Claude Max API Proxy + Hermes on Windows / Windows Server.

  Usage:
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -StartOnly
    powershell -ExecutionPolicy Bypass -File install.ps1 -LoginOnly
    powershell -ExecutionPolicy Bypass -File install.ps1 -Stop
#>

param(
    [switch]$LoginOnly,
    [switch]$StartOnly,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$ScriptVersion = "1.0.5"
$RepoUrl       = "https://github.com/gutbits/claude-max-api-proxy.git"
$DefaultDir    = Join-Path $env:USERPROFILE "claude-max-api-proxy"
$InstallMarker = Join-Path $env:USERPROFILE ".claude-max-api-proxy.dir"
$Port          = if ($env:CLAUDE_MAX_PROXY_PORT) { [int]$env:CLAUDE_MAX_PROXY_PORT } else { 3456 }
$PidFile       = Join-Path $env:USERPROFILE ".claude-max-api-proxy.pid"
$LogFile       = Join-Path $env:USERPROFILE ".claude-max-api-proxy.log"
$NpmGlobal     = Join-Path $env:APPDATA "npm"
$ClaudePkg     = '@anthropic-ai/claude-code'

function Write-Info($m)  { Write-Host "> $m" -ForegroundColor Green }
function Write-Warn($m)  { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Fail($m)  { Write-Host "X $m" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
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
    $candidates = @()

    try {
        $npmRoot = (& npm root -g 2>$null)
        if ($npmRoot) {
            $npmRoot = $npmRoot.ToString().Trim()
            $candidates += (Join-Path $npmRoot '@anthropic-ai\claude-code\bin\claude.exe')
        }
    }
    catch {}

    $candidates += (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe')
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'nodejs\node_modules\@anthropic-ai\claude-code\bin\claude.exe')
    }

    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $npmBin = Split-Path $cmd.Source -Parent
        $candidates += (Join-Path $npmBin 'node_modules\@anthropic-ai\claude-code\bin\claude.exe')
    }

    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
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
    if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
        Write-Fail "Missing '$n'. Install it first."
    }
}

function Get-HermesConfig {
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA "hermes\config.yaml"),
        (Join-Path $env:USERPROFILE ".hermes\config.yaml")
    )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Show-LogTail {
    if (Test-Path $LogFile) {
        Write-Host "--- log ---" -ForegroundColor DarkGray
        Get-Content $LogFile -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Write-Host "-----------" -ForegroundColor DarkGray
    }
}

function Install-Node {
    Refresh-Path
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $maj = [int]((node -v) -replace '^v', '' -split '\.')[0]
        if ($maj -lt 20) { Write-Fail "Need Node 20+ (have $(node -v))" }
        return
    }
    Write-Warn "Node not found - trying winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        Refresh-Path
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Fail "Install Node.js 20+ from https://nodejs.org then re-run."
    }
}

function Install-ClaudeCli {
    Refresh-Path
    $exe = Get-ClaudeExe
    if ($exe) {
        Write-Info ("Claude CLI OK: " + (claude --version 2>$null))
        Write-Info ("Claude exe: " + $exe)
        return
    }
    Write-Info "Installing Claude Code CLI..."
    & npm install -g $ClaudePkg
    Refresh-Path
    Start-Sleep -Seconds 2
    $exe = Get-ClaudeExe
    if (-not $exe) {
        Write-Warn ("npm root -g: " + (npm root -g 2>$null))
        Write-Warn ("where claude: " + (where.exe claude 2>$null))
        Write-Fail "Claude CLI install failed. Try manually: npm install -g @anthropic-ai/claude-code"
    }
    Write-Info ("Claude exe: " + $exe)
}

function Install-Proxy {
    $dir = Get-InstallDir
    $standalone = Join-Path $dir "dist\server\standalone.js"

    if (-not (Test-Path (Join-Path $dir "package.json"))) {
        Test-Cmd git
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if (-not (Test-Path (Join-Path $dir ".git"))) {
            Write-Info ("Cloning to " + $dir + " ...")
            & git clone $RepoUrl $dir
        }
    }
    elseif (Test-Path (Join-Path $dir ".git")) {
        Write-Info ("Updating " + $dir + " ...")
        & git -C $dir pull --ff-only 2>$null
    }

    Save-InstallDir $dir
    Set-Location $dir
    Write-Info "npm install..."
    & npm install --loglevel error
    Write-Info "npm run build..."
    & npm run build

    if (-not (Test-Path $standalone)) {
        Write-Fail ("Build failed - no " + $standalone)
    }
    return $dir
}

function Ensure-Login {
    Refresh-Path
    Set-ClaudeEnv | Out-Null
    $s = & claude auth status 2>&1 | Out-String
    if ($s -match '"loggedIn"\s*:\s*true') {
        Write-Info "Claude logged in."
        ($s -split "`n") | Where-Object { $_ -match 'email|subscriptionType' } | ForEach-Object { Write-Host ("  " + $_) }
        return
    }
    Write-Warn "Need Claude Max login..."
    & claude auth login
}

function Get-HermesPython {
    $p = Join-Path $env:LOCALAPPDATA "hermes\hermes-agent\venv\Scripts\python.exe"
    if (Test-Path $p) { return $p }
    if (Get-Command python -ErrorAction SilentlyContinue) { return "python" }
    return $null
}

function Test-HermesConfigValid($cfgPath) {
    $py = Get-HermesPython
    if ($py) {
        $check = @'
import sys
try:
    import yaml
    with open(sys.argv[1], encoding='utf-8') as f:
        yaml.safe_load(f)
    sys.exit(0)
except Exception:
    sys.exit(1)
'@
        & $py -c $check $cfgPath 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    if (Get-Command hermes -ErrorAction SilentlyContinue) {
        $o = (& hermes gateway status 2>&1 | Out-String)
        return ($o -notmatch 'Failed to parse')
    }
    return $true
}

function Restore-HermesBackup($cfgPath) {
    $bak = Get-ChildItem -Path ($cfgPath + ".bak.*") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($bak) {
        Write-Warn ("Restoring Hermes config from " + $bak.Name)
        Copy-Item $bak.FullName $cfgPath -Force
        return $true
    }
    return $false
}

function Patch-Hermes {
    $cfg = Get-HermesConfig
    if (-not $cfg) {
        Write-Warn "No Hermes config found - skip."
        return
    }

    if (-not (Test-HermesConfigValid $cfg)) {
        Write-Warn "Hermes config.yaml is broken - restoring latest backup..."
        if (-not (Restore-HermesBackup $cfg)) {
            Write-Fail "Broken config and no backup found. Fix config.yaml manually."
        }
    }

    $backup = $cfg + ".bak." + (Get-Date -Format "yyyyMMdd-HHmmss")
    Copy-Item $cfg $backup
    $url = "http://localhost:" + $Port + "/v1"
    $lines = Get-Content $cfg
    $out = New-Object System.Collections.ArrayList
    $inModel = $false
    $ind = "  "
    $seenProvider = $false
    $seenBaseUrl = $false
    $seenDefault = $false
    $seenApiKey = $false
    $textAll = $lines -join "`n"
    $hasCustomProviders = $textAll -match '(?m)^custom_providers:'

    foreach ($line in $lines) {
        if ($line -match '^model:\s*$') {
            [void]$out.Add($line)
            $inModel = $true
            continue
        }

        if ($inModel -and ($line -match '^[^\s#]')) {
            if (-not $seenProvider) { [void]$out.Add($ind + "provider: custom") }
            if (-not $seenBaseUrl) { [void]$out.Add($ind + "base_url: " + $url) }
            if (-not $seenDefault) { [void]$out.Add($ind + "default: claude-sonnet-4") }
            if (-not $seenApiKey) { [void]$out.Add($ind + "api_key: not-needed") }
            $inModel = $false
        }

        if ($inModel) {
            if ($line -match '^\s+provider:') {
                [void]$out.Add($ind + "provider: custom"); $seenProvider = $true; continue
            }
            if ($line -match '^\s+base_url:') {
                [void]$out.Add($ind + "base_url: " + $url); $seenBaseUrl = $true; continue
            }
            if ($line -match '^\s+default:') {
                [void]$out.Add($ind + "default: claude-sonnet-4"); $seenDefault = $true; continue
            }
            if ($line -match '^\s+api_key:') {
                [void]$out.Add($ind + "api_key: not-needed"); $seenApiKey = $true; continue
            }
        }

        [void]$out.Add($line)
    }

    if ($inModel) {
        if (-not $seenProvider) { [void]$out.Add($ind + "provider: custom") }
        if (-not $seenBaseUrl) { [void]$out.Add($ind + "base_url: " + $url) }
        if (-not $seenDefault) { [void]$out.Add($ind + "default: claude-sonnet-4") }
        if (-not $seenApiKey) { [void]$out.Add($ind + "api_key: not-needed") }
    }

    if (-not $hasCustomProviders) {
        [void]$out.Add("")
        [void]$out.Add("custom_providers:")
        [void]$out.Add("  - name: claude-max-proxy")
        [void]$out.Add("    base_url: " + $url)
    }

    Set-Content -Path $cfg -Value ($out -join "`n") -Encoding UTF8

    if (-not (Test-HermesConfigValid $cfg)) {
        Write-Warn "Patch produced invalid YAML - rolling back..."
        Copy-Item $backup $cfg -Force
        Write-Fail ("Could not patch Hermes config safely. Set manually under model: only - provider: custom, base_url: " + $url)
    }

    Write-Info ("  Hermes -> custom at " + $url)
}

function Stop-Proxy {
    if (Test-Path $PidFile) {
        $p = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($p -and (Get-Process -Id $p -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name node -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $c = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $_.Id)).CommandLine
            if ($c -match 'standalone\.js') {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Write-Info "Proxy stopped."
}

function Start-Proxy {
    $dir = Get-InstallDir
    $standalone = Join-Path $dir "dist\server\standalone.js"
    if (-not (Test-Path $standalone)) {
        Write-Fail "Not built. Run without -StartOnly first."
    }

    $claude = Set-ClaudeEnv
    if (-not $claude) {
        Write-Fail "Claude CLI missing. Re-run full install."
    }

    Stop-Proxy

    $wrapper = Join-Path $env:TEMP "claude-max-run.cmd"
    $bat = @()
    $bat += '@echo off'
    $bat += ('set "CLAUDE_BIN=' + $claude + '"')
    $bat += ('set "PATH=' + $env:Path + ';' + $NpmGlobal + '"')
    $bat += ('cd /d "' + $dir + '"')
    $bat += ('node "dist\server\standalone.js" ' + $Port + ' 1>> "' + $LogFile + '" 2>&1')
    Set-Content -Path $wrapper -Value ($bat -join "`r`n") -Encoding ASCII

    Write-Info ("Starting proxy on http://127.0.0.1:" + $Port + " ...")
    Write-Info ("Install dir: " + $dir)
    Write-Info ("Log: " + $LogFile)

    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $wrapper) -WindowStyle Hidden -PassThru
    $proc.Id | Set-Content $PidFile

    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ($proc.HasExited) { break }
        try {
            Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + "/health") -TimeoutSec 2 | Out-Null
            $ok = $true
            break
        }
        catch {}
    }

    if (-not $ok) {
        Show-LogTail
        if ($proc.HasExited) {
            Write-Fail ("Proxy crashed (exit " + $proc.ExitCode + "). See log above.")
        }
        Write-Fail "Proxy not responding after 30s. See log above."
    }
    Write-Info ("Proxy running - http://127.0.0.1:" + $Port + "/v1")
}

function Restart-Hermes {
    Refresh-Path
    if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
        Write-Warn "hermes not in PATH - start manually: hermes gateway run"
        return
    }
    Write-Info "Restarting Hermes gateway..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & hermes gateway stop 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    $gwLog = Join-Path $env:LOCALAPPDATA "hermes\gateway.log"
    if (-not (Test-Path (Split-Path $gwLog))) {
        $gwLog = Join-Path $env:USERPROFILE ".hermes\gateway.log"
    }
    $gwCmd = 'hermes gateway run >> "' + $gwLog + '" 2>&1'
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $gwCmd) -WindowStyle Hidden
    Start-Sleep -Seconds 2
    & hermes gateway status 2>&1
    $ErrorActionPreference = $prevEap
}

function Show-Done {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Green
    Write-Host "  Done! Claude Max proxy is ready for Hermes" -ForegroundColor Green
    Write-Host "================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host ("  API:      http://127.0.0.1:" + $Port + "/v1")
    Write-Host "  Model:    claude-sonnet-4  (or claude-opus-4)"
    Write-Host ("  Install:  " + (Get-InstallDir))
    Write-Host ("  Log:      " + $LogFile)
    Write-Host "  Stop:     install.ps1 -Stop"
    Write-Host ""
}

Write-Host ""
Write-Host ("  Claude Max Proxy - Windows Installer (gutbits v" + $ScriptVersion + ")")
Write-Host "  ================================================"
Write-Host ""

Refresh-Path

if ($Stop) { Stop-Proxy; exit 0 }
if ($LoginOnly) { Ensure-Login; exit 0 }

if ($StartOnly) {
    $d = Join-Path (Get-InstallDir) "dist\server\standalone.js"
    if (-not (Test-Path $d)) {
        Install-Node
        Install-ClaudeCli
        Install-Proxy | Out-Null
        Ensure-Login
    }
    Start-Proxy
    Show-Done
    exit 0
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
