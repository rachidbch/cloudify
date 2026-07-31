#!/usr/bin/env bats
# Tests for install/run split (ADR-008): optional install.sh (idempotent bits +
# install guard) + configure.sh (run-phase, no guard); init.sh back-compat.

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/remote.sh
    rm -f /tmp/unit-split-log /tmp/unit-split-installed
    export CLOUDIFY_RECIPE_FILENAME=init.sh
    export CLOUDIFY_NO_VERIFY=true
}

teardown() {
    teardown_test_env
    rm -f /tmp/unit-split-log /tmp/unit-split-installed
}

# Inline fixtures mirroring pkg/fixture-split (real ones used by integration).
make_split_fixture() {
    mkdir -p "$CLOUDIFY_DIR/pkg/split"
    cat > "$CLOUDIFY_DIR/pkg/split/install.sh" <<'EOF'
#!/usr/bin/env bash
if [[ -f /tmp/unit-split-installed ]] && \
   [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    echo "INSTALL_SKIPPED" >> /tmp/unit-split-log
    return 0
fi
echo "INSTALL_RAN" >> /tmp/unit-split-log
touch /tmp/unit-split-installed
EOF
    cat > "$CLOUDIFY_DIR/pkg/split/configure.sh" <<'EOF'
#!/usr/bin/env bash
echo "CONFIGURE_RAN" >> /tmp/unit-split-log
EOF
}

make_legacy_fixture() {
    mkdir -p "$CLOUDIFY_DIR/pkg/legacy"
    cat > "$CLOUDIFY_DIR/pkg/legacy/init.sh" <<'EOF'
#!/usr/bin/env bash
echo "LEGACY_RAN" >> /tmp/unit-split-log
EOF
}

@test "split pkg recipe resolves to install.sh; legacy resolves to init.sh" {
    make_split_fixture
    make_legacy_fixture
    run cloudify_package_recipe_path split
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/split/install.sh" ]
    run cloudify_package_recipe_path legacy
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/legacy/init.sh" ]
}

@test "configure.sh resolves only for split pkgs" {
    make_split_fixture
    make_legacy_fixture
    run cloudify_package_recipe_path split configure.sh
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/split/configure.sh" ]
    run cloudify_package_recipe_path legacy configure.sh
    [ "$status" -ne 0 ]
}

@test "pkg_depends runs install.sh then configure.sh for a split pkg" {
    make_split_fixture
    export CLOUDIFY_FORCE=true
    pkg_depends split
    grep -q "INSTALL_RAN" /tmp/unit-split-log
    grep -q "CONFIGURE_RAN" /tmp/unit-split-log
}

@test "re-run without FORCE: install guard skips install.sh, configure.sh still runs" {
    make_split_fixture
    export CLOUDIFY_FORCE=true
    pkg_depends split
    # Dep-style re-run (no FORCE): guard trips, configure still runs
    unset CLOUDIFY_FORCE
    pkg_depends split
    grep -q "INSTALL_SKIPPED" /tmp/unit-split-log
    grep -q "CONFIGURE_RAN" /tmp/unit-split-log
}

@test "pkg_depends runs init.sh only for a legacy pkg" {
    make_legacy_fixture
    export CLOUDIFY_FORCE=true
    pkg_depends legacy
    grep -q "LEGACY_RAN" /tmp/unit-split-log
    if grep -q "CONFIGURE_RAN" /tmp/unit-split-log; then
        echo "legacy pkg must not run a configure phase" >&2
        return 1
    fi
}

@test "cloudify_configure_package runs configure.sh only (no install phase)" {
    make_split_fixture
    cloudify_configure_package split
    grep -q "CONFIGURE_RAN" /tmp/unit-split-log
    if grep -q "INSTALL_RAN" /tmp/unit-split-log; then
        echo "configure must not run the install phase" >&2
        return 1
    fi
}

@test "cloudify_configure_package errors clearly for a non-split pkg" {
    make_legacy_fixture
    run cloudify_configure_package legacy
    [ "$status" -ne 0 ]
    [[ "$output" == *"no configure.sh"* ]]
}
