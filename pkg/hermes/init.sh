#!/usr/bin/env bash
# hermes — Nous Research AI agent
pkg_depends git

curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup

# The installer writes a bash wrapper to /usr/local/lib/hermes-agent/venv/bin/hermes
# that execs itself in an infinite loop. Restore the correct Python entry point.
HERMES_VENV_BIN="/usr/local/lib/hermes-agent/venv/bin/hermes"
if [[ -f "$HERMES_VENV_BIN" ]] && ! head -1 "$HERMES_VENV_BIN" | grep -q python; then
    cat > "$HERMES_VENV_BIN" << 'PYEOF'
#!/usr/local/lib/hermes-agent/venv/bin/python3
# -*- coding: utf-8 -*-
import sys
from hermes_cli.main import main
if __name__ == "__main__":
    if sys.argv[0].endswith("-script.pyw"):
        sys.argv[0] = sys.argv[0][:-11]
    elif sys.argv[0].endswith(".exe"):
        sys.argv[0] = sys.argv[0][:-4]
    sys.exit(main())
PYEOF
    chmod +x "$HERMES_VENV_BIN"
fi

# --- Auto-configure KeylessAI as default LLM provider ---
# Free, keyless, no-account OpenAI-compatible endpoint.
# Only written if no provider is already configured (idempotent).
HERMES_DIR="$HOME/.hermes"
HERMES_CONFIG="$HERMES_DIR/config.yaml"
mkdir -p "$HERMES_DIR"
if [[ ! -f "$HERMES_CONFIG" ]] || ! grep -q "^provider:" "$HERMES_CONFIG"; then
    cat > "$HERMES_CONFIG" << 'KEYLESSEOF'
model: openai-fast
provider: custom
base_url: https://keylessai.thryx.workers.dev/v1
KEYLESSEOF
    msg "${GREEN}Hermes auto-configured with KeylessAI (free, no account needed).${RESET}"
    msg "Run 'hermes model' anytime to switch to a paid provider."
fi
