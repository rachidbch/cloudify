#!/usr/bin/env bats
# Reconciliation freeze (state-model-v2 4.3, amended design 2026-09-20): the
# collected result lines are checked against the two facts the worker already
# holds - the requested package words and what the lines themselves report.
# No recipe-text graph is computed; packages are opaque, the run reports.

source tests/helpers/common.bash

setup() {
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/results.sh
    source lib/packages.sh

    export CLOUDIFY_NO_VERIFY=true
}

teardown() {
    teardown_test_env
}

# A collection file from canned lines (the tap already collected them).
collect() {
    printf '%s\n' "$@" > "$CLOUDIFY_TMP/collected"
}

res() { # res <parent> <package> <outcome> <exit> <verification> <version>
    printf 'result v1: parent=%s package=%s instance=default phase=install action=install outcome=%s exit=%s verification=%s version=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6"
}

@test "reconcile: every requested word reported top-level passes" {
    mkdir -p "$CLOUDIFY_DIR/pkg/hermes"
    collect "$(res - hermes succeeded 0 not-run 1.0.0)" \
        "$(res hermes hermes-dashboard succeeded 0 not-run none)"
    cloudify_results_reconcile "$CLOUDIFY_TMP/collected" hermes
}

@test "reconcile: a requested word with no line fails the dispatch, named" {
    collect "$(res - hermes succeeded 0 not-run 1.0.0)"
    run cloudify_results_reconcile "$CLOUDIFY_TMP/collected" hermes wezterm
    [ "$status" -ne 0 ]
    [[ "$output" == *"wezterm"* ]]
}

@test "reconcile: a dependency-class appearance does not satisfy the request" {
    # hermes-dashboard was pulled by hermes; requesting hermes-dashboard directly
    # is unfulfilled: no top-level attempt ever reported.
    mkdir -p "$CLOUDIFY_DIR/pkg/hermes"
    collect "$(res - hermes succeeded 0 not-run 1.0.0)" \
        "$(res hermes hermes-dashboard succeeded 0 not-run none)"
    run cloudify_results_reconcile "$CLOUDIFY_TMP/collected" hermes hermes-dashboard
    [ "$status" -ne 0 ]
    [[ "$output" == *"hermes-dashboard"* ]]
}

@test "reconcile: a bogus parent fails the dispatch" {
    collect "$(res - hermes succeeded 0 not-run 1.0.0)" \
        "$(res @podcast hermes-model succeeded 0 not-run none)"
    run cloudify_results_reconcile "$CLOUDIFY_TMP/collected" hermes
    [ "$status" -ne 0 ]
    [[ "$output" == *"@podcast"* ]]
}

@test "reconcile: native subjects, framework work and repeats are expected, never failures" {
    mkdir -p "$CLOUDIFY_DIR/pkg/hermes"
    collect "$(res - hermes succeeded 0 not-run 1.0.0)" \
        "$(res hermes libqrencode succeeded 0 not-run none)" \
        "$(res @defaults tree succeeded 0 not-run none)" \
        "$(res @init required succeeded 0 not-run none)" \
        "$(res - hermes succeeded 0 not-run 1.0.0)"
    cloudify_results_reconcile "$CLOUDIFY_TMP/collected" hermes
}

@test "reconcile: a native subject satisfies its own top-level request" {
    collect "$(res - some-apt-only-thing succeeded 0 not-run none)"
    cloudify_results_reconcile "$CLOUDIFY_TMP/collected" some-apt-only-thing
}

@test "classify: requested, dependency, framework and native buckets land in file order" {
    mkdir -p "$CLOUDIFY_DIR/pkg/hermes" "$CLOUDIFY_DIR/pkg/hermes-dashboard"
    collect "$(res @defaults tree succeeded 0 not-run none)" \
        "$(res - hermes succeeded 0 not-run 1.0.0)" \
        "$(res hermes libqrencode succeeded 0 not-run none)" \
        "$(res hermes hermes-dashboard succeeded 0 not-run none)"
    run cloudify_results_classify "$CLOUDIFY_TMP/collected" hermes
    [ "$status" -eq 0 ]
    printf '%s\n' "$output"
    [ "$(grep -c . <<< "$output")" -eq 4 ]
    [ "$(sed -n 1p <<< "$output")" = "framework	tree" ]
    [ "$(sed -n 2p <<< "$output")" = "requested	hermes" ]
    [ "$(sed -n 3p <<< "$output")" = "native	libqrencode" ]
    [ "$(sed -n 4p <<< "$output")" = "dependency	hermes-dashboard" ]
}

@test "classify: an unrequested top-level cloudify package is marked, not failed" {
    mkdir -p "$CLOUDIFY_DIR/pkg/hermes" "$CLOUDIFY_DIR/pkg/sidequest"
    collect "$(res - hermes succeeded 0 not-run 1.0.0)" \
        "$(res - sidequest succeeded 0 not-run 1.0.0)"
    run cloudify_results_classify "$CLOUDIFY_TMP/collected" hermes
    [ "$status" -eq 0 ]
    grep -q '^unrequested	sidequest$' <<< "$output"
    cloudify_results_reconcile "$CLOUDIFY_TMP/collected" hermes
}

@test "classify: checkout lines are skipped, not classified" {
    mkdir -p "$CLOUDIFY_DIR/pkg/hermes"
    collect "checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false" \
        "$(res - hermes succeeded 0 not-run 1.0.0)"
    run cloudify_results_classify "$CLOUDIFY_TMP/collected" hermes
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<< "$output")" -eq 1 ]
    grep -q '^requested	hermes$' <<< "$output"
}
