#!/usr/bin/env bash
# lib/vars.sh — five-source var helpers (ADR-007 + ADR-011)
#
# One read/write helper per var source. The collector
# (_cloudify_pkg_remote_vars, lib/remote.sh) is a thin precedence walker over
# these helpers. Target precedence (weakest -> strongest):
#   recipe default < global < package < deployment < caller env
#
# Readers export resolved values into the CURRENT shell (their exports are the
# value channel) and must be invoked with a redirect, never `$(...)` (I1).
# A reader called with a claim ledger set (_CLOUDIFY_VARS_LEDGER) is
# non-clobbering: the first source to claim a name wins, so the walker order
# alone decides precedence.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_VARS_LOADED:-}" ]] && return 0
_CLOUDIFY_VARS_LOADED=1

# Secret backends (lib/secrets/*.sh) are needed by the value resolver below.
if [[ -z "${_CLOUDIFY_SECRETS_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.sh"
fi

# Framework-owned names a file store must never set (L5): a rogue
# `DEBUG: true`, `CLOUDIFY_REMOTE_USER: evil` or `CLOUDIFY_FORCE: true` would
# retarget execution or flip the control channel (dispatch flags, target id).
_CLOUDIFY_VARS_RESERVED=(
    CLOUDIFY_REMOTE_USER
    CLOUDIFY_REMOTE_PWD
    DEBUG
    CLOUDIFY_BOOTSTRAP_URL
    CLOUDIFY_UPDATE_DELAY
    CLOUDIFY_FORCE
    CLOUDIFY_NO_VERIFY
    CLOUDIFY_DEPLOYMENT
    CLOUDIFY_NODE
    CLOUDIFY_INSTANCE
)

_cloudify_vars_reserved() {
    local name="$1" r
    for r in "${_CLOUDIFY_VARS_RESERVED[@]}"; do
        [[ "$name" == "$r" ]] && return 0
    done
    return 1
}

# Claim a name in the walker ledger. Returns 1 when a stronger source already
# claimed it. With no ledger set, always returns 0 (legacy direct-call mode).
_cloudify_vars_claim() {
    local name="$1"
    [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" ]] || return 0
    if grep -qx "$name" "$_CLOUDIFY_VARS_LEDGER" 2>/dev/null; then
        return 1
    fi
    echo "$name" >> "$_CLOUDIFY_VARS_LEDGER"
    return 0
}

_cloudify_vars_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Resolve a raw value to its literal form (R4).
#   plain      -> identity
#   @@foo      -> @foo (escape a literal leading @)
#   @b:locator -> cloudify_secret_backend_<b> locator
# Prints the resolved value; returns non-zero on malformed reference, unknown
# backend, or backend failure. Callers must die on non-zero (never forward empty).
_cloudify_resolve_var_value() {
    local name="$1" raw="$2" ref backend locator
    if [[ "$raw" == @@* ]]; then
        printf '%s' "${raw#@}"
        return 0
    fi
    if [[ "$raw" != @* ]]; then
        printf '%s' "$raw"
        return 0
    fi
    ref="${raw#@}"
    if [[ "$ref" != *:* || "$ref" == :* || "$ref" == *: ]]; then
        log_error "Var $name: malformed secret reference (expected @<backend>:<locator> or @@literal)."
        return 1
    fi
    backend="${ref%%:*}"
    locator="${ref#*:}"
    cloudify_secret_resolve "$name" "$backend" "$locator"
}

# Export one value from a file store, honouring the ledger and the reserved guard.
# _cloudify_vars_emit <name> <raw> [no-clobber] [print]
_cloudify_vars_emit() {
    local name="$1" raw="$2" mode="${3:-}" print="${4:-}"
    if _cloudify_vars_reserved "$name"; then
        log_warn "Var $name is framework-owned — ignored from file store."
        return 0
    fi
    _cloudify_vars_claim "$name" || return 0
    [[ -n "$print" ]] && echo "$name"
    # Non-clobbering only matters in walker mode (ledger set): the caller env is
    # the strongest source and file reads must not overwrite it.
    if [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" && "$mode" == "no-clobber" && -n "${!name:-}" ]]; then
        return 0
    fi
    local value
    if ! value=$(_cloudify_resolve_var_value "$name" "$raw"); then
        die "Var $name: cannot resolve value — refusing to forward an empty value."
    fi
    export "$name"="$value"
}

# Parse a flat `KEY: value` file and export each value.
# _cloudify_load_yaml_vars <file> [no-clobber] [print]
# - no ledger: unconditional export (verify path, package-api.sh).
# - ledger set + no-clobber: first source to claim a name wins (walker).
function _cloudify_load_yaml_vars() {
    local file="$1"
    local mode="${2:-}"
    local print="${3:-}"
    [[ -f "$file" ]] || return 0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local key="${line%%:*}"
        local value="${line#*:}"
        key="${key## }"; key="${key%% }"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue

        value="${value## }"; value="${value%% }"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"

        _cloudify_vars_emit "$key" "$value" "$mode" "$print"
    done < "$file"
}

# --- path helpers ---

cloudify_vars_config_dir() {
    echo "${CLOUDIFY_CREDENTIALS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cloudify}"
}

cloudify_vars_global_file() {
    echo "$(cloudify_vars_config_dir)/remote-vars.yaml"
}

cloudify_vars_pkg_file() {
    echo "$(cloudify_vars_config_dir)/pkgs/$1.yaml"
}

# --- file writes (0700 dir / 0600 file, I10) ---

_cloudify_vars_chmod() {
    local file="$1"
    chmod 700 "$(dirname "$file")" 2>/dev/null || true
    chmod 600 "$file" 2>/dev/null || true
}

# _cloudify_vars_file_set <file> <key> <value> [strict]
# strict=1 enforces uppercase keys (global/pkg readers are uppercase-only).
# A multi-line value cannot live on one `KEY: value` line, so it is stored as
# a `@base64:` reference the flat reader + resolver round-trip (R6/L4).
# A value starting with `@` must be a valid reference or the `@@` escape (R1b-7).
_cloudify_vars_file_set() {
    local file="$1" key="$2" value="$3" strict="${4:-}" _ref _backend
    [[ -n "$key" ]] || die "Usage: cloudify vars set <key> <value>"
    if [[ -n "$strict" ]]; then
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Invalid var name: $key (use UPPERCASE_WITH_UNDERSCORES)"
    else
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid var name: $key"
    fi
    if [[ "$value" == @* && "$value" != @@* ]]; then
        _ref="${value#@}"
        if [[ "$_ref" != *:* || "$_ref" == :* || "$_ref" == *: ]]; then
            die "Var $key: value starts with '@' — use '@@' for a literal leading '@' or '@<backend>:<locator>' for a secret reference."
        fi
        _backend="${_ref%%:*}"
        declare -F "cloudify_secret_backend_$_backend" >/dev/null 2>&1 || die "Var $key: unknown secret backend '$_backend'."
    fi
    if [[ "$value" == *$'\n'* ]]; then
        value="@base64:$(printf '%s' "$value" | base64 -w0)"
    fi
    mkdir -p "$(dirname "$file")"
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}:" "$file" > "$tmp" 2>/dev/null || true
    printf '%s: %s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
    _cloudify_vars_chmod "$file"
}

# --- global source ---

cloudify_vars_global_read() {
    local file="${1:-$(cloudify_vars_global_file)}"
    local print=""
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1
    _cloudify_load_yaml_vars "$file" no-clobber "$print"
}

cloudify_vars_global_write() {
    _cloudify_vars_file_set "$(cloudify_vars_global_file)" "$1" "$2" 1
}

# --- package source ---

# cloudify_vars_pkg_read <pkg> [yaml-file]
# Declared names come from pkg/<pkg>/.remote-vars (values from caller env);
# values come from the per-package yaml. Declared names are recorded for the
# walker's deferred warn (L12) via _CLOUDIFY_VARS_DECLARED.
cloudify_vars_pkg_read() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 0
    local print=""
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1

    local decl="$CLOUDIFY_DIR/pkg/${pkg}/.remote-vars"
    if [[ -f "$decl" ]]; then
        local name kind mirror
        while IFS= read -r line; do
            line="$(_cloudify_vars_trim "$line")"
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
                name="${BASH_REMATCH[1]}"; mirror="${BASH_REMATCH[2]}"
                if [[ -n "$mirror" ]]; then kind=defaulted; else kind=optional; fi
            elif [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)$ ]]; then
                name="${BASH_REMATCH[1]}"; kind=required
            else
                continue
            fi
            if [[ -n "${_CLOUDIFY_VARS_DECLARED:-}" ]]; then
                printf '%s\t%s\t%s\n' "$name" "$pkg" "$kind" >> "$_CLOUDIFY_VARS_DECLARED"
            fi
            if [[ -n "${!name:-}" ]]; then
                _cloudify_vars_claim "$name" || continue
                [[ -n "$print" ]] && echo "$name"
                export "$name"="${!name}"
            fi
        done < "$decl"
    fi

    _cloudify_load_yaml_vars "${2:-$(cloudify_vars_pkg_file "$pkg")}" no-clobber "$print"
}

cloudify_vars_pkg_write() {
    local pkg="$1"
    [[ -n "$pkg" ]] || die "Usage: cloudify vars set <key> <value> --pkg <name>"
    _cloudify_vars_file_set "$(cloudify_vars_pkg_file "$pkg")" "$2" "$3" 1
}

# --- deployment source ---

cloudify_vars_deployment_read() {
    local id="${1:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$id" ]] || return 0
    local config
    config=$(_cloudify_deployment_config "$id")
    [[ -f "$config" ]] || return 0
    local print=""
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1

    local line key raw
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" == *:* ]] || continue
        key="${line%%:*}"; raw="${line#*:}"
        key="${key## }"; key="${key%% }"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        raw=$(_cloudify_vars_trim "$raw")
        _cloudify_vars_emit "$key" "$raw" no-clobber "$print"
    done < "$config"
}

cloudify_vars_deployment_write() {
    local key="$1" value="$2" id="${3:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$key" ]] || die "Usage: cloudify vars set <key> <value>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id> or 'eval \"\$(cloudify deployment use <id>)\"'."
    _cloudify_deployment_ensure "$id"
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$id")" "$key" "$value"
}

cloudify_vars_deployment_delete() {
    local key="$1" id="${2:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$key" ]] || die "Usage: cloudify vars delete <key>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id> or 'eval \"\$(cloudify deployment use <id>)\"'."
    _cloudify_vars_store_delete "$(_cloudify_deployment_config "$id")" "$key"
}

cloudify_vars_deployment_list() {
    local mode="" id
    if [[ "${1:-}" == "--json" ]]; then mode="--json"; shift; fi
    id="${1:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id> or 'eval \"\$(cloudify deployment use <id>)\"'."
    _cloudify_vars_store_list "$(_cloudify_deployment_config "$id")" "$mode"
}

cloudify_vars_deployment_show() {
    local key="$1" id="${2:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$key" ]] || die "Usage: cloudify vars show <key>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id> or 'eval \"\$(cloudify deployment use <id>)\"'."
    _cloudify_vars_store_get "$(_cloudify_deployment_config "$id")" "$key"
}

# --- env source (strongest; candidate names only — no ambient var enters) ---

# cloudify_vars_env_read <name...> — claim names present in the caller env.
cloudify_vars_env_read() {
    local print="" name
    [[ -z "${_CLOUDIFY_VARS_LEDGER:-}" ]] && print=1
    for name in "$@"; do
        [[ -n "$name" ]] || continue
        [[ -n "${!name:-}" ]] || continue
        _cloudify_vars_claim "$name" || continue
        [[ -n "$print" ]] && echo "$name"
        export "$name"="${!name}"
    done
}

# --- generic flat-store ops + scope/arg helpers (branch 1b) ---

_cloudify_vars_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s=$(printf '%s' "$s" | tr -d '\000-\037')
    printf '%s' "$s"
}

# _cloudify_vars_is_secret_name <name> — the masking heuristic (name-based).
_cloudify_vars_is_secret_name() {
    [[ "$1" =~ (PASSWORD|TOKEN|SECRET|KEY) ]]
}

# _cloudify_vars_store_get <file> <key> — raw stored value; missing key = empty, rc 0.
_cloudify_vars_store_get() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 0
    line=$(grep "^${key}:" "$file" 2>/dev/null | head -1) || true
    [[ -n "$line" ]] || return 0
    printf '%s\n' "$(printf '%s' "$line" | sed "s/^${key}: *//")"
}

# _cloudify_vars_store_list <file> [--json] [mask] — raw by default; mask=1 replaces
# secret-looking values with *** (the router passes it unless --reveal).
_cloudify_vars_store_list() {
    local file="$1" mode="${2:-}" mask="${3:-}" line k v kt first=true
    if [[ ! -f "$file" || ! -s "$file" ]]; then
        if [[ "$mode" == "--json" ]]; then echo "{}"; else echo "(no vars)"; fi
        return 0
    fi
    if [[ "$mode" == "--json" ]]; then
        echo "{"
        while IFS= read -r line; do
            line="$(_cloudify_vars_trim "$line")"
            [[ -z "$line" || "$line" == \#* || "$line" != *:* ]] && continue
            k="$(_cloudify_vars_trim "${line%%:*}")"
            v="$(_cloudify_vars_trim "${line#*:}")"
            [[ -n "$k" ]] || continue
            [[ -n "$mask" ]] && _cloudify_vars_is_secret_name "$k" && v="***"
            if $first; then first=false; else echo ","; fi
            printf '  "%s": "%s"' "$(_cloudify_vars_json_escape "$k")" "$(_cloudify_vars_json_escape "$v")"
        done < "$file"
        echo
        echo "}"
    elif [[ -n "$mask" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == *:* && "$line" != \#* ]]; then
                kt="$(_cloudify_vars_trim "${line%%:*}")"
                if _cloudify_vars_is_secret_name "$kt"; then printf '%s: ***\n' "$kt"; continue; fi
            fi
            printf '%s\n' "$line"
        done < "$file"
    else
        cat "$file"
    fi
}

_cloudify_vars_store_delete() {
    local file="$1" key="$2" tmp
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    grep -v "^${key}:" "$file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
}

# _cloudify_vars_scope_file <scope> [arg] — target file for global/pkg/deployment.
_cloudify_vars_scope_file() {
    local scope="$1" arg="${2:-}" id
    case "$scope" in
        global) cloudify_vars_global_file ;;
        pkg)
            [[ -n "$arg" ]] || die "vars: --pkg needs a package name."
            cloudify_vars_pkg_file "$arg" ;;
        deployment | ambient)
            id="${arg:-${CLOUDIFY_DEPLOYMENT:-}}"
            [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id> or 'eval \"\$(cloudify deployment use <id>)\"'."
            _cloudify_deployment_config "$id" ;;
        *) die "vars: unknown scope '$scope'." ;;
    esac
}

# _cloudify_vars_parse_args <args...> — sets _CV_SCOPE/_CV_SCOPE_ARG,
# _CV_VALUE_MODE/_CV_VALUE_ARG, _CV_JSON, _CV_SOURCES, _CV_POS (positionals).
_cloudify_vars_parse_args() {
    _CV_SCOPE=ambient; _CV_SCOPE_ARG=""; _CV_VALUE_MODE=literal; _CV_VALUE_ARG=""
    _CV_JSON=0; _CV_SOURCES=0; _CV_REVEAL=0; _CV_RESOLVE=0; _CV_POS=()
    local stop=false scope_seen=0 value_seen=0
    while [[ $# -gt 0 ]]; do
        if $stop; then _CV_POS+=("$1"); shift; continue; fi
        case "$1" in
            --) stop=true ;;
            --global | --pkg | --deployment)
                [[ $scope_seen -eq 0 ]] || die "vars: --global, --pkg and --deployment are mutually exclusive."
                scope_seen=1; _CV_SCOPE="${1#--}"
                if [[ "$1" != --global ]]; then
                    shift
                    [[ -n "${1:-}" ]] || die "vars: $1 needs a value."
                    _CV_SCOPE_ARG="$1"
                fi ;;
            --stdin | --file)
                [[ $value_seen -eq 0 ]] || die "vars: --stdin and --file are mutually exclusive."
                value_seen=1
                if [[ "$1" == --stdin ]]; then _CV_VALUE_MODE="stdin"; else
                    shift
                    [[ -n "${1:-}" ]] || die "vars: --file needs a path."
                    _CV_VALUE_MODE="file"; _CV_VALUE_ARG="$1"
                fi ;;
            --json) _CV_JSON=1 ;;
            --sources) _CV_SOURCES=1 ;;
            --reveal) _CV_REVEAL=1 ;;
            --resolve) _CV_RESOLVE=1 ;;
            --*) die "vars: unknown flag '$1'." ;;
            *) _CV_POS+=("$1") ;;
        esac
        shift
    done
}

# _cloudify_vars_source_of <name> <pkg> — walker-order source, read-only, no export.
_cloudify_vars_source_of() {
    local name="$1" pkg="$2"
    [[ -n "${!name:-}" ]] && { echo env; return 0; }
    if [[ -n "${CLOUDIFY_DEPLOYMENT:-}" ]] && grep -q "^${name}:" "$(_cloudify_deployment_config "$CLOUDIFY_DEPLOYMENT")" 2>/dev/null; then
        echo deployment; return 0
    fi
    grep -q "^${name}:" "$(cloudify_vars_pkg_file "$pkg")" 2>/dev/null && { echo package; return 0; }
    grep -q "^${name}:" "$(cloudify_vars_global_file)" 2>/dev/null && { echo global; return 0; }
    echo recipe-default
}

# cloudify_vars_declared <pkg> [--sources] — the declaration mirror, three kinds.
cloudify_vars_declared() {
    local pkg="$1" sources="" reveal="" decl line name kind mirror src shown
    [[ "${2:-}" == "1" || "${2:-}" == "--sources" ]] && sources=1
    [[ "${3:-}" == "1" || "${3:-}" == "--reveal" ]] && reveal=1
    [[ -n "$pkg" ]] || die "Usage: cloudify vars declared <pkg> [--sources]"
    [[ -d "$CLOUDIFY_DIR/pkg/$pkg" ]] || die "Unknown package '$pkg'."
    decl="$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
    if [[ ! -f "$decl" ]]; then echo "(no declared vars)"; return 0; fi
    while IFS= read -r line; do
        line="$(_cloudify_vars_trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"; mirror="${BASH_REMATCH[2]}"
            if [[ -n "$mirror" ]]; then kind=defaulted; else kind=optional; fi
        elif [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)$ ]]; then
            name="${BASH_REMATCH[1]}"; kind=required; mirror=""
        else
            continue
        fi
        case "$kind" in
            required) shown="$name" ;;
            optional) shown="$name=" ;;
            defaulted)
                if _cloudify_vars_is_secret_name "$name" && [[ -z "$reveal" ]]; then shown="$name=***"; else shown="$name=$mirror"; fi ;;
        esac
        if [[ -n "$sources" ]]; then
            src="$(_cloudify_vars_source_of "$name" "$pkg")"
            printf '%s\t%s\n' "$shown" "$src"
        else
            printf '%s\n' "$shown"
        fi
    done < "$decl"
}

# --- legacy public aliases (R7) ---

cloudify_vars_set() { cloudify_vars_deployment_write "$@"; }
cloudify_vars_delete() { cloudify_vars_deployment_delete "$@"; }
cloudify_vars_list() { cloudify_vars_deployment_list "$@"; }
cloudify_vars_show() { cloudify_vars_deployment_show "$@"; }
_cloudify_deployment_read_vars() { cloudify_vars_deployment_read "$@"; }

# --- state source (branch 7: replay input, read-only) ---

cloudify_vars_state_read() {
    return 0
}
