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
# Local dispatches also append the line to $CLOUDIFY_RESULTS_FILE (the
# worker's private collection): the child runs in-process there, so no
# stream filter is needed; remote dispatches collect through the tap stage
# instead - the remote child never has CLOUDIFY_RESULTS_FILE set.
function cloudify_result_emit() {
    local parent="$1" package="$2" phase="$3" action="$4"
    local exit_code="$5" verification="$6" version="$7"
    local instance outcome line
    instance=$(_cloudify_result_instance_of "$package")
    if [[ "$exit_code" == 0 && "$verification" != "failed" && "$version" != "unknown" ]]; then
        outcome=succeeded
    else
        outcome=failed
    fi
    line=$(printf 'result v1: parent=%s package=%s instance=%s phase=%s action=%s outcome=%s exit=%s verification=%s version=%s' \
        "$parent" "$package" "$instance" "$phase" "$action" \
        "$outcome" "$exit_code" "$verification" "$version")
    printf '%s\n' "$line"
    if [[ -n "${CLOUDIFY_RESULTS_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$CLOUDIFY_RESULTS_FILE" 2>/dev/null || true
    fi
}

#-- The worker side: capture, validation, executed-code --

# _cloudify_results_body <line> - the line's body after the optional host
# prefix (`host: ` - one space-free token, colon, space) as produced by the
# stream's host-prefix stages. Everything else is the body verbatim.
_cloudify_results_body() {
    local line="$1"
    if [[ "$line" =~ ^[^[:space:]]+:[[:space:]](.*)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$line"
    fi
}

# cloudify_results_tap <collection-file> - the pass-through capture stage on
# the received stream (lib/remote.sh pipeline). Prints EVERY line onward
# unchanged and additionally appends the keyed lines (result v1: / checkout
# v1:, host prefix stripped) to the collection file. The worker creates the
# file fresh per dispatch; the stage only appends.
#
# FRAGILE (docs/FRAGILE.md section 3): this stage sits in the live log
# pipeline. It never buffers, never filters the pass-through, keeps a final
# line without a trailing newline (read || [[ -n $line ]] idiom), keeps every
# command in condition context, and returns 0 unconditionally - it can never
# fail the stream or fire the router's ERR trap.
function cloudify_results_tap() {
    local file="$1" line body
    [[ -n "$file" ]] || return 0
    touch "$file" 2>/dev/null || true
    while IFS= read -r line || [[ -n $line ]]; do
        printf '%s\n' "$line"
        body=$(_cloudify_results_body "$line")
        case "$body" in
            "result v1: "* | "checkout v1: "*)
                printf '%s\n' "$body" >> "$file" 2>/dev/null || true
                ;;
        esac
    done
    return 0
}

# _cloudify_results_fail <message> - named validator diagnostic (stderr).
_cloudify_results_fail() {
    printf 'cloudify_results_validate: %s\n' "$1" >&2
    return 1
}

# _cloudify_results_validate_result <body-after-prefix> <line-number>
# Field-by-field check of one `result v1:` line. Required keys exactly once,
# unknown appended fields ignored, enum and charset checks, and the
# forced-failure consistency: a non-zero exit, a failed verification or an
# unknown version can never claim succeeded.
_cloudify_results_validate_result() {
    local body="$1" n="$2"
    local rest="${body#result v1: }" kv key val
    local -A f=()
    for kv in $rest; do
        [[ "$kv" == *=* ]] || { _cloudify_results_fail "line $n: field without =: $kv"; return 1; }
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ -n "$key" ]] || { _cloudify_results_fail "line $n: empty key"; return 1; }
        [[ -z "${f[$key]+x}" ]] || { _cloudify_results_fail "line $n: duplicate field $key"; return 1; }
        f[$key]="$val"
    done
    local key
    for key in parent package instance phase action outcome exit verification version; do
        [[ -n "${f[$key]+x}" ]] || { _cloudify_results_fail "line $n: missing field $key"; return 1; }
    done
    [[ "${f[parent]}" =~ ^[A-Za-z0-9._+~:@-]+$ ]] || { _cloudify_results_fail "line $n: bad parent '${f[parent]}'"; return 1; }
    [[ "${f[package]}" =~ ^[A-Za-z0-9._+~:-]+$ ]] || { _cloudify_results_fail "line $n: bad package '${f[package]}'"; return 1; }
    [[ "${f[instance]}" =~ ^[A-Za-z0-9._+~:-]+$ ]] || { _cloudify_results_fail "line $n: bad instance '${f[instance]}'"; return 1; }
    case "${f[phase]}" in
        install | reconfigure | teardown | verify) ;;
        *) { _cloudify_results_fail "line $n: bad phase '${f[phase]}'"; return 1; } ;;
    esac
    case "${f[action]}" in
        install | configure | uninstall | verify) ;;
        *) { _cloudify_results_fail "line $n: bad action '${f[action]}'"; return 1; } ;;
    esac
    case "${f[outcome]}" in
        succeeded | failed) ;;
        *) { _cloudify_results_fail "line $n: bad outcome '${f[outcome]}'"; return 1; } ;;
    esac
    [[ "${f[exit]}" =~ ^[0-9]+$ && "${f[exit]}" -le 255 ]] || { _cloudify_results_fail "line $n: bad exit '${f[exit]}'"; return 1; }
    case "${f[verification]}" in
        ok | failed | not-run) ;;
        *) { _cloudify_results_fail "line $n: bad verification '${f[verification]}'"; return 1; } ;;
    esac
    [[ "${f[version]}" =~ ^[A-Za-z0-9._+~:-]+$ ]] || { _cloudify_results_fail "line $n: bad version '${f[version]}'"; return 1; }
    if [[ "${f[outcome]}" == succeeded ]]; then
        [[ "${f[exit]}" == 0 && "${f[verification]}" != failed && "${f[version]}" != unknown ]] \
            || { _cloudify_results_fail "line $n: succeeded claimed despite a forcing failure"; return 1; }
    fi
    return 0
}

# _cloudify_results_validate_checkout <body-after-prefix> <line-number>
_cloudify_results_validate_checkout() {
    local body="$1" n="$2"
    local rest="${body#checkout v1: }" kv key val
    local -A f=()
    for kv in $rest; do
        [[ "$kv" == *=* ]] || { _cloudify_results_fail "line $n: field without =: $kv"; return 1; }
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ -n "$key" ]] || { _cloudify_results_fail "line $n: empty key"; return 1; }
        [[ -z "${f[$key]+x}" ]] || { _cloudify_results_fail "line $n: duplicate field $key"; return 1; }
        f[$key]="$val"
    done
    [[ -n "${f[commit]+x}" ]] || { _cloudify_results_fail "line $n: missing field commit"; return 1; }
    [[ -n "${f[dirty]+x}" ]] || { _cloudify_results_fail "line $n: missing field dirty"; return 1; }
    [[ "${f[commit]}" == unknown || "${f[commit]}" =~ ^[0-9a-f]{40}$ ]] || { _cloudify_results_fail "line $n: bad commit '${f[commit]}'"; return 1; }
    [[ "${f[dirty]}" == true || "${f[dirty]}" == false ]] || { _cloudify_results_fail "line $n: bad dirty '${f[dirty]}'"; return 1; }
    return 0
}

# cloudify_results_validate <collection-file> - structural gate over the
# collected lines. Anything bent fails the dispatch: unknown keys are ignored,
# everything else (required fields, enums, charsets, forced-failure
# consistency, the 64-line and 512-byte caps) must hold exactly.
function cloudify_results_validate() {
    local file="$1" line body n=0 keyed=0
    [[ -f "$file" ]] || { _cloudify_results_fail "no collection file: $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        (( ${#line} <= 512 )) || { _cloudify_results_fail "line $n: over 512 bytes"; return 1; }
        body=$(_cloudify_results_body "$line")
        case "$body" in
            "result v1: "*)
                keyed=$((keyed + 1))
                _cloudify_results_validate_result "$body" "$n" || return 1
                ;;
            "checkout v1: "*)
                keyed=$((keyed + 1))
                _cloudify_results_validate_checkout "$body" "$n" || return 1
                ;;
        esac
    done < "$file"
    (( keyed <= 64 )) || { _cloudify_results_fail "$keyed keyed lines exceed the 64-line cap"; return 1; }
    return 0
}

# cloudify_results_print_checkout - the child's one checkout line, printed
# before package work: which git commit of cloudify this host runs and
# whether the tree is dirty. Outside a git repo: commit=unknown dirty=false
# (the executed-code check degrades on unknown either way; no guessing).
# Prints once per process.
function cloudify_results_print_checkout() {
    [[ -n "${_CLOUDIFY_CHECKOUT_PRINTED:-}" ]] && return 0
    _CLOUDIFY_CHECKOUT_PRINTED=1
    local commit=unknown dirty=false
    if command git -C "${CLOUDIFY_SCRIPT_DIR:-$PWD}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        commit=$(command git -C "${CLOUDIFY_SCRIPT_DIR:-$PWD}" rev-parse HEAD 2>/dev/null) || commit=unknown
        [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || commit=unknown
        if [[ "$commit" != unknown ]]; then
            [[ -z "$(command git -C "${CLOUDIFY_SCRIPT_DIR:-$PWD}" status --porcelain 2>/dev/null)" ]] || dirty=true
        fi
    fi
    printf 'checkout v1: commit=%s dirty=%s\n' "$commit" "$dirty"
    # Local dispatch children collect in-process (their stdout is not
    # tapped): append there when the collection file is set, mirroring
    # cloudify_result_emit. Remote children keep the stdout path the tap
    # captures.
    if [[ -n "${CLOUDIFY_RESULTS_FILE:-}" ]]; then
        printf 'checkout v1: commit=%s dirty=%s\n' "$commit" "$dirty" >> "$CLOUDIFY_RESULTS_FILE" 2>/dev/null || true
    fi
}

# _cloudify_results_fields <body> <assoc-name> - one `result v1:` line's
# key=value fields into the caller's associative array (a nameref, so no
# second parser ever drifts from the line format). The caller declares the
# array; validation owns the shape rules.
_cloudify_results_fields() {
    local body="${1:?}"
    local -n _fields="${2:?}"
    local kv key val
    _fields=()
    for kv in ${body#"result v1: "}; do
        key="${kv%%=*}"
        val="${kv#*=}"
        _fields["$key"]="$val"
    done
}

# _cloudify_results_is_package <name> - true only when the name is a cloudify
# package directory. cloudify_is_package signals by OUTPUT (the name when
# found, empty when not) and always exits 0, so its rc is never the test.
_cloudify_results_is_package() {
    [[ -n "$(cloudify_is_package "$1" 2>/dev/null)" ]]
}

# cloudify_results_reconcile <collection-file> [requested-words...]
# Membership and legitimacy (amended design 2026-09-20): every requested word
# must have at least one result line naming it with parent=- (a dependency-
# class appearance does not satisfy the request), and every line's parent must
# be `-`, a framework token (@defaults/@init), or a cloudify package. Native
# subjects (names that are not cloudify packages) and repeats are expected,
# never failures. Nothing is computed from recipe text: the run's reports and
# the requested words are the only inputs. Failures are named on stderr.
function cloudify_results_reconcile() {
    local file="$1"
    shift
    local -a wanted=()
    wanted=("$@")
    [[ -f "$file" ]] || { printf 'cloudify_results_reconcile: no collection file: %s\n' "$file" >&2; return 1; }

    local line body key val rest pkg parent
    local -a top_packages=()
    local -A top_seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        body=$(_cloudify_results_body "$line")
        case "$body" in
            "result v1: "*) ;;
            *) continue ;;
        esac
        pkg="" parent=""
        rest="${body#result v1: }"
        for kv in $rest; do
            key="${kv%%=*}"
            val="${kv#*=}"
            case "$key" in
                package) pkg="$val" ;;
                parent) parent="$val" ;;
            esac
        done
        [[ "$pkg" == "-" ]] && pkg=""
        [[ -n "$pkg" ]] || { printf 'cloudify_results_reconcile: result line without a package\n' >&2; return 1; }
        if [[ "$parent" == "-" ]]; then
            top_packages+=("$pkg")
            top_seen[$pkg]=1
        elif [[ "$parent" != "@defaults" && "$parent" != "@init" ]] && ! _cloudify_results_is_package "$parent"; then
            printf 'cloudify_results_reconcile: bogus parent %q (not a package, not framework work)\n' "$parent" >&2
            return 1
        fi
    done < "$file"

    local word
    for word in "${wanted[@]}"; do
        [[ -n "${top_seen[$word]+x}" ]] || {
            printf 'cloudify_results_reconcile: requested package %q never reported top-level\n' "$word" >&2
            return 1
        }
    done
    return 0
}

# cloudify_results_classify <collection-file> [requested-words...]
# One class<TAB>package line per result line, in file order - the ordered
# attempt list the commit phase consumes. Classes: requested (top-level,
# in the requested words), dependency (parent is a cloudify package),
# framework (@defaults/@init), native (not a cloudify package), unrequested
# (top-level cloudify package nobody asked for - recorded as observed; the
# worker surfaces it at commit time). Checkout lines and other stream lines
# are skipped.
function cloudify_results_classify() {
    local file="$1"
    shift
    local -A requested=()
    local w
    for w in "$@"; do requested[$w]=1; done

    local line body key val rest pkg parent cls
    while IFS= read -r line || [[ -n $line ]]; do
        body=$(_cloudify_results_body "$line")
        case "$body" in
            "result v1: "*) ;;
            *) continue ;;
        esac
        pkg="" parent=""
        rest="${body#result v1: }"
        for kv in $rest; do
            key="${kv%%=*}"
            val="${kv#*=}"
            case "$key" in
                package) pkg="$val" ;;
                parent) parent="$val" ;;
            esac
        done
        if [[ "$parent" == "@defaults" || "$parent" == "@init" ]]; then
            cls=framework
        elif ! _cloudify_results_is_package "$pkg"; then
            cls=native
        elif [[ "$parent" == "-" ]]; then
            if [[ -n "${requested[$pkg]+x}" ]]; then
                cls=requested
            else
                cls=unrequested
            fi
        else
            cls=dependency
        fi
        printf '%s\t%s\n' "$cls" "$pkg"
    done < "$file"
    return 0
}
# cloudify_results_check_executed <collection-file> <expected-commit> \
#                                 <dev-override:true|false>
# The executed-code verdict. One word on stdout:
#   ok                  the proved commit matches the manifest, or no commit
#                       was declared (a bare/_direct dispatch: no claim, no
#                       violation - guards non-git controllers)
#   ok-dev              a development-override run never degrades
#   degraded-missing    no checkout line reached the worker
#   degraded-unknown    the child could not determine its own commit
#   degraded-mismatch   the host ran a different commit than declared
#   degraded-divergent  two children disagree; the first line wins the value
function cloudify_results_check_executed() {
    local file="$1" expected="$2" dev="${3:-false}"
    if [[ "$dev" == true ]]; then
        printf 'ok-dev\n'
        return 0
    fi
    # No declared commit: the executed-code discipline is a claim check -
    # nothing was claimed, so unknown or absent checkout evidence is an
    # honest observation, never a degradation.
    [[ -n "$expected" ]] || { printf 'ok\n'; return 0; }
    local first="" line body
    local -a checkouts=()
    [[ -f "$file" ]] || { printf 'degraded-missing\n'; return 0; }
    while IFS= read -r line || [[ -n $line ]]; do
        body=$(_cloudify_results_body "$line")
        case "$body" in
            "checkout v1: "*) checkouts+=("$body") ;;
        esac
    done < "$file"
    (( ${#checkouts[@]} > 0 )) || { printf 'degraded-missing\n'; return 0; }
    first="${checkouts[0]}"
    for line in "${checkouts[@]}"; do
        [[ "$line" == "$first" ]] || { printf 'degraded-divergent\n'; return 0; }
    done
    local commit="${first#checkout v1: commit=}"
    commit="${commit%% *}"
    [[ "$commit" != unknown ]] || { printf 'degraded-unknown\n'; return 0; }
    if [[ "$commit" == "$expected" ]]; then
        printf 'ok\n'
    else
        printf 'degraded-mismatch\n'
    fi
    return 0
}
