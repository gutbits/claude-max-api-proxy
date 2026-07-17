# Claude Max API Proxy

**Use your Claude Max subscription with any OpenAI-compatible client — no separate API costs.**

Wraps the Claude Code CLI as a subprocess and exposes an OpenAI-compatible HTTP API so tools like Hermes, Continue.dev, or any OpenAI client can use your Claude Max subscription instead of pay-per-token API billing.

## Why This Exists

| Approach | Cost | Limitation |
|----------|------|------------|
| Claude API | ~$15/M input, ~$75/M output tokens | Pay per use |
| Claude Max | Flat monthly | OAuth blocked for third-party API use |
| **This Proxy** | $0 extra (uses Max subscription) | Routes through CLI |

Anthropic blocks OAuth tokens from third-party API clients. The Claude Code CLI can use OAuth. This proxy bridges that gap.

## Windows + Hermes (one-liner)

See **[README-WINDOWS.md](README-WINDOWS.md)** for full Windows/VPS instructions. Quick copy-paste:

```powershell
Remove-Item $env:USERPROFILE\install.ps1 -Force -EA 0; iwr "https://raw.githubusercontent.com/gutbits/claude-max-api-proxy/main/install.ps1" -OutFile $env:USERPROFILE\install.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\install.ps1
```

Restart proxy + Hermes gateway after setup:

```powershell
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\install.ps1 -RestartAll
```

## How It Works

```
Your App (Hermes, Continue.dev, etc.)
         ↓
    HTTP Request (OpenAI format)
         ↓
   Claude Max API Proxy (this project)
         ↓
   Claude Code CLI (subprocess)
         ↓
   OAuth Token (from Max subscription)
         ↓
   Anthropic API
         ↓
   Response → OpenAI format → Your App
```

## Features

- **OpenAI-compatible API** — Works with any client that supports OpenAI's API format
- **Streaming support** — Real-time token streaming via Server-Sent Events
- **Multiple models** — Fable 5, Opus 4.8, Sonnet 5, Haiku 4.5 + aliases
- **Hermes-ready** — One-click Windows installer patches Hermes config
- **Content block handling** — Proper text block separators for multi-block responses
- **Session management** — Maintains conversation context via session IDs
- **Zero configuration** — Uses existing Claude CLI authentication
- **Secure by design** — Uses `spawn()` to prevent shell injection

## Prerequisites

1. **Claude Max subscription** — [Subscribe here](https://claude.ai)
2. **Claude Code CLI** installed and authenticated:
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude auth login
   ```

## Installation

```bash
# Clone the repository
git clone https://github.com/gutbits/claude-max-api-proxy.git
cd claude-max-api-proxy

# Install dependencies
npm install

# Build
npm run build
```

## Usage

### Start the server

```bash
npm start
# or
node dist/server/standalone.js
```

The server runs at `http://localhost:3456` by default. Pass a custom port as an argument:

```bash
node dist/server/standalone.js 8080
```

### Test it

```bash
# Health check
curl http://localhost:3456/health

# List models
curl http://localhost:3456/v1/models

# Chat completion (non-streaming)
curl -X POST http://localhost:3456/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-5",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Chat completion (streaming)
curl -N -X POST http://localhost:3456/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-5",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/v1/models` | GET | List available models |
| `/v1/chat/completions` | POST | Chat completions (streaming & non-streaming) |

## Available Models

| Model ID | Alias | Notes |
|----------|-------|-------|
| `claude-fable-5` | `fable` | Fable 5 — frontier agentic |
| `claude-opus-4-8` | `opus` | Opus 4.8 |
| `claude-sonnet-5` | `sonnet` | Sonnet 5 (default) |
| `claude-sonnet-4-6` | — | Sonnet 4.6 |
| `claude-haiku-4-5` | `haiku` | Haiku 4.5 |

Also advertised: `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-4-5`, `claude-sonnet-4`, plus `-max` aliases. Unknown models default to Opus.

## Configuration with Popular Tools

### Hermes

Use the Windows one-liner above, or set in Hermes config:

```yaml
model:
  provider: custom
  base_url: http://localhost:3456/v1
  default: claude-sonnet-5
  api_key: not-needed
```

Then switch models in chat:

```
/model custom:claude-max-proxy:claude-sonnet-5
/model custom:claude-max-proxy:claude-fable-5
/model custom:claude-max-proxy:claude-opus-4-8
```

### Continue.dev

Add to your Continue config:

```json
{
  "models": [{
    "title": "Claude (Max)",
    "provider": "openai",
    "model": "claude-sonnet-5",
    "apiBase": "http://localhost:3456/v1",
    "apiKey": "not-needed"
  }]
}
```

### Generic OpenAI Client (Python)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:3456/v1",
    api_key="not-needed"  # Any value works
)

response = client.chat.completions.create(
    model="claude-sonnet-5",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

## Auto-Start on macOS

The proxy can run as a macOS LaunchAgent on port 3456.

**Plist location:** `~/Library/LaunchAgents/com.openclaw.claude-max-proxy.plist`

```bash
# Start the service
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.claude-max-proxy.plist

# Restart
launchctl kickstart -k gui/$(id -u)/com.openclaw.claude-max-proxy

# Stop
launchctl bootout gui/$(id -u)/com.openclaw.claude-max-proxy

# Check status
launchctl list com.openclaw.claude-max-proxy
```

## Architecture

```
src/
├── types/
│   ├── claude-cli.ts      # Claude CLI JSON streaming types + type guards
│   └── openai.ts          # OpenAI API types (including tool calls)
├── adapter/
│   ├── openai-to-cli.ts   # Convert OpenAI requests → CLI format
│   └── cli-to-openai.ts   # Convert CLI responses → OpenAI format
├── subprocess/
│   └── manager.ts         # Claude CLI subprocess manager
├── session/
│   └── manager.ts         # Session ID mapping
├── server/
│   ├── index.ts           # Express server setup
│   ├── routes.ts          # API route handlers
│   └── standalone.ts      # Entry point
└── index.ts               # Package exports
```

## Security

- Uses Node.js `spawn()` instead of shell execution to prevent injection attacks
- No API keys stored or transmitted by this proxy
- All authentication handled by Claude CLI's secure keychain storage
- Prompts passed as CLI arguments, not through shell interpretation

## Troubleshooting

### "Claude CLI not found"

Install and authenticate the CLI:
```bash
npm install -g @anthropic-ai/claude-code
claude auth login
```

### Streaming returns immediately with no content

Ensure you're using `-N` flag with curl (disables buffering):
```bash
curl -N -X POST http://localhost:3456/v1/chat/completions ...
```

### Server won't start

Check that the Claude CLI is in your PATH:
```bash
which claude
```

## License

MIT
