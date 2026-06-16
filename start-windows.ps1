# Start Claude Max API Proxy on Windows
# Requires: npm install -g @anthropic-ai/claude-code && claude auth login

$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:CLAUDE_BIN = "$env:APPDATA\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"

Set-Location $PSScriptRoot
npm start
