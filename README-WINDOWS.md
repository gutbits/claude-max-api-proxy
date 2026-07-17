# Claude Max API Proxy (Windows + Hermes)

Use your **Claude Max** subscription with **Hermes** via an OpenAI-compatible local proxy.

## One-liner (Windows VPS / Server)

Copy **only the command** — not the `PS C:\...>` prompt.

**Fresh install** (download, setup, start proxy + Hermes gateway):

```powershell
Remove-Item $env:USERPROFILE\install.ps1 -Force -EA 0; iwr "https://raw.githubusercontent.com/gutbits/claude-max-api-proxy/main/install.ps1" -OutFile $env:USERPROFILE\install.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\install.ps1
```

**Already installed — restart everything** (kill gateways + proxy, repatch Hermes, start fresh):

```powershell
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\install.ps1 -RestartAll
```

**Update code + rebuild + restart** (pull latest models, fix gutbits remote):

```powershell
iwr "https://raw.githubusercontent.com/gutbits/claude-max-api-proxy/main/install.ps1" -OutFile $env:USERPROFILE\install.ps1 -UseBasicParsing; $d="$env:USERPROFILE\claude-max-api-proxy"; git -C $d remote set-url origin https://github.com/gutbits/claude-max-api-proxy.git 2>$null; git -C $d fetch origin; git -C $d reset --hard origin/main; npm --prefix $d install --loglevel error; npm --prefix $d run build; powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\install.ps1 -RestartAll; (Invoke-RestMethod http://127.0.0.1:3456/v1/models).data.id
```

Or double-click **`install.bat`** if you already cloned the repo.

### What the installer does

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
.\install.ps1 -LoginOnly     # re-auth Claude CLI
.\install.ps1 -Stop          # stop proxy + gateways
.\install.ps1 -RestartAll    # kill all, rebuild services, restart
```

## Hermes model switch

```
/model custom:claude-max-proxy:claude-opus-4-8
/model custom:claude-max-proxy:claude-sonnet-5
/model custom:claude-max-proxy:claude-fable-5
```

Use **dashes** not dots (`4-8` not `4.8`). Also: `claude-sonnet-4-6`, `claude-haiku-4-5`, aliases `opus` / `sonnet` / `fable`.

## Requirements

- Windows 10 / Server 2019+
- Git — https://git-scm.com/download/win
- Hermes Agent installed
- Claude Max subscription

## Linux VPS

See `vps-setup-and-run.sh`.

## License

MIT
