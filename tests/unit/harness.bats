#!/usr/bin/env bats
# Harness test: validates the bats test infrastructure works correctly

setup() {
    source tests/helpers/common.bash
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "bats test harness runs" {
    run echo "bats works"
    [ "$status" -eq 0 ]
    [ "$output" = "bats works" ]
}

@test "setup_test_env creates required directories" {
    [ -d "$CLOUDIFY_DIR" ]
    [ -d "$CLOUDIFY_DIR/pkg" ]
    [ -d "$CLOUDIFY_DIR/inventory" ]
    [ -d "$CLOUDIFY_TMP" ]
    [ -d "$CLOUDIFY_TMP/backup" ]
}

@test "setup_test_env sets required environment variables" {
    [ "$CLOUDIFY_DISABLE_COLORS" = "true" ]
    [ "$CLOUDIFY_SKIPCREDENTIALS" = "true" ]
    [ "$CLOUDIFY_IS_LOCAL" = "true" ]
    [ -n "$CLOUDIFY_DIR" ]
    [ -n "$CLOUDIFY_TMP" ]
}

@test "sourcing cloudify defines functions" {
    # Source the main script - since it calls main() at the end, we need to handle that
    # We'll source individual lib files to check they define functions
    CLOUDIFY_SCRIPT_DIR="/root/cloudify"

    # Source just the function definitions from cloudify by extracting them
    # We use a trick: setBASH_SOURCE and prevent main from running
    run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true
        export CLOUDIFY_SKIPCREDENTIALS=true
        export CLOUDIFY_IS_LOCAL=true
        export CLOUDIFY_DIR=/tmp/test_cloudify_dir
        export CLOUDIFY_TMP=/tmp/test_cloudify_tmp
        export CLOUDIFY_LOCAL_BIN=/tmp/test_bin
        export CLOUDIFY_HOSTPWD=dummy
        export DEBUG=false
        mkdir -p /tmp/test_cloudify_dir/pkg /tmp/test_cloudify_dir/inventory /tmp/test_cloudify_tmp
        # Source cloudify but prevent main() from executing
        # by aliasing main to a noop
        main() { true; }
        source /root/cloudify/cloudify
        # Check key functions exist
        type -t msg && type -t die && type -t cloudify_setup_colors && type -t cloudify_osdetect
    "
    [ "$status" -eq 0 ]
}
