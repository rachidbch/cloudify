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
    # Capture stdout (var names) — can't use `run` because exports must survive
    local names
    names=$(_cloudify_deployment_read_vars testdep)
    # Returns var names
    echo "$names" | grep -qx "K3S_TOKEN"
    echo "$names" | grep -qx "K3S_URL"
    # Exported values (function is called WITHOUT run, so exports survive)
    # Re-call directly to export
    _cloudify_deployment_read_vars testdep >/dev/null
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

# ---------------------------------------------------------------
# Nested desired inputs, read-through, migration and the read
# surface (state model v2 Phase 3 slice 3B)
# ---------------------------------------------------------------

# An explicit application reference: the three tuple components exported, which
# is what `cloudify app run` does before any child dispatch.
_app_ref() {
    export CLOUDIFY_APPLICATION="$1" CLOUDIFY_FLAVOR="$2" CLOUDIFY_DEPLOYMENT_NAME="$3"
}

@test "nested inputs: values file path is one validated component per level" {
    run cloudify_deployment_values_file myapp default prod
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod/values.yaml" ]

    run cloudify_deployment_values_file "../evil" default prod
    [ "$status" -ne 0 ]
    run cloudify_deployment_values_file myapp "a/b" prod
    [ "$status" -ne 0 ]
    run cloudify_deployment_values_file myapp default "."
    [ "$status" -ne 0 ]
}

@test "nested inputs: no explicit application reference keeps the legacy store" {
    cloudify_deployment_create legacy-dep
    [ "$(_cloudify_deployment_config legacy-dep)" = "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-dep/config.yaml" ]
    [ "$(_cloudify_deployment_write_config legacy-dep)" = "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-dep/config.yaml" ]

    export CLOUDIFY_DEPLOYMENT=legacy-dep
    cloudify_vars_set LEGACY_KEY legacy-value
    run cloudify_vars_show LEGACY_KEY
    [ "$output" = "legacy-value" ]
    [ -f "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-dep/config.yaml" ]
}

@test "nested inputs: read-through uses the legacy store until the nested file exists" {
    cloudify_deployment_create legacy-dep
    export CLOUDIFY_DEPLOYMENT=legacy-dep
    cloudify_vars_set FROM_LEGACY read-through

    _app_ref myapp default prod
    # No nested file yet: the read resolves through the legacy single-ID store.
    [ "$(_cloudify_deployment_config legacy-dep)" = "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-dep/config.yaml" ]
    [ "$(_cloudify_deployment_read_vars legacy-dep >/dev/null; printf ok)" = "ok" ]
    run cloudify_vars_deployment_show FROM_LEGACY legacy-dep
    [ "$output" = "read-through" ]
}

@test "nested inputs: a write after an explicit application reference goes to the nested path only" {
    cloudify_deployment_create legacy-dep
    export CLOUDIFY_DEPLOYMENT=legacy-dep
    cloudify_vars_set OLD_KEY old-value

    _app_ref myapp default prod
    # The legacy store still holds OLD_KEY: the write guard refuses until the operator migrates.
    run cloudify_vars_deployment_write NEW_KEY new-value legacy-dep
    [ "$status" -ne 0 ]
    [[ "$output" == *"migrate"* ]]
    [ ! -f "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod/values.yaml" ]

    # After the explicit migration the nested store is authoritative.
    run cloudify_deployment_migrate legacy-dep --application myapp --flavor default --name prod
    [ "$status" -eq 0 ]
    run cloudify_vars_deployment_write NEW_KEY new-value legacy-dep
    [ "$status" -eq 0 ]
    [ -f "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod/values.yaml" ]
    run grep -c '^NEW_KEY:' "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-dep/config.yaml"
    [ "$output" = "0" ]
    run grep '^OLD_KEY:' "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-dep/config.yaml"
    [ "$output" = "OLD_KEY: old-value" ]
}

@test "migrate: requires an explicit application and flavor, never splits the ID" {
    cloudify_deployment_create legacy-app
    run cloudify_deployment_migrate legacy-app
    [ "$status" -ne 0 ]
    [[ "$output" == *"--application is required"* ]]
    [[ "$output" == *"never split"* ]]

    run cloudify_deployment_migrate legacy-app --application "../evil"
    [ "$status" -ne 0 ]
    [ ! -d "$CLOUDIFY_DEPLOYMENTS_DIR/../evil" ]
}

@test "migrate: dry run writes nothing and prints names and paths, never a value" {
    cloudify_deployment_create legacy-app
    export CLOUDIFY_DEPLOYMENT=legacy-app
    cloudify_vars_set API_TOKEN "PLACEHOLDER_MIGRATE_SECRET"
    cloudify_vars_set PUBLIC_HOST "demo.example.com"

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"source: $CLOUDIFY_DEPLOYMENTS_DIR/legacy-app/config.yaml"* ]]
    [[ "$output" == *"destination: $CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"* ]]
    [[ "$output" == *"input keys (names only, 2): API_TOKEN,PUBLIC_HOST"* ]]
    [[ "$output" == *"add (names only): API_TOKEN,PUBLIC_HOST"* ]]
    [[ "$output" == *"dry run, nothing written"* ]]
    # names and paths only: neither value leaks
    [[ "$output" != *"PLACEHOLDER_MIGRATE_SECRET"* ]]
    [[ "$output" != *"demo.example.com"* ]]
    [ ! -f "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml" ]
}

@test "migrate: copies idempotently, keeps the legacy store, mode 0600" {
    cloudify_deployment_create legacy-app
    export CLOUDIFY_DEPLOYMENT=legacy-app
    cloudify_vars_set API_TOKEN "@@literal-at-sign"
    cloudify_vars_set PUBLIC_HOST "demo.example.com"

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default
    [ "$status" -eq 0 ]
    [[ "$output" == *"migrated (2 key names added"* ]]
    local target="$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"
    [ -f "$target" ]
    [ "$(stat -c '%a' "$target")" = "600" ]
    [ "$(stat -c '%a' "$(dirname "$target")")" = "700" ]

    # The legacy store is untouched: a rollback needs no reverse transformation.
    run grep -c '^API_TOKEN:' "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-app/config.yaml"
    [ "$output" = "1" ]

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default
    [ "$status" -eq 0 ]
    [[ "$output" == *"already migrated"* ]]
    [[ "$output" == *"nothing to do"* ]]
}

@test "migrate: a conflicting destination key is refused unless --force" {
    cloudify_deployment_create legacy-app
    export CLOUDIFY_DEPLOYMENT=legacy-app
    cloudify_vars_set PUBLIC_HOST "legacy.example.com"

    _app_ref myapp default default
    mkdir -p "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default"
    printf 'PUBLIC_HOST: nested.example.com\n' > "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default
    [ "$status" -ne 0 ]
    [[ "$output" == *"conflict (names only): PUBLIC_HOST"* ]]
    [[ "$output" == *"--force"* ]]
    run grep '^PUBLIC_HOST:' "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"
    [ "$output" = "PUBLIC_HOST: nested.example.com" ]

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default --force
    [ "$status" -eq 0 ]
    run grep '^PUBLIC_HOST:' "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"
    [ "$output" = "PUBLIC_HOST: legacy.example.com" ]
}

@test "show: prints the manifest and the compatibility snapshots, never a value" {
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    source lib/state.sh
    _app_ref myapp default default
    export CLOUDIFY_DEPLOYMENT=myapp.default.default
    local bindings="$CLOUDIFY_TMP/bindings.tsv"
    printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\tcloudify\n' > "$bindings"
    cloudify_manifest_write myapp default default applying 0123456789abcdef0123456789abcdef01234567 false "$bindings"
    mkdir -p "$CLOUDIFY_DEPLOYMENTS_DIR/myapp.default.default/runs"
    printf 'status: succeeded\n' > "$CLOUDIFY_DEPLOYMENTS_DIR/myapp.default.default/runs/20260101T000000Z.yaml"

    # The read surface takes the tuple from an explicit application reference, or
    # from the runbook that declares the deployment (none in this fixture).
    run cloudify_deployment_show myapp.default.default
    [ "$status" -eq 0 ]
    [[ "$output" == *"application: myapp/default"* ]]
    [[ "$output" == *"deployment_name: default"* ]]
    [[ "$output" == *"status: applying"* ]]
    [[ "$output" == *"replayable: yes"* ]]
    [[ "$output" == *"snapshots: 1"* ]]
    [[ "$output" == *"binding guest: cloudai:cloudify"* ]]
    # the read surface carries names, paths and bindings, never an applied value
    [[ "$output" != *"value."* ]]
}

@test "list: current manifests are listed alongside legacy deployment ids" {
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    source lib/state.sh
    cloudify_deployment_create legacy-listed
    local bindings="$CLOUDIFY_TMP/bindings.tsv"
    printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\tcloudify\n' > "$bindings"
    cloudify_manifest_write myapp default default applying 0123456789abcdef0123456789abcdef01234567 false "$bindings"

    run cloudify_deployment_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"legacy-listed"* ]]
    [[ "$output" == *"myapp/default --name default"* ]]
}
