#!/usr/bin/env bash
# lib/deployments.sh — Deployment-wide state (ADR-011)
# A deployment is a first-class cloud-global entity — an application across nodes.
# Context: per-shell CLOUDIFY_DEPLOYMENT env var (parallel-safe, no shared file).
# Precedence: caller-env > per-(node,pkg) > deployment-wide.

[[ -n "${_CLOUDIFY_DEPLOYMENTS_LOADED:-}" ]] && return 0
_CLOUDIFY_DEPLOYMENTS_LOADED=1

# Deployment-store var read/write helpers + legacy aliases live in lib/vars.sh.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vars.sh"

CLOUDIFY_DEPLOYMENTS_DIR="${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/deployments"

# --- Internal helpers ---

# _cloudify_deployment_dir <id> — canonical path to deployment dir. Rejects unsafe ids.
_cloudify_deployment_dir() {
    local id="$1"
    [[ -z "$id" ]] && die "Deployment id is required"
    [[ "$id" == *"/"* || "$id" == ".." || "$id" == "." ]] && die "Invalid deployment id: $id (no path separators)"
    echo "${CLOUDIFY_DEPLOYMENTS_DIR}/${id}"
}

# _cloudify_deployment_config <id> — path to deployment config.yaml
_cloudify_deployment_config() {
    echo "$(_cloudify_deployment_dir "$1")/config.yaml"
}

# _cloudify_deployment_ensure <id> — create deployment dir + empty config.yaml if absent. Idempotent.
_cloudify_deployment_ensure() {
    local id="$1"
    local dir config
    dir=$(_cloudify_deployment_dir "$id")
    config=$(_cloudify_deployment_config "$id")
    mkdir -p "$dir"
    [[ -f "$config" ]] || touch "$config"
    chmod 700 "$dir"
    chmod 600 "$config" 2>/dev/null || true
}

# --- Public API (called by router) ---

# cloudify_deployment_create <id> — idempotent create
cloudify_deployment_create() {
    local id="$1"
    local dir config
    dir=$(_cloudify_deployment_dir "$id")
    config=$(_cloudify_deployment_config "$id")
    if [[ -d "$dir" ]]; then
        log_info "Deployment '$id' already exists."
        return 0
    fi
    mkdir -p "$dir"
    touch "$config"
    chmod 700 "$dir"
    chmod 600 "$config" 2>/dev/null || true
    log_info "Deployment '$id' created ($dir)."
    echo "To use: export CLOUDIFY_DEPLOYMENT=$id"
}

# cloudify_deployment_delete <id> — trash the deployment dir + its registry records
cloudify_deployment_delete() {
    local id="$1"
    local dir
    dir=$(_cloudify_deployment_dir "$id")
    if [[ -d "$dir" ]]; then
        trash-put "$dir" 2>/dev/null || {
            # fallback: just rm if trash-cli unavailable
            rm -rf "$dir"
            log_warn "trash-put unavailable, removed directly."
        }
        log_info "Deployment '$id' deleted."
    else
        log_info "Deployment '$id' does not exist."
    fi
    # Records live outside the deployment store (lib/registry.sh); clean them too
    # so a deleted deployment leaves nothing behind. Indexed so the module can be
    # absent when only lib/deployments.sh is sourced (tests, standalone reuse).
    if declare -F cloudify_registry_delete_deployment >/dev/null; then
        cloudify_registry_delete_deployment "$id"
    fi
    return 0
}

# cloudify_deployment_list — list all deployment ids
cloudify_deployment_list() {
    local d
    if [[ ! -d "$CLOUDIFY_DEPLOYMENTS_DIR" ]]; then
        echo "(no deployments)"
        return 0
    fi
    local count=0
    for d in "$CLOUDIFY_DEPLOYMENTS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local name; name=$(basename "$d")
        echo "$name"
        count=$((count + 1))
    done
    [[ $count -gt 0 ]] || echo "(no deployments)"
}

# cloudify_deployment_use <id> — print the export command (can't set parent shell env)
cloudify_deployment_use() {
    local id="$1"
    local dir
    dir=$(_cloudify_deployment_dir "$id")
    [[ -d "$dir" ]] || { log_error "Deployment '$id' not found. Create it first: cloudify deployment create $id"; return 1; }
    echo "export CLOUDIFY_DEPLOYMENT=$id"
    echo "# Run: eval \"\$(cloudify deployment use $id)\""
}

# --- Var management lives in lib/vars.sh (canonical) + legacy aliases ---
