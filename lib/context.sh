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


# cloudify_context_applied_seed <mode> <node> <instance> <app> <flavor> <name>
# The applied-seed file for one deployment on one host (ADR-030): one
# `NAME\x1fkind\x1fdigest\x1fraw` line per applied value, records sorted and
# merged first-per-name (the namespace is dispatch-global).
#   kind=value  - seedable: a non-secret (its source form) or a secret
#                 reference (the reference text; the backend resolves it)
#   kind=secret - a literal secret: digest-only in applied, a demand marker -
#                 it can never seed, the caller must resupply it
# mode reconfigure filters to SET values (source=caller); verify and teardown
# take every applied value. Prints the seed path (0600, context dir). A
# deployment with no applied record on the host dies named: reconfigure,
# verify and teardown all require one.
function cloudify_context_applied_seed() {
    local mode="${1:?}" node="${2:?}" inst="${3:-}" app="${4:?}" flavor="${5:?}" name="${6:?}"
    local pkg_root seed records rec rows
    pkg_root="$(cloudify_state_inventory_root "$node" "$inst")/$app/$flavor/$name/packages"
    records=$(find "$pkg_root" -mindepth 3 -maxdepth 3 -name state.json 2>/dev/null | sort)
    [[ -n "$records" ]] ||
        die "applied seed: no inventory record for deployment $app/$flavor/$name on '$node${inst:+:$inst}'."
    seed=$(mktemp "${CLOUDIFY_CONTEXT_DIR:-/tmp}/.applied-seed-XXXXXX") || die "applied seed: cannot create the seed file."
    chmod 600 "$seed" 2>/dev/null || true
    local -A seen=()
    while IFS= read -r rec; do
        [[ -f "$rec" ]] || continue
        rows=$(jq -r --arg mode "$mode" '
            .applied.values // {} | to_entries[]
            | select(if $mode == "reconfigure" then .value.source == "caller" else true end)
            | .key as $k | .value as $v
            | (if ($v.secret and $v.redacted) then "secret" else "value" end) as $kind
            | (if $kind == "secret" then null
               elif $v.secret then $v.reference
               else $v.source_form end) as $form
            | [$k, $kind, ($v.digest // ""),
               (if $form == null then ""
                elif ($form | contains("\n") or contains("\t") or contains("\u0001")) then "b:" + ($form | @base64)
                else "t:" + $form end)]
            | join("\u001f")' "$rec" 2>/dev/null) || continue
        local line n kind digest raw rest
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            n="${line%%$'\x1f'*}"
            [[ -n "${seen[$n]+x}" ]] && continue
            seen[$n]=1
            printf '%s\n' "$line" >> "$seed"
        done <<< "$rows"
    done <<< "$records"
    printf '%s\n' "$seed"
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


# _cloudify_context_seed_walk <label> - one applied-seed pass: emit every
# seedable entry into the ladder with the given provenance label
# (`environment` for reconfigure set values - a set value keeps its caller
# identity through reseeding, ADR-030; `applied` for verify/teardown). Only
# declared candidate names seed; framework-owned names are refused by the
# emit itself. no-clobber keeps a pre-set caller env value winning.
_cloudify_context_seed_walk() {
    local label="$1" seed="${CLOUDIFY_APPLIED_SEED:-}" line n kind digest raw
    [[ -n "$seed" && -f "$seed" ]] || return 0
    while IFS=$'\x1f' read -r n kind digest raw; do
        [[ -n "$n" ]] || continue
        [[ -n "${_ctx_candidate[$n]:-}" ]] || continue
        [[ "$kind" == value ]] || continue
        _cloudify_vars_emit "$n" "$(_cloudify_vars_raw_decode "$raw")" no-clobber "" "$label"
    done < "$seed"
}

# _cloudify_context_seed_check - after the walk, every literal-secret demand
# marker must be resupplied (caller env or a store) with a plaintext whose
# digest matches the recorded one. Unsupplied or mismatching dies named
# before any dispatch - a set secret never falls back to a recipe default.
_cloudify_context_seed_check() {
    local seed="${CLOUDIFY_APPLIED_SEED:-}" line n kind digest got
    [[ -n "$seed" && -f "$seed" ]] || return 0
    while IFS=$'\x1f' read -r n kind digest raw; do
        [[ "$kind" == "secret" ]] || continue
        [[ -n "${_ctx_candidate[$n]:-}" ]] || continue
        if [[ -z "${!n:-}" ]]; then
            die "applied seed: value '$n' is a literal secret in the applied state (digest only); resupply it in the caller environment or the deployment store."
        fi
        got=$(_cloudify_context_sha256 "${!n}")
        [[ "sha256:$got" == "$digest" ]] ||
            die "applied seed: resupplied value '$n' does not match the applied digest; refusing to forward it."
    done < "$seed"
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
    # Applied seeding (ADR-030). Reconfigure: SET values seed between the
    # caller env and the deployment store (env > applied[set] > store) - the
    # pass runs BEFORE the store read, so the seed's claim wins the ledger
    # while a pre-set caller env value still wins through no-clobber.
    if [[ "$phase" == "reconfigure" ]]; then
        _cloudify_context_seed_walk environment
    fi
    if [[ -n "$deployment" ]]; then
        cloudify_vars_deployment_read "$deployment" > /dev/null
    fi
    # Verify and teardown: every applied value seeds BELOW the store, so the
    # caller env and the deployment inputs resupply over the record.
    if [[ "$phase" == "verify" || "$phase" == "teardown" ]]; then
        _cloudify_context_seed_walk applied
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

    # Literal-secret demand markers: resupplied and digest-checked, or the
    # dispatch dies named before any payload is built.
    _cloudify_context_seed_check

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
            declaration="none"
            if [[ "$form" == "reference" ]] \
                || [[ -n "${_ctx_secret[$name]:-}" ]]; then
                is_secret=true
                declaration="explicit"
            elif _cloudify_context_name_is_secret "$name"; then
                is_secret=true
                declaration="heuristic"
            fi
            digest=""
            if [[ "$form" == "literal" && "$is_secret" == "true" ]]; then
                digest="sha256:$(_cloudify_context_sha256 "${!name:-}")"
            fi

            printf 'value.%s.source: %s\n' "$name" "$label"
            printf 'value.%s.form: %s\n' "$name" "$form"
            printf 'value.%s.secret: %s\n' "$name" "$is_secret"
            # The classification origin, surfaced from the same inputs that set
            # .secret: a reference or the explicit marker is explicit, the name
            # heuristic alone is heuristic, everything else is none.
            printf 'value.%s.declaration: %s\n' "$name" "$declaration"
            printf 'value.%s.reference: %s\n' "$name" "$ref"
            printf 'value.%s.digest: %s\n' "$name" "$digest"
            # The raw source form, in the transport encoding, so a multiline
            # value stays on one line. This is what lets the registry record and
            # the run snapshot be built without reopening a source.
            printf 'value.%s.raw: %s\n' "$name" "${_ctx_raw[$name]:-t:}"
        done
        # One sorted package.<PACKAGE>.instance field per precomputed package:
        # the instance key is part of the package's configuration (ADR-027).
        # 4.1 records the default key; the .package-instance recipe contract
        # upgrades the resolution in 4.2. Sorted, and outside the value namespace,
        # so the payload allow-list recovery (value.<NAME>.source) never sees it.
        local _pkg _inst_var _inst_val
        while IFS= read -r _pkg; do
            [[ -n "$_pkg" ]] || continue
            # The instance key is part of the package's configuration
            # (ADR-027): a .package-instance file names the variable whose
            # resolved value selects the instance; no marker means default.
            _inst_var=$(cat "$CLOUDIFY_DIR/pkg/$_pkg/.package-instance" 2>/dev/null || true)
            _inst_val="default"
            if [[ -n "$_inst_var" ]]; then
                _cloudify_identity_check_name "package instance variable" "$_inst_var"
                cloudify_vars_declared_names "$_pkg" | cut -f1 | grep -qx "$_inst_var" \
                    || die "package '$_pkg': instance variable '$_inst_var' is not declared in .remote-vars."
                # The instance key lands in state paths and result lines
                # (both logged) - a secret-classified value can never be it.
                # Explicit `secret` declarations and the masking name
                # heuristic both refuse: whatever the walker would mask
                # anywhere else must not become a path component here.
                if [[ -n "${_ctx_secret[$_inst_var]:-}" ]] \
                    || _cloudify_context_name_is_secret "$_inst_var"; then
                    die "package '$_pkg': instance variable '$_inst_var' is secret-classified - a secret value can never be the instance key (it would land in paths and result lines)."
                fi
                _inst_val="${!_inst_var:-}"
                [[ -n "$_inst_val" ]] \
                    || die "package '$_pkg': instance variable '$_inst_var' is unsupplied; refusing to guess the instance key."
                _cloudify_identity_check_instance "package instance" "$_inst_val"
            fi
            printf 'package.%s.instance: %s\n' "$_pkg" "$_inst_val"
        done < <(sort -u "$order")
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
            context_version:*|action:*|deployment:*|phase:*|target:*|top_kind:*|value.*|package.*) ;;
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

    # Instance keys ride result lines and paths: the space-free result-line
    # charset is a hard shape, same rule as schemas/v1/identity.md.
    local _pk _pv
    while IFS='|' read -r _pk _pv; do
        [[ -n "$_pk" ]] || continue
        [[ "$_pv" =~ ^[A-Za-z0-9._+~:-]+$ ]] \
            || die "context '$file': instance key '$_pv' has characters outside the result-line charset."
    done < <(sed -n 's/^package\.\([^.]*\)\.instance: \(.*\)$/\1|\2/p' "$file")

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

#-- One-context projection (state-model-v2 4.3) --

# The one parsed context: cloudify_context_load fills it once, every consumer
# (matching, the guard, the worker's commits) reads the copy, so two
# projections can never disagree and no value is ever re-resolved.
# -gA: a global associative even when this file is first sourced from inside
# a function (a bats setup), where a plain declare would stay local and the
# name would later fall back to an indexed array.
declare -gA _CLOUDIFY_CONTEXT=()

# cloudify_context_load <file> - parse the flat context once into
# _CLOUDIFY_CONTEXT[key]=value (one shell split at the first ': '). Fail
# closed: missing file, empty file, malformed line, missing context_version.
function cloudify_context_load() {
    local file="${1:-}" line key val
    [[ -n "$file" && -f "$file" ]] || die "context load: no context file '$file'."
    [[ -s "$file" ]] || die "context load: context file '$file' is empty."
    _CLOUDIFY_CONTEXT=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *": "* ]] || die "context load: malformed line: $line"
        key="${line%%: *}"   # shortest suffix matching ': *' = split at the FIRST ': '
        val="${line#*: }"    # shortest prefix removal = the rest, verbatim
        _CLOUDIFY_CONTEXT["$key"]="$val"
    done < "$file"
    [[ "${_CLOUDIFY_CONTEXT[context_version]:-}" == "1" ]] ||
        die "context load: unsupported or missing context_version."
    return 0
}

# _cloudify_context_value_field <name> <field> - one field of a value block;
# fails closed when the field is absent (emptiness is a legal value).
_cloudify_context_value_field() {
    local name="${1:-}" field="${2:-}"
    [[ -n "${_CLOUDIFY_CONTEXT[value.$name.$field]+x}" ]] ||
        die "context: value '$name' is missing field '$field'."
    printf '%s' "${_CLOUDIFY_CONTEXT[value.$name.$field]}"
}

# cloudify_context_value_json <name> - the comparable value object of one
# resolved name, exactly schemas/v1/package-state.schema.json $defs/value:
# a non-secret keeps its decoded source form, a secret reference its
# reference, a literal secret only its digest. Fail closed on a missing
# field, inconsistent secret metadata or a malformed digest; plaintext of a
# literal secret never enters the object.
function cloudify_context_value_json() {
    local name="${1:?}"
    local source form secret declaration reference digest raw text
    source=$(_cloudify_context_value_field "$name" source)
    form=$(_cloudify_context_value_field "$name" form)
    secret=$(_cloudify_context_value_field "$name" secret)
    declaration=$(_cloudify_context_value_field "$name" declaration)
    reference=$(_cloudify_context_value_field "$name" reference)
    digest=$(_cloudify_context_value_field "$name" digest)
    raw=$(_cloudify_context_value_field "$name" raw)
    case "$form" in literal | reference) ;; *) die "context: value '$name' has malformed form '$form'." ;; esac
    case "$secret" in true | false) ;; *) die "context: value '$name' has malformed secret '$secret'." ;; esac
    case "$declaration" in explicit | heuristic | none) ;; *) die "context: value '$name' has malformed declaration '$declaration'." ;; esac
    case "$source" in
        environment) source=caller ;;
        # applied and migration are record-backed labels (ADR-030: a released
        # pin stays applied; a migrated record carries migration) - a seeded
        # verify/teardown re-reads them, so the projection must accept them.
        deployment | application | package | global | recipe | applied | migration | caller) ;;
        *) die "context: value '$name' has unknown source label '$source'." ;;
    esac
    if [[ "$form" == reference ]]; then
        [[ "$secret" == true ]] || die "context: value '$name' is a reference but not marked secret."
        [[ "$reference" =~ ^@[A-Za-z0-9_-]+:.+$ ]] || die "context: value '$name' has a malformed reference."
        jq -cn --arg src "$source" --arg ref "$reference" --arg d "$declaration" \
            '{source: $src, secret: true, declaration: $d, source_form: $ref, reference: $ref, digest: null, redacted: false}'
        return 0
    fi
    if [[ "$secret" == true ]]; then
        [[ -z "$reference" ]] || die "context: value '$name' is a literal secret but carries a reference."
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "context: value '$name' has a malformed digest."
        jq -cn --arg src "$source" --arg digest "$digest" --arg d "$declaration" \
            '{source: $src, secret: true, declaration: $d, source_form: null, reference: null, digest: $digest, redacted: true}'
        return 0
    fi
    [[ -z "$reference" && -z "$digest" ]] || die "context: value '$name' is not secret but carries a reference or digest."
    [[ "$declaration" == "none" ]] || die "context: value '$name' is not secret but declares '$declaration'."
    case "$raw" in
        t:*) text="${raw#t:}" ;;
        b:*) text=$(printf '%s' "${raw#b:}" | base64 -d) \
                || die "context: value '$name' has a malformed base64 raw form." ;;
        *) die "context: value '$name' has a malformed raw form." ;;
    esac
    # The resolution source travels with the comparable form (ADR-030): caller
    # marks a set value - the fact the reconfigure ladder discriminates on.
    jq -cn --arg src "$source" --arg sf "$text" \
        '{source: $src, secret: false, declaration: "none", source_form: $sf, reference: null, digest: null, redacted: false}'
}

# cloudify_context_values_json [name...] - the comparable projection of the
# given resolved names (default: none, {}): one JSON object mapping NAME to
# its comparable value object. The inventory projection passes every resolved
# name; the compared projection passes one package's declared names only.
function cloudify_context_values_json() {
    local n
    # One `NAME\t<compact-json>` line per name; jq -cn already terminates each
    # object with a newline, so no extra separator is printed.
    { for n in "$@"; do
        printf '%s\t' "$n"
        cloudify_context_value_json "$n"
      done; } | jq -cRn '
        reduce inputs as $line ({};
            ($line | split("\t")) as $p
            | . + {($p[0]): ($p[1:] | join("\t") | fromjson)})'
}

# cloudify_context_event_value_json <name> - one declared value in the EVENT
# shape (schemas/v1/event.schema.json $defs/value_metadata): a source label
# (context `environment` maps to `caller`), the secret flag and declaration,
# reference or digest for secrets, and the source form for non-secrets only.
# Never raw, never plaintext of a secret. Fail closed like the comparable
# projection.
function cloudify_context_event_value_json() {
    local name="${1:?}"
    local source form secret declaration reference digest raw text
    source=$(_cloudify_context_value_field "$name" source)
    form=$(_cloudify_context_value_field "$name" form)
    secret=$(_cloudify_context_value_field "$name" secret)
    declaration=$(_cloudify_context_value_field "$name" declaration)
    reference=$(_cloudify_context_value_field "$name" reference)
    digest=$(_cloudify_context_value_field "$name" digest)
    raw=$(_cloudify_context_value_field "$name" raw)
    [[ "$source" == environment ]] && source=caller
    case "$source" in
        caller | deployment | applied | application | package | global | recipe) ;;
        *) die "context: value '$name' has unknown source label '$source'." ;;
    esac
    case "$form" in literal | reference) ;; *) die "context: value '$name' has malformed form '$form'." ;; esac
    case "$secret" in true | false) ;; *) die "context: value '$name' has malformed secret '$secret'." ;; esac
    case "$declaration" in explicit | heuristic | none) ;; *) die "context: value '$name' has malformed declaration '$declaration'." ;; esac
    if [[ "$secret" == true ]]; then
        [[ -z "$digest" || "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || die "context: value '$name' has a malformed digest."
        [[ -z "$reference" || "$reference" =~ ^@[A-Za-z0-9_-]+:.+$ ]] \
            || die "context: value '$name' has a malformed reference."
        jq -cn --arg source "$source" --arg d "$declaration" \
            --arg ref "$reference" --arg digest "$digest" \
            '{source: $source, secret: true, declaration: $d,
              reference: (if $ref == "" then null else $ref end),
              digest: (if $digest == "" then null else $digest end)}'
        return 0
    fi
    [[ -z "$reference" && -z "$digest" ]] || die "context: value '$name' is not secret but carries a reference or digest."
    [[ "$declaration" == "none" ]] || die "context: value '$name' is not secret but declares '$declaration'."
    case "$raw" in
        t:*) text="${raw#t:}" ;;
        b:*) text=$(printf '%s' "${raw#b:}" | base64 -d) \
                || die "context: value '$name' has a malformed base64 raw form." ;;
        *) die "context: value '$name' has a malformed raw form." ;;
    esac
    jq -cn --arg source "$source" --arg sf "$text" \
        '{source: $source, secret: false, declaration: "none",
          reference: null, digest: null, source_form: $sf}'
}

# cloudify_context_event_values_json [name...] - the event projection of the
# given resolved names (default: none, {}): one JSON object mapping NAME to
# its event-shape value metadata.
function cloudify_context_event_values_json() {
    local n
    { for n in "$@"; do
        printf '%s\t' "$n"
        cloudify_context_event_value_json "$n"
      done; } | jq -cRn '
        reduce inputs as $line ({};
            ($line | split("\t")) as $p
            | . + {($p[0]): ($p[1:] | join("\t") | fromjson)})'
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
