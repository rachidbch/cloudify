#!/usr/bin/env bash
# lib/adoption.sh - deployment adoption (GLOSSARY deployment adoption; plan
# adoption-honesty item 4).
#
# Adoption is an operator action: the operator infers a deployment's state
# from the observed machine, and cloudify records the inference in mechanical
# shape. One command, in order:
#   1. one adoption event per package (writer: operator, command_kind: adopt,
#      no commit - adoption pins no commit) through the one inventory
#      transition (cloudify_state_inventory_apply);
#   2. the package record beside it (applied values with provenance,
#      last_attempt preserved-or-null, health unknown);
#   3. the manifest: created unproved when absent (null commit beside the
#      development override), its status derived from the events -> adopted;
#   4. the seeded verify per package - a read-only dispatch under the
#      deployment tuple, the machine's first cloudify touch. Its outcome only
#      moves health and the derived word: pass -> verified, fail -> health
#      degraded and the word stays adopted. A failed verify never unwrites
#      the adoption, and the command still succeeds: the recording happened.
#
# Values arrive on stdin as TSV facts (one per line):
#   version<TAB><pkg><TAB><version|unknown>
#   value<TAB><pkg><TAB><NAME><TAB><source_form><TAB><source-label>
# Secrets are refused: adoption records claims, not plaintext - a value whose
# source_form starts with '@' (a reference or an escaped literal) is rejected.

_CLOUDIFY_ADOPTION_LOADED="${_CLOUDIFY_ADOPTION_LOADED:-}"
[[ -n "$_CLOUDIFY_ADOPTION_LOADED" ]] && return 0
_CLOUDIFY_ADOPTION_LOADED=1

# _cloudify_adoption_usage - the fact grammar, named.
_cloudify_adoption_usage() {
    cat <<'EOF'
Usage: cloudify adoption record <app>/<flavor>/<name> --on <target> [--notes <text>] <pkg>...

The operator's inferred facts arrive on stdin, one TSV fact per line:
  version<TAB><pkg><TAB><version|unknown>
  value<TAB><pkg><TAB><NAME><TAB><source_form><TAB><source-label>

source-label is one of: caller, deployment, application, package, global, recipe.
Every named package needs a version fact. Secrets are refused: a source_form
starting with '@' (a reference or an escaped literal) is not an inference -
record it through a store instead.
EOF
}

# _cloudify_adoption_facts <pkg>... - read the stdin facts into per-package
# state: _ADOPT_VERSION[pkg], and one JSON object per value fact appended to
# per-package accumulator files (record shape and event shape differ only in
# the redacted field, so both are emitted here).
_cloudify_adoption_facts() {
    local -a pkgs=("$@")
    local kind pkg rest a b c line
    declare -gA _ADOPT_VERSION=()
    local -A have_version=()
    _ADOPT_VALUES_DIR=$(mktemp -d "$CLOUDIFY_TMP/adoption-values-XXXXXX") ||
        die "adoption: cannot create the values accumulator."
    local -A value_files=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        kind="${line%%$'\t'*}"; rest="${line#*$'\t'}"
        pkg="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        local known=false p
        for p in ${pkgs[@]+"${pkgs[@]}"}; do [[ "$p" == "$pkg" ]] && known=true; done
        $known || die "adoption: fact for package '$pkg' - not a named package."
        case "$kind" in
            version)
                [[ -z "${have_version[$pkg]+x}" ]] || die "adoption: two version facts for '$pkg'."
                have_version[$pkg]=1
                a="${rest%%$'\t'*}"
                [[ "$a" == "unknown" || "$a" =~ ^[A-Za-z0-9._+~:-]+$ ]] ||
                    die "adoption: version '$a' for '$pkg' is not a version string or 'unknown'."
                _ADOPT_VERSION[$pkg]=$a
                ;;
            value)
                a="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
                b="${rest%%$'\t'*}"; c="${rest#*$'\t'}"
                [[ "$a" =~ ^[A-Z_][A-Z0-9_]*$ ]] ||
                    die "adoption: value name '$a' is not a value name (uppercase, digits, underscore)."
                [[ -n "$b" ]] || die "adoption: empty source_form for '$a'."
                [[ "$b" != @* ]] ||
                    die "adoption: '$a' carries a secret form ('$b') - adoption records claims, not secrets; use a store."
                case "$c" in
                    caller|deployment|application|package|global|recipe) ;;
                    *) die "adoption: source '$c' for '$a' is not a provenance label (caller, deployment, application, package, global, recipe)." ;;
                esac
                value_files[$pkg]="${value_files[$pkg]:-$(mktemp "$_ADOPT_VALUES_DIR/v-XXXXXX")}"
                jq -cn --arg n "$a" --arg f "$b" --arg s "$c" \
                    '{($n): {source: $s, secret: false, declaration: "none",
                             source_form: $f, reference: null, digest: null, redacted: false}}' \
                    >> "${value_files[$pkg]}" ||
                    die "adoption: cannot record the fact for '$a'."
                ;;
            *) die "adoption: unknown fact kind '$kind' (version | value)." ;;
        esac
    done
    local p vfile_rec vfile_ev
    for p in ${pkgs[@]+"${pkgs[@]}"}; do
        [[ -n "${have_version[$p]+x}" ]] ||
            die "adoption: package '$p' has no version fact."
        value_files[$p]="${value_files[$p]:-$(mktemp "$_ADOPT_VALUES_DIR/v-XXXXXX")}"
        vfile_rec="${value_files[$p]}.record"
        vfile_ev="${value_files[$p]}.event"
        # Both shapes per package: the record's applied values (with redacted)
        # and the event's value metadata (the schema allows no redacted there).
        jq -s 'add' "${value_files[$p]}" > "$vfile_rec"
        jq -s 'add | map_values(del(.redacted))' "${value_files[$p]}" > "$vfile_ev"
        _ADOPT_VALUE_FILES+=("$p|$vfile_rec|$vfile_ev")
    done
}

# cloudify_adoption_record <app>/<flavor>/<name> --on <target> [--notes <text>]
#                         <pkg>... - see the module header.
function cloudify_adoption_record() {
    local id="" target="" notes=""
    local -a pkgs=()
    while [[ -n "${1:-}" ]]; do
        case "$1" in
            --on) target="${2:-}"; shift 2 ;;
            --notes) notes="${2:-}"; shift 2 ;;
            -h|--help) _cloudify_adoption_usage; return 0 ;;
            *)
                if [[ -z "$id" ]]; then id="$1"; else pkgs+=("$1"); fi
                shift
                ;;
        esac
    done
    [[ -n "$id" && "${pkgs[*]:-}" ]] || { _cloudify_adoption_usage >&2; return 2; }
    [[ -n "$target" ]] || { _cloudify_adoption_usage >&2; return 2; }
    [[ -n "$notes" ]] || die "adoption: --notes is required - the adoption event carries the operator's honest summary."

    # Identity: application/flavor/name, validated before anything is created.
    [[ "$id" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]] ||
        die "adoption: identity '$id' is not <app>/<flavor>/<name>."
    local app="${BASH_REMATCH[1]}" flavor="${BASH_REMATCH[2]}" name="${BASH_REMATCH[3]}"
    cloudify_state_deployment_dir "$app" "$flavor" "$name" >/dev/null ||
        die "adoption: identity '$id' is not a valid deployment identity."

    local pkg p
    for p in ${pkgs[@]+"${pkgs[@]}"}; do
        _cloudify_state_check_package "$p" || die "adoption: '$p' is not a package name."
        cloudify_is_package "$p" >/dev/null || die "adoption: no recipe for package '$p'."
    done

    # The runbook the deployment hangs from: identity comes from the path, the
    # binding slot from its front matter. One slot: a single --on target binds
    # one host, so a multi-slot application is not adoptable this way.
    local rb
    rb="$(_cloudify_runbook_root)/$app/$flavor/runbook.md"
    [[ -f "$rb" ]] || die "adoption: no runbook at runbooks/$app/$flavor/runbook.md - a deployment is runbook-shaped; write the runbook first."
    local slots slot
    slots=$(_cloudify_runbook_fm_value "$rb" targets)
    [[ -n "$slots" ]] || die "adoption: runbooks/$app/$flavor/runbook.md declares no targets."
    [[ "$slots" != *,* ]] || die "adoption: the runbook declares several targets ($slots) - adoption binds one host; adopt per slot is not supported yet."
    slot="$slots"

    # The target: node, instance, ssh address (lib/targets.sh; ivps is the
    # inventory provider).
    local row node inst ssh
    row=$(_cloudify_target_resolve "$target")
    IFS=$'\t' read -r node inst ssh <<< "$row"
    local host="${node}${inst:+:$inst}"
    local host_key
    host_key=$(cloudify_state_host_key_of "$node" "$inst")

    _cloudify_adoption_facts ${pkgs[@]+"${pkgs[@]}"}

    # The manifest: created unproved when absent - null commit beside the
    # development override (the schema's encoding for "no commit was proved").
    # An existing manifest is reused untouched (re-adoption is non-destructive;
    # rebinding stays --migrate-targets territory).
    local bindings
    bindings=$(mktemp "$CLOUDIFY_TMP/adoption-bindings-XXXXXX")
    printf '%s\t%s\t%s\t%s\t%s\n' "$slot" "$ssh" "$node" "$inst" "$ssh" > "$bindings"
    if cloudify_manifest_exists "$app" "$flavor" "$name"; then
        # The recorded binding may spell the same host differently (node:instance
        # vs the instance's own name): compare the resolved identity, not the
        # address strings. A different host is a rebinding - a migration.
        local recorded=""
        recorded=$(cloudify_manifest_bindings "$app" "$flavor" "$name" 2>/dev/null |
            awk -F'\t' -v s="$slot" '$1 == s { print $3 "\x1f" $4 }')
        if [[ -n "$recorded" ]]; then
            local r_node r_inst
            IFS=$'\x1f' read -r r_node r_inst <<< "$recorded"
            [[ "$r_node" == "$node" && "$r_inst" == "$inst" ]] ||
                die "adoption: the manifest binds '$slot' to '$r_node${r_inst:+:$r_inst}', not '$node${inst:+:$inst}' - rebinding is a migration (--migrate-targets), not an adoption."
        fi
    else
        cloudify_manifest_write "$app" "$flavor" "$name" "" "" true "$bindings" ||
            die "adoption: cannot create the manifest."
    fi
    rm -f "$bindings"

    # Per package: the adoption event and the record, through the one
    # inventory transition (revision stamping, validation, atomic landing).
    local now writer_json rec rec_dir next_file ev_file eid last_eid=""
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    writer_json=$(cloudify_state_operator_writer "${CLOUDIFY_OPERATOR:-}") ||
        die "adoption: the operator writer needs a name (set CLOUDIFY_OPERATOR)."
    for p in ${pkgs[@]+"${pkgs[@]}"}; do
        local vfile_rec="" vfile_ev=""
        local triple
        for triple in ${_ADOPT_VALUE_FILES[@]+"${_ADOPT_VALUE_FILES[@]}"}; do
            [[ "$triple" == "$p|"* ]] || continue
            vfile_rec="${triple#*|}"; vfile_rec="${vfile_rec%%|*}"
            vfile_ev="${triple##*|}"
        done
        ev_file=$(mktemp "$CLOUDIFY_TMP/adoption-ev-XXXXXX")
        next_file=$(mktemp "$CLOUDIFY_TMP/adoption-next-XXXXXX")
        jq -cn --arg at "$now" --arg tool "$(cloudify_state_writer_identity | jq -r .tool_version)" \
            --argjson writer "$writer_json" \
            --arg app "$app" --arg flavor "$flavor" --arg name "$name" \
            --arg host "$host" --arg host_key "$host_key" \
            --arg pkg "$p" --argjson values "$(cat "$vfile_ev")" \
            --arg summary "$notes" \
            '{schema_version: 1, at: $at, tool: "cloudify", tool_version: $tool, writer: $writer,
              run_id: null, step_id: "adopt",
              application: $app, flavor: $flavor, deployment: $name,
              application_commit: null, development_override: true,
              subject: {kind: "package", host: $host, host_key: $host_key,
                        package: $pkg, package_instance: "default"},
              phase: null, command_kind: "adopt", values: $values,
              outcome: {exit_status: 0, summary: $summary}}' > "$ev_file" ||
            die "adoption: cannot render the event body for '$p'."
        # The next capture: applied values carry the operator's inference;
        # last_attempt is preserved on re-adoption and null on a fresh record;
        # health resets to unknown - the seeded verify re-observes it.
        rec_dir=$(cloudify_state_record_dir "$node" "$inst" "$app" "$flavor" "$name" "$p" default)
        rec="$rec_dir/state.json"
        local last_attempt='null'
        [[ -f "$rec" ]] && last_attempt=$(jq -c '.last_attempt' "$rec")
        local version_json='null'
        [[ "${_ADOPT_VERSION[$p]}" != "unknown" ]] && version_json="\"${_ADOPT_VERSION[$p]}\""
        jq -cn --arg host "$host" --arg host_key "$host_key" \
            --arg pkg "$p" --arg app "$app" --arg flavor "$flavor" --arg name "$name" \
            --arg at "$now" --argjson version "$version_json" \
            --argjson last_attempt "$last_attempt" \
            --argjson values "$(cat "$vfile_rec")" \
            '{schema_version: 1, host: $host, host_key: $host_key,
              package: $pkg, package_instance: "default",
              application: $app, flavor: $flavor, deployment: $name, step_id: "adopt",
              applied: {version: $version, at: $at, values: $values},
              last_attempt: $last_attempt,
              health: {status: "unknown", checked_at: null, event_id: null}}' > "$next_file" ||
            die "adoption: cannot render the record for '$p'."
        eid=$(cloudify_state_inventory_apply "$rec" "$ev_file" "$next_file") ||
            die "adoption: the inventory transition for '$p' failed; nothing half-landed."
        rm -f "$ev_file" "$next_file"
        last_eid="$eid"
        msg "adoption: $p@default on $host - event $eid, record $rec"
    done

    # The manifest's derived fields: recomputed from the events, never claimed
    # and never carried over - a re-adoption re-derives the status AND the
    # commit cache (an adoption pins no commit; a stale hand-era pin goes).
    local word dev commit scan
    word=$(cloudify_state_status_from_events "$app" "$flavor" "$name")
    [[ "$word" == "null" ]] && word=""
    scan=$(_cloudify_state_event_scan "$app" "$flavor" "$name")
    IFS=$'\x1f' read -r _head commit _host <<< "$scan"
    if [[ -z "$commit" ]]; then
        dev=true
    else
        dev=$(jq -r '.development_override // false' \
            "$(cloudify_state_events_root)/${_head:0:4}-${_head:4:2}/$_head.json" 2>/dev/null || true)
        [[ "$dev" == "true" ]] || dev=false
    fi
    cloudify_manifest_update_status "$app" "$flavor" "$name" "$word" "$commit" "$dev" "$last_eid" ||
        die "adoption: cannot update the manifest status."
    msg "adoption: manifest $(cloudify_state_manifest_file "$app" "$flavor" "$name") (status ${word:-none})"

    # The seeded verify: read-only, under the deployment tuple, through the
    # same CLI. Its outcome only moves health and the derived word; a failure
    # never unwrites the adoption and never fails this command.
    local rc failed=0
    for p in ${pkgs[@]+"${pkgs[@]}"}; do
        msg "adoption: seeded verify of '$p' on $host (read-only)..."
        rc=0
        CLOUDIFY_APPLICATION="$app" CLOUDIFY_FLAVOR="$flavor" CLOUDIFY_DEPLOYMENT_NAME="$name" \
            cloudify --on "$target" verify "$p" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            msg "adoption: verify passed - '$p' observed against the applied values."
        else
            failed=1
            log_warn "adoption: verify failed for '$p' (rc $rc) - health records it; the adoption stands (status $(cloudify_manifest_field "$app" "$flavor" "$name" status))."
        fi
    done
    rm -rf "$_ADOPT_VALUES_DIR"
    (( failed == 0 )) || log_warn "adoption: recorded with a failed verify - re-run 'cloudify --on $target verify <pkg>' when ready; a failed verify never unwrites the adoption."
    return 0
}
