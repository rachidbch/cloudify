#!/usr/bin/env bash
# lib/migrate-registry.sh - legacy registry-record conversion (S2; ADR-043).
#
# Converts one old deployment id's registry records
# (<bucket>/deployments/<id>/pkgs/<pkg>/config.yaml) into lean inventory
# records (<host-state-root>/deployments/<app>/<flavor>/<name>/packages/
# <pkg>/default/state.json) with one migrate-registry event per record.
#
# Two phases in one command; the per-application approval is the review
# between them (ADR-043):
#   investigate (default, read-only) - resolve each record's target from the
#     record's own node/instance fields, then run the ad-hoc (unnamed,
#     therefore unrecorded) verify on that target with the record's
#     non-secret values as caller env: playfield facts before any write.
#   --write - the investigation runs fresh; a failed verify refuses that
#     record by name before anything is written; otherwise a restricted
#     backup of the old record, then lean record + event through the one
#     inventory transition. Idempotent: a valid destination record is
#     reported and skipped. Old records are never deleted here (the sweep is
#     a later, separately approved step).
#
# Value mapping (schemas/v1/README.md):
#   @<backend>:...                 -> **** (secret reference; locator dropped)
#   @@x                            -> @x unescaped, then classified
#   @base64:...                    -> decoded, then classified
#   marker- or suffix-classified   -> **** (plaintext dropped, no digest)
#   anything else                  -> literal, as stored
# status installed|configured converts; removed refuses (migration history);
# anything else refuses by name. version carries over; empty becomes null.
# Reports are value-free: names, paths, classes and outcomes only.

_CLOUDIFY_MIGRATE_REGISTRY_LOADED="${_CLOUDIFY_MIGRATE_REGISTRY_LOADED:-}"
[[ -n "$_CLOUDIFY_MIGRATE_REGISTRY_LOADED" ]] && return 0
_CLOUDIFY_MIGRATE_REGISTRY_LOADED=1

_cloudify_migr_usage() {
    cat <<'EOF'
Usage: cloudify deployment migrate-registry <old-deployment-id>
                   --application <app> [--flavor <flavor>] [--name <deployment>]
                   [--operator <name>] [--write]

Investigate (default, read-only) or convert (--write) the legacy registry
records of one old deployment id, one application at a time (ADR-043).
The application/flavor/name mapping is operator-supplied: the old id is never
split or guessed. Investigate resolves each record's target and runs the
ad-hoc verify with the record's non-secret values; review its report, then
re-run with --write to convert (the investigation runs again, fresh).
The old records are not deleted; the sweep is a separate later step.
EOF
}

# _cloudify_migr_field <file> <key> - the value after `KEY: ` (one line),
# leading store padding stripped. Empty when absent.
_cloudify_migr_field() {
    local file="$1" want="$2" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
        key="${line%%:*}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" == "$want" ]] || continue
        line="${line#*:}"
        printf '%s\n' "${line#"${line%%[![:space:]]*}"}"
        return 0
    done < "$file"
    return 0
}

# _cloudify_migr_class <pkg> <name> - why a name is classified (marker wins
# over suffix); empty when the name is not classified.
_cloudify_migr_class() {
    local pkg="$1" name="$2" marked
    marked=$(_cloudify_vars_secret_names "$pkg" 2>/dev/null || true)
    while IFS= read -r marked; do
        [[ -n "$marked" ]] || continue
        if [[ "$marked" == "$name" ]]; then
            printf 'marker\n'
            return 0
        fi
    done <<< "$marked"
    if _cloudify_vars_is_secret_name "$name"; then
        printf 'suffix\n'
        return 0
    fi
    return 0
}

# _cloudify_migr_map <name> <raw> <classified>
# Prints "<class-label>\x1f<mapped-form>" (unit separator; the form may be
# multiline or empty). Dies named on an undecodable form.
_cloudify_migr_map() {
    local name="$1" raw="$2" classified="$3" label form
    if [[ "$raw" == @base64:* ]]; then
        form=$(printf '%s' "${raw#@base64:}" | base64 -d 2>/dev/null) ||
            die "migrate-registry: '$name' has an undecodable @base64: form."
        label="base64"
    elif [[ "$raw" == @@* ]]; then
        form="${raw#@}"
        label="escaped"
    elif [[ "$raw" == @* ]]; then
        # A secret reference: the locator is never persisted (mapping rules).
        printf 'secret-reference\x1f****\n'
        return 0
    else
        form="$raw"
        label="literal"
    fi
    if [[ -n "$classified" ]]; then
        printf '%s-secret\x1f****\n' "$label"
        return 0
    fi
    printf '%s\x1f%s\n' "$label" "$form"
}

# _cloudify_migr_walk <id> - every legacy record path for the id, across the
# ivps nodes root and the fallback external-host root (both bucket depths),
# the same walk the migration report uses (schemas/v1/validate.sh).
_cloudify_migr_walk() {
    local id="$1" nodes config root p
    nodes="${IVPS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ivps}/nodes"
    config="${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}"
    for root in "$nodes" "$config/registry/hosts"; do
        [[ -d "$root" ]] || continue
        shopt -s nullglob
        for p in "$root"/*/deployments/"$id"/pkgs/*/config.yaml \
                 "$root"/*/*/deployments/"$id"/pkgs/*/config.yaml; do
            [[ -f "$p" ]] && printf '%s\n' "$p"
        done
        shopt -u nullglob
    done
    return 0
}

# cloudify_deployment_migrate_registry <id> --application <app>
#   [--flavor <flavor>] [--name <name>] [--operator <name>] [--write]
function cloudify_deployment_migrate_registry() {
    local id="" app="" flavor="default" name="default" operator="" write=0
    while [[ -n "${1:-}" ]]; do
        case "$1" in
            --application) app="${2:-}"; shift 2 ;;
            --flavor) flavor="${2:-}"; shift 2 ;;
            --name) name="${2:-}"; shift 2 ;;
            --operator) operator="${2:-}"; shift 2 ;;
            --write) write=1; shift ;;
            -h|--help) _cloudify_migr_usage; return 0 ;;
            -*) die "deployment migrate-registry: unknown flag '$1'." ;;
            *)
                [[ -z "$id" ]] || die "deployment migrate-registry: unexpected argument '$1'."
                id="$1"; shift
                ;;
        esac
    done
    [[ -n "$id" && -n "$app" ]] || { _cloudify_migr_usage >&2; return 2; }
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    _cloudify_identity_check_component "deployment name" "$name"
    if ((write)); then
        # The operator writer is resolved before anything is written: a missing
        # name is a usage error, never a mid-write surprise.
        [[ -n "${operator:-${CLOUDIFY_OPERATOR:-}}" ]] ||
            die "deployment migrate-registry: --write needs the operator's name (--operator or CLOUDIFY_OPERATOR)."
    fi
    local writer_json=""
    if [[ -n "${operator:-${CLOUDIFY_OPERATOR:-}}" ]]; then
        writer_json=$(cloudify_state_operator_writer "${operator:-${CLOUDIFY_OPERATOR:-}}")
    fi

    local -a olds=()
    mapfile -t olds < <(_cloudify_migr_walk "$id")
    if (( ${#olds[@]} == 0 )); then
        msg "deployment migrate-registry: no legacy records for '$id'; nothing to convert."
        return 0
    fi

    local mode="investigate"
    ((write)) && mode="convert"
    msg "deployment migrate-registry: $mode of ${#olds[@]} record(s) for '$id' as $app/$flavor/$name (old records are kept; the sweep is a later step)"

    local backup_dir=""
    if ((write)); then
        backup_dir="${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/migration-backup/$(date -u '+%Y%m%dT%H%M%SZ')-$id"
    fi

    local old pkg converted=0 already=0 refused=0
    local -a refused_names=()
    for old in ${olds[@]+"${olds[@]}"}; do
        pkg="$(basename "$(dirname "$old")")"
        _cloudify_state_check_package "$pkg" ||
            die "deployment migrate-registry: '$old' has an invalid package name."
        # Proven-fact cross-checks: the record's own fields must agree with
        # its path before anything is derived from them.
        [[ "$(_cloudify_migr_field "$old" deployment)" == "$id" ]] ||
            die "deployment migrate-registry: '$old' records deployment '$(_cloudify_migr_field "$old" deployment)', not '$id'."
        [[ "$(_cloudify_migr_field "$old" package)" == "$pkg" ]] ||
            die "deployment migrate-registry: '$old' records package '$(_cloudify_migr_field "$old" package)', not '$pkg'."

        local status version node inst target
        status="$(_cloudify_migr_field "$old" status)"
        version="$(_cloudify_migr_field "$old" version)"
        node="$(_cloudify_migr_field "$old" node)"
        inst="$(_cloudify_migr_field "$old" instance)"
        target="$node${inst:+:$inst}"

        printf 'record path=%s bucket-record node=%s instance=%s package=%s status=%s version=%s\n' \
            "$old" "$node" "$inst" "$pkg" "$status" "$version"

        if [[ "$status" == "removed" ]]; then
            printf '  refused migration-history (a removal is history, never an inventory)\n'
            refused=$((refused + 1)); refused_names+=("$pkg@$target:removed")
            continue
        fi
        case "$status" in
            installed|configured) ;;
            *)
                printf '  refused unresolved-fact (status is neither installed, configured nor removed)\n'
                refused=$((refused + 1)); refused_names+=("$pkg@$target:status")
                continue
                ;;
        esac

        # The destination and idempotence first: a converted record is not
        # re-investigated and not re-written.
        local rec_dir="" rec
        if ! rec_dir=$(ivps node path "$target" 2>/dev/null) || [[ -z "$rec_dir" ]]; then
            printf '  refused unresolved-fact (target %s does not resolve in the ivps inventory)\n' "$target"
            refused=$((refused + 1)); refused_names+=("$pkg@$target:target")
            continue
        fi
        rec_dir=$(cloudify_state_record_dir "$node" "$inst" "$app" "$flavor" "$name" "$pkg" default)
        rec="$rec_dir/state.json"
        if [[ -f "$rec" ]]; then
            if cloudify_state_validate_file "$CLOUDIFY_SCHEMA_DIR/package-state.schema.json" "$rec" >/dev/null 2>&1; then
                printf '  already converted (%s valid at revision %s); skipping\n' "$rec" "$(jq -r '.revision' "$rec")"
                already=$((already + 1))
                continue
            fi
            die "deployment migrate-registry: '$rec' exists but is not a valid record; refusing to touch it."
        fi

        # A missing recipe cannot be probed: refuse by name before mapping.
        if ! cloudify_is_package "$pkg" >/dev/null 2>&1; then
            printf '  refused unresolved-fact (no recipe for %s; the deployment cannot be probed)\n' "$pkg"
            refused=$((refused + 1)); refused_names+=("$pkg@$target:recipe")
            continue
        fi

        # Map every stored value: names, classes and recorded forms. Forms
        # travel into the verify env array and the jq accumulator - never to
        # stdout (value-free report).
        local acc line key varname raw classified label form mapped_env=0
        local -a venv=(env -u CLOUDIFY_APPLICATION -u CLOUDIFY_FLAVOR -u CLOUDIFY_DEPLOYMENT_NAME)
        acc=$(mktemp "$CLOUDIFY_TMP/migr-acc-XXXXXX")
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" && "$line" != \#* && "$line" == *:* ]] || continue
            key="${line%%:*}"
            key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
            [[ "$key" == var.* ]] || continue
            varname="${key#var.}"
            [[ "$varname" =~ ^[A-Z_][A-Z0-9_]*$ ]] ||
                die "deployment migrate-registry: '$old' holds an invalid value name '$varname'."
            raw="${line#*:}"
            raw="${raw#"${raw%%[![:space:]]*}"}"
            classified=$(_cloudify_migr_class "$pkg" "$varname")
            label=$(_cloudify_migr_map "$varname" "$raw" "$classified")
            form="${label#*$'\x1f'}"
            label="${label%%$'\x1f'*}"
            printf '  var %s (%s)\n' "$varname" "$label"
            jq -cn --arg n "$varname" --arg f "$form" '{($n): $f}' >> "$acc" ||
                die "deployment migrate-registry: cannot record the mapping for '$varname'."
            if [[ -z "$classified" && "$label" != "secret-reference" ]]; then
                venv+=("$varname=$form")
                mapped_env=$((mapped_env + 1))
            else
                printf '  var %s not probed (no value is available; the record keeps only the name)\n' "$varname"
            fi
        done < "$old"

        # Investigation: the ad-hoc (unnamed -> unrecorded) verify on the
        # record's target, with the record's non-secret values as caller env.
        local vrc=0
        "${venv[@]}" cloudify --on "$target" verify "$pkg" || vrc=$?
        if (( vrc != 0 )); then
            printf '  refused unresolved-fact (ad-hoc verify failed, rc %s: the record does not reflect the deployment)\n' "$vrc"
            refused=$((refused + 1)); refused_names+=("$pkg@$target:verify-rc-$vrc")
            rm -f "$acc"
            continue
        fi
        printf '  verify passed on %s (%d value(s) probed)\n' "$target" "$mapped_env"

        if ((!write)); then
            rm -f "$acc"
            continue
        fi

        # --write: restricted backup of the old record before this write.
        local backup="$backup_dir/${pkg}__${node}__${inst:-none}.yaml"
        (umask 077; mkdir -p "$backup_dir")
        (umask 077; cp "$old" "$backup") ||
            die "deployment migrate-registry: cannot back up '$old' before the write."
        chmod 600 "$backup"

        # The lean record and the migrate-registry event, through the one
        # inventory transition (revision stamping, validation, atomic landing).
        local values next_file ev_file eid now tool_version host_key summary
        values=$(jq -s 'if length == 0 then {} else add end' "$acc")
        rm -f "$acc"
        local version_json='null'
        if [[ -n "$version" ]]; then
            [[ "$version" =~ ^[A-Za-z0-9._+~:-]+$ ]] ||
                die "deployment migrate-registry: '$old' carries an invalid version string."
            version_json="\"$version\""
        fi
        host_key=$(cloudify_state_host_key_of "$node" "$inst")
        next_file=$(mktemp "$CLOUDIFY_TMP/migr-next-XXXXXX")
        jq -cn --argjson version "$version_json" --argjson values "$values" \
            '{schema_version: 1, target: "direct", revision: 1,
              version: $version, user_forced: []} + $values' > "$next_file" ||
            die "deployment migrate-registry: cannot render the record for '$pkg'."
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        tool_version=$(cloudify_state_writer_identity | jq -r .tool_version)
        summary="converted from $old; ad-hoc verify passed on $target ($mapped_env value(s) probed)"
        if (( ${#summary} > 512 )); then summary="${summary:0:512}"; fi
        ev_file=$(mktemp "$CLOUDIFY_TMP/migr-ev-XXXXXX")
        jq -cn --arg at "$now" --arg tool "$tool_version" \
            --argjson writer "$writer_json" --arg hk "$host_key" \
            --arg app "$app" --arg flavor "$flavor" --arg name "$name" \
            --arg node "$node" --arg inst "$inst" --arg pkg "$pkg" \
            --argjson values "$values" --arg summary "$summary" \
            '{schema_version: 1, at: $at, tool: "cloudify", tool_version: $tool,
              writer: $writer, run_id: null, step_id: "migrate-registry",
              application: $app, flavor: $flavor, deployment: $name,
              application_commit: null, development_override: true,
              subject: {kind: "package",
                        host: ($node + (if $inst != "" then ":" + $inst else "" end)),
                        host_key: $hk,
                        package: $pkg, package_instance: "default"},
              phase: null, command_kind: "migrate-registry", origin: "old-registry",
              values: $values,
              outcome: {exit_status: 0, summary: $summary}}' > "$ev_file" ||
            die "deployment migrate-registry: cannot render the event for '$pkg'."

        eid=$(cloudify_state_inventory_apply "$rec" "$ev_file" "$next_file") ||
            die "deployment migrate-registry: the inventory transition for '$pkg' failed; nothing half-landed."
        rm -f "$ev_file" "$next_file"
        converted=$((converted + 1))
        printf '  converted: event %s, record %s (backup %s)\n' "$eid" "$rec" "$backup"
    done

    printf 'summary converted=%d already-converted=%d refused=%d\n' "$converted" "$already" "$refused"
    if (( refused > 0 )); then
        printf 'refused (names only): %s\n' "$(IFS='; '; echo "${refused_names[*]}")"
        return 1
    fi
    return 0
}
