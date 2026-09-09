#!/usr/bin/env bats
# Branch 2: uninstall action (optional uninstall.sh, no guessing, deps untouched).

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/package-api.sh
    source lib/packages.sh
}

teardown() {
    teardown_test_env
}

@test "uninstall runs the package's uninstall.sh" {
    mkdir -p "$CLOUDIFY_DIR/pkg/good"
    echo '# recipe' > "$CLOUDIFY_DIR/pkg/good/init.sh"
    touch "$CLOUDIFY_TMP/marker-good"
    printf 'rm -f "$CLOUDIFY_TMP/marker-good"\n' > "$CLOUDIFY_DIR/pkg/good/uninstall.sh"
    run cloudify_uninstall_package good
    [ "$status" -eq 0 ]
    [ ! -f "$CLOUDIFY_TMP/marker-good" ]
}

@test "uninstall refuses a package with no uninstall leg and changes nothing" {
    mkdir -p "$CLOUDIFY_DIR/pkg/noleg"
    echo '# recipe' > "$CLOUDIFY_DIR/pkg/noleg/init.sh"
    touch "$CLOUDIFY_TMP/marker-noleg"
    run cloudify_uninstall_package noleg
    [ "$status" -ne 0 ]
    [ -f "$CLOUDIFY_TMP/marker-noleg" ]
    echo "$output" | grep -q "no uninstall.sh"
}

@test "uninstall errors on an unknown package" {
    run cloudify_uninstall_package notapkg
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Not a cloudify package"
}

@test "uninstall collects failures and still runs the valid package" {
    mkdir -p "$CLOUDIFY_DIR/pkg/good" "$CLOUDIFY_DIR/pkg/noleg"
    echo '# recipe' > "$CLOUDIFY_DIR/pkg/good/init.sh"
    echo '# recipe' > "$CLOUDIFY_DIR/pkg/noleg/init.sh"
    touch "$CLOUDIFY_TMP/marker-good"
    printf 'rm -f "$CLOUDIFY_TMP/marker-good"\n' > "$CLOUDIFY_DIR/pkg/good/uninstall.sh"
    run cloudify_uninstall_package good noleg
    [ "$status" -ne 0 ]
    [ ! -f "$CLOUDIFY_TMP/marker-good" ]
}

@test "uninstall never touches dependencies" {
    mkdir -p "$CLOUDIFY_DIR/pkg/parent" "$CLOUDIFY_DIR/pkg/dep"
    printf 'pkg_depends dep\n' > "$CLOUDIFY_DIR/pkg/parent/init.sh"
    echo '# dep' > "$CLOUDIFY_DIR/pkg/dep/init.sh"
    printf ':\n' > "$CLOUDIFY_DIR/pkg/parent/uninstall.sh"
    printf 'rm -f "$CLOUDIFY_TMP/marker-dep"\n' > "$CLOUDIFY_DIR/pkg/dep/uninstall.sh"
    touch "$CLOUDIFY_TMP/marker-dep"
    run cloudify_uninstall_package parent
    [ "$status" -eq 0 ]
    [ -f "$CLOUDIFY_TMP/marker-dep" ]
}
