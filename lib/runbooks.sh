#!/usr/bin/env bash
# lib/runbooks.sh — playable runbooks (Branch 7 T6a)
#
# A runbook is repo-tracked Markdown: structure + names only, never values.
# Front-matter declares the deployment and its named targets; each fenced
# ```bash step=<type> ...``` block is one step. T6a parses, discovers, binds
# targets, preflights required vars and previews (`--dry-run`). Step execution,
# outputs and the human gate land in T6b; replay in T6c.
#
# Machine contract (tab-separated, stable):
#   cloudify_runbook_parse <path>            one line per step:
#                                            type \t id \t target \t pkg \t body-b64
#   cloudify_runbook_meta <path>             deployment \t targets-csv
#   cloudify_runbook_find <id> [root]        path of the single matching runbook
#   cloudify_runbook_bind_targets <path> [--target name=addr]...
#                                            name \t node \t instance \t ssh_host
#   cloudify_runbook_preflight <path> [--target name=addr]...
#   cloudify_deployment_run <id> [--runbook <path>] [--target name=addr]...
#                               [--from <id>] [--dry-run] [--yes]
#
# body-b64 is base64 so a multi-line shell body survives one line.  Empty fields
# print as empty (never omitted): a human-gate step has no target and no pkg.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_RUNBOOKS_LOADED:-}" ]] && return 0
_CLOUDIFY_RUNBOOKS_LOADED=1

_CLOUDIFY_RUNBOOK_TYPES=(launch install configure verify uninstall human-gate)
# Step types that consume a package (and so declare required vars)
_CLOUDIFY_RUNBOOK_PKG_TYPES=(install configure verify uninstall)

#== Internals ==

# _cloudify_runbook_root — the runbooks tree, resolved like `pkg/`
# (${CLOUDIFY_DIR}/runbooks). CLOUDIFY_RUNBOOKS_DIR overrides it for tests.
function _cloudify_runbook_root() {
    printf '%s\n' "${CLOUDIFY_RUNBOOKS_DIR:-${CLOUDIFY_DIR:-$HOME/cloudify}/runbooks}"
}

# _cloudify_runbook_type_known <type>
function _cloudify_runbook_type_known() {
    local type="${1:-}" k
    for k in "${_CLOUDIFY_RUNBOOK_TYPES[@]}"; do
        [[ "$type" == "$k" ]] && return 0
    done
    return 1
}

# _cloudify_runbook_pkg_type <type>
function _cloudify_runbook_pkg_type() {
    local type="${1:-}" k
    for k in "${_CLOUDIFY_RUNBOOK_PKG_TYPES[@]}"; do
        [[ "$type" == "$k" ]] && return 0
    done
    return 1
}

# _cloudify_runbook_frontmatter <path> — print the front-matter body (the lines
# between the first two `---`), rc 1 when the file has none.
function _cloudify_runbook_frontmatter() {
    local path="${1:-}" line opened=false
    [[ -f "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if ! $opened; then
            [[ "$line" == "---" ]] || return 1
            opened=true
            continue
        fi
        [[ "$line" == "---" ]] && return 0
        printf '%s\n' "$line"
    done < "$path"
    return 1
}

# _cloudify_runbook_meta_parse <path> — print "deployment\ttargets-csv".
# Targets may be comma- or space-separated in the source; the CSV is always
# comma-separated, deduplicated, in declaration order.
function _cloudify_runbook_meta_parse() {
    local path="${1:-}" fm line key val deployment="" targets_raw=""
    fm=$(_cloudify_runbook_frontmatter "$path") ||
        die "Runbook '$path': missing front-matter (expected the opening '---' and a closing '---')."
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        key="$(_cloudify_vars_trim "${line%%:*}")"
        val="$(_cloudify_vars_trim "${line#*:}")"
        case "$key" in
            deployment) deployment="$val" ;;
            targets) targets_raw="$val" ;;
        esac
    done <<< "$fm"
    [[ -n "$deployment" ]] || die "Runbook '$path': front-matter is missing 'deployment:'."

    local -a targets=()
    local -a parts=()
    IFS=', ' read -ra parts <<< "$targets_raw" || true
    local p seen=""
    for p in ${parts[@]+"${parts[@]}"}; do
        p="$(_cloudify_vars_trim "$p")"
        [[ -n "$p" ]] || continue
        [[ ",$seen," == *",$p,"* ]] && continue
        seen="${seen:+$seen,}$p"
        targets+=("$p")
    done
    local csv=""
    if [[ ${#targets[@]} -gt 0 ]]; then
        csv=$(
            IFS=,
            printf '%s' "${targets[*]}"
        )
    fi
    printf '%s\t%s\n' "$deployment" "$csv"
}

# _cloudify_runbook_deployment_of <path> — front-matter deployment id, or empty
function _cloudify_runbook_deployment_of() {
    local path="${1:-}" fm line key
    fm=$(_cloudify_runbook_frontmatter "$path") || return 0
    while IFS= read -r line; do
        key="$(_cloudify_vars_trim "${line%%:*}")"
        [[ "$key" == "deployment" ]] || continue
        printf '%s' "$(_cloudify_vars_trim "${line#*:}")"
        return 0
    done <<< "$fm"
    return 0
}

# _cloudify_runbook_emit_step <path> <line> <info> <body> <index> <declared-ref> \
#                               <seen-ref>
# Validate one fenced block. A non-step fence (info not "bash step=...") is
# silently ignored. A step prints "type\tid\ttarget\tpkg\tbody-b64", or dies
# with the runbook path + the fence's line number.
function _cloudify_runbook_emit_step() {
    local path="$1" line="$2" info="$3" body="$4" index="$5"
    local -n _declared="$6"
    local -n _seen="$7"

    local -a tokens=()
    IFS=$' \t\n' read -ra tokens <<< "$info" || true
    [[ "${tokens[0]:-}" == "bash" && "${tokens[1]:-}" == step=* ]] || return 0

    local type="${tokens[1]#step=}"
    _cloudify_runbook_type_known "$type" ||
        die "Runbook '$path': line $line: unknown step type '$type' (expected: ${_CLOUDIFY_RUNBOOK_TYPES[*]})."

    local target="" pkg="" id="" tok i
    for ((i = 2; i < ${#tokens[@]}; i++)); do
        tok="${tokens[i]}"
        case "$tok" in
            target=*) target="${tok#target=}" ;;
            pkg=*) pkg="${tok#pkg=}" ;;
            id=*) id="${tok#id=}" ;;
            *) die "Runbook '$path': line $line: unknown step attribute '$tok'." ;;
        esac
    done

    # A human gate is prose; every other step addresses a target.
    if [[ "$type" != "human-gate" && -z "$target" ]]; then
        die "Runbook '$path': line $line: step '$type' is missing 'target='."
    fi
    if _cloudify_runbook_pkg_type "$type" && [[ -z "$pkg" ]]; then
        die "Runbook '$path': line $line: step '$type' is missing 'pkg='."
    fi
    if [[ -n "$target" && -z "${_declared[$target]:-}" ]]; then
        die "Runbook '$path': line $line: target '$target' is not declared in the front-matter 'targets:'."
    fi

    [[ -n "$id" ]] || id=$(printf '%02d' "$index")
    [[ -z "${_seen[$id]:-}" ]] || die "Runbook '$path': line $line: duplicate step id '$id'."
    _seen["$id"]=1

    printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$id" "$target" "$pkg" \
        "$(printf '%s' "$body" | base64 -w0)"
}

#== Public API ==

# cloudify_runbook_meta <path> — "deployment\ttargets-csv"
function cloudify_runbook_meta() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_meta <path>"
    _cloudify_runbook_meta_parse "$path"
}

# cloudify_runbook_parse <path> — one machine line per step.
function cloudify_runbook_parse() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_parse <path>"
    [[ -f "$path" ]] || die "Runbook '$path': file not found."

    local meta targets_csv
    meta=$(_cloudify_runbook_meta_parse "$path")
    targets_csv="${meta#*$'\t'}"
    local -a declared_list=()
    if [[ -n "$targets_csv" ]]; then
        IFS=',' read -ra declared_list <<< "$targets_csv" || true
    fi
    local -A declared=()
    local t
    # shellcheck disable=SC2034  # read through the nameref in _cloudify_runbook_emit_step
    for t in ${declared_list[@]+"${declared_list[@]}"}; do
        declared["$t"]=1
    done

    local line lineno=0 in_block=false info="" body="" open_line=0 index=0 trimmed
    # shellcheck disable=SC2034  # read through the nameref in _cloudify_runbook_emit_step
    local -A seen_ids=()
    # shellcheck disable=SC2094  # emit reads $path argument only; it never writes it
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        if ! $in_block; then
            if [[ "$trimmed" == '```'* ]]; then
                info="${trimmed:3}"
                info=$(_cloudify_vars_trim "$info")
                in_block=true
                body=""
                open_line=$lineno
            fi
            continue
        fi
        if [[ "$trimmed" == '```' ]]; then
            in_block=false
            index=$((index + 1))
            _cloudify_runbook_emit_step "$path" "$open_line" "$info" "$body" "$index" \
                declared seen_ids
            continue
        fi
        body="${body:+$body$'\n'}$line"
    done < "$path"
    $in_block && die "Runbook '$path': line $open_line: unterminated fenced block."
    return 0
}

# cloudify_runbook_find <deployment-id> [<runbooks-root>] — print the path of the
# single runbook whose front-matter declares that deployment.
function cloudify_runbook_find() {
    local id="${1:-}" root
    [[ -n "$id" ]] || die "Usage: cloudify_runbook_find <deployment-id> [<runbooks-root>]"
    root="${2:-$(_cloudify_runbook_root)}"
    [[ -d "$root" ]] || die "Runbooks root '$root' not found."

    local -a matches=()
    local f dep
    while IFS= read -r f; do
        dep=$(_cloudify_runbook_deployment_of "$f")
        [[ "$dep" == "$id" ]] && matches+=("$f")
    done < <(find "$root" -type f -name '*.md' | sort)
    [[ ${#matches[@]} -gt 0 ]] || die "No runbook found for deployment '$id' under '$root'."
    [[ ${#matches[@]} -eq 1 ]] ||
        die "Multiple runbooks found for deployment '$id':"$'\n'"$(printf '  %s\n' "${matches[@]}")"
    printf '%s\n' "${matches[0]}"
}

# cloudify_runbook_bind_targets <path> [--target name=addr]...
# For every declared target: the CLI binding, else the deployment-store var
# TARGET_<NAME> (uppercased). Prints "name\tnode\tinstance\tssh_host" after
# validating each address via the target resolver; dies listing every unbound
# target (and a binding for a name the runbook does not declare).
function cloudify_runbook_bind_targets() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_bind_targets <path> [--target name=addr]..."
    shift || true

    local -A bindings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "runbook: --target expects name=addr."
                bindings["${1%%=*}"]="${1#*=}"
                ;;
            *) die "runbook: unknown argument '$1'." ;;
        esac
        shift
    done

    local meta deployment targets_csv
    meta=$(_cloudify_runbook_meta_parse "$path")
    deployment="${meta%%$'\t'*}"
    targets_csv="${meta#*$'\t'}"
    local -a targets=()
    if [[ -n "$targets_csv" ]]; then
        IFS=',' read -ra targets <<< "$targets_csv" || true
    fi

    # Fail closed on a binding the runbook never declared (a typo would
    # otherwise surface only as a confusing "unbound target" for another name).
    local bname t found
    for bname in "${!bindings[@]}"; do
        found=false
        for t in ${targets[@]+"${targets[@]}"}; do
            [[ "$t" == "$bname" ]] && { found=true; break; }
        done
        $found || die "runbook '$path': --target '$bname' is not a declared target."
    done

    local name addr resolved
    local -a lines=() unbound=()
    for name in ${targets[@]+"${targets[@]}"}; do
        addr="${bindings[$name]:-}"
        if [[ -z "$addr" ]]; then
            addr=$(_cloudify_vars_store_get "$(_cloudify_deployment_config "$deployment")" "TARGET_${name^^}")
        fi
        if [[ -z "$addr" ]]; then
            unbound+=("$name")
            continue
        fi
        # dies (fail closed) on an unknown/ambiguous address
        resolved=$(_cloudify_target_resolve "$addr")
        lines+=("$(printf '%s\t%s' "$name" "$resolved")")
    done

    if [[ ${#unbound[@]} -gt 0 ]]; then
        die "Unbound target(s) for deployment '$deployment': ${unbound[*]}. Bind with --target <name>=<addr> or set the deployment var TARGET_<NAME>."
    fi
    local l
    for l in ${lines[@]+"${lines[@]}"}; do printf '%s\n' "$l"; done
}

# cloudify_runbook_preflight <path> [--target name=addr]...
# Resolve every target, then check that each required name (a bare NAME line in
# pkg/<pkg>/.remote-vars) of every install/configure/verify/uninstall step
# resolves through the var ladder. A recipe-default source means unresolved.
# Dies listing every missing "pkg: NAME".
function cloudify_runbook_preflight() {
    local path="${1:-}"
    [[ -n "$path" ]] || die "Usage: cloudify_runbook_preflight <path> [--target name=addr]..."
    shift || true

    local meta deployment
    meta=$(_cloudify_runbook_meta_parse "$path")
    deployment="${meta%%$'\t'*}"
    # Target validation first: an unbound target is a harder failure than a var.
    cloudify_runbook_bind_targets "$path" "$@" > /dev/null

    # The deployment store of the runbook's own deployment is part of the ladder,
    # so source_of must see it (the router exits after `deployment run`).
    export CLOUDIFY_DEPLOYMENT="$deployment"

    local parse_out
    parse_out=$(cloudify_runbook_parse "$path")

    local -a missing=()
    local seen_missing=""
    local line type rest pkg decl dline name src
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type="${line%%$'\t'*}"
        _cloudify_runbook_pkg_type "$type" || continue
        rest="${line#*$'\t'}"     # drop type -> id\ttarget\tpkg\tbody
        rest="${rest#*$'\t'}"      # drop id -> target\tpkg\tbody
        rest="${rest#*$'\t'}"      # drop target -> pkg\tbody
        pkg="${rest%%$'\t'*}"
        [[ -n "$pkg" ]] || continue
        decl="$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
        [[ -f "$decl" ]] || continue
        while IFS= read -r dline; do
            dline="$(_cloudify_vars_trim "$dline")"
            [[ -z "$dline" || "$dline" == \#* ]] && continue
            [[ "$dline" == *=* ]] && continue # NAME=/NAME=value are not required
            [[ "$dline" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            name="$dline"
            src=$(_cloudify_vars_source_of "$name" "$pkg")
            [[ "$src" == "recipe-default" ]] || continue
            [[ ",$seen_missing," == *",$pkg:$name,"* ]] && continue
            seen_missing="${seen_missing:+$seen_missing,}$pkg:$name"
            missing+=("$pkg: $name")
        done < "$decl"
    done <<< "$parse_out"

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Runbook '$path': unresolved required vars:"$'\n'"$(printf '  %s\n' "${missing[@]}")"
    fi
}

# cloudify_deployment_run <id> [--runbook <path>] [--target name=addr]...
#                           [--from <id>] [--dry-run] [--yes]
# T6a: find + parse + bind + preflight + print the plan. Execution is T6b.
function cloudify_deployment_run() {
    local id="" runbook="" from="" dry=0
    local -a target_bindings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runbook)
                shift
                runbook="${1:-}"
                [[ -n "$runbook" ]] || die "deployment run: --runbook needs a path."
                ;;
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "deployment run: --target expects name=addr."
                target_bindings+=("$1")
                ;;
            --from)
                shift
                from="${1:-}"
                [[ -n "$from" ]] || die "deployment run: --from needs a step id."
                ;;
            --dry-run) dry=1 ;;
            --yes) ;; # T6b: non-interactive human-gate confirmation
            -*) die "deployment run: unknown flag '$1'." ;;
            *)
                [[ -z "$id" ]] || die "deployment run: unexpected argument '$1'."
                id="$1"
                ;;
        esac
        shift
    done
    [[ -n "$id" ]] ||
        die "Usage: cloudify deployment run <id> [--runbook <path>] [--target name=addr]... [--from <id>] [--dry-run] [--yes]"

    if [[ -n "$runbook" ]]; then
        [[ -f "$runbook" ]] || die "Runbook '$runbook' not found."
    else
        runbook=$(cloudify_runbook_find "$id")
    fi

    local meta deployment
    meta=$(_cloudify_runbook_meta_parse "$runbook")
    deployment="${meta%%$'\t'*}"
    [[ "$deployment" == "$id" ]] ||
        die "Runbook '$runbook' declares deployment '$deployment', not '$id'."

    local -a bind_args=()
    local b
    for b in ${target_bindings[@]+"${target_bindings[@]}"}; do
        bind_args+=(--target "$b")
    done

    local bound parse_out
    bound=$(cloudify_runbook_bind_targets "$runbook" ${bind_args[@]+"${bind_args[@]}"})
    cloudify_runbook_preflight "$runbook" ${bind_args[@]+"${bind_args[@]}"}
    parse_out=$(cloudify_runbook_parse "$runbook")

    if [[ -n "$from" ]] &&
        ! awk -F'\t' -v want="$from" '$2 == want { found = 1 } END { exit !found }' <<< "$parse_out"; then
        die "deployment run: no step with id '$from' (--from)."
    fi

    msg "Deployment: $deployment"
    msg "Runbook: $runbook"
    msg "Targets:"
    local name rest node instance ssh_host
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        node="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"
        ssh_host="${rest#*$'\t'}"
        msg "  $name -> node=${node:-<plain>} instance=${instance:-<none>} ssh=$ssh_host"
    done <<< "$bound"

    msg "Steps:"
    local type sid tgt pkg
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        sid="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        tgt="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        pkg="${rest%%$'\t'*}"
        msg "  $sid  $type${tgt:+  target=$tgt}${pkg:+  pkg=$pkg}"
    done <<< "$parse_out"

    if [[ "$dry" == "1" ]]; then
        return 0
    fi
    die "Runbook step execution lands in T6b; nothing was executed. Re-run with --dry-run to preview the plan."
}
