# Shared helpers for Claude Max proxy on Windows

function Get-ProxyPaths {
    $DefaultDir = Join-Path $env:USERPROFILE "claude-max-api-proxy"
    $InstallMarker = Join-Path $env:USERPROFILE ".claude-max-api-proxy.dir"
    $Port = if ($env:CLAUDE_MAX_PROXY_PORT) { [int]$env:CLAUDE_MAX_PROXY_PORT } else { 3456 }
    $PidFile = Join-Path $env:USERPROFILE ".claude-max-api-proxy.pid"
    $LogFile = Join-Path $env:USERPROFILE ".claude-max-api-proxy.log"

    $InstallDir = if ($env:CLAUDE_MAX_PROXY_DIR) {
        $env:CLAUDE_MAX_PROXY_DIR
    } elseif (Test-Path $InstallMarker) {
        $saved = (Get-Content $InstallMarker -Raw).Trim()
        if ($saved -and (Test-Path $saved)) { $saved } else { $DefaultDir }
    } else {
        $DefaultDir
    }

    return @{
        DefaultDir    = $DefaultDir
        InstallDir    = $InstallDir
        InstallMarker = $InstallMarker
        Port          = $Port
        PidFile       = $PidFile
        LogFile       = $LogFile
        Standalone    = Join-Path $InstallDir "dist\server\standalone.js"
        LauncherBat   = Join-Path $InstallDir "run-proxy.bat"
    }
}

function Get-ClaudeBinPath {
    $candidates = @(
        (Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
        (Join-Path $env:ProgramFiles "nodejs\node_modules\@anthropic-ai\claude-code\bin\claude.exe")
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Set-ClaudeBinPersistent {
    $exe = Get-ClaudeBinPath
    if ($exe) {
        $env:CLAUDE_BIN = $exe
        [Environment]::SetEnvironmentVariable("CLAUDE_BIN", $exe, "User")
    }
    return $exe
}

function Write-ProxyLauncher {
    param([hashtable]$Paths)

    $claudeBin = Get-ClaudeBinPath
    if (-not $claudeBin) { return $false }

    $bat = @"
@echo off
setlocal
set "CLAUDE_BIN=$claudeBin"
set "PATH=%PATH%;$env:APPDATA\npm"
cd /d "$($Paths.InstallDir)"
node "dist\server\standalone.js" $($Paths.Port)
"@
    Set-Content -Path $Paths.LauncherBat -Value $bat -Encoding ASCII
    return $true
}

function Stop-ProxyProcess {
    param([hashtable]$Paths)

    if (Test-Path $Paths.PidFile) {
        $proxyPid = Get-Content $Paths.PidFile -ErrorAction SilentlyContinue
        if ($proxyPid -and (Get-Process -Id $proxyPid -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $proxyPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $Paths.PidFile -Force -ErrorAction SilentlyContinue
    }

    Get-Process -Name node -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
            if ($cmd -match 'standalone\.js') {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    Get-NetTCPConnection -LocalPort $Paths.Port -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}

function Start-ProxyProcess {
    param([hashtable]$Paths)

    if (-not (Test-Path $Paths.Standalone)) {
        throw "Proxy not built at $($Paths.Standalone)"
    }

    $claudeBin = Set-ClaudeBinPersistent
    if (-not $claudeBin) {
        throw "Claude CLI not found. Run: npm install -g @anthropic-ai/claude-code"
    }

    Stop-ProxyProcess -Paths $Paths

    $wrapperBat = Join-Path $env:TEMP "claude-max-proxy-run.cmd"
    $log = $Paths.LogFile
    $dir = $Paths.InstallDir
    $port = $Paths.Port

    $content = "@echo off`r`nset `"CLAUDE_BIN=$claudeBin`"`r`nset `"PATH=$env:Path;$env:APPDATA\npm`"`r`ncd /d `"$dir`"`r`nnode `"dist\server\standalone.js`" $port 1>> `"$log`" 2>&1`r`n"
    Set-Content -Path $wrapperBat -Value $content -Encoding ASCII

    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "`"$wrapperBat`"" `
        -WindowStyle Hidden `
        -PassThru

    $proc.Id | Set-Content $Paths.PidFile

    $ok = $false
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        if ($proc.HasExited) { break }
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 | Out-Null
            $ok = $true
            break
        } catch {}
    }

    if (-not $ok) {
        Show-ProxyLogTail -LogFile $log
        if ($proc.HasExited) {
            throw "Proxy exited immediately (exit code $($proc.ExitCode))."
        }
        throw "Proxy did not respond on port $port within 25 seconds."
    }

    return $proc
}

function Show-ProxyLogTail {
    param([string]$LogFile, [int]$Lines = 20)
    if (Test-Path $LogFile) {
        Write-Host "--- log tail ---" -ForegroundColor DarkGray
        Get-Content $LogFile -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Write-Host "----------------" -ForegroundColor DarkGray
    }
}
