# Stop Claude Max API Proxy (Windows)

$Port    = if ($env:CLAUDE_MAX_PROXY_PORT) { [int]$env:CLAUDE_MAX_PROXY_PORT } else { 3456 }
$PidFile = Join-Path $env:USERPROFILE ".claude-max-api-proxy.pid"

if (Test-Path $PidFile) {
    $proxyPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($proxyPid -and (Get-Process -Id $proxyPid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $proxyPid -Force
        Write-Host "Stopped proxy (PID $proxyPid)" -ForegroundColor Green
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "No PID file found." -ForegroundColor Yellow
}

Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
    ForEach-Object {
        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
        Write-Host "Freed port $Port" -ForegroundColor Green
    }

Write-Host "Done."
