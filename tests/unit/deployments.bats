#!/usr/bin/env bats
# Tests for lib/deployments.sh (ADR-011)

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/packages.sh
    source lib/deployments.sh
    # Override deployments dir to use test temp
    export CLOUDIFY_DEPLOYMENTS_DIR="$CLOUDIFY_TMP/test-deployments"
}

teardown() {
    teardown_test_env
}

# --- Function definitions ---

@test "deployment functions are defined after sourcing" {
    [ "$(type -t cloudify_deployment_create)" = "function" ]
    [ "$(type -t cloudify_deployment_delete)" = "function" ]
    [ "$(type -t cloudify_deployment_list)" = "function" ]
    [ "$(type -t cloudify_deployment_use)" = "function" ]
    [ "$(type -t cloudify_vars_set)" = "function" ]
    [ "$(type -t cloudify_vars_delete)" = "function" ]
    [ "$(type -t cloudify_vars_list)" = "function" ]
    [ "$(type -t cloudify_vars_show)" = "function" ]
    [ "$(type -t _cloudify_deployment_read_vars)" = "function" ]
}

@test "module guard prevents double-sourcing" {
    source lib/deployments.sh
    source lib/deployments.sh
    [ "$(type -t cloudify_deployment_create)" = "function" ]
}

# --- Deployment dir helpers ---

@test "_cloudify_deployment_dir returns canonical path" {
    run _cloudify_deployment_dir my-cluster
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DEPLOYMENTS_DIR/my-cluster" ]
}

@test "_cloudify_deployment_dir rejects unsafe ids" {
    run _cloudify_deployment_dir "../escape"
    [ "$status" -ne 0 ]
    run _cloudify_deployment_dir "path/traversal"
    [ "$status" -ne 0 ]
    run _cloudify_deployment_dir "."
    [ "$status" -ne 0 ]
    run _cloudify_deployment_dir ""
    [ "$status" -ne 0 ]
}

# --- Deployment CRUD ---

@test "cloudify_deployment_create creates dir and config, is idempotent" {
    run cloudify_deployment_create my-cluster
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "my-cluster"
    [ -d "$CLOUDIFY_DEPLOYMENTS_DIR/my-cluster" ]
    [ -f "$CLOUDIFY_DEPLOYMENTS_DIR/my-cluster/config.yaml" ]
    # Idempotent: no error on re-create
    run cloudify_deployment_create my-cluster
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "already exists"
}

@test "cloudify_deployment_delete removes deployment dir" {
    cloudify_deployment_create my-cluster
    run cloudify_deployment_delete my-cluster
    [ "$status" -eq 0 ]
    [ ! -d "$CLOUDIFY_DEPLOYMENTS_DIR/my-cluster" ]
}

@test "cloudify_deployment_delete is no-op for nonexistent" {
    run cloudify_deployment_delete nonexistent
    [ "$status" -eq 0 ]
}

@test "cloudify_deployment_list shows created deployments" {
    run cloudify_deployment_list
    echo "$output" | grep -q "(no deployments)"
    cloudify_deployment_create prod
    cloudify_deployment_create dev
    run cloudify_deployment_list
    echo "$output" | grep -q "prod"
    echo "$output" | grep -q "dev"
}

@test "cloudify_deployment_use prints export command" {
    cloudify_deployment_create my-cluster
    run cloudify_deployment_use my-cluster
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "export CLOUDIFY_DEPLOYMENT=my-cluster"
}

@test "cloudify_deployment_use errors on nonexistent" {
    run cloudify_deployment_use nonexistent
    [ "$status" -ne 0 ]
}

# --- Var management ---

@test "vars: set/get/delete cycle" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep

    # Set var
    run cloudify_vars_set K3S_TOKEN "my-secret-token"
    [ "$status" -eq 0 ]

    # Show var
    run cloudify_vars_show K3S_TOKEN
    [ "$status" -eq 0 ]
    [ "$output" = "my-secret-token" ]

    # Delete var
    run cloudify_vars_delete K3S_TOKEN
    [ "$status" -eq 0 ]
    run cloudify_vars_show K3S_TOKEN
    [ -z "$output" ]
}

@test "vars: set overwrites existing key" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_set K3S_TOKEN "old-token"
    run cloudify_vars_set K3S_TOKEN "new-token"
    [ "$status" -eq 0 ]
    run cloudify_vars_show K3S_TOKEN
    [ "$output" = "new-token" ]
    # No duplicate lines
    run cloudify_vars_list
    [ "$(echo "$output" | grep -c "K3S_TOKEN")" -eq 1 ]
}

@test "vars: multiple vars coexist" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_set K3S_TOKEN "token-abc"
    cloudify_vars_set K3S_URL "https://server:6443"
    run cloudify_vars_show K3S_TOKEN
    [ "$output" = "token-abc" ]
    run cloudify_vars_show K3S_URL
    [ "$output" = "https://server:6443" ]
}

@test "vars: set requires CLOUDIFY_DEPLOYMENT" {
    unset CLOUDIFY_DEPLOYMENT
    run cloudify_vars_set FOO bar
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "CLOUDIFY_DEPLOYMENT"
}

@test "vars: list (no vars)" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    run cloudify_vars_list
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "(no vars)"
}

@test "vars: list --json produces valid JSON" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_set K3S_TOKEN "token-abc"
    cloudify_vars_set CLUSTER_NAME "my-prod"
    run cloudify_vars_list --json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"K3S_TOKEN"'
    echo "$output" | grep -q '"token-abc"'
    echo "$output" | grep -q '"CLUSTER_NAME"'
    echo "$output" | grep -q '"my-prod"'
    # Valid JSON
    echo "$output" | python3 -m json.tool >/dev/null 2>&1 || {
        echo "Invalid JSON: $output"
        return 1
    }
}

@test "vars: delete nonexistent is no-op" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    run cloudify_vars_delete DOES_NOT_EXIST
    [ "$status" -eq 0 ]
}

# --- Deployment-wide var reading (remote integration) ---

@test "_cloudify_deployment_read_vars reads and exports vars, returns names" {
    cloudify_deployment_create testdep
    # Write config directly (simulating vars set)
    cat > "$CLOUDIFY_DEPLOYMENTS_DIR/testdep/config.yaml" <<'EOF'
K3S_TOKEN: secret-123
K3S_URL: https://server:6443
EOF
    run _cloudify_deployment_read_vars testdep
    [ "$status" -eq 0 ]
    # Returns var names
    echo "$output" | grep -qx "K3S_TOKEN"
    echo "$output" | grep -qx "K3S_URL"
    # Exported values
    [ "${K3S_TOKEN:-}" = "secret-123" ]
    [ "${K3S_URL:-}" = "https://server:6443" ]
}

@test "_cloudify_deployment_read_vars no-ops for nonexistent deployment" {
    run _cloudify_deployment_read_vars nonexistent
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_cloudify_deployment_read_vars no-ops for empty id" {
    run _cloudify_deployment_read_vars ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- Var values with special characters ---

@test "vars: values with spaces and special chars" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_set GREETING "hello world"
    cloudify_vars_set URL "https://example.com/path?foo=bar&baz=qux"
    run cloudify_vars_show GREETING
    [ "$output" = "hello world" ]
    run cloudify_vars_show URL
    [ "$output" = "https://example.com/path?foo=bar&baz=qux" ]
}

@test "vars: empty value is stored as empty" {
    cloudify_deployment_create testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_set EMPTY ""
    run cloudify_vars_show EMPTY
    [ -z "$output" ]
}

# --- Two deployments track independent vars ---

@test "vars: two deployments have independent state" {
    cloudify_deployment_create dep-a
    cloudify_deployment_create dep-b
    export CLOUDIFY_DEPLOYMENT=dep-a
    cloudify_vars_set TOKEN "token-a"
    export CLOUDIFY_DEPLOYMENT=dep-b
    cloudify_vars_set TOKEN "token-b"
    # Verify isolation
    export CLOUDIFY_DEPLOYMENT=dep-a
    run cloudify_vars_show TOKEN
    [ "$output" = "token-a" ]
    export CLOUDIFY_DEPLOYMENT=dep-b
    run cloudify_vars_show TOKEN
    [ "$output" = "token-b" ]
}
