#!/usr/bin/env bats
# Tests for lib/vars.sh — five-source var helpers (ADR-007/ADR-011),
# the precedence walker, the secret resolver (R4), the reserved-name guard
# (R5) and the deployment reader value parsing (R6).
#
# Note: _cloudify_pkg_remote_vars is called in the parent shell (exports must
# survive for envsubst), so walker tests call it directly, not via `run`.

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
    source lib/remote.sh
    unset _CLOUDIFY_VARS_LEDGER _CLOUDIFY_VARS_DECLARED
}

teardown() {
    teardown_test_env
}

# --- Function surface ---

@test "five-source helpers are defined" {
    [ "$(type -t cloudify_vars_global_read)" = "function" ]
    [ "$(type -t cloudify_vars_global_write)" = "function" ]
    [ "$(type -t cloudify_vars_pkg_read)" = "function" ]
    [ "$(type -t cloudify_vars_pkg_write)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_read)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_write)" = "function" ]
    [ "$(type -t cloudify_vars_env_read)" = "function" ]
    [ "$(type -t cloudify_vars_state_read)" = "function" ]
}

@test "module guard prevents double-sourcing lib/vars.sh" {
    source lib/vars.sh
    source lib/vars.sh
    [ "$(type -t cloudify_vars_global_read)" = "function" ]
}

@test "cloudify_vars_state_read is a read-only no-op until branch 7" {
    run cloudify_vars_state_read
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- Resolver (R4) ---

@test "resolver is identity for a plain value" {
    run _cloudify_resolve_var_value MYVAR "plain value"
    [ "$status" -eq 0 ]
    [ "$output" = "plain value" ]
}

@test "resolver @@ escapes a literal leading @" {
    run _cloudify_resolve_var_value MYVAR "@@literal"
    [ "$status" -eq 0 ]
    [ "$output" = "@literal" ]
}

@test "resolver decodes @base64: locator" {
    run _cloudify_resolve_var_value MYVAR "@base64:$(printf 'hello' | base64 -w0)"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "resolver base64 round-trips a multi-line value" {
    local encoded
    encoded=$(printf 'line1\nline2' | base64 -w0)
    run _cloudify_resolve_var_value MYVAR "@base64:${encoded}"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'line1\nline2')" ]
}

@test "resolver dies on an unknown backend" {
    run _cloudify_resolve_var_value MYVAR "@nope:whatever"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown secret backend"* || "$output" == *"nope"* ]]
}

@test "resolver dies on a malformed reference" {
    run _cloudify_resolve_var_value MYVAR "@nocolon"
    [ "$status" -ne 0 ]
}

@test "resolver dies when the backend fails (never forwards empty)" {
    run _cloudify_resolve_var_value MYVAR "@base64:not-valid-base64!!!"
    [ "$status" -ne 0 ]
}

@test "resolver value never reaches stdout as empty on backend failure" {
    local out
    out=$(_cloudify_resolve_var_value MYVAR "@base64:not-valid-base64!!!" 2>/dev/null) || true
    [ -z "$out" ]
}

# --- global source ---

@test "cloudify_vars_global_write then read round-trips and enforces perms" {
    cloudify_vars_global_write MY_GLOBAL "global-value"
    local file="$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    [ -f "$file" ]
    [ "$(stat -c '%a' "$file")" = "600" ]
    [ "$(stat -c '%a' "$CLOUDIFY_CREDENTIALS_DIR")" = "700" ]
    unset MY_GLOBAL
    cloudify_vars_global_read "$file" > /dev/null
    [ "$MY_GLOBAL" = "global-value" ]
}

@test "global read is back-compat with quoted and colon values" {
    cat > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml" <<'EOF'
# comment
QUOTED: "a: b"
SINGLE: 'c d'
PLAIN: https://host:6443/path
EOF
    unset QUOTED SINGLE PLAIN
    cloudify_vars_global_read "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml" > /dev/null
    [ "$QUOTED" = "a: b" ]
    [ "$SINGLE" = "c d" ]
    [ "$PLAIN" = "https://host:6443/path" ]
}

@test "global write preserves other keys and replaces the same key" {
    cloudify_vars_global_write KEEP keepme
    cloudify_vars_global_write KEEP replaced
    run cat "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    [ "$(echo "$output" | grep -c '^KEEP:')" -eq 1 ]
    [ "$(echo "$output" | grep -c 'replaced')" -eq 1 ]
}

# --- package source ---

@test "cloudify_vars_pkg_write then read round-trips and enforces perms" {
    cloudify_vars_pkg_write mypkg MY_PKG "pkg-value"
    local file="$CLOUDIFY_CREDENTIALS_DIR/pkgs/mypkg.yaml"
    [ -f "$file" ]
    [ "$(stat -c '%a' "$file")" = "600" ]
    [ "$(stat -c '%a' "$CLOUDIFY_CREDENTIALS_DIR/pkgs")" = "700" ]
    unset MY_PKG
    cloudify_vars_pkg_read mypkg > /dev/null
    [ "$MY_PKG" = "pkg-value" ]
}

@test "pkg read declares names from .remote-vars and takes values from caller env" {
    mkdir -p "$CLOUDIFY_DIR/pkg/mypkg"
    printf 'DECLARED_VAR\n' > "$CLOUDIFY_DIR/pkg/mypkg/.remote-vars"
    export DECLARED_VAR=fromenv
    cloudify_vars_pkg_read mypkg > /dev/null
    [ "$DECLARED_VAR" = "fromenv" ]
}

# --- deployment source ---

@test "cloudify_vars_deployment_write then read round-trips" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_deployment_write DEP_VAR "dep-value"
    unset DEP_VAR
    cloudify_vars_deployment_read testdep > /dev/null
    [ "$DEP_VAR" = "dep-value" ]
}

@test "deployment read preserves single quotes, double quotes, backslashes and spaces (R6)" {
    cloudify_deployment_create testdep
    cat > "$CLOUDIFY_DEPLOYMENTS_DIR/testdep/config.yaml" <<'EOF'
QUOTED: it's a "test" \ backslash
SPACED:   lots   of   spaces
EOF
    unset QUOTED SPACED
    cloudify_vars_deployment_read testdep > /dev/null
    [ "$QUOTED" = "it's a \"test\" \\ backslash" ]
    [ "$SPACED" = "lots   of   spaces" ]
}

@test "deployment read resolves @base64: multi-line values (R6)" {
    cloudify_deployment_create testdep
    local encoded
    encoded=$(printf 'line1\nline2' | base64 -w0)
    printf 'MULTI: @base64:%s\n' "$encoded" > "$CLOUDIFY_DEPLOYMENTS_DIR/testdep/config.yaml"
    unset MULTI
    cloudify_vars_deployment_read testdep > /dev/null
    [ "$MULTI" = "$(printf 'line1\nline2')" ]
}

# --- env source ---

@test "env read claims a set name and skips an unset one" {
    export ENV_SET=yes
    unset ENV_UNSET
    local out
    out=$(cloudify_vars_env_read ENV_SET ENV_UNSET)
    echo "$out" | grep -qx ENV_SET
    ! echo "$out" | grep -qx ENV_UNSET
}

# --- reserved names (R5) ---

@test "reserved name in the global file is warned and skipped" {
    printf 'DEBUG: true\nCLOUDIFY_REMOTE_USER: evil\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    export DEBUG=false
    export CLOUDIFY_REMOTE_USER=root
    run bash -c 'source lib/colors.sh; source lib/utils.sh; source lib/pkg-config.sh; \
        DEBUG=false; CLOUDIFY_REMOTE_USER=root; \
        cloudify_vars_global_read "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml" >/dev/null 2>&1; \
        echo "DEBUG=$DEBUG USER=$CLOUDIFY_REMOTE_USER"'
    [ "$output" = "DEBUG=false USER=root" ]
}

@test "reserved name in a pkg yaml is skipped" {
    cloudify_vars_pkg_write mypkg CLOUDIFY_REMOTE_PWD evil
    export CLOUDIFY_REMOTE_PWD=good
    cloudify_vars_pkg_read mypkg > /dev/null 2>&1
    [ "$CLOUDIFY_REMOTE_PWD" = "good" ]
}

@test "reserved name in the deployment store is skipped" {
    cloudify_deployment_create testdep
    printf 'CLOUDIFY_UPDATE_DELAY: 999\n' > "$CLOUDIFY_DEPLOYMENTS_DIR/testdep/config.yaml"
    export CLOUDIFY_UPDATE_DELAY=30
    cloudify_vars_deployment_read testdep > /dev/null 2>&1
    [ "$CLOUDIFY_UPDATE_DELAY" = "30" ]
}
