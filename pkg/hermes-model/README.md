# hermes-model

Configure the LLM provider and model for a Hermes agent.

## Usage

```bash
# 1. Set config in ~/.config/cloudify/pkgs/hermes-model.yaml:
cat > ~/.config/cloudify/pkgs/hermes-model.yaml << 'EOF'
HERMES_MODEL_PROVIDER: "deepseek"
HERMES_MODEL_NAME: "deepseek/deepseek-v4-pro"
HERMES_MODEL_API_KEY: "sk-..."
EOF

# 2. Install (local or remote):
cloudify install hermes-model
cloudify --on <host> install hermes-model
```

The recipe writes `~/.hermes/config.yaml` and `~/.hermes/.env`, then restarts the gateway.

## Configuration

Set these in `~/.config/cloudify/pkgs/hermes-model.yaml`:

| Var | Required | Description |
|-----|----------|-------------|
| `HERMES_MODEL_PROVIDER` | yes | Provider: `deepseek`, `openrouter`, `novita`, `google`, `custom` |
| `HERMES_MODEL_NAME` | yes | Model identifier, e.g. `deepseek/deepseek-v4-pro` |
| `HERMES_MODEL_API_KEY` | no | API key. If empty, key is not written (provider may already have one) |

Provider → env var mapping (written to `~/.hermes/.env`):

| Provider | Env var |
|----------|---------|
| `deepseek` | `DEEPSEEK_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |
| `novita` | `NOVITA_API_KEY` |
| `google` | `GOOGLE_API_KEY` |
| `custom` | `CUSTOM_API_KEY` |

## Idempotency

The recipe checks if the existing `~/.hermes/config.yaml` already has the requested provider+model. If they match, it skips. To change model/provider, just update the yaml and re-run — the smart guard detects the mismatch and applies the change.

No `--force` / `--clear-data` needed for model changes.

## Restart

After applying config, the recipe restarts `hermes-gateway` (user systemd service).
