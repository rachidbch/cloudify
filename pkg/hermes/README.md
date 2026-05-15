# hermes

[Hermes Agent](https://hermes-agent.nousresearch.com/) by Nous Research — an autonomous AI agent with terminal access, file operations, web search, memory, and extensible skills.

## Install

```bash
cloudify install hermes
```

Works out of the box — auto-configured with [KeylessAI](https://keylessai.thryx.workers.dev) (free, no account, no API key). Chat immediately:

```bash
hermes
```

## Switching Providers

Run `hermes model` to switch to a paid provider (Nous Portal, OpenRouter, Anthropic, etc.). The KeylessAI default is overwritten — no conflict.

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
