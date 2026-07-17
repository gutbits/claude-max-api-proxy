#!/usr/bin/env bash
# One-shot: install Claude Max API proxy on a Linux VPS + point Hermes at it.
# Usage:  bash vps-setup-and-run.sh
#         bash vps-setup-and-run.sh --login-only   # just (re)auth Claude CLI

set -euo pipefail

REPO_URL="https://github.com/gutbits/claude-max-api-proxy.git"
INSTALL_DIR="${CLAUDE_MAX_PROXY_DIR:-$HOME/claude-max-api-proxy}"
PORT="${CLAUDE_MAX_PROXY_PORT:-3456}"
PID_FILE="$HOME/.claude-max-api-proxy.pid"
LOG_FILE="$HOME/.claude-max-api-proxy.log"
HERMES_CONFIG="$HOME/.hermes/config.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}▸${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
die()   { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. Install it and re-run."
}

stop_proxy() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "Stopping existing proxy (PID $pid)..."
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$PID_FILE"
  fi
  # Also kill anything else on our port
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti:"$PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" 2>/dev/null || true
  fi
}

install_node_if_needed() {
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -v | sed 's/v//' | cut -d. -f1)"
    [[ "$major" -ge 20 ]] || die "Node.js 20+ required (found $(node -v)). Install from https://nodejs.org or use nvm."
    return
  fi
  warn "Node.js not found. Attempting install via NodeSource (needs sudo)..."
  need_cmd curl
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
  need_cmd node
}

install_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    info "Claude CLI already installed: $(claude --version 2>/dev/null || echo ok)"
    return
  fi
  info "Installing Claude Code CLI..."
  sudo npm install -g @anthropic-ai/claude-code
  need_cmd claude
}

clone_or_update_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating proxy at $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --ff-only
  else
    info "Cloning proxy to $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
  cd "$INSTALL_DIR"
  info "Installing npm dependencies..."
  npm install
  info "Building..."
  npm run build
}

ensure_claude_login() {
  if claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
    info "Claude CLI already logged in."
    claude auth status 2>/dev/null | grep -E 'subscriptionType|email' || true
    return
  fi
  warn "Claude CLI not logged in."
  echo ""
  echo "  You need to sign in with your Claude Max account."
  echo "  If this is a headless VPS, the URL will print below — open it on your phone/PC."
  echo ""
  claude auth login
}

patch_hermes_config() {
  if [[ ! -f "$HERMES_CONFIG" ]]; then
    warn "Hermes config not found at $HERMES_CONFIG — skipping Hermes patch."
    warn "After installing Hermes, set provider: custom and base_url: http://localhost:${PORT}/v1"
    return
  fi

  info "Patching Hermes config ($HERMES_CONFIG)..."
  cp "$HERMES_CONFIG" "${HERMES_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

  python3 - "$HERMES_CONFIG" "$PORT" <<'PY'
import re, sys, pathlib

path, port = sys.argv[1], sys.argv[2]
base_url = f"http://localhost:{port}/v1"
text = pathlib.Path(path).read_text()

# model block: set provider, base_url, default
text = re.sub(r"(?m)^(\s*provider:\s*).*$", rf"\1custom", text, count=1)
text = re.sub(r"(?m)^(\s*base_url:\s*).*$", rf"\1{base_url}", text, count=1)
text = re.sub(r"(?m)^(\s*default:\s*).*$", r"\1claude-sonnet-5", text, count=1)

# ensure api_key line exists under model (optional for local)
if "api_key:" not in text.split("model:")[1].split("\n\n")[0]:
    text = re.sub(r"(?m)^(\s*base_url:\s*.*)$", rf"\1\n  api_key: not-needed", text, count=1)

snippet = f"""custom_providers:
  - name: claude-max-proxy
    base_url: {base_url}
"""
if "custom_providers:" not in text:
    # insert after model block (before next top-level key)
    text = re.sub(
        r"(?m)(^model:\n(?:  .+\n)+)",
        r"\1" + snippet,
        text,
        count=1,
    )

pathlib.Path(path).write_text(text)
print(f"  → provider: custom, base_url: {base_url}, model: claude-sonnet-5")
PY
}

start_proxy() {
  cd "$INSTALL_DIR"
  stop_proxy
  info "Starting proxy on http://127.0.0.1:${PORT} (log: $LOG_FILE)..."
  nohup node dist/server/standalone.js "$PORT" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 2

  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
    info "Proxy is up ✓  http://127.0.0.1:${PORT}/v1"
  else
    die "Proxy failed to start. Check $LOG_FILE"
  fi
}

restart_hermes_gateway() {
  if ! command -v hermes >/dev/null 2>&1; then
    warn "hermes CLI not in PATH — restart gateway manually after setup."
    return
  fi
  info "Restarting Hermes gateway..."
  hermes gateway stop 2>/dev/null || true
  if hermes gateway status 2>/dev/null | grep -q running; then
    warn "Gateway still running; you may need: hermes gateway run"
  else
    nohup hermes gateway run >>"$HOME/.hermes/gateway.log" 2>&1 &
    sleep 2
    hermes gateway status 2>/dev/null || true
  fi
}

print_done() {
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Claude Max proxy ready on this VPS${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Proxy:    http://127.0.0.1:${PORT}/v1"
  echo "  Models:   claude-sonnet-5, claude-fable-5, claude-opus-4-8"
  echo "  Log:      $LOG_FILE"
  echo "  Stop:     bash $(basename "$0" | sed 's/setup-and-run/stop/')  (or kill \$(cat $PID_FILE))"
  echo ""
  echo "  Hermes:   provider custom → localhost:${PORT}"
  echo "  Switch:   /model custom:claude-max-proxy:claude-opus-4"
  echo ""
}

main() {
  echo ""
  echo "  Claude Max API Proxy — VPS setup"
  echo "  ================================="
  echo ""

  if [[ "${1:-}" == "--login-only" ]]; then
    need_cmd claude
    ensure_claude_login
    exit 0
  fi

  if [[ "${1:-}" == "--start-only" ]]; then
    [[ -d "$INSTALL_DIR/dist" ]] || die "Not installed yet. Run without flags first."
    start_proxy
    print_done
    exit 0
  fi

  need_cmd git
  need_cmd curl
  install_node_if_needed
  install_claude_cli
  clone_or_update_repo
  ensure_claude_login
  patch_hermes_config
  start_proxy
  restart_hermes_gateway
  print_done
}

main "$@"
