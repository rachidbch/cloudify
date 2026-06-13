#!/usr/bin/env bash
# hermes-model — Configure the LLM model/provider for a Hermes instance
#
# Config (~/.config/cloudify/pkgs/hermes-model.yaml):
#   HERMES_MODEL_PROVIDER: "deepseek"
#   HERMES_MODEL_NAME:     "deepseek/deepseek-v4-pro"
#   HERMES_MODEL_API_KEY:  "sk-..."

HERMES_CONFIG="$HOME/.hermes/config.yaml"
HERMES_ENV="$HOME/.hermes/.env"

HERMES_MODEL_PROVIDER="${HERMES_MODEL_PROVIDER:-}"
HERMES_MODEL_NAME="${HERMES_MODEL_NAME:-}"
HERMES_MODEL_API_KEY="${HERMES_MODEL_API_KEY:-}"

pkg_depends hermes

# --- Validate ---
[[ -z "$HERMES_MODEL_PROVIDER" ]] && \
    die "HERMES_MODEL_PROVIDER required. Set in ~/.config/cloudify/pkgs/hermes-model.yaml"

# --- Provider -> API key env var mapping ---
case "$HERMES_MODEL_PROVIDER" in
    deepseek)   API_KEY_VAR="DEEPSEEK_API_KEY" ;;
    openrouter) API_KEY_VAR="OPENROUTER_API_KEY" ;;
    novita)     API_KEY_VAR="NOVITA_API_KEY" ;;
    google)     API_KEY_VAR="GOOGLE_API_KEY" ;;
    custom)     API_KEY_VAR="CUSTOM_API_KEY" ;;
    *)          die "Unknown provider: $HERMES_MODEL_PROVIDER" ;;
esac

# --- Smart guard: skip if already configured ---
if [[ -f "$HERMES_CONFIG" ]]; then
    cur_provider=$(grep "^provider:" "$HERMES_CONFIG" 2>/dev/null | awk '{print $2}')
    cur_model=$(grep "^model:" "$HERMES_CONFIG" 2>/dev/null | awk '{print $2}')
    if [[ "$cur_provider" == "$HERMES_MODEL_PROVIDER" ]] && \
       [[ "$cur_model" == "$HERMES_MODEL_NAME" ]]; then
        log_info "Hermes already set to ${HERMES_MODEL_PROVIDER}/${HERMES_MODEL_NAME}. Skipping."
        return 0
    fi
fi

# --- Apply config ---
mkdir -p "$(dirname "$HERMES_CONFIG")"
cat > "$HERMES_CONFIG" << EOF
model: ${HERMES_MODEL_NAME}
provider: ${HERMES_MODEL_PROVIDER}
EOF

if [[ -n "$HERMES_MODEL_API_KEY" ]]; then
    if grep -q "^${API_KEY_VAR}=" "$HERMES_ENV" 2>/dev/null; then
        sed -i "s|^${API_KEY_VAR}=.*|${API_KEY_VAR}=${HERMES_MODEL_API_KEY}|" "$HERMES_ENV"
    else
        echo "${API_KEY_VAR}=${HERMES_MODEL_API_KEY}" >> "$HERMES_ENV"
    fi
fi

# --- Restart gateway ---
if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
    systemctl --user restart hermes-gateway
    sleep 2
    if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
        log_info "Gateway restarted."
    else
        log_warn "Gateway failed to restart. Check: journalctl --user -u hermes-gateway -n 20"
    fi
fi

msg "${GREEN}Hermes model: ${HERMES_MODEL_PROVIDER}/${HERMES_MODEL_NAME}${RESET}"
