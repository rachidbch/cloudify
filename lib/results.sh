#!/usr/bin/env bash
# lib/results.sh - the result-line channel (state-model-v2, Phase 4.3).
#
# The child's framework code prints one `result v1:` line per package attempt,
# when that attempt ends, on the ordinary streamed log (payload
# `exec > >(tee -a ...)` -> SSH channel -> host-prefix stages -> protected log).
# The lines are keyed for the worker's pass-through tap (4.3, later slice);
# nothing here reads, filters or buffers the stream.
#
# Contract (plans/state-model-v2-phase4-design.md, "Result lines on the
# streamed log"; version semantics per Rachid's 2026-09-20 ruling):
#   result v1: parent=... package=... instance=... phase=... action=... \
#              outcome=... exit=... verification=... version=...
# - key=value, space-separated, no spaces in values; no values, environment
#   snapshots, stdout/stderr or free-form text on a line.
# - outcome is succeeded|failed; a non-zero exit, a failed verification or an
#   unknown version forces failed while `exit` stays the recipe's real status.
# - version is the package's DECLARED version: a dev-owned `.version` file in
#   the package dir, one line, charset-safe. Packages are opaque and their
#   devs are trusted; the framework never probes the machine for a version.
#   Missing, empty or off-charset declaration reads `unknown` - a failed
#   attempt. Native fallback subjects (no cloudify package dir) declare
#   nothing and report `none`; they are exempt from the version contract.
# - instance is the package's instance key (default, or the .package-instance
#   variable's value); the dispatch context gate guarantees a supplied key,
#   so a bad or unsupplied key renders `unknown` here rather than a guess.
#
# Attribution: the caller sets CLOUDIFY_RESULT_PARENT for framework work
# (`@defaults`, `@init`); pkg_depends sets it to the declaring package before
# sourcing a recipe, so dependency pulls attribute to their caller. Unset
# means a top-level package: `-`.

set -Eeuo pipefail

[[ -n "${_CLOUDIFY_RESULTS_LOADED:-}" ]] && return 0
_CLOUDIFY_RESULTS_LOADED=1

# _cloudify_result_version_of <pkg> - the declared version: first line of
# pkg/<pkg>/.version, leading/trailing whitespace stripped. A missing, empty
# or off-charset declaration reads `unknown` (the attempt is then recorded
# failed); the tripwire test (results.bats) keeps every committed recipe's
# declaration well-formed. Interior whitespace is never rewritten: `1.0 beta`
# is unknown, not a silently mutated `1.0beta`.
function _cloudify_result_version_of() {
    local pkg="${1:-}" token=""
    [[ -n "$pkg" && -n "${CLOUDIFY_DIR:-}" ]] || { printf 'unknown'; return 0; }
    token=$(head -n 1 "$CLOUDIFY_DIR/pkg/$pkg/.version" 2>/dev/null || true)
    token="${token#"${token%%[![:space:]]*}"}"   # strip leading whitespace
    token="${token%"${token##*[![:space:]]}"}"   # strip trailing whitespace
    if [[ -n "$token" && "$token" =~ ^[A-Za-z0-9._+~:-]+$ ]]; then
        printf '%s' "$token"
    else
        printf 'unknown'
    fi
    return 0
}

# _cloudify_result_instance_of <pkg> - the instance key as the child sees it:
# no .package-instance marker means default; a marker names the variable whose
# environment value selects the key (forwarded by the payload exports). The
# dispatch context gate already refused unsupplied or off-charset keys before
# any dispatch, so those render `unknown` here - never a guessed key.
function _cloudify_result_instance_of() {
    local pkg="${1:-}" var val
    var=$(cat "$CLOUDIFY_DIR/pkg/$pkg/.package-instance" 2>/dev/null || true)
    var=$(printf '%s' "$var" | tr -d '[:space:]')
    if [[ -z "$var" ]]; then
        printf 'default'
        return 0
    fi
    if [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'unknown'
        return 0
    fi
    val="${!var:-}"
    if [[ -n "$val" ]] && _cloudify_identity_valid_instance "$val"; then
        printf '%s' "$val"
    else
        printf 'unknown'
    fi
    return 0
}

# cloudify_result_emit <parent> <package> <phase> <action> <exit> \
#                      <verification> <version>
# Render one result line on stdout (the streamed log). outcome is DERIVED
# here, in one place: succeeded only when the recipe exited 0, verification
# did not fail and the version is known; forced failures never alter exit.
function cloudify_result_emit() {
    local parent="$1" package="$2" phase="$3" action="$4"
    local exit_code="$5" verification="$6" version="$7"
    local instance outcome
    instance=$(_cloudify_result_instance_of "$package")
    if [[ "$exit_code" == 0 && "$verification" != "failed" && "$version" != "unknown" ]]; then
        outcome=succeeded
    else
        outcome=failed
    fi
    printf 'result v1: parent=%s package=%s instance=%s phase=%s action=%s outcome=%s exit=%s verification=%s version=%s\n' \
        "$parent" "$package" "$instance" "$phase" "$action" \
        "$outcome" "$exit_code" "$verification" "$version"
}
