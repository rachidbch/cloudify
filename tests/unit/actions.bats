#!/usr/bin/env bats
# Branch 2: verify as a first-class action (local + --on), alias preserved.
# Router functions live in the `cloudify` entrypoint (it always runs main), so
# these are black-box subprocess tests; the pinned shell-router verify tests
# stay unmodified.

router() {
    run bash -c "cd $CLOUDIFY_SCRIPT_DIR && CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=$CLOUDIFY_DIR CLOUDIFY_TMP=$CLOUDIFY_TMP DEBUG=false PKG_VERIFY_TIMEOUT=1 bash cloudify $* 2>&1"
}

setup() {
    source tests/helpers/common.bash
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "router: --on localhost verify with no package is a verify action, not a host" {
    router --on localhost verify
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Missing package"
    ! echo "$output" | grep -q "No packages found"
}

@test "router: verify on an unknown package errors" {
    router verify notapkg
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Not a cloudify package"
}

@test "router: --verify install alias routes to the same verify path" {
    router --verify install notapkg
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Not a cloudify package"
}

@test "router: verify on a known package without verify.sh is a no-op success" {
    mkdir -p "$CLOUDIFY_DIR/pkg/novpkg"
    echo '# recipe' > "$CLOUDIFY_DIR/pkg/novpkg/init.sh"
    router verify novpkg
    [ "$status" -eq 0 ]
}

@test "router: uninstall with no package errors" {
    router uninstall
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Empty package"
}

@test "router: a flag after the action errors instead of becoming a package" {
    router install --verify
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "unexpected flag"
}
