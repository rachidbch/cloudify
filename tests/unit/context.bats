#!/usr/bin/env bats
# Tests for lib/context.sh - one resolved dispatch context (state model v2,
# Phase 2 slice 2A). Additive: nothing here is wired into the payload, registry
# writer, snapshot or router yet.
#
# The build and the legacy walker both export into the CALLING shell, so every
# equivalence test invokes them directly in the bats shell (never inside
# `$(...)`) and asserts the export survived, exactly like remote-vars.bats.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/deployments.sh
    source lib/vars.sh
    source lib/remote.sh
    source lib/registry.sh
    source lib/context.sh

    unset _CLOUDIFY_VARS_LEDGER _CLOUDIFY_VARS_DECLARED
    unset SPEC A_ONLY B_ONLY DEP_ONLY PLAIN_NAME
    unset AMBIENT_UNDECLARED FIXTURE_SECRET CLOUDIFY_FORCE CLOUDIFY_CONTEXT_TARGET

    export DEP="ctx-dep"
    export CLOUDIFY_DEPLOYMENT="$DEP"
    export CLOUDIFY_CONTEXT_TARGET=$'local\t\tlocalhost'
    cloudify_deployment_create "$DEP" >/dev/null
    cloudify_init_log

    CTX="$CLOUDIFY_TMP/context.yaml"
    export CLOUDIFY_CONTEXT_FILE="$CTX"
}

teardown() {
    teardown_test_env
}

# --- fixtures ---------------------------------------------------------------

# declare_pkg <pkg> <names...> - bare (required) declarations, the shape the
# walker and the registry both enumerate.
declare_pkg() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

# recipe_for <pkg> <dep...> - an install recipe whose only content is pkg_depends.
recipe_for() {
    local pkg="$1"
    shift
    printf 'pkg_depends %s\n' "$*" > "$CLOUDIFY_DIR/pkg/$pkg/install.sh"
}

set_deployment() { _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" "$1" "$2"; }
set_pkg() { cloudify_vars_pkg_write "$1" "$2" "$3"; }
set_global() { cloudify_vars_global_write "$1" "$2"; }

reset_stores() {
    rm -f "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    rm -rf "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    : > "$(_cloudify_deployment_config "$DEP")"
}

# candidate_file <pkg...> - the candidate name set the build consumes.
candidate_file() {
    cloudify_context_candidate_names "$@" > "$CLOUDIFY_TMP/candidates"
    printf '%s\n' "$CLOUDIFY_TMP/candidates"
}

# --- module surface ---------------------------------------------------------

@test "module guard prevents double-sourcing lib/context.sh" {
    source lib/context.sh
    source lib/context.sh
    [ "$_CLOUDIFY_CONTEXT_LOADED" = "1" ]
    [ "$(type -t cloudify_context_build)" = "function" ]
    [ "$(type -t cloudify_context_source_of)" = "function" ]
    [ "$(type -t cloudify_context_read)" = "function" ]
    [ "$(type -t cloudify_context_candidate_names)" = "function" ]
}

@test "missing CLOUDIFY_CONTEXT_FILE is a hard error" {
    declare_pkg foo SPEC
    local cand
    cand=$(candidate_file foo)
    unset CLOUDIFY_CONTEXT_FILE
    run cloudify_context_build install "$DEP" install "$cand" foo
    [ "$status" -ne 0 ]
    [[ "$output" == *"CLOUDIFY_CONTEXT_FILE"* ]]
}

@test "context build prints nothing on stdout" {
    declare_pkg foo SPEC
    reset_stores
    set_deployment SPEC deployment-value
    unset SPEC
    local cand
    cand=$(candidate_file foo)
    # Invoked in the parent shell (exports survive), stdout captured to a file.
    cloudify_context_build install "$DEP" install "$cand" foo \
        > "$CLOUDIFY_TMP/build-stdout" 2> /dev/null
    [ ! -s "$CLOUDIFY_TMP/build-stdout" ]
    [ "$SPEC" = "deployment-value" ]
}

# --- the ladder -------------------------------------------------------------

@test "context build exports the same value as the legacy walker for every source combination" {
    rubric "one declared name (SPEC) against 9 source combinations"
    declare_pkg foo SPEC
    local cand
    cand=$(candidate_file foo)
    [ "$(wc -l < "$cand")" -eq 1 ]

    local -a cases=(env deployment package global all file_only package_global none empty_env)
    local case legacy context

    # apply_case re-creates the case's stores and caller env; it is run twice so
    # the legacy walk and the context build start from the same state.
    apply_case() {
        reset_stores
        unset SPEC
        case "$1" in
            env) export SPEC=env-value ;;
            deployment) set_deployment SPEC deployment-value ;;
            package) set_pkg foo SPEC package-value ;;
            global) set_global SPEC global-value ;;
            all)
                export SPEC=env-value
                set_deployment SPEC deployment-value
                set_pkg foo SPEC package-value
                set_global SPEC global-value
                ;;
            file_only)
                set_deployment SPEC deployment-value
                set_pkg foo SPEC package-value
                set_global SPEC global-value
                ;;
            package_global)
                set_pkg foo SPEC package-value
                set_global SPEC global-value
                ;;
            none) : ;;
            empty_env)
                export SPEC=""
                set_deployment SPEC deployment-value
                ;;
        esac
    }

    for case in "${cases[@]}"; do
        subrubric "case=$case"
        apply_case "$case"
        # Legacy walker, in this shell: its exports are the value channel (inv 1).
        _cloudify_pkg_remote_vars install foo > /dev/null 2>&1
        legacy="${SPEC:-}"

        apply_case "$case"
        cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
        context="${SPEC:-}"
        step "legacy='$legacy' context='$context'"
        [ "$legacy" = "$context" ]
        unset SPEC
    done
}

@test "context build records the first-providing source label" {
    declare_pkg foo SPEC
    local cand
    cand=$(candidate_file foo)

    reset_stores
    set_global SPEC global-value
    unset SPEC
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$(cloudify_context_read "$CTX" value.SPEC.source)" = "global" ]

    reset_stores
    set_pkg foo SPEC package-value
    unset SPEC
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$(cloudify_context_read "$CTX" value.SPEC.source)" = "package" ]

    reset_stores
    set_deployment SPEC deployment-value
    set_pkg foo SPEC package-value
    unset SPEC
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$(cloudify_context_read "$CTX" value.SPEC.source)" = "deployment" ]

    export SPEC=env-value
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$(cloudify_context_read "$CTX" value.SPEC.source)" = "environment" ]
}

# --- inv 5: the declaration/name gate ---------------------------------------

@test "an ambient undeclared env var is never exported nor written to the context (inv 5)" {
    declare_pkg foo SPEC
    local cand
    cand=$(candidate_file foo)
    reset_stores
    set_deployment SPEC deployment-value
    export AMBIENT_UNDECLARED=do-not-forward
    unset SPEC

    # The legacy gate this must preserve: the claimed name list.
    _cloudify_pkg_remote_vars install foo > "$CLOUDIFY_TMP/names" 2>/dev/null
    grep -q '^SPEC$' "$CLOUDIFY_TMP/names"
    ! grep -q 'AMBIENT_UNDECLARED' "$CLOUDIFY_TMP/names"
    unset SPEC

    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    grep -q '^value.SPEC.source:' "$CTX"
    ! grep -q 'AMBIENT_UNDECLARED' "$CTX"
}

# --- inv 6: file-store references resolve, caller env passes through --------

@test "store references arrive decoded while the same text in the caller env arrives verbatim (inv 6)" {
    declare_pkg foo SPEC
    local cand b64="YWRtaW4tc2VjcmV0" # admin-secret
    cand=$(candidate_file foo)

    reset_stores
    set_deployment SPEC "@base64:$b64"
    unset SPEC
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$SPEC" = "admin-secret" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.form)" = "reference" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.reference)" = "@base64:$b64" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.secret)" = "true" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.digest)" = "" ]

    reset_stores
    export SPEC="@base64:$b64"
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$SPEC" = "@base64:$b64" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.form)" = "literal" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.reference)" = "" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.source)" = "environment" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.secret)" = "false" ]
    unset SPEC
}

# --- inv 7: unresolvable reference fails, writes nothing --------------------

@test "an unresolvable reference dies and writes no context file (inv 7)" {
    declare_pkg foo SPEC
    local cand
    cand=$(candidate_file foo)
    reset_stores
    printf 'SPEC: @nosuch:locator\n' >> "$(_cloudify_deployment_config "$DEP")"
    unset SPEC
    rm -f "$CTX"

    run cloudify_context_build install "$DEP" install "$cand" foo
    [ "$status" -ne 0 ]
    step "no context file written at $CTX"
    [ ! -e "$CTX" ]
}

# --- inv 8: reserved names --------------------------------------------------

@test "a reserved name coming from a file store is skipped (inv 8)" {
    declare_pkg foo CLOUDIFY_FORCE
    reset_stores
    set_pkg foo CLOUDIFY_FORCE true
    unset CLOUDIFY_FORCE
    local cand
    cand=$(candidate_file foo)

    _cloudify_pkg_remote_vars install foo > "$CLOUDIFY_TMP/names" 2> "$CLOUDIFY_TMP/warn"
    ! grep -q '^CLOUDIFY_FORCE$' "$CLOUDIFY_TMP/names"
    grep -q 'framework-owned' "$CLOUDIFY_TMP/warn"

    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    ! grep -q 'value.CLOUDIFY_FORCE' "$CTX"
    [ "${CLOUDIFY_FORCE:-}" = "" ]
}

# --- source_of equivalence --------------------------------------------------

@test "cloudify_context_source_of agrees with _cloudify_vars_source_of" {
    declare_pkg foo SPEC
    local -a cases=(env deployment package global none)
    local case legacy mapped ctx
    map_source() {
        case "$1" in
            env) printf 'environment\n' ;;
            recipe-default) printf 'recipe\n' ;;
            *) printf '%s\n' "$1" ;;
        esac
    }
    for case in "${cases[@]}"; do
        reset_stores
        unset SPEC
        case "$case" in
            env) export SPEC=env-value ;;
            deployment) set_deployment SPEC deployment-value ;;
            package) set_pkg foo SPEC package-value ;;
            global) set_global SPEC global-value ;;
            none) : ;;
        esac
        legacy="$(_cloudify_vars_source_of SPEC foo)"
        mapped="$(map_source "$legacy")"
        ctx="$(cloudify_context_source_of SPEC foo)"
        step "case=$case legacy=$legacy mapped=$mapped context=$ctx"
        [ "$mapped" = "$ctx" ]
        unset SPEC
    done
}

# --- dependency walk --------------------------------------------------------

@test "an unresolvable dependency is reported, never given an invented name" {
    declare_pkg alpha A_ONLY
    recipe_for alpha phantom-pkg
    cloudify_context_candidate_names alpha > "$CLOUDIFY_TMP/candidates" 2> "$CLOUDIFY_TMP/report"
    subrubric "only the real declaration is emitted"
    [ "$(wc -l < "$CLOUDIFY_TMP/candidates")" -eq 1 ]
    grep -q '^A_ONLY' "$CLOUDIFY_TMP/candidates"
    ! grep -q 'phantom' "$CLOUDIFY_TMP/candidates"

    subrubric "the unresolved dependency is reported at debug level"
    DEBUG=true CLOUDIFY_LOG_LEVEL=DEBUG cloudify_context_candidate_names alpha \
        > /dev/null 2> "$CLOUDIFY_TMP/report"
    grep -q 'phantom-pkg' "$CLOUDIFY_TMP/report"
}

# --- rightmost package + dependency recursion -------------------------------

@test "rightmost package wins and dependency recursion matches the legacy walker" {
    declare_pkg alpha SHARED A_ONLY
    declare_pkg beta SHARED B_ONLY
    declare_pkg dep SHARED DEP_ONLY
    recipe_for alpha dep
    recipe_for beta dep
    reset_stores
    set_pkg alpha SHARED from-alpha
    set_pkg alpha A_ONLY a-val
    set_pkg beta SHARED from-beta
    set_pkg beta B_ONLY b-val
    set_pkg dep SHARED from-dep
    set_pkg dep DEP_ONLY dep-val
    unset SHARED A_ONLY B_ONLY DEP_ONLY

    local cand
    cand=$(candidate_file alpha beta)
    subrubric "the shared dependency is visited once"
    [ "$(grep -c '^DEP_ONLY' "$cand")" -eq 1 ]

    _cloudify_pkg_remote_vars install alpha beta > "$CLOUDIFY_TMP/names" 2>/dev/null
    local legacy_shared="$SHARED"
    unset SHARED A_ONLY B_ONLY DEP_ONLY

    cloudify_context_build install "$DEP" install "$cand" alpha beta > /dev/null
    subrubric "values"
    [ "$SHARED" = "from-beta" ]
    [ "$SHARED" = "$legacy_shared" ]
    [ "$A_ONLY" = "a-val" ]
    [ "$B_ONLY" = "b-val" ]
    [ "$DEP_ONLY" = "dep-val" ]

    subrubric "resolved value names equal the legacy claimed names"
    local -a ctx_names legacy_names
    mapfile -t ctx_names < <(sed -n 's/^value\.\([A-Z_][A-Z0-9_]*\)\.source:.*$/\1/p' "$CTX" | sort -u)
    mapfile -t legacy_names < <(sort -u "$CLOUDIFY_TMP/names")
    step "context=${ctx_names[*]} legacy=${legacy_names[*]}"
    [ "${ctx_names[*]}" = "${legacy_names[*]}" ]
}

# --- no plaintext secrets ---------------------------------------------------

@test "no secret plaintext reaches the context file or the log" {
    declare_pkg foo FIXTURE_SECRET
    reset_stores
    set_deployment FIXTURE_SECRET "fixture-secret-value-xyz"
    unset FIXTURE_SECRET
    local cand
    cand=$(candidate_file foo)

    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$FIXTURE_SECRET" = "fixture-secret-value-xyz" ]
    [ "$(cloudify_context_read "$CTX" value.FIXTURE_SECRET.secret)" = "true" ]
    [ -n "$(cloudify_context_read "$CTX" value.FIXTURE_SECRET.digest)" ]
    subrubric "the literal appears nowhere in the metadata file or the log"
    ! grep -q "fixture-secret-value-xyz" "$CTX"
    ! grep -rq "fixture-secret-value-xyz" "$CLOUDIFY_TMP/logs"
}

@test "an explicit secret declaration marker classifies a non-heuristic name" {
    declare_pkg foo PLAIN_NAME
    printf 'secret PLAIN_NAME\n' >> "$CLOUDIFY_DIR/pkg/foo/.remote-vars"
    reset_stores
    set_deployment PLAIN_NAME "plain-looking-value"
    unset PLAIN_NAME
    local cand
    cand=$(candidate_file foo)
    [ "$(grep -c '^PLAIN_NAME' "$cand")" -eq 1 ]

    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ "$(cloudify_context_read "$CTX" value.PLAIN_NAME.secret)" = "true" ]
    [ -n "$(cloudify_context_read "$CTX" value.PLAIN_NAME.digest)" ]
}

# --- the read surface -------------------------------------------------------

@test "cloudify_context_read round-trips each field" {
    declare_pkg foo SPEC
    reset_stores
    set_deployment SPEC deployment-value
    unset SPEC
    local cand
    cand=$(candidate_file foo)

    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null

    [ "$(cloudify_context_read "$CTX" context_version)" = "1" ]
    [ "$(cloudify_context_read "$CTX" action)" = "install" ]
    [ "$(cloudify_context_read "$CTX" deployment)" = "$DEP" ]
    [ "$(cloudify_context_read "$CTX" phase)" = "install" ]
    [ "$(cloudify_context_read "$CTX" target)" = "$CLOUDIFY_CONTEXT_TARGET" ]
    [ "$(cloudify_context_read "$CTX" top_kind)" = "package" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.source)" = "deployment" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.form)" = "literal" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.secret)" = "false" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.reference)" = "" ]
    [ "$(cloudify_context_read "$CTX" value.SPEC.digest)" = "" ]

    subrubric "absent fields are non-zero, never empty success"
    run cloudify_context_read "$CTX" value.NOPE.source
    [ "$status" -ne 0 ]
    run cloudify_context_read "$CLOUDIFY_TMP/missing.yaml" action
    [ "$status" -ne 0 ]

    subrubric "mode 0600"
    [ "$(stat -c '%a' "$CTX")" = "600" ]
}

@test "verify dispatches record top_kind verified" {
    declare_pkg foo SPEC
    reset_stores
    set_deployment SPEC deployment-value
    unset SPEC
    local cand
    cand=$(candidate_file foo)

    cloudify_context_build verify "$DEP" verify "$cand" foo > /dev/null
    [ "$(cloudify_context_read "$CTX" top_kind)" = "verified" ]
    [ "$(cloudify_context_read "$CTX" action)" = "verify" ]
}

# --- single resolution: the label and the value cannot disagree -------------

@test "the recorded label and digest follow the one resolution, never a second store read" {
    rubric "one secret name (MATRIX_SECRET) through each single source"
    declare_pkg foo MATRIX_SECRET
    local cand
    cand=$(candidate_file foo)

    # Builds, then asserts the label names the source that provably supplied the
    # exported literal and the digest is that literal's digest.
    check_case() {
        local case="$1" exported="$2" label="$3" digest
        subrubric "case=$case"
        cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
        step "exported='${MATRIX_SECRET:-}' label=$label"
        [ "${MATRIX_SECRET:-}" = "$exported" ]
        [ "$(cloudify_context_read "$CTX" value.MATRIX_SECRET.source)" = "$label" ]
        [ "$(cloudify_context_read "$CTX" value.MATRIX_SECRET.secret)" = "true" ]
        digest="$(printf '%s' "$exported" | sha256sum | cut -d' ' -f1)"
        [ "$(cloudify_context_read "$CTX" value.MATRIX_SECRET.digest)" = "sha256:$digest" ]
    }

    subrubric "environment only"
    reset_stores
    unset MATRIX_SECRET
    export MATRIX_SECRET=env-value
    check_case env env-value environment

    subrubric "deployment only"
    reset_stores
    unset MATRIX_SECRET
    set_deployment MATRIX_SECRET deployment-value
    check_case deployment deployment-value deployment

    subrubric "package only"
    reset_stores
    unset MATRIX_SECRET
    set_pkg foo MATRIX_SECRET package-value
    check_case package package-value package

    subrubric "global only"
    reset_stores
    unset MATRIX_SECRET
    set_global MATRIX_SECRET global-value
    check_case global global-value global

    subrubric "all four present: the label and the digest follow the same winner (env)"
    reset_stores
    unset MATRIX_SECRET
    set_deployment MATRIX_SECRET deployment-value
    set_pkg foo MATRIX_SECRET package-value
    set_global MATRIX_SECRET global-value
    export MATRIX_SECRET=env-value
    check_case all env-value environment
    ! grep -q "sha256:$(printf '%s' deployment-value | sha256sum | cut -d' ' -f1)" "$CTX"

    subrubric "recipe default: cloudify supplies no value, so it records no label"
    reset_stores
    unset MATRIX_SECRET
    printf 'MATRIX_SECRET=recipe-default\n' > "$CLOUDIFY_DIR/pkg/foo/.remote-vars"
    cloudify_context_build install "$DEP" install "$cand" foo > /dev/null
    [ -z "${MATRIX_SECRET:-}" ]
    ! grep -q '^value\.MATRIX_SECRET\.' "$CTX"
    [ "$(cloudify_context_source_of MATRIX_SECRET foo)" = "recipe" ]
    [ "$(_cloudify_vars_source_of MATRIX_SECRET foo)" = "recipe-default" ]
    unset MATRIX_SECRET
}

@test "the build cannot re-read a store to label a name (single-resolution structural guard)" {
    local ctx="$BATS_TEST_DIRNAME/../../lib/context.sh"
    local vars="$BATS_TEST_DIRNAME/../../lib/vars.sh"
    [ -f "$ctx" ]
    subrubric "the second-pass helpers are gone"
    ! grep -q '_cloudify_context_store_raw' "$ctx"
    ! grep -q 'compgen -v' "$ctx"
    ! grep -q '_ctx_env' "$ctx"
    subrubric "provenance comes from the single export decision, not from context.sh"
    grep -q '_CLOUDIFY_VARS_SOURCES' "$ctx"
    grep -q '_CLOUDIFY_VARS_SOURCES' "$vars"
    grep -q '_cloudify_vars_sources_record' "$vars"
}

@test "cloudify_context_source_of and _cloudify_vars_source_of share one label implementation" {
    declare_pkg foo SPEC
    subrubric "both spellings delegate to lib/vars.sh:_cloudify_vars_source_label"
    local ctx_src vars_src
    ctx_src="$(declare -f cloudify_context_source_of)"
    vars_src="$(declare -f _cloudify_vars_source_of)"
    [[ "$ctx_src" == *'_cloudify_vars_source_label'* ]]
    [[ "$vars_src" == *'_cloudify_vars_source_label'* ]]

    subrubric "a recipe-default name: each caller keeps the spelling it pins"
    reset_stores
    unset SPEC
    [ "$(_cloudify_vars_source_of SPEC foo)" = "recipe-default" ]
    [ "$(cloudify_context_source_of SPEC foo)" = "recipe" ]

    subrubric "replacing the shared core moves BOTH callers"
    local saved
    saved="$(declare -f _cloudify_vars_source_label)"
    _cloudify_vars_source_label() { printf 'package\n'; }
    [ "$(_cloudify_vars_source_of SPEC foo)" = "package" ]
    [ "$(cloudify_context_source_of SPEC foo)" = "package" ]
    eval "$saved"

    subrubric "a discriminating case: caller env outranks a file store, for both"
    reset_stores
    set_deployment SPEC deployment-value
    export SPEC=env-value
    [ "$(_cloudify_vars_source_of SPEC foo)" = "env" ]
    [ "$(cloudify_context_source_of SPEC foo)" = "environment" ]
    unset SPEC
}
