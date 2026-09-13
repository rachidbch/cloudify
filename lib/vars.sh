#!/usr/bin/env bash
# lib/vars.sh — five-source var helpers (ADR-007 + ADR-011)
#
# One read/write helper per var source. The collector (lib/context.sh:
# cloudify_context_build, reached through lib/remote.sh:_cloudify_dispatch_vars)
# is a thin precedence walker over these helpers. Target precedence (weakest ->
# strongest), extended by the state model v2 application inputs:
#   recipe default < global < package < application < deployment < caller env
# `application` covers an application default (apps/<app>/<flavor>/defaults.yaml)
# and the mapped application input; its own value resolves as
# application default < deployment value for the input name < caller env for the
# input name. See runbooks/README.md.
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
# claimed it. With no ledger set, always returns 0 (direct-call mode).
_cloudify_vars_claim() {
    local name="$1"
    [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" ]] || return 0
    if grep -qx "$name" "$_CLOUDIFY_VARS_LEDGER" 2>/dev/null; then
        return 1
    fi
    echo "$name" >> "$_CLOUDIFY_VARS_LEDGER"
    return 0
}

# Record the single-pass provenance of a claimed name: which reader supplied
# it, plus (reference values only) the store's raw `@<backend>:<locator>` text.
# No-op unless a caller set _CLOUDIFY_VARS_SOURCES, so every existing call path
# behaves identically. One `printf >>` per claimed name: no subprocess, and no
# store is ever read a second time to recover this.
_cloudify_vars_sources_record() {
    [[ -n "${_CLOUDIFY_VARS_SOURCES:-}" ]] || return 0
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$_CLOUDIFY_VARS_SOURCES"
}

_cloudify_vars_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --- identity components (schemas/v1/identity.md) ---

# _cloudify_identity_valid_component <value> - the frozen machine-owned
# identity component rule: non-empty, no '/', no control character, not '.' or
# '..', no leading/trailing whitespace, no leading '-', at most 255 bytes.
# Pure predicate (never dies) so a caller can choose its own message.
function _cloudify_identity_valid_component() {
    local v="${1:-}" LC_ALL=C
    [[ -n "$v" ]] || return 1
    (( ${#v} <= 255 )) || return 1
    [[ "$v" != */* ]] || return 1
    [[ "$v" != "." && "$v" != ".." ]] || return 1
    [[ "$v" != -* ]] || return 1
    [[ "$v" != [[:space:]]* && "$v" != *[[:space:]] ]] || return 1
    [[ "$v" != *[[:cntrl:]]* ]] || return 1
    return 0
}

# _cloudify_identity_check_component <label> <value> - die, naming the component.
function _cloudify_identity_check_component() {
    _cloudify_identity_valid_component "${2:-}" ||
        die "Invalid ${1:-component} '${2:-}' (non-empty, no '/', no control character, not '.' or '..', no leading/trailing whitespace, no leading '-', at most 255 bytes)."
}

# _cloudify_identity_valid_name <value> - a shell/variable name (the runbook step
# ID tightening and the application input / mapped package variable shape).
function _cloudify_identity_valid_name() {
    [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

function _cloudify_identity_check_name() {
    _cloudify_identity_valid_name "${2:-}" ||
        die "Invalid ${1:-name} '${2:-}' (expected a letter or '_' followed by letters, digits or '_')."
}

# _cloudify_identity_valid_step_id <value> - the frozen stable runbook step ID
# shape: a leading alphanumeric followed by alphanumerics, '.', '_' or '-'.
function _cloudify_identity_valid_step_id() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

function _cloudify_identity_check_step_id() {
    if _cloudify_identity_valid_step_id "${2:-}" && _cloudify_identity_valid_component "${2:-}"; then
        return 0
    fi
    die "Invalid ${1:-step id} '${2:-}' (expected a leading alphanumeric followed by alphanumerics, '.', '_' or '-', and no path separator or control character)."
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
# _cloudify_vars_emit <name> <raw> [no-clobber] [print] [source]
# `source` is the calling reader's label (deployment|package|global|...). It is
# recorded at this, the single export decision, so a caller never has to
# re-derive it by reading the store again. Absent, it is `recipe`: the verify
# path (lib/package-api.sh) passes no label and behaves exactly as before.
_cloudify_vars_emit() {
    local name="$1" raw="$2" mode="${3:-}" print="${4:-}" source="${5:-recipe}"
    if _cloudify_vars_reserved "$name"; then
        log_warn "Var $name is framework-owned — ignored from file store."
        return 0
    fi
    _cloudify_vars_claim "$name" || return 0
    [[ -n "$print" ]] && echo "$name"
    # Non-clobbering only matters in walker mode (ledger set): the caller env is
    # the strongest source and file reads must not overwrite it. With the ledger
    # set, a claimed name that is already set can only have come from the caller
    # env (every file export claims first), so that is the providing source.
    if [[ -n "${_CLOUDIFY_VARS_LEDGER:-}" && "$mode" == "no-clobber" && -n "${!name:-}" ]]; then
        _cloudify_vars_sources_record "$name" environment ""
        return 0
    fi
    local value ref="" _ref
    if ! value=$(_cloudify_resolve_var_value "$name" "$raw"); then
        die "Var $name: cannot resolve value — refusing to forward an empty value."
    fi
    export "$name"="$value"
    # Reference text only, same shape _cloudify_resolve_var_value accepts: it
    # decodes `@base64:...` to plaintext, so the exported literal alone cannot
    # reveal the form. A literal raw is never written here, so the provenance
    # file holds no plaintext value.
    if [[ "$raw" == @* && "$raw" != @@* ]]; then
        _ref="${raw#@}"
        [[ "$_ref" == *:* && "$_ref" != :* && "$_ref" != *: ]] && ref="$raw"
    fi
    _cloudify_vars_sources_record "$name" "$source" "$ref"
}

# Parse a flat `KEY: value` file and export each value.
# _cloudify_load_yaml_vars <file> [no-clobber] [print] [source]
# - no ledger: unconditional export (verify path, package-api.sh).
# - ledger set + no-clobber: first source to claim a name wins (walker).
# - `source` is threaded through to _cloudify_vars_emit's provenance label.
function _cloudify_load_yaml_vars() {
    local file="$1"
    local mode="${2:-}"
    local print="${3:-}"
    local source="${4:-}"
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

        _cloudify_vars_emit "$key" "$value" "$mode" "$print" "$source"
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

# cloudify_vars_app_file <application> <flavor> - the application defaults file
# (REDESIGN "Defaults and desired inputs"). Keyed by application input name.
cloudify_vars_app_file() {
    echo "$(cloudify_vars_config_dir)/apps/$1/$2/defaults.yaml"
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
    _cloudify_load_yaml_vars "$file" no-clobber "$print" global
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
                # With a claim ledger set, this branch is reachable only while
                # the name is unclaimed and already set, i.e. from the caller
                # env (nothing else can set a name without claiming it first),
                # so env is the providing source. No-op unless a context build
                # is recording.
                _cloudify_vars_sources_record "$name" environment ""
            fi
        done < "$decl"
    fi

    _cloudify_load_yaml_vars "${2:-$(cloudify_vars_pkg_file "$pkg")}" no-clobber "$print" package
}

cloudify_vars_pkg_write() {
    local pkg="$1"
    [[ -n "$pkg" ]] || die "Usage: cloudify vars set <key> <value> --pkg <name>"
    _cloudify_vars_file_set "$(cloudify_vars_pkg_file "$pkg")" "$2" "$3" 1
}

# --- deployment source ---

# cloudify_vars_deployment_read [<id>]
# Read the ONE desired-inputs store this process resolves from: the nested
# values.yaml of the active application reference
# (lib/deployments.sh:_cloudify_deployment_config). One file means one label and
# one value, so the payload and the registry record cannot disagree (Phase 2
# one-resolution rule). Without an application reference there is no deployment
# source at all. Nothing is deleted.
cloudify_vars_deployment_read() {
    local id="${1:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$id" ]] || return 0
    local config
    config=$(_cloudify_deployment_config) || return 0
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
        _cloudify_vars_emit "$key" "$raw" no-clobber "$print" deployment
    done < "$config"
}

cloudify_vars_deployment_write() {
    local key="$1" value="$2" id="${3:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$key" ]] || die "Usage: cloudify vars set <key> <value>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id>."
    _cloudify_deployment_ensure "$id"
    local file
    file=$(_cloudify_deployment_config) || return 1
    _cloudify_vars_file_set "$file" "$key" "$value"
}

cloudify_vars_deployment_delete() {
    local key="$1" id="${2:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$key" ]] || die "Usage: cloudify vars delete <key>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id>."
    _cloudify_deployment_require "$id"
    local file
    file=$(_cloudify_deployment_config) || return 1
    _cloudify_vars_store_delete "$file" "$key"
}

cloudify_vars_deployment_list() {
    local mode="" id
    if [[ "${1:-}" == "--json" ]]; then mode="--json"; shift; fi
    id="${1:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id>."
    _cloudify_deployment_require "$id"
    local file
    file=$(_cloudify_deployment_config) || return 1
    _cloudify_vars_store_list "$file" "$mode"
}

cloudify_vars_deployment_show() {
    local key="$1" id="${2:-${CLOUDIFY_DEPLOYMENT:-}}"
    [[ -n "$key" ]] || die "Usage: cloudify vars show <key>"
    [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id>."
    _cloudify_deployment_require "$id"
    local file
    file=$(_cloudify_deployment_config) || return 1
    _cloudify_vars_store_get "$file" "$key"
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
        _cloudify_vars_sources_record "$name" environment ""
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
            [[ -n "$id" ]] || die "CLOUDIFY_DEPLOYMENT is not set. Use --deployment <id>."
            _cloudify_deployment_require "$id"
            _cloudify_deployment_config ;;
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

# _cloudify_vars_deployment_has_key <id> <key> — rc 0 when the ONE store this
# process resolves from holds the key. Never a value, never a second walk; the
# label check and the value read therefore see the same file. rc 1 when no
# application reference is active.
function _cloudify_vars_deployment_has_key() {
    local id="${1:-}" key="${2:-}" file
    [[ -n "$id" && -n "$key" ]] || return 1
    file=$(_cloudify_deployment_config) || return 1
    grep -q "^${key}:" "$file" 2>/dev/null
}

# _cloudify_vars_source_label <name> <pkg> — THE first-providing source label,
# read-only and non-mutating. Single implementation: the walker-order spelling
# below and lib/context.sh:cloudify_context_source_of both delegate here, so
# runbook preflight and dispatch cannot select different sources.
_cloudify_vars_source_label() {
    local name="${1:-}" pkg="${2:-}"
    [[ -n "${!name:-}" ]] && { echo environment; return 0; }
    if [[ -n "${CLOUDIFY_DEPLOYMENT:-}" ]] && _cloudify_vars_deployment_has_key "$CLOUDIFY_DEPLOYMENT" "$name"; then
        echo deployment; return 0
    fi
    # Application ranks: the mapped application input (its own value resolved as
    # application default < deployment value for the input name < caller env for
    # the input name) sits above package and global, below the deployment value
    # for the package variable itself (checked above) and its caller env (first).
    local _app_input
    _app_input=$(_cloudify_vars_app_input_for "$name")
    if [[ -n "$_app_input" ]] && _cloudify_vars_app_input_has_value "$_app_input"; then
        echo application; return 0
    fi
    if [[ -n "${CLOUDIFY_APPLICATION:-}" && -n "${CLOUDIFY_FLAVOR:-}" ]] \
        && grep -q "^${name}:" "$(cloudify_vars_app_file "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR")" 2>/dev/null; then
        echo application; return 0
    fi
    grep -q "^${name}:" "$(cloudify_vars_pkg_file "$pkg")" 2>/dev/null && { echo package; return 0; }
    grep -q "^${name}:" "$(cloudify_vars_global_file)" 2>/dev/null && { echo global; return 0; }
    echo recipe
}

# _cloudify_vars_app_input_for <package-variable> - print the application input
# that the (names-only) CLOUDIFY_APP_MAP maps this package variable onto, else
# nothing. The map carries no value.
function _cloudify_vars_app_input_for() {
    local name="${1:-}" map="${CLOUDIFY_APP_MAP:-}" pair
    [[ -n "$name" && -n "$map" ]] || return 0
    local IFS=','
    for pair in $map; do
        pair="$(_cloudify_vars_trim "$pair")"
        [[ -n "$pair" && "$pair" == *=* ]] || continue
        [[ "${pair%%=*}" == "$name" ]] && { printf '%s\n' "${pair#*=}"; return 0; }
    done
    return 0
}

# _cloudify_vars_app_input_has_value <input> - a pure check: is there any value
# for this application input (caller env, then the deployment store, then the
# application defaults file)? Never prints the value.
function _cloudify_vars_app_input_has_value() {
    local input="${1:-}"
    [[ -n "$input" ]] || return 1
    [[ -n "${!input:-}" ]] && return 0
    if [[ -n "${CLOUDIFY_DEPLOYMENT:-}" ]] \
        && _cloudify_vars_deployment_has_key "$CLOUDIFY_DEPLOYMENT" "$input"; then
        return 0
    fi
    if [[ -n "${CLOUDIFY_APPLICATION:-}" && -n "${CLOUDIFY_FLAVOR:-}" ]] \
        && grep -q "^${input}:" "$(cloudify_vars_app_file "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR")" 2>/dev/null; then
        return 0
    fi
    return 1
}

# _cloudify_vars_source_of <name> <pkg> — walker-order source, read-only, no
# export. Keeps the display spelling (`env`, `recipe-default`) that runbook
# preflight and `cloudify vars declared --sources` pin; only the label
# computation is shared.
_cloudify_vars_source_of() {
    local label
    label=$(_cloudify_vars_source_label "${1:-}" "${2:-}")
    case "$label" in
        environment) echo env ;;
        recipe) echo recipe-default ;;
        *) echo "$label" ;;
    esac
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

# --- public aliases (R7) ---

cloudify_vars_set() { cloudify_vars_deployment_write "$@"; }
cloudify_vars_delete() { cloudify_vars_deployment_delete "$@"; }
cloudify_vars_list() { cloudify_vars_deployment_list "$@"; }
cloudify_vars_show() { cloudify_vars_deployment_show "$@"; }
_cloudify_deployment_read_vars() { cloudify_vars_deployment_read "$@"; }
