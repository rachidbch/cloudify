# hermes

[Hermes Agent](https://hermes-agent.nousresearch.com/) by Nous Research — an autonomous AI agent with terminal access, file operations, web search, memory, and extensible skills.

## Install

```bash
cloudify install hermes
hermes setup
```

The install uses `--skip-setup`. Run `hermes setup` interactively to configure your model provider and API key.

## Configuration

Hermes config lives in `~/.hermes/`:

- `config.yaml` — model, provider, base_url
- `.env` — API server settings (API_SERVER_ENABLED, API_SERVER_KEY, API_SERVER_PORT, API_SERVER_HOST)

## API Server

Hermes exposes an OpenAI-compatible API server (`/v1/chat/completions`, `/v1/models`). The `hermes-openwebui` package enables and configures this automatically.

Manual setup:

```bash
hermes config set API_SERVER_ENABLED true
hermes config set API_SERVER_KEY your-secret-key
hermes gateway
```

## Integrations

- **hermes-openwebui** — connect to Open WebUI as a chat frontend
- **hermes-signal** — connect to Signal messenger
