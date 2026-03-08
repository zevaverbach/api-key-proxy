# api-key-proxy

Zero-dependency Node.js reverse proxy that injects API keys into upstream
requests. Designed to keep LLM API keys out of reach of AI agents that have
shell access.

## How it works

1. Reads a JSON routes config — one listener per upstream API
2. Reads API keys from environment variables at startup
3. **Immediately scrubs keys from `process.env`** — they live only in closures
4. Proxies requests: strips any incoming `Authorization` header, injects the real key

The AI agent talks to `localhost:PORT` and never sees the key.

## Usage

```bash
MOONSHOT_API_KEY=sk-... OPENAI_API_KEY=sk-... \
  node proxy.js routes.json
```

## Routes config

```json
[
  {
    "name": "moonshot",
    "port": 18792,
    "upstream": "https://api.moonshot.ai",
    "keyEnv": "MOONSHOT_API_KEY"
  },
  {
    "name": "openai",
    "port": 18793,
    "upstream": "https://api.openai.com",
    "keyEnv": "OPENAI_API_KEY"
  }
]
```

| Field | Description |
|---|---|
| `name` | Label for logs (optional, defaults to `upstream`) |
| `port` | Local port to listen on (`127.0.0.1` only) |
| `upstream` | Target API base URL |
| `keyEnv` | Environment variable name holding the API key |

## Security model

| Layer | Protected? |
|---|---|
| `printenv` / child process env | ✅ Keys deleted from `process.env` after read |
| `/proc/PID/environ` | ⚠️ Shows initial env (Linux kernel snapshot). Only same-user or root can read. |
| Disk | ✅ No keys on disk — fetched from secret manager at startup |
| Network | ✅ Listeners bind to `127.0.0.1` only |

For maximum isolation, run the proxy as a separate systemd unit from the
application that consumes it.

## Example: systemd + Bitwarden Secrets Manager

See [the-dude-kit/OPENCLAW-SECRETS-RUNBOOK.md](https://github.com/zevaverbach/the-dude-kit)
for a complete setup using `bws` (Bitwarden Secrets Manager CLI) to inject keys
at service startup.

## Requirements

- Node.js >= 18
- No dependencies
