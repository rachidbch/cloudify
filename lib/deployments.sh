#!/usr/bin/env bash
# lib/deployments.sh — Deployment-wide state (ADR-011)
# A deployment is a first-class cloud-global entity — an application across nodes.
# Context: per-shell CLOUDIFY_DEPLOYMENT env var (parallel-safe, no shared file).
# Precedence: caller-env > per-(node,pkg) > deployment-wide.

[[ -n "${_CLOUDIFY_DEPLOYMENTS_LOADED:-}" ]] && return 0
_CLOUDIFY_DEPLOYMENTS_LOADED=1

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

# cloudify_deployment_delete <id> — trash the deployment dir
cloudify_deployment_delete() {
    local id="$1"
    local dir
    dir=$(_cloudify_deployment_dir "$id")
    [[ -d "$dir" ]] || { log_info "Deployment '$id' does not exist."; return 0; }
    trash-put "$dir" 2>/dev/null || {
        # fallback: just rm if trash-cli unavailable
        rm -rf "$dir"
        log_warn "trash-put unavailable, removed directly."
    }
    log_info "Deployment '$id' deleted."
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

# --- Var management ---

# cloudify_vars_set <key> <value> — set a var in the current deployment
cloudify_vars_set() {
    local key="$1" value="$2"
    [[ -n "$key" ]] || die "Usage: cloudify vars set <key> <value>"
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Set it or create a deployment first."
    _cloudify_deployment_ensure "$id"
    local config; config=$(_cloudify_deployment_config "$id")
    # Remove existing key line if present
    local tmp; tmp=$(mktemp)
    grep -v "^${key}:" "$config" > "$tmp" 2>/dev/null || true
    echo "${key}: ${value}" >> "$tmp"
    mv "$tmp" "$config"
    chmod 600 "$config" 2>/dev/null || true
}

# cloudify_vars_delete <key> — remove a var from the current deployment
cloudify_vars_delete() {
    local key="$1"
    [[ -n "$key" ]] || die "Usage: cloudify vars delete <key>"
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set."
    local config; config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || { log_info "No config for deployment '$id'."; return 0; }
    local tmp; tmp=$(mktemp)
    grep -v "^${key}:" "$config" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$config"
    chmod 600 "$config" 2>/dev/null || true
}

# cloudify_vars_list [--json] — list all vars in the current deployment
cloudify_vars_list() {
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set."
    local config; config=$(_cloudify_deployment_config "$id")
    if [[ ! -f "$config" || ! -s "$config" ]]; then
        [[ "${1:-}" == "--json" ]] && echo "{}" || echo "(no vars)"
        return 0
    fi
    if [[ "${1:-}" == "--json" ]]; then
        # Emit simple JSON from flat YAML
        echo "{"
        local first=true
        while IFS=: read -r k v; do
            [[ -z "$k" ]] && continue
            k=$(echo "$k" | xargs)  # trim
            v=$(echo "$v" | xargs)
            $first && first=false || echo ","
            printf '  "%s": "%s"' "$k" "$v"
        done < "$config"
        echo
        echo "}"
    else
        cat "$config"
    fi
}

# cloudify_vars_show <key> — show a single var value
cloudify_vars_show() {
    local key="$1"
    [[ -n "$key" ]] || die "Usage: cloudify vars show <key>"
    local id="${CLOUDIFY_DEPLOYMENT:-}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set."
    local config; config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || { echo ""; return 0; }
    # Read value for key
    local val
    val=$(grep "^${key}:" "$config" 2>/dev/null | head -1 | sed "s/^${key}: *//")
    echo "${val:-}"
}

# --- Remote integration (called by lib/remote.sh) ---

# _cloudify_deployment_read_vars <id> — read deployment-wide vars, export them,
# return var names (one per line). Lowest priority; called AFTER per-pkg vars.
# No-op if deployment doesn't exist.
_cloudify_deployment_read_vars() {
    local id="$1"
    [[ -n "$id" ]] || return 0
    local config; config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || return 0
    local var_names=()
    local k v
    while IFS=: read -r k v; do
        [[ -z "$k" ]] && continue
        k=$(echo "$k" | xargs)
        v=$(echo "$v" | xargs)
        [[ -z "$k" ]] && continue
        # Export the var (lowest priority — _try_claim_env checks first)
        export "$k"="$v"
        var_names+=("$k")
    done < "$config"
    # Return names for envsubst allow-list
    printf '%s\n' "${var_names[@]}"
}
