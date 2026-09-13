#!/usr/bin/env bats
# Proofs for the Phase 2 repair: the resolution records each value's raw source
# form in the dispatch context, and no consumer opens a source again. The
# registry record and the run snapshot therefore cannot drift from the payload.
#
# The load-bearing test is "the record survives the sources disappearing": it is
# the only one that fails if a consumer reopens a store.

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
    source lib/registry.sh
    source lib/context.sh
    source lib/targets.sh
    source lib/runbooks.sh

    unset _CLOUDIFY_VARS_LEDGER _CLOUDIFY_VARS_DECLARED
    unset SPEC PLAIN_NAME TABBED MULTILINE LOOKSLIKE

    export DEP="rawform"
    export CLOUDIFY_DEPLOYMENT="$DEP"
    export CLOUDIFY_APPLICATION="ctxapp" CLOUDIFY_FLAVOR="default" CLOUDIFY_DEPLOYMENT_NAME="default"
    export CLOUDIFY_CONTEXT_TARGET=$'local\t\tlocalhost'
    cloudify_init_log

    CTX="$CLOUDIFY_TMP/context.yaml"
    export CLOUDIFY_CONTEXT_FILE="$CTX"
}

teardown() {
    teardown_test_env
}

declare_pkg() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

set_deployment() { _cloudify_vars_file_set "$(_cloudify_deployment_config)" "$1" "$2"; }

# build_ctx <pkg> - resolve one package into CTX. Called in the parent shell
# because the build exports the resolved values into it.
build_ctx() {
    local pkg="$1" cand
    cand=$(mktemp "$CLOUDIFY_TMP/cand-XXXXXX")
    cloudify_context_candidate_names "$pkg" > "$cand"
    cloudify_context_build install "$DEP" install "$cand" "$pkg" >/dev/null
    rm -f "$cand"
}

# raw_of <name> - decode the raw source form the context recorded.
raw_of() {
    local enc
    enc=$(cloudify_context_read "$CTX" "value.$1.raw")
    _cloudify_vars_raw_decode "$enc"
}

# record_of <pkg> - the registry record text built from CTX alone.
record_of() {
    cloudify_registry_record_build install "$DEP" node inst "" "$1" "$CTX"
}

@test "raw form: a value containing a tab survives to the record verbatim" {
    subrubric "the store holds a tab; the transport must not eat it"
    declare_pkg tabpkg TABBED
    set_deployment TABBED $'left\tright'

    build_ctx tabpkg

    [ "$(raw_of TABBED)" = $'left\tright' ]
    [[ "$(record_of tabpkg)" == *$'var.TABBED: left\tright'* ]]
}

@test "raw form: a multiline env value reaches the record as @base64:" {
    subrubric "env is the only source that can carry a newline"
    declare_pkg mlpkg MULTILINE
    export MULTILINE=$'one\ntwo'

    build_ctx mlpkg

    [ "$(raw_of MULTILINE)" = $'one\ntwo' ]
    [[ "$(record_of mlpkg)" == *"var.MULTILINE: @base64:"* ]]
}

@test "raw form: a raw that itself looks encoded is not mistaken for the transport" {
    subrubric "@base64: in a store is a store encoding, not our transport marker"
    declare_pkg lookpkg LOOKSLIKE
    set_deployment LOOKSLIKE '@base64:bm90LXJlYWxseQ=='

    build_ctx lookpkg

    [ "$(raw_of LOOKSLIKE)" = '@base64:bm90LXJlYWxseQ==' ]
    [[ "$(record_of lookpkg)" == *'var.LOOKSLIKE: @base64:bm90LXJlYWxseQ=='* ]]
}

@test "no second walk: the record survives the sources disappearing" {
    subrubric "resolve once, then destroy every source the record used to reopen"
    declare_pkg walkpkg PLAIN_NAME
    set_deployment PLAIN_NAME from-deployment

    build_ctx walkpkg
    # Compare the recorded VALUE, not the whole record: the record carries an
    # installed_at timestamp, so a whole-text compare would pass or fail on
    # whether the two calls landed in the same second.
    before=$(record_of walkpkg | sed -n 's/^var\.PLAIN_NAME: //p')

    subrubric "the deployment store now says something else, and the pkg yaml is gone"
    set_deployment PLAIN_NAME CHANGED
    rm -f "$(cloudify_vars_pkg_file walkpkg)"

    after=$(record_of walkpkg | sed -n 's/^var\.PLAIN_NAME: //p')

    [ "$before" = "$after" ]
    [ "$after" = "from-deployment" ]
}

@test "no second walk: the snapshot resolver survives the sources disappearing" {
    subrubric "the same proof for the run snapshot's resolver"
    declare_pkg snapshotpkg PLAIN_NAME
    set_deployment PLAIN_NAME from-deployment

    build_ctx snapshotpkg
    [ "$(_cloudify_runbook_resolver_value PLAIN_NAME deployment snapshotpkg "$CTX")" = "from-deployment" ]

    set_deployment PLAIN_NAME CHANGED
    rm -f "$(cloudify_vars_pkg_file snapshotpkg)"

    [ "$(_cloudify_runbook_resolver_value PLAIN_NAME deployment snapshotpkg "$CTX")" = "from-deployment" ]
}

@test "first-wins: the stronger source is the one recorded" {
    subrubric "deployment outranks package; the recorded raw must be the deployment's"
    declare_pkg winpkg PLAIN_NAME
    _cloudify_vars_file_set "$(cloudify_vars_pkg_file winpkg)" PLAIN_NAME from-package
    set_deployment PLAIN_NAME from-deployment

    build_ctx winpkg

    [ "$(raw_of PLAIN_NAME)" = "from-deployment" ]
    [ "$(cloudify_context_read "$CTX" "value.PLAIN_NAME.source")" = "deployment" ]
}

@test "validate: a name with no raw form is rejected before anything consumes it" {
    subrubric "a silently partial context is the failure mode this guards"
    declare_pkg valpkg SPEC
    set_deployment SPEC a-value
    build_ctx valpkg

    grep -v '^value.SPEC.raw:' "$CTX" > "$CTX.bad"

    run cloudify_context_validate "$CTX.bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no raw source form"* ]]
}

@test "validate: a malformed raw form is rejected" {
    declare_pkg badpkg SPEC
    set_deployment SPEC a-value
    build_ctx badpkg

    sed 's/^value.SPEC.raw: .*/value.SPEC.raw: nonsense/' "$CTX" > "$CTX.bad"

    run cloudify_context_validate "$CTX.bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed raw form"* ]]
}

@test "validate: an unexpected line is rejected" {
    declare_pkg oddpkg SPEC
    set_deployment SPEC a-value
    build_ctx oddpkg

    cp "$CTX" "$CTX.bad"
    printf 'surprise: yes\n' >> "$CTX.bad"

    run cloudify_context_validate "$CTX.bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected line"* ]]
}

@test "cleanup: a context is removed even with logging in DEBUG" {
    subrubric "the DEBUG run must not be the one run that leaves a resolved-value file behind"
    ctx="$CLOUDIFY_TMP/leaked-context"
    printf 'context_version: 1\n' > "$ctx"

    declare -gA _CLOUDIFY_BG_CONTEXT=()
    _CLOUDIFY_BG_CONTEXT[999]="$ctx"
    CLOUDIFY_LOG_LEVEL=DEBUG cleanup

    [ ! -e "$ctx" ]
}
