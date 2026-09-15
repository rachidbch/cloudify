#!/usr/bin/env bash
# lib/context.sh - one resolved dispatch context (state model v2, Phase 2 slice 2A)
#
# Owns value RESOLUTION only. It reproduces the existing six-source ladder
# (lib/remote.sh:_cloudify_dispatch_vars) exactly by delegating to the same
# readers in lib/vars.sh in the same visit order, and then records each resolved
# name in a mode-0600 context file: its provenance AND its raw source form.
#
# The context DOES carry plaintext: the raw source form of a literal value is its
# text, and a literal secret's text is a secret. That is deliberate - it is what
# lets the registry record and the run snapshot be built without reopening a
# source - and it is why the file is 0600, never named on a command line, and
# removed when the dispatch ends. It must never be logged, copied into a
# manifest, package state, a run record or an event.
#
# Every label and every reference text in that file is captured at the single
# export decision inside those readers (lib/vars.sh:_cloudify_vars_emit, via
# _CLOUDIFY_VARS_SOURCES), so this module never reads a store file a second
# time: a label cannot drift from the source that supplied the exported value.
#
# Application inputs (state model v2 Phase 3): the runbook engine exports the
# names-only mapping CLOUDIFY_APP_MAP (`PKG_VAR=APPLICATION_INPUT,...`) plus
# CLOUDIFY_APPLICATION/CLOUDIFY_FLAVOR and the resolved application input values.
# The ladder below reads the application defaults file once (label
# `application`) and then maps each input value onto its package variable names
# (also `application`), both above package/global and below the deployment value
# for the package variable itself and its caller env.
#
# Interface:
#   cloudify_context_build <action> <deployment> <phase> <declared-names-file> <packages...>
#     Exports every resolved runtime literal into the CALLING shell (never
#     through `$(...)`, which would lose the exports in a subshell), never
#     prints a value on stdout, and writes the dispatch context (including
#     each declared value's raw source form) to $CLOUDIFY_CONTEXT_FILE.
#   cloudify_context_source_of <name> <pkg>
#     Pure: prints environment|deployment|package|global|recipe, never exports.
#   cloudify_context_read <context-file> <field>
#     Prints one field of a context file; non-zero when absent.
#   cloudify_context_candidate_names <packages...>
#     Static dependency walk for the candidate name set, one
#     `NAME<TAB>PKG<TAB>KIND` line per declared name (same shape as the walker's
#     _CLOUDIFY_VARS_DECLARED mirror, so it can be passed as <declared-names-file>).
#
# Context file (flat `KEY: value`):
#   context_version: 1
#   action, deployment, phase, target (node<TAB>instance<TAB>ssh_host), top_kind
#   value.<NAME>.source   environment|deployment|package|global|recipe
#   value.<NAME>.form     literal|reference
#   value.<NAME>.secret   true|false
#   value.<NAME>.reference  the @<backend>:<locator> text when form=reference
#   value.<NAME>.digest   sha256:<hex> of a literal secret
#   value.<NAME>.raw      the raw source form, `t:<text>` or `b:<base64>`, i.e.
#                        the exact text the registry record and the run snapshot
#                        must contain. See lib/vars.sh:_cloudify_vars_raw_encode.
#
# The target triple travels in CLOUDIFY_CONTEXT_TARGET, else _CLOUDIFY_CUR_TARGET
# (the router's per-dispatch triple), so it never becomes a command argument.
#
# Secret classification is the explicit `secret <NAME>` declaration marker in
# `.remote-vars` (a shape every existing declaration reader already ignores, so
# it is backward compatible), the explicit `@<backend>:<locator>` reference form,
# plus the name heuristic as defense in depth.

[[ -n "${_CLOUDIFY_CONTEXT_LOADED:-}" ]] && return 0
_CLOUDIFY_CONTEXT_LOADED=1

# _cloudify_context_name_is_secret <name> - the masking name heuristic
# (lib/vars.sh:_cloudify_vars_is_secret_name) plus PWD, which the remote payload
# masks too.
_cloudify_context_name_is_secret() {
    case "${1:-}" in
        *PWD* | *PASSWORD* | *SECRET* | *TOKEN* | *KEY*) return 0 ;;
    esac
    return 1
}

# _cloudify_context_secret_names <pkg> - explicit secret-marked names from a
# package's .remote-vars, one per line. The marker is a `secret NAME` line.
_cloudify_context_secret_names() {
    local pkg="${1:-}" decl line name
    [[ -n "$pkg" && -n "${CLOUDIFY_DIR:-}" ]] || return 0
    decl="$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
    [[ -f "$decl" ]] || return 0
    while IFS= read -r line; do
        line="$(_cloudify_vars_trim "$line")"
        line="${line%%#*}"
        line="$(_cloudify_vars_trim "$line")"
        [[ "$line" == secret\ * ]] || continue
        name="$(_cloudify_vars_trim "${line#secret }")"
        [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        printf '%s\n' "$name"
    done < "$decl"
}

# _cloudify_context_emit_declared <pkg> - the declaration mirror of a package,
# one `NAME<TAB>PKG<TAB>KIND` line per declared name, in declaration order. The
# shapes live in the one enumerator (lib/vars.sh:cloudify_vars_declared_names).
_cloudify_context_emit_declared() {
    local pkg="${1:-}" name kind
    [[ -n "$pkg" ]] || return 0
    while IFS=$'\t' read -r name kind _; do
        [[ -n "$name" ]] || continue
        printf '%s\t%s\t%s\n' "$name" "$pkg" "$kind"
    done < <(cloudify_vars_declared_names "$pkg")
}

# _cloudify_context_report <message> - best-effort diagnostic; never a value.
_cloudify_context_report() {
    if declare -F log_debug >/dev/null 2>&1; then
        log_debug "$1"
    fi
    return 0
}

# _cloudify_context_walk_pkg <pkg> <out-file> <visited-file>
# Recursive static graph walk for the candidate name set: line-oriented
# pkg_depends grep over the resolved install recipe, install recipe only, a
# visited set (inv 29). It emits declared names only; a dependency it cannot
# resolve to a cloudify package is reported, never given an invented name.
_cloudify_context_walk_pkg() {
    local pkg="${1:-}" out="${2:-}" visited="${3:-}" recipe deps dep
    [[ -n "$pkg" && -n "$out" && -n "$visited" ]] || return 0
    grep -qx "$pkg" "$visited" 2>/dev/null && return 0
    printf '%s\n' "$pkg" >> "$visited"
    _cloudify_context_emit_declared "$pkg" >> "$out"

    recipe=$(cloudify_package_recipe_path "$pkg" 2>/dev/null) || return 0
    # `|| true`: grep exits 1 when a recipe has no pkg_depends line, which under
    # errexit+pipefail would abort the whole walk.
    deps=$(grep '^[[:space:]]*pkg_depends ' "$recipe" 2>/dev/null \
        | sed 's/.*pkg_depends //' | tr ' ' '\n' || true)
    for dep in $deps; do
        [[ -n "$dep" ]] || continue
        if [[ ! -d "${CLOUDIFY_DIR:-}/pkg/$dep" ]]; then
            _cloudify_context_report "dependency '$dep' (from '$pkg') has no cloudify package; its declared names are unknown."
        fi
        _cloudify_context_walk_pkg "$dep" "$out" "$visited"
    done
}

# cloudify_context_candidate_names <packages...>
# Print the candidate name set for the given package words, rightmost package
# first with its dependencies (the walker's visit order).
function cloudify_context_candidate_names() {
    [[ $# -gt 0 ]] || return 0
    local -a pkgs=("$@")
    local out visited i
    out=$(mktemp) || return 1
    visited=$(mktemp) || { rm -f "$out"; return 1; }
    for ((i = ${#pkgs[@]} - 1; i >= 0; i--)); do
        _cloudify_context_walk_pkg "${pkgs[i]}" "$out" "$visited"
    done
    cat "$out"
    rm -f "$out" "$visited"
    return 0
}

# _cloudify_context_sha256 <text> - lowercase hex digest, computed at build time.
_cloudify_context_sha256() {
    printf '%s' "${1:-}" | sha256sum | cut -d' ' -f1
}

# _cloudify_context_cleanup_tmp <path...> - remove the temps this module made.
_cloudify_context_cleanup_tmp() {
    local f
    for f in "$@"; do
        [[ -n "$f" && -e "$f" ]] || continue
        rm -f "$f"
    done
    return 0
}

# cloudify_context_build <action> <deployment> <phase> <declared-names-file> <packages...>
# Exports each resolved runtime literal into the calling shell and writes the
# dispatch context file (each declared value's source form, raw source form and
# resolved runtime form) to $CLOUDIFY_CONTEXT_FILE. Prints nothing on stdout.
function cloudify_context_build() {
    local action="${1:-}" deployment="${2:-}" phase="${3:-}" declared_file="${4:-}"
    shift 4 2>/dev/null || true
    local -a pkgs=("$@")

    if [[ -z "${CLOUDIFY_CONTEXT_FILE:-}" ]]; then
        die "cloudify_context_build: CLOUDIFY_CONTEXT_FILE is not set."
    fi
    local context_dir
    context_dir=$(dirname "$CLOUDIFY_CONTEXT_FILE")
    # The context dir is created by the parent (_cloudify_context_file_init)
    # and by cloudify_init_paths, but cleanup() can run early (an ERR trap in a
    # subshell, e.g. a failing `comm` inside a command substitution) and empty
    # it. Recreate it rather than dying, exactly as the pre-swept-dir code
    # recreated a wiped context file. This keeps the build self-healing without
    # weakening the fail-loud validation below.
    mkdir -p "$context_dir" \
        || die "cloudify_context_build: cannot create context directory '$context_dir'."

    local ledger visited order sources out
    ledger=$(mktemp) || die "cloudify_context_build: cannot create a claim ledger."
    trap '[[ "${FUNCNAME[0]:-}" == "cloudify_context_build" ]] && { _cloudify_context_cleanup_tmp "${ledger:-}" "${visited:-}" "${order:-}" "${sources:-}" "${out:-}"; unset _CLOUDIFY_VARS_LEDGER _CLOUDIFY_VARS_SOURCES; }' RETURN
    visited=$(mktemp) || die "cloudify_context_build: cannot create a walk set."
    order=$(mktemp) || die "cloudify_context_build: cannot create a visit log."
    sources=$(mktemp "$context_dir/.cloudify-vars-sources-XXXXXX") || die "cloudify_context_build: cannot create the provenance file."
    chmod 600 "$sources" 2>/dev/null || true
    out=$(mktemp "$context_dir/.cloudify-context-XXXXXX") || die "cloudify_context_build: cannot create the context file."
    chmod 600 "$out" 2>/dev/null || true

    # The claim ledger is the walker's precedence mechanism (inv 4). The
    # candidate file replaces _CLOUDIFY_VARS_DECLARED, which is not needed here.
    _CLOUDIFY_VARS_LEDGER="$ledger"
    # The provenance file is filled inside the readers, at the single export
    # decision (lib/vars.sh:_cloudify_vars_emit): one `name<TAB>source<TAB>ref`
    # line per claimed name. Nothing below re-reads a store to label a name.
    _CLOUDIFY_VARS_SOURCES="$sources"
    unset _CLOUDIFY_VARS_DECLARED

    # -- candidate name set: the env pass gate (inv 5), and the gate for the
    # mapped application inputs (only a declared package variable is forwarded) --
    local -a candidates=()
    local -A _ctx_candidate=()
    if [[ -n "$declared_file" && -f "$declared_file" ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -n "$_line" ]] || continue
            _line="${_line%%$'\t'*}"
            candidates+=("$_line")
            _ctx_candidate["$_line"]=1
        done < "$declared_file"
    fi

    # -- explicit secret declarations + package visit order --
    local -A _ctx_secret=()
    local -A _ctx_visit=()

    _cloudify_context_walk_pkgs() {
        local pkg="${1:-}" _sname recipe deps dep
        [[ -n "$pkg" ]] || return 0
        [[ -n "${_ctx_visit[$pkg]:-}" ]] && return 0
        _ctx_visit[$pkg]=1
        printf '%s\n' "$pkg" >> "$order"
        while IFS= read -r _sname; do
            [[ -n "$_sname" ]] && _ctx_secret[$_sname]=1
        done < <(_cloudify_context_secret_names "$pkg")
        cloudify_vars_pkg_read "$pkg" > /dev/null

        recipe=$(cloudify_package_recipe_path "$pkg" 2>/dev/null) || return 0
        deps=$(grep '^[[:space:]]*pkg_depends ' "$recipe" 2>/dev/null \
            | sed 's/.*pkg_depends //' | tr ' ' '\n' || true)
        for dep in $deps; do
            [[ -n "$dep" ]] && _cloudify_context_walk_pkgs "$dep"
        done
    }

    # The ladder, unchanged: deployment, then application defaults, then the
    # mapped application inputs, then packages rightmost-first with
    # dependencies, then global, then caller env (inv 4, extended by Phase 3).
    if [[ -n "$deployment" ]]; then
        cloudify_vars_deployment_read "$deployment" > /dev/null
    fi
    if [[ -n "${CLOUDIFY_APPLICATION:-}" && -n "${CLOUDIFY_FLAVOR:-}" ]]; then
        _cloudify_load_yaml_vars "$(cloudify_vars_app_file "$CLOUDIFY_APPLICATION" "$CLOUDIFY_FLAVOR")" \
            no-clobber "" application
    fi
    # Mapped application inputs. The mapping is names only and the input values
    # are already in the step environment (the runbook engine resolved them);
    # this exports them under the package variable names at the `application`
    # rank. A value a replay would re-read as a reference is escaped, exactly as
    # _cloudify_vars_emit expects a literal.
    if [[ -n "${CLOUDIFY_APP_MAP:-}" ]]; then
        local -a _app_pairs=()
        IFS=',' read -ra _app_pairs <<< "$CLOUDIFY_APP_MAP" || true
        local _app_pair _app_var _app_input _app_raw
        for _app_pair in ${_app_pairs[@]+"${_app_pairs[@]}"}; do
            _app_pair="$(_cloudify_vars_trim "$_app_pair")"
            [[ -n "$_app_pair" && "$_app_pair" == *=* ]] || continue
            _app_var="${_app_pair%%=*}"
            _app_input="${_app_pair#*=}"
            [[ -n "${_ctx_candidate[$_app_var]:-}" ]] || continue
            [[ -n "${!_app_input:-}" ]] || continue
            _app_raw="${!_app_input}"
            [[ "$_app_raw" == @* ]] && _app_raw="@$_app_raw"
            _cloudify_vars_emit "$_app_var" "$_app_raw" no-clobber "" application
        done
    fi
    local i
    for ((i = ${#pkgs[@]} - 1; i >= 0; i--)); do
        _cloudify_context_walk_pkgs "${pkgs[i]}"
    done
    cloudify_vars_global_read "$(cloudify_vars_global_file)" > /dev/null
    if (( ${#candidates[@]} )); then
        cloudify_vars_env_read "${candidates[@]}" > /dev/null
    fi

    local top_kind="package"
    [[ "$action" == "verify" ]] && top_kind="verified"
    local target="${CLOUDIFY_CONTEXT_TARGET:-${_CLOUDIFY_CUR_TARGET:-}}"

    # -- provenance, captured during the walk above (first claim wins) --
    # No store file is consulted here: this is the same single resolution the
    # readers already performed, so the label cannot drift from the value.
    # Four fields, 0x1f-separated. A tab separator would let `read` collapse an
    # empty field and shift the rest; see _cloudify_vars_sources_record.
    local -A _ctx_source=() _ctx_ref=() _ctx_raw=()
    if [[ -s "$sources" ]]; then
        local _sn _sl _sr _sw
        while IFS=$'\x1f' read -r _sn _sl _sr _sw; do
            [[ -n "$_sn" ]] || continue
            [[ -n "${_ctx_source[$_sn]:-}" ]] && continue
            _ctx_source[$_sn]="$_sl"
            _ctx_ref[$_sn]="${_sr:-}"
            _ctx_raw[$_sn]="${_sw:-}"
        done < "$sources"
    fi

    local name label form ref is_secret digest
    local -a resolved=()
    if [[ -s "$ledger" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && resolved+=("$name")
        done < <(sort -u "$ledger")
    fi

    {
        printf 'context_version: 1\n'
        printf 'action: %s\n' "$action"
        printf 'deployment: %s\n' "$deployment"
        printf 'phase: %s\n' "$phase"
        printf 'target: %s\n' "$target"
        printf 'top_kind: %s\n' "$top_kind"
        for name in "${resolved[@]}"; do
            label="${_ctx_source[$name]:-recipe}"
            form="literal"; ref="${_ctx_ref[$name]:-}"
            [[ -n "$ref" ]] && form="reference"

            is_secret=false
            if [[ "$form" == "reference" ]] \
                || [[ -n "${_ctx_secret[$name]:-}" ]] \
                || _cloudify_context_name_is_secret "$name"; then
                is_secret=true
            fi
            digest=""
            if [[ "$form" == "literal" && "$is_secret" == "true" ]]; then
                digest="sha256:$(_cloudify_context_sha256 "${!name:-}")"
            fi

            printf 'value.%s.source: %s\n' "$name" "$label"
            printf 'value.%s.form: %s\n' "$name" "$form"
            printf 'value.%s.secret: %s\n' "$name" "$is_secret"
            printf 'value.%s.reference: %s\n' "$name" "$ref"
            printf 'value.%s.digest: %s\n' "$name" "$digest"
            # The raw source form, in the transport encoding, so a multiline
            # value stays on one line. This is what lets the registry record and
            # the run snapshot be built without reopening a source.
            printf 'value.%s.raw: %s\n' "$name" "${_ctx_raw[$name]:-t:}"
        done
    } > "$out"

    chmod 600 "$out" 2>/dev/null || true
    cloudify_context_validate "$out" || die "cloudify_context_build: the context failed validation; refusing to dispatch."
    mv "$out" "$CLOUDIFY_CONTEXT_FILE" || die "cloudify_context_build: cannot write $CLOUDIFY_CONTEXT_FILE."
    return 0
}

# cloudify_context_validate <file> - fail loudly before anything consumes the
# context. A context that is silently empty or partial stops payload forwarding
# with no error at all, so this is a hard gate, not a convenience.
function cloudify_context_validate() {
    local file="${1:-}" line seen_bad="" _sn
    [[ -f "$file" ]] || return 1

    local version="" action="" deployment="" phase="" target="" top_kind=""
    while IFS= read -r line; do
        case "$line" in
            "") continue ;;
            context_version:*|action:*|deployment:*|phase:*|target:*|top_kind:*|value.*) ;;
            *) seen_bad="$line" ;;
        esac
        case "$line" in
            context_version:*) version="${line#context_version: }" ;;
            action:*) action="${line#action: }" ;;
            deployment:*) deployment="${line#deployment: }" ;;
            phase:*) phase="${line#phase: }" ;;
            target:*) target="${line#target: }" ;;
            top_kind:*) top_kind="${line#top_kind: }" ;;
        esac
    done < "$file"

    [[ -z "$seen_bad" ]] || die "context '$file': unexpected line '$seen_bad'."
    [[ "$version" == "1" ]] || die "context '$file': unsupported or missing context_version '${version:-<none>}'."
    [[ -n "$action" ]] || die "context '$file': no action."
    [[ -n "$top_kind" ]] || die "context '$file': no top_kind."
    # target, deployment and phase are NOT required: a direct package command has
    # no deployment, and a context built for a record write alone has no target.
    # Requiring a field no producer supplies is how a phase ends up fabricating one.

    # Every name with a source block must also carry a raw block, and the raw
    # form must be one this build understands.
    while IFS= read -r _sn; do
        [[ -n "$_sn" ]] || continue
        local raw
        raw=$(cloudify_context_read "$file" "value.$_sn.raw") \
            || die "context '$file': value '$_sn' has no raw source form."
        case "$raw" in
            t:*) ;;
            b:*) [[ -n "${raw#b:}" ]] \
                    || die "context '$file': value '$_sn' has an empty base64 raw form." \
                ; printf '%s' "${raw#b:}" | base64 -d >/dev/null 2>&1 \
                    || die "context '$file': value '$_sn' has a malformed base64 raw form." ;;
            *) die "context '$file': value '$_sn' has a malformed raw form." ;;
        esac
    done < <(sed -n 's/^value\.\([^.]*\)\.source:.*$/\1/p' "$file")

    return 0
}

# cloudify_context_source_of <name> <pkg> - the first providing source label,
# pure and non-mutating. Delegates to the one shared implementation
# (lib/vars.sh:_cloudify_vars_source_label), so runbook preflight and dispatch
# use the SAME label code path; only the spelling differs (`recipe` here,
# `recipe-default` in _cloudify_vars_source_of).
function cloudify_context_source_of() {
    _cloudify_vars_source_label "${1:-}" "${2:-}"
}

# cloudify_context_read <context-file> <field> - print one field, rc 1 when the
# field is absent. Exact key match: no regex, no partial keys.
function cloudify_context_read() {
    local file="${1:-}" field="${2:-}" line
    [[ -n "$file" && -n "$field" ]] || return 1
    [[ -f "$file" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "$field:"* ]] || continue
        line="${line#"$field":}"
        printf '%s\n' "${line# }"
        return 0
    done < "$file"
    return 1
}
