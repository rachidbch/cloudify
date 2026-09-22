#!/usr/bin/env bash
# lib/matching.sh - deployment identity: matching, generated names, creation
# (state-model-v2 4.3; design "Deployment identity and matching", ADR-027).
#
# The deployment id is the deployment name. An explicit --name never reaches
# this module (identity by resolve); a bare `_direct` install never matches
# (synthesize-always). Matching decides what a run with NO name does:
#
#   - candidates are the existing deployments of the same application and
#     flavor (never the `_direct` namespace);
#   - a candidate matches when its recorded bindings equal the run's resolved
#     bindings, its recorded (package, instance) inventory set equals the
#     run's covered set, and every record's `last_attempt.requested` values
#     equal the run's resolved value source forms (requested values are
#     recorded even when `applied` is null, so a failed first install still
#     matches);
#   - a match converges that deployment: the name is printed, nothing created;
#   - no match creates a generated `<application>-<flavor>-<UTC-timestamp>
#     [-suffix]` deployment under the uniform commit rule, and the created
#     name is printed.
#
# Comparisons read the ONE parsed dispatch context (cloudify_context_load):
# secrets compare by reference or digest, non-secrets by source form - never
# plaintext.

set -Eeuo pipefail

[[ -n "${_CLOUDIFY_MATCHING_LOADED:-}" ]] && return 0
_CLOUDIFY_MATCHING_LOADED=1

# The naming, commit-rule and creation primitives live in lib/state.sh
# (_cloudify_state_unique_name, _cloudify_state_commit_rule,
# cloudify_state_deployment_create): they predate matching and serve the
# `_direct` synthesis too. This module adds the application/flavor generated
# name and the match-or-create decision on top of them.

# cloudify_state_deployment_generated_name <application> <flavor>
# `<application>-<flavor>-<UTC-timestamp>[-suffix]`, unique against existing
# deployments. The application and flavor segments are truncated to fit the
# 255-byte component cap before the timestamp; a name that still cannot fit
# fails with a named error before any write.
function cloudify_state_deployment_generated_name() {
    local app="${1:?}" flavor="${2:?}"
    # Truncate FIRST, validate the resulting name after (design: the segments
    # are truncated to fit the component byte cap; an input the check would
    # refuse wholesale is exactly what truncation exists for).
    local cap=255 ts base keep
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    base="${app}-${flavor}-${ts}"
    if (( ${#base} > cap )); then
        keep=$((cap - ${#ts} - ${#flavor} - 2))
        if (( keep < 1 )); then
            # The flavor alone crowds out the application: truncate it too.
            keep=$((cap - ${#ts} - 1 - 2))
            (( keep >= 1 )) ||
                die "matching: application '$app' and flavor '$flavor' cannot fit a generated deployment name."
            base="${app:0:1}-$(printf '%s' "$flavor" | cut -c1-"$keep")-${ts}"
        else
            base="${app:0:keep}-${flavor}-${ts}"
        fi
    fi
    _cloudify_state_unique_name "$base" "$app" "$flavor"
}

# cloudify_state_match_deployment <application> <flavor> <context-file>
#                                 <bindings-file>
# Converge-or-create, per the module header. Prints the deployment name on
# stdout (the matched one, or the created one); a creation is announced on
# stderr. The context is parsed ONCE; the covered package set, the target
# triple and every compared value come from that one parse.
function cloudify_state_match_deployment() {
    local app="${1:?}" flavor="${2:?}" ctx_file="${3:?}" bindings="${4:?}"
    [[ "$app" == "_direct" ]] &&
        die "matching: bare installs never match; '_direct' deployments are synthesized and reused only through an explicit --name."
    _cloudify_identity_check_component "application" "$app"
    _cloudify_identity_check_component "flavor" "$flavor"
    [[ -f "$bindings" ]] || die "matching: bindings file '$bindings' missing."
    cloudify_context_load "$ctx_file"

    # The run's target triple comes from the same one parsed context. Parsed
    # by hand: read collapses consecutive tabs, so an empty instance field
    # would shift localhost into it.
    local target="${_CLOUDIFY_CONTEXT[target]:-}" node="" inst="" rest
    [[ -n "$target" ]] || die "matching: the dispatch context names no target."
    node="${target%%$'\t'*}"
    rest="${target#*$'\t'}"
    inst="${rest%%$'\t'*}"

    # The run's covered package set: package.<PKG>.instance lines of the one
    # parsed context, `pkg<TAB>instance`, sorted.
    local key p pkg cinst
    local -a covered=()
    for key in "${!_CLOUDIFY_CONTEXT[@]}"; do
        case "$key" in
            package.*.instance)
                p="${key#package.}"
                pkg="${p%.instance}"
                covered+=("${pkg}"$'\t'"${_CLOUDIFY_CONTEXT[$key]}")
                ;;
        esac
    done
    ((${#covered[@]} > 0)) ||
        die "matching: the dispatch context names no packages; nothing to match."

    # The run's resolved value source forms, the inventory projection: every
    # resolved name of the context, in comparable form.
    local -a vnames=()
    for key in "${!_CLOUDIFY_CONTEXT[@]}"; do
        case "$key" in
            value.*.source)
                p="${key#value.}"
                vnames+=("${p%.source}")
                ;;
        esac
    done
    local run_values
    # shellcheck disable=SC2046  # names are [A-Z_][A-Z0-9_]* - space-free
    run_values=$(cloudify_context_values_json $(printf '%s\n' "${vnames[@]}" | sort))
    local run_bindings_sorted
    run_bindings_sorted=$(sort "$bindings")

    # Candidates: existing deployments of the same application and flavor.
    local capp cflavor cname
    local -a candidates=()
    while IFS=$'\t' read -r capp cflavor cname _; do
        [[ -n "$cname" ]] || continue
        [[ "$capp" == "$app" && "$cflavor" == "$flavor" ]] || continue
        candidates+=("$cname")
    done < <(cloudify_state_list_manifests)

    local name rec_req pkg_root cand_bindings_sorted rel rec match
    for name in ${candidates[@]+"${candidates[@]}"}; do
        # Bindings are part of the match: same values, different hosts, no match.
        cand_bindings_sorted=$(cloudify_manifest_bindings "$app" "$flavor" "$name" | sort) || continue
        [[ "$cand_bindings_sorted" == "$run_bindings_sorted" ]] || continue

        # The candidate's recorded inventory set, on the run's target host
        # (`pkg<TAB>instance`, sorted - the same shape as the covered set).
        pkg_root="$(cloudify_state_inventory_root "${node:-}" "${inst:-}")/$app/$flavor/$name/packages"
        local -a recorded=()
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            rel="${rel%/state.json}"
            recorded+=("$(printf '%s' "$rel" | tr '/' '\t')")
        done < <(find "$pkg_root" -mindepth 3 -maxdepth 3 -name state.json -printf '%P\n' 2>/dev/null | sort)
        [[ "$(printf '%s\n' ${recorded[@]+"${recorded[@]}"} | sort)" \
            == "$(printf '%s\n' "${covered[@]}" | sort)" ]] || continue

        # Every recorded requested value must equal the run's projection.
        match=true
        for rel in "${covered[@]}"; do
            pkg="${rel%%$'\t'*}"
            cinst="${rel##*$'\t'}"
            rec="$pkg_root/$pkg/$cinst/state.json"
            rec_req=$(jq -c '.last_attempt.requested // empty' "$rec" 2>/dev/null) || { match=false; break; }
            [[ -n "$rec_req" ]] || { match=false; break; }
            jq -e --argjson a "$run_values" --argjson b "$rec_req" '$a == $b' >/dev/null 2>&1 <<< "$rec_req" \
                || { match=false; break; }
        done
        [[ "$match" == true ]] || continue

        printf '%s\n' "$name"
        return 0
    done

    # A deployment exists but none converged: a second deployment of this
    # application requires a name (ADR-031, Rachid's ruling 2026-09-21). A
    # differing - or unprovable - configuration refuses, naming the existing
    # deployments; never a silent fork, and never a converge on unproven
    # equality (a digest-only secret the run did not resupply is exactly
    # that: unprovable).
    if (( ${#candidates[@]} > 0 )); then
        local listed=""
        local cname2
        for cname2 in "${candidates[@]}"; do
            listed+="${listed:+, }${cname2}"
        done
        die "matching: application $app/$flavor already has deployment(s): $listed. An unnamed run only creates the FIRST deployment; re-running one or adding another needs --name."
    fi

    # No deployment exists: the first one is created with a generated id and
    # the created name is printed clearly.
    name=$(cloudify_state_deployment_generated_name "$app" "$flavor")
    cloudify_state_deployment_create "$app" "$flavor" "$name" "$bindings"
    printf 'matching: no deployment matched; created %s/%s/%s\n' "$app" "$flavor" "$name" >&2
    printf '%s\n' "$name"
}
