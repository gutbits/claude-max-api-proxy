# Claude Max API Proxy (Windows + Hermes)

Use your **Claude Max** subscription with **Hermes** via an OpenAI-compatible local proxy.

Fork of [wende/claude-max-api-proxy](https://github.com/wende/claude-max-api-proxy) with Windows installer scripts.

## Quick start (Windows Server / Windows 10+)

**One file — download and run:**

```powershell
# Option A: save install.ps1 and run
powershell -ExecutionPolicy Bypass -File install.ps1

# Option B: one-liner (after repo is live)
irm https://raw.githubusercontent.com/gutbits/claude-max-api-proxy/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1
```

Or double-click **`install.bat`**.

### What it does

1. Installs Node.js 20+ (via winget if needed)
2. Installs `@anthropic-ai/claude-code` globally
3. Clones this repo to `%USERPROFILE%\claude-max-api-proxy`
4. Builds the proxy
5. Runs `claude auth login` (Claude Max account)
6. Patches `%LOCALAPPDATA%\hermes\config.yaml` → `provider: custom`
7. Starts proxy on `http://localhost:3456/v1`
8. Restarts Hermes gateway

### Other commands

```powershell
.\install.ps1 -StartOnly   # start proxy (already set up)
.\install.ps1 -LoginOnly   # re-auth Claude CLI
.\install.ps1 -Stop         # stop proxy
```

## Requirements

- Windows 10 / Server 2019+
- Git — https://git-scm.com/download/win
- Hermes Agent installed
- Claude Max subscription

## Hermes model switch

```
/model custom:claude-max-proxy:claude-opus-4
/model custom:claude-max-proxy:claude-sonnet-4
```

## Linux VPS

See `vps-setup-and-run.sh`.

## License

MIT
