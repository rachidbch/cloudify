#!/usr/bin/env bash
# lib/runbooks.sh — playable runbooks (Branch 7 T6a)
#
# A runbook is repo-tracked Markdown: structure + names only, never values.
# Front-matter declares the deployment and its named targets; each fenced
# ```bash step=<type> ...``` block is one step. T6a parses, discovers, binds
# targets, preflights required vars and previews (`--dry-run`). T6b executes the
# steps (`cloudify_runbook_execute`): run-wide exports, step outputs, the human
# gate and the run snapshot. T6c replays a recorded run
# (`cloudify_deployment_replay`): seed the environment from a run snapshot (target
# bindings + resolved values), then run the same engine.
#
# Machine contract (tab-separated, stable):
#   cloudify_runbook_parse <path>            one line per step:
#                                            type \t id \t target \t pkg \t body-b64
#   cloudify_runbook_meta <path>             deployment \t targets-csv
#   cloudify_runbook_find <id> [root]        path of the single matching runbook
#   cloudify_runbook_bind_targets <path> [--target name=addr]...
#                                            name \t node \t instance \t ssh_host
#   cloudify_runbook_preflight <path> [--target name=addr]...
#   cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes]
#   cloudify_deployment_run <id> [--runbook <path>] [--target name=addr]...
#                               [--from <id>] [--dry-run] [--yes]
#   cloudify_deployment_replay <id> [--at <run>] [--runbook <path>]
#                               [--target name=addr]... [--from <id>] [--dry-run] [--yes]
#
# cloudify_runbook_execute also honours CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES (a run
# snapshot path): the new snapshot records that file's `value.*` lines instead of
# the deployment store's current state. replay sets it so its own snapshot stays
# replayable after the store changes. Snapshots are
# ${CLOUDIFY_DEPLOYMENTS_DIR}/<id>/runs/<utc>.yaml (0600, atomic); a name already
# taken (a run and its immediate replay share a second) gets a -2, -3, ... suffix.
#
# body-b64 is base64 so a multi-line shell body survives one line.  Empty fields
# print as empty (never omitted): a human-gate step has no target and no pkg.
set -Eeuo pipefail

[[ -n "${_CLOUDIFY_RUNBOOKS_LOADED:-}" ]] && return 0
_CLOUDIFY_RUNBOOKS_LOADED=1

_CLOUDIFY_RUNBOOK_TYPES=(launch install configure verify uninstall run human-gate)
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

# _cloudify_runbook_now — UTC ISO8601, second precision (snapshot timestamps)
function _cloudify_runbook_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# _cloudify_runbook_utc — UTC, filename-safe (run snapshot name)
function _cloudify_runbook_utc() {
    date -u +%Y%m%dT%H%M%SZ
}

# _cloudify_runbook_target_addr <node> <instance> <ssh_host>
# Reconstruct the address `--on` accepts from a resolved binding: "node:instance",
# "node", or the plain ssh host when there is no node. This is what a step sees
# as TARGET_<NAME> and what the snapshot records as target.<name>.
function _cloudify_runbook_target_addr() {
    local node="${1:-}" instance="${2:-}" ssh_host="${3:-}" addr
    addr="${node:-$ssh_host}"
    [[ -n "$instance" ]] && addr="$addr:$instance"
    printf '%s' "$addr"
}

# _cloudify_runbook_snapshot <status> <started> <finished> <runbook> \
#                              <targets-var> <values-var> <outputs-var> \
#                              <output-order-var>
# Print the flat run snapshot on stdout. Arrays are passed by name.
function _cloudify_runbook_snapshot() {
    local status="$1" started="$2" finished="$3" runbook="$4"
    local -n _targets="$5"
    local -n _values="$6"
    local -n _outputs="$7"
    local -n _order="$8"
    printf 'status: %s\n' "$status"
    printf 'started_at: %s\n' "$started"
    printf 'finished_at: %s\n' "$finished"
    printf 'runbook: %s\n' "$runbook"
    local l o
    for l in ${_targets[@]+"${_targets[@]}"}; do printf '%s\n' "$l"; done
    for l in ${_values[@]+"${_values[@]}"}; do printf '%s\n' "$l"; done
    for o in ${_order[@]+"${_order[@]}"}; do
        printf 'output.%s: %s\n' "$o" "${_outputs[$o]}"
    done
}

# _cloudify_runbook_select_snapshot <deployment-id> [<at>] — print the chosen run
# snapshot path. --at matches an existing file path, a basename, or a timestamp
# prefix under the deployment's runs dir; without it, the most recently written
# (mtime, not name: a same-second replay shares the source's timestamp prefix).
# Dies on none or several matches.
function _cloudify_runbook_select_snapshot() {
    local id="$1" at="${2:-}"
    [[ -n "$id" ]] || die "Usage: _cloudify_runbook_select_snapshot <deployment-id> [<at>]"

    # An explicit path wins over the runs dir (a copied or archived snapshot).
    if [[ -n "$at" && -f "$at" ]]; then
        printf '%s\n' "$at"
        return 0
    fi

    local runs_dir="$CLOUDIFY_DEPLOYMENTS_DIR/$id/runs"
    [[ -d "$runs_dir" ]] ||
        die "deployment replay: no runs for deployment '$id' (expected '$runs_dir')."

    local -a all=()
    local f
    # Newest first by mtime: a run and its immediate replay share the timestamp
    # prefix (the replay's name gets a -2 suffix), so names alone cannot order them.
    mapfile -t all < <(ls -1t "$runs_dir"/*.yaml 2>/dev/null)
    [[ ${#all[@]} -gt 0 ]] ||
        die "deployment replay: no run snapshot for deployment '$id' under '$runs_dir'."

    if [[ -z "$at" ]]; then
        printf '%s\n' "${all[0]}"
        return 0
    fi

    local -a matches=() base
    for f in "${all[@]}"; do
        base="${f##*/}"
        [[ "$base" == "$at"* ]] && matches+=("$f")
    done
    [[ ${#matches[@]} -gt 0 ]] ||
        die "deployment replay: no run snapshot matching '$at' for deployment '$id' under '$runs_dir'."
    [[ ${#matches[@]} -eq 1 ]] ||
        die "deployment replay: --at '$at' is ambiguous, ${#matches[@]} runs match:"$'\n'"$(printf '  %s\n' "${matches[@]}")"
    printf '%s\n' "${matches[0]}"
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

    # A human gate is prose and `run` is a generic passthrough; every other step
    # addresses a target.
    if [[ "$type" != "human-gate" && "$type" != "run" && -z "$target" ]]; then
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
# T6a find + parse + bind + preflight + print the plan; without --dry-run it then
# dispatches cloudify_runbook_execute.
function cloudify_deployment_run() {
    local id="" runbook="" from="" dry=0 yes=0
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
            --yes) yes=1 ;; # non-interactive human-gate confirmation
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

    local -a exec_args=()
    for b in ${target_bindings[@]+"${target_bindings[@]}"}; do
        exec_args+=(--target "$b")
    done
    [[ -n "$from" ]] && exec_args+=(--from "$from")
    [[ "$yes" == "1" ]] && exec_args+=(--yes)
    cloudify_runbook_execute "$runbook" ${exec_args[@]+"${exec_args[@]}"}
}

# cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes]
# Execute a runbook's steps in document order. Exports CLOUDIFY_DEPLOYMENT,
# TARGET_<NAME> and CLOUDIFY_OUTPUTS_FILE for the whole run; each step gets
# STEP_ID/STEP_TYPE/STEP_TARGET/STEP_PKG. A step appends `name=value` to the
# outputs file and later steps see it as OUT_<name>. Stops at the first failure
# and always writes the run snapshot.
function cloudify_runbook_execute() {
    local path="${1:-}"
    [[ -n "$path" ]] ||
        die "Usage: cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes]"
    shift || true

    local from="" yes=0
    local -a target_bindings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "runbook execute: --target expects name=addr."
                target_bindings+=("$1")
                ;;
            --from)
                shift
                [[ -n "${1:-}" ]] || die "runbook execute: --from needs a step id."
                from="$1"
                ;;
            --yes) yes=1 ;;
            *) die "runbook execute: unknown argument '$1'." ;;
        esac
        shift
    done
    [[ -f "$path" ]] || die "Runbook '$path': file not found."

    local -a bind_args=()
    local b
    for b in ${target_bindings[@]+"${target_bindings[@]}"}; do
        bind_args+=(--target "$b")
    done

    # 1. Fail before executing anything: targets resolvable, required vars present.
    cloudify_runbook_preflight "$path" ${bind_args[@]+"${bind_args[@]}"}

    local meta deployment bound parse_out
    meta=$(_cloudify_runbook_meta_parse "$path")
    deployment="${meta%%$'\t'*}"
    bound=$(cloudify_runbook_bind_targets "$path" ${bind_args[@]+"${bind_args[@]}"})
    parse_out=$(cloudify_runbook_parse "$path")

    if [[ -n "$from" ]] &&
        ! awk -F'\t' -v want="$from" '$2 == want { found = 1 } END { exit !found }' <<< "$parse_out"; then
        die "runbook execute: no step with id '$from' (--from)."
    fi

    # 2. Run-wide exports: the deployment, every bound target, the outputs channel.
    export CLOUDIFY_DEPLOYMENT="$deployment"
    local line rest name node instance ssh_host addr
    local -a target_lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        node="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        instance="${rest%%$'\t'*}"
        ssh_host="${rest#*$'\t'}"
        addr=$(_cloudify_runbook_target_addr "$node" "$instance" "$ssh_host")
        export "TARGET_${name^^}=$addr"
        target_lines+=("target.$name: $addr")
    done <<< "$bound"

    local outputs_file
    outputs_file=$(mktemp) || die "runbook execute: cannot create the outputs file."
    chmod 600 "$outputs_file" 2>/dev/null || true
    export CLOUDIFY_OUTPUTS_FILE="$outputs_file"

    # 3. Snapshot the deployment store's raw vars for the record. A replay sets
    # CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES (its source snapshot): the new record then
    # carries the values the run was seeded with, so it stays replayable even if
    # the store changed since.
    local -a value_lines=()
    local cfg
    if [[ -n "${CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES:-}" ]]; then
        [[ -f "$CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES" ]] ||
            die "runbook execute: replayed snapshot '$CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES' not found."
        local rline
        while IFS= read -r rline; do
            [[ "$rline" == value.* ]] || continue
            value_lines+=("$rline")
        done < "$CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES"
    else
        cfg=$(_cloudify_deployment_config "$deployment")
        if [[ -f "$cfg" ]]; then
            local vline vkey
            while IFS= read -r vline; do
                [[ -n "$vline" && "$vline" != \#* && "$vline" == *:* ]] || continue
                vkey="$(_cloudify_vars_trim "${vline%%:*}")"
                [[ -n "$vkey" ]] || continue
                value_lines+=("value.$vkey: $(_cloudify_vars_trim "${vline#*:}")")
            done < "$cfg"
        fi
    fi

    # 4/5. Walk the steps, streaming their output, collecting step outputs.
    local status="succeeded" fail_msg="" started_at finished_at
    started_at=$(_cloudify_runbook_now)
    local -A run_outputs=()
    local -a run_output_order=()
    local outputs_consumed=0
    local type sid tgt pkg body body_b64 started=0
    [[ -z "$from" ]] && started=1

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        sid="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        tgt="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        pkg="${rest%%$'\t'*}"
        body_b64="${rest#*$'\t'}"
        body=$(printf '%s' "$body_b64" | base64 -d)

        if [[ "$started" == "0" ]]; then
            [[ "$sid" == "$from" ]] || continue
            started=1
        fi

        export STEP_ID="$sid" STEP_TYPE="$type" STEP_TARGET="$tgt" STEP_PKG="$pkg"

        if [[ "$type" == "human-gate" ]]; then
            msg "human-gate [$sid]"
            msg "$body"
            if [[ "$yes" != "1" ]]; then
                if [[ ! -t 0 ]]; then
                    status="failed"
                    fail_msg="Runbook step '$sid' (human-gate): no TTY to confirm; re-run with --yes."
                    break
                fi
                local reply=""
                if ! read -r -p "Confirm step '$sid'? [y/N] " reply || [[ ! "$reply" =~ ^[Yy] ]]; then
                    status="failed"
                    fail_msg="Runbook step '$sid' (human-gate): not confirmed."
                    break
                fi
            fi
            continue
        fi

        local rc=0
        bash -c "$body" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            status="failed"
            fail_msg="Runbook step '$sid' failed (exit $rc)."
        fi

        # Ingest outputs appended by this step (also on failure: keep the record).
        local oline oname oval new_count=0
        while IFS= read -r oline; do
            new_count=$((new_count + 1))
            [[ -n "$oline" && "$oline" != \#* && "$oline" == *=* ]] || continue
            oname="${oline%%=*}"
            oval="${oline#*=}"
            [[ "$oname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            export "OUT_$oname=$oval"
            if [[ -z "${run_outputs[$oname]+x}" ]]; then
                run_output_order+=("$oname")
            fi
            run_outputs["$oname"]="$oval"
        done < <(tail -n +$((outputs_consumed + 1)) "$outputs_file")
        outputs_consumed=$((outputs_consumed + new_count))

        [[ "$status" == "failed" ]] && break
    done <<< "$parse_out"

    finished_at=$(_cloudify_runbook_now)

    # 6. Write the run snapshot (always, success or failure).
    local runs_dir="$CLOUDIFY_DEPLOYMENTS_DIR/$deployment/runs"
    (umask 077; mkdir -p "$runs_dir")
    chmod 700 "$runs_dir" 2>/dev/null || true
    local snapshot tmp
    snapshot="$runs_dir/$(_cloudify_runbook_utc).yaml"
    # A run and its immediate replay land in the same second: never overwrite an
    # existing snapshot, suffix -2, -3, ... instead (the source run must survive
    # a replay). `--at` still selects by timestamp prefix.
    local n=1 base="${snapshot%.yaml}"
    while [[ -e "$snapshot" ]]; do
        n=$((n + 1))
        snapshot="$base-$n.yaml"
    done
    tmp=$(mktemp "$runs_dir/.run.XXXXXX") || die "runbook execute: cannot create the run snapshot."
    _cloudify_runbook_snapshot "$status" "$started_at" "$finished_at" "$path" \
        target_lines value_lines run_outputs run_output_order > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$snapshot"

    rm -f "$outputs_file"
    unset CLOUDIFY_OUTPUTS_FILE STEP_ID STEP_TYPE STEP_TARGET STEP_PKG

    if [[ "$status" == "failed" ]]; then
        die "$fail_msg"
    fi
    msg "Runbook '$path' $status."
    msg "Snapshot: $snapshot"
    return 0
}

# cloudify_deployment_replay <id> [--at <run>] [--runbook <path>] [--target name=addr]...
#                             [--from <id>] [--dry-run] [--yes]
# Re-run a recorded run. The environment is seeded from a run snapshot before
# anything executes: every `target.<name>` becomes a binding (a --target on the
# command line still wins) and every `value.<NAME>` is resolved (a stored
# @base64:/@backend: reference must be resolved here, or the step would receive
# the literal) and exported, so the normal ladder forwards exactly the recorded
# values. The runbook defaults to the snapshot's. Then the same engine as
# `deployment run` runs (preflight + steps + a new run snapshot). Seeded values
# are referred to by name only: never printed, never part of argv.
function cloudify_deployment_replay() {
    local id="" at="" runbook="" from="" dry=0 yes=0
    local -a cli_bindings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --at)
                shift
                at="${1:-}"
                [[ -n "$at" ]] || die "deployment replay: --at needs a run path, basename or timestamp prefix."
                ;;
            --runbook)
                shift
                runbook="${1:-}"
                [[ -n "$runbook" ]] || die "deployment replay: --runbook needs a path."
                ;;
            --target)
                shift
                [[ -n "${1:-}" && "$1" == *=* ]] || die "deployment replay: --target expects name=addr."
                cli_bindings+=("$1")
                ;;
            --from)
                shift
                from="${1:-}"
                [[ -n "$from" ]] || die "deployment replay: --from needs a step id."
                ;;
            --dry-run) dry=1 ;;
            --yes) yes=1 ;;
            -*) die "deployment replay: unknown flag '$1'." ;;
            *)
                [[ -z "$id" ]] || die "deployment replay: unexpected argument '$1'."
                id="$1"
                ;;
        esac
        shift
    done
    [[ -n "$id" ]] ||
        die "Usage: cloudify deployment replay <id> [--at <run>] [--runbook <path>] [--target name=addr]... [--from <id>] [--dry-run] [--yes]"

    local snapshot
    # The selector dies with the reason (none/ambiguous); stop here explicitly
    # rather than relying on errexit, which a caller in a || list disables.
    if ! snapshot=$(_cloudify_runbook_select_snapshot "$id" "$at"); then
        exit 1
    fi
    grep -q '^runbook:' "$snapshot" ||
        die "deployment replay: '$snapshot' is not a run snapshot (no 'runbook:' line)."

    # Command-line bindings win over the snapshot's.
    local -A cli_bound=()
    local b
    for b in ${cli_bindings[@]+"${cli_bindings[@]}"}; do
        cli_bound["${b%%=*}"]="${b#*=}"
    done

    local line key raw value snap_runbook=""
    local -a value_names=() target_args=() seeded_targets=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" == *:* ]] || continue
        key="$(_cloudify_vars_trim "${line%%:*}")"
        raw="$(_cloudify_vars_trim "${line#*:}")"
        case "$key" in
            runbook) snap_runbook="$raw" ;;
            target.*)
                key="${key#target.}"
                [[ -n "$key" ]] || die "deployment replay: '$snapshot': empty target name."
                [[ -n "${cli_bound[$key]+x}" ]] && continue
                target_args+=(--target "$key=$raw")
                seeded_targets+=("$key=$raw")
                ;;
            value.*)
                key="${key#value.}"
                [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "deployment replay: '$snapshot': malformed value name '$key'."
                _cloudify_vars_reserved "$key" &&
                    die "deployment replay: '$snapshot' records the framework-owned var '$key' — refusing to seed it."
                # Resolve before exporting (the env path is a pass-through). The
                # value stays in this process's environment, never in output.
                value=$(_cloudify_resolve_var_value "$key" "$raw") ||
                    die "deployment replay: var $key: cannot resolve the snapshot value — refusing to replay an empty value."
                export "$key"="$value"
                value_names+=("$key")
                ;;
        esac
    done < "$snapshot"

    [[ -n "$runbook" ]] || runbook="$snap_runbook"
    [[ -f "$runbook" ]] ||
        die "deployment replay: runbook '$runbook' (from $snapshot) not found; pass --runbook <path>."

    local names_str="" targets_str=""
    [[ ${#value_names[@]} -gt 0 ]] &&
        names_str=$(IFS=','; printf '%s' "${value_names[*]}")
    [[ ${#seeded_targets[@]} -gt 0 ]] &&
        targets_str=$(IFS=','; printf '%s' "${seeded_targets[*]}")
    msg "Replay: $snapshot"
    msg "Seeded values (names only): ${names_str:-<none>}"
    msg "Seeded targets: ${targets_str:-<none>}"

    local -a run_args=()
    for b in ${cli_bindings[@]+"${cli_bindings[@]}"}; do
        run_args+=(--target "$b")
    done
    for b in ${target_args[@]+"${target_args[@]}"}; do
        run_args+=("$b")
    done
    [[ -n "$from" ]] && run_args+=(--from "$from")
    [[ "$dry" == "1" ]] && run_args+=(--dry-run)
    [[ "$yes" == "1" ]] && run_args+=(--yes)

    # The engine records the seeded values (not the store's current state) in the
    # new snapshot, so a replay stays replayable after the store changes.
    CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES="$snapshot"
    cloudify_deployment_run "$id" --runbook "$runbook" ${run_args[@]+"${run_args[@]}"}
}
