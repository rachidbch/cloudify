#!/usr/bin/env bats
# Branch 2: verify reads the environment the walker resolved (constraint a).
# A parent's forwarded value must not be overwritten by the dependency's yaml.

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/deployments.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/remote.sh
}

teardown() {
    teardown_test_env
}

@test "verify keeps the walker's parent-priority value over the dep yaml" {
    mkdir -p "$CLOUDIFY_DIR/pkg/parent" "$CLOUDIFY_DIR/pkg/dep" "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    echo 'pkg_depends dep' > "$CLOUDIFY_DIR/pkg/parent/init.sh"
    echo '# dep' > "$CLOUDIFY_DIR/pkg/dep/init.sh"
    printf 'SHARED_VAR\n' > "$CLOUDIFY_DIR/pkg/parent/.remote-vars"
    printf 'SHARED_VAR\n' > "$CLOUDIFY_DIR/pkg/dep/.remote-vars"
    printf 'SHARED_VAR: parent-value\n' > "$CLOUDIFY_CREDENTIALS_DIR/pkgs/parent.yaml"
    printf 'SHARED_VAR: dep-value\n' > "$CLOUDIFY_CREDENTIALS_DIR/pkgs/dep.yaml"
    cat > "$CLOUDIFY_DIR/pkg/dep/verify.sh" <<'V'
pkg_verify() { [[ "$SHARED_VAR" == parent-value ]]; }
V

    _cloudify_pkg_remote_vars install parent > /dev/null 2>&1
    [ "$SHARED_VAR" = "parent-value" ]

    run _cloudify_run_verify dep
    [ "$status" -eq 0 ]
    [ "$SHARED_VAR" = "parent-value" ]
}

@test "verify still fills an unset name from the pkg yaml" {
    mkdir -p "$CLOUDIFY_DIR/pkg/cfgpkg" "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    echo '# recipe' > "$CLOUDIFY_DIR/pkg/cfgpkg/init.sh"
    cat > "$CLOUDIFY_DIR/pkg/cfgpkg/verify.sh" <<'V'
pkg_verify() { [[ "${TEST_VERIFY_VAR:-}" == "from-yaml" ]]; }
V
    printf 'TEST_VERIFY_VAR: from-yaml\n' > "$CLOUDIFY_CREDENTIALS_DIR/pkgs/cfgpkg.yaml"
    unset TEST_VERIFY_VAR
    run _cloudify_run_verify cfgpkg
    [ "$status" -eq 0 ]
}
