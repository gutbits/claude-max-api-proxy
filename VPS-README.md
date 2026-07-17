# Claude Max Proxy — setup scripts

## Windows / Windows Server 2022

Copy the whole `claude-max-api-proxy` folder to the server, then **double-click**:

| File | What it does |
|------|----------------|
| **`setup-and-run.bat`** | Full setup: install deps, login, patch Hermes, start proxy |
| **`start-only.bat`** | Start proxy only (after first setup) |
| **`stop-proxy.bat`** | Stop the proxy |

Or from PowerShell:
```powershell
cd D:\path\to\claude-max-api-proxy
.\setup-and-run.ps1
.\setup-and-run.ps1 -LoginOnly
.\setup-and-run.ps1 -StartOnly
```

## Linux VPS

Run **`vps-setup-and-run.sh`** (see below).

---

## Linux VPS (bash)

**Option A — copy script from this PC:**
```bash
# From your home PC (PowerShell):
scp d:\WORK\claudexhermes\claude-max-api-proxy\vps-setup-and-run.sh user@your-vps:~/

# On VPS:
bash ~/vps-setup-and-run.sh
```

**Option B — clone repo on VPS:**
```bash
git clone https://github.com/gutbits/claude-max-api-proxy.git ~/claude-max-api-proxy
cd ~/claude-max-api-proxy
bash vps-setup-and-run.sh
```

## What it does

1. Installs Node.js 20+ (if missing)
2. Installs `@anthropic-ai/claude-code` globally
3. Clones/updates this proxy repo
4. Runs `claude auth login` if needed (opens URL — use your phone/PC browser)
5. Patches `~/.hermes/config.yaml` → `provider: custom`, `base_url: http://localhost:3456/v1`
6. Starts the proxy in the background
7. Restarts Hermes gateway (if `hermes` is in PATH)

## Commands

| Action | Command |
|--------|---------|
| Full setup + start | `bash vps-setup-and-run.sh` |
| Start only (already set up) | `bash vps-setup-and-run.sh --start-only` |
| Re-login Claude | `bash vps-setup-and-run.sh --login-only` |
| Stop proxy | `bash vps-stop.sh` |

## Headless VPS login tip

When `claude auth login` prints a URL, open it on any device, sign in with Claude Max, paste the code back in the SSH session.

## This is per-machine

Your home PC and VPS each need their own proxy + Claude login. They do not sync.
