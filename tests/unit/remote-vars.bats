#!/usr/bin/env bats
# Tests for pkg .remote-vars (ADR-007): names in repo, values from caller env.
# The parallel test is the regression guard: a shared on-disk values file
# would make two concurrent collections race and cross-contaminate.
#
# Note: _cloudify_pkg_remote_vars is called in the parent shell (exports must
# survive for envsubst below), so tests call it directly, not via `run`.

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
}

teardown() {
    teardown_test_env
}

# Fixture: a package declaring K3S_TOKEN in .remote-vars, no yaml on disk.
make_fixture() {
    mkdir -p "$CLOUDIFY_DIR/pkg/foo"
    printf 'K3S_TOKEN\n' > "$CLOUDIFY_DIR/pkg/foo/.remote-vars"
}

@test "declared name takes its value from caller env" {
    make_fixture
    export K3S_TOKEN=abc123
    _cloudify_pkg_remote_vars install foo > "$CLOUDIFY_TMP/names" 2>&1
    grep -q "K3S_TOKEN" "$CLOUDIFY_TMP/names"
    [ "$K3S_TOKEN" = "abc123" ]
}

@test "declared value lands in the remote payload via envsubst" {
    make_fixture
    export K3S_TOKEN=token-A
    export CLOUDIFY_REMOTE_USER=testuser
    cloudify_init_log
    ssh() { printf '%s' "${@: -1}" > "$CLOUDIFY_TMP/payload"; return 0; }
    cloudify_remote_sync somehost install foo
    grep -q "K3S_TOKEN='token-A'" "$CLOUDIFY_TMP/payload"
}

@test "declared-but-unset name produces a visible warning" {
    make_fixture
    unset K3S_TOKEN
    _cloudify_pkg_remote_vars install foo > "$CLOUDIFY_TMP/out" 2>&1
    grep -qi "K3S_TOKEN" "$CLOUDIFY_TMP/out"
}

@test "no .remote-vars: per-pkg yaml still applies (back-compat)" {
    mkdir -p "$CLOUDIFY_DIR/pkg/foo"
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    printf 'SOME_VAR: fromyaml\n' > "$CLOUDIFY_CREDENTIALS_DIR/pkgs/foo.yaml"
    unset SOME_VAR
    _cloudify_pkg_remote_vars install foo > /dev/null 2>&1
    [ "$SOME_VAR" = "fromyaml" ]
}

@test "global remote-vars.yaml still forwarded (back-compat)" {
    mkdir -p "$CLOUDIFY_DIR/pkg/foo"
    printf 'ALWAYS_VAR: fromglobal\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    unset ALWAYS_VAR
    _cloudify_pkg_remote_vars install foo > /dev/null 2>&1
    [ "$ALWAYS_VAR" = "fromglobal" ]
}

@test "env value wins over same-name per-pkg yaml value" {
    make_fixture
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    printf 'K3S_TOKEN: fromyaml\n' > "$CLOUDIFY_CREDENTIALS_DIR/pkgs/foo.yaml"
    export K3S_TOKEN=fromenv
    _cloudify_pkg_remote_vars install foo > /dev/null 2>&1
    [ "$K3S_TOKEN" = "fromenv" ]
}

@test "parallel collections each keep their own env value (no shared-file race)" {
    make_fixture
    ( export K3S_TOKEN=token-A; _cloudify_pkg_remote_vars install foo >/dev/null 2>&1; \
        echo "K3S_TOKEN=$K3S_TOKEN" > "$CLOUDIFY_TMP/env-A" ) &
    local p1=$!
    ( export K3S_TOKEN=token-B; _cloudify_pkg_remote_vars install foo >/dev/null 2>&1; \
        echo "K3S_TOKEN=$K3S_TOKEN" > "$CLOUDIFY_TMP/env-B" ) &
    local p2=$!
    wait "$p1"
    wait "$p2"
    grep -q "K3S_TOKEN=token-A" "$CLOUDIFY_TMP/env-A"
    grep -q "K3S_TOKEN=token-B" "$CLOUDIFY_TMP/env-B"
}
