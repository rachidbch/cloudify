#!/usr/bin/env bats
# Tests for lib/deployments.sh (ADR-011, state model v2 Phase 3)

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
    [ "$(type -t cloudify_deployment_list)" = "function" ]
    [ "$(type -t cloudify_deployment_show)" = "function" ]
    [ "$(type -t cloudify_deployment_migrate)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_write)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_delete)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_list)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_show)" = "function" ]
    [ "$(type -t cloudify_vars_deployment_read)" = "function" ]
}

@test "module guard prevents double-sourcing" {
    source lib/deployments.sh
    source lib/deployments.sh
    [ "$(type -t cloudify_deployment_list)" = "function" ]
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

# --- Deployment list ---

@test "cloudify_deployment_list lists current manifests" {
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    source lib/state.sh
    run cloudify_deployment_list
    echo "$output" | grep -q "(no deployments)"

    local bindings="$CLOUDIFY_TMP/bindings.tsv"
    printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\tcloudify\n' > "$bindings"
    cloudify_manifest_write myapp default prod applying 0123456789abcdef0123456789abcdef01234567 false "$bindings"
    run cloudify_deployment_list
    echo "$output" | grep -q "myapp/default --name prod"
}

@test "cloudify_deployment_list never prints a bare directory as a deployment" {
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    source lib/state.sh
    # A legacy single-ID run directory and a nested desired-inputs tree: neither
    # is a deployment on its own.
    mkdir -p "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-id/runs"
    mkdir -p "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod"
    : > "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod/values.yaml"
    run cloudify_deployment_list
    [ "$status" -eq 0 ]
    [[ "$output" == *"(no deployments)"* ]]
    [[ "$output" != *"legacy-id"* ]]
    [[ "$output" != *"myapp"* ]]
}

# --- Var management ---

# An explicit application reference: the three tuple components exported, which
# is what `cloudify app run` does before any child dispatch. The deployment ID
# stays the run label; the store is the nested path.
_app_ref() {
    export CLOUDIFY_APPLICATION="$1" CLOUDIFY_FLAVOR="$2" CLOUDIFY_DEPLOYMENT_NAME="$3"
}

@test "vars: set/get/delete cycle" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep

    # Set var
    run cloudify_vars_deployment_write K3S_TOKEN "my-secret-token"
    [ "$status" -eq 0 ]

    # Show var
    run cloudify_vars_deployment_show K3S_TOKEN
    [ "$status" -eq 0 ]
    [ "$output" = "my-secret-token" ]

    # Delete var
    run cloudify_vars_deployment_delete K3S_TOKEN
    [ "$status" -eq 0 ]
    run cloudify_vars_deployment_show K3S_TOKEN
    [ -z "$output" ]
}

@test "vars: set overwrites existing key" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_deployment_write K3S_TOKEN "old-token"
    run cloudify_vars_deployment_write K3S_TOKEN "new-token"
    [ "$status" -eq 0 ]
    run cloudify_vars_deployment_show K3S_TOKEN
    [ "$output" = "new-token" ]
    # No duplicate lines
    run cloudify_vars_deployment_list
    [ "$(echo "$output" | grep -c "K3S_TOKEN")" -eq 1 ]
}

@test "vars: multiple vars coexist" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_deployment_write K3S_TOKEN "token-abc"
    cloudify_vars_deployment_write K3S_URL "https://server:6443"
    run cloudify_vars_deployment_show K3S_TOKEN
    [ "$output" = "token-abc" ]
    run cloudify_vars_deployment_show K3S_URL
    [ "$output" = "https://server:6443" ]
}

@test "vars: set requires CLOUDIFY_DEPLOYMENT" {
    unset CLOUDIFY_DEPLOYMENT
    run cloudify_vars_deployment_write FOO bar
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "CLOUDIFY_DEPLOYMENT"
}

@test "vars: set without an application reference fails closed" {
    export CLOUDIFY_DEPLOYMENT=testdep
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    run cloudify_vars_deployment_write FOO bar
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "application reference"
}

@test "vars: list (no vars)" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    run cloudify_vars_deployment_list
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "(no vars)"
}

@test "vars: list --json produces valid JSON" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_deployment_write K3S_TOKEN "token-abc"
    cloudify_vars_deployment_write CLUSTER_NAME "my-prod"
    run cloudify_vars_deployment_list --json
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
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    run cloudify_vars_deployment_delete DOES_NOT_EXIST
    [ "$status" -eq 0 ]
}

# --- Deployment-wide var reading (remote integration) ---

@test "cloudify_vars_deployment_read reads and exports vars, returns names" {
    _app_ref testapp default testdep
    # Write the store directly (simulating vars set)
    local store
    store=$(_cloudify_deployment_config)
    mkdir -p "$(dirname "$store")"
    cat > "$store" <<'EOF'
K3S_TOKEN: secret-123
K3S_URL: https://server:6443
EOF
    # Capture stdout (var names) — can't use `run` because exports must survive
    local names
    names=$(cloudify_vars_deployment_read testdep)
    # Returns var names
    echo "$names" | grep -qx "K3S_TOKEN"
    echo "$names" | grep -qx "K3S_URL"
    # Exported values (function is called WITHOUT run, so exports survive)
    # Re-call directly to export
    cloudify_vars_deployment_read testdep >/dev/null
    [ "${K3S_TOKEN:-}" = "secret-123" ]
    [ "${K3S_URL:-}" = "https://server:6443" ]
}

@test "cloudify_vars_deployment_read no-ops for nonexistent deployment" {
    run cloudify_vars_deployment_read nonexistent
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "cloudify_vars_deployment_read no-ops for empty id" {
    run cloudify_vars_deployment_read ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- Var values with special characters ---

@test "vars: values with spaces and special chars" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_deployment_write GREETING "hello world"
    cloudify_vars_deployment_write URL "https://example.com/path?foo=bar&baz=qux"
    run cloudify_vars_deployment_show GREETING
    [ "$output" = "hello world" ]
    run cloudify_vars_deployment_show URL
    [ "$output" = "https://example.com/path?foo=bar&baz=qux" ]
}

@test "vars: empty value is stored as empty" {
    _app_ref testapp default testdep
    export CLOUDIFY_DEPLOYMENT=testdep
    cloudify_vars_deployment_write EMPTY ""
    run cloudify_vars_deployment_show EMPTY
    [ -z "$output" ]
}

# --- Two deployments track independent vars ---

@test "vars: two deployments have independent state" {
    export CLOUDIFY_DEPLOYMENT=dep-a
    _app_ref testapp default dep-a
    cloudify_vars_deployment_write TOKEN "token-a"
    export CLOUDIFY_DEPLOYMENT=dep-b
    _app_ref testapp default dep-b
    cloudify_vars_deployment_write TOKEN "token-b"
    # Verify isolation
    export CLOUDIFY_DEPLOYMENT=dep-a
    _app_ref testapp default dep-a
    run cloudify_vars_deployment_show TOKEN
    [ "$output" = "token-a" ]
    export CLOUDIFY_DEPLOYMENT=dep-b
    _app_ref testapp default dep-b
    run cloudify_vars_deployment_show TOKEN
    [ "$output" = "token-b" ]
}

# ---------------------------------------------------------------
# Nested desired inputs, migration and the read surface
# (state model v2 Phase 3)
# ---------------------------------------------------------------

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

@test "nested inputs: the store is the nested path of the application reference" {
    _app_ref myapp default prod
    [ "$(_cloudify_deployment_config)" = "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod/values.yaml" ]

    export CLOUDIFY_DEPLOYMENT=myapp.default.prod
    cloudify_vars_deployment_write FROM_NESTED nested-value
    run cloudify_vars_deployment_show FROM_NESTED
    [ "$output" = "nested-value" ]
    [ -f "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/prod/values.yaml" ]
}

@test "nested inputs: without an application reference there is no store" {
    export CLOUDIFY_DEPLOYMENT=myapp.default.prod
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    run _cloudify_deployment_config
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run cloudify_vars_deployment_show FROM_NESTED
    [ "$status" -ne 0 ]
    [[ "$output" == *"application reference"* ]]
}

# A single-ID store as `deployment migrate` finds it (the pre-nested layout).
_write_single_id_store() {
    local id="$1"
    shift
    mkdir -p "$CLOUDIFY_DEPLOYMENTS_DIR/$id"
    printf '%s\n' "$@" > "$CLOUDIFY_DEPLOYMENTS_DIR/$id/config.yaml"
    chmod 600 "$CLOUDIFY_DEPLOYMENTS_DIR/$id/config.yaml"
}

@test "migrate: requires an explicit application and flavor, never splits the ID" {
    _write_single_id_store legacy-app 'PUBLIC_HOST: demo.example.com'
    run cloudify_deployment_migrate legacy-app
    [ "$status" -ne 0 ]
    [[ "$output" == *"--application is required"* ]]
    [[ "$output" == *"never split"* ]]

    run cloudify_deployment_migrate legacy-app --application "../evil"
    [ "$status" -ne 0 ]
    [ ! -d "$CLOUDIFY_DEPLOYMENTS_DIR/../evil" ]
}

@test "migrate: dry run writes nothing and prints names and paths, never a value" {
    _write_single_id_store legacy-app 'API_TOKEN: PLACEHOLDER_MIGRATE_SECRET' 'PUBLIC_HOST: demo.example.com'

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

@test "migrate: copies idempotently, keeps the single-ID store, mode 0600" {
    _write_single_id_store legacy-app 'API_TOKEN: @@literal-at-sign' 'PUBLIC_HOST: demo.example.com'

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default
    [ "$status" -eq 0 ]
    [[ "$output" == *"migrated (2 key names added"* ]]
    local target="$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"
    [ -f "$target" ]
    [ "$(stat -c '%a' "$target")" = "600" ]
    [ "$(stat -c '%a' "$(dirname "$target")")" = "700" ]

    # The single-ID store is untouched: a rollback needs no reverse transformation.
    run grep -c '^PUBLIC_HOST:' "$CLOUDIFY_DEPLOYMENTS_DIR/legacy-app/config.yaml"
    [ "$output" = "1" ]

    run cloudify_deployment_migrate legacy-app --application myapp --flavor default --name default
    [ "$status" -eq 0 ]
    [[ "$output" == *"already migrated"* ]]
    [[ "$output" == *"nothing to do"* ]]
}

@test "migrate: a conflicting destination key is refused unless --force" {
    _write_single_id_store legacy-app 'PUBLIC_HOST: legacy.example.com'

    mkdir -p "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default"
    printf 'PUBLIC_HOST: nested.example.com\n' > "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"

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

@test "show: prints the manifest and the run snapshots, never a value" {
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
    [[ "$output" == *"inputs: $CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/default/values.yaml"* ]]
    # the read surface carries names, paths and bindings, never an applied value
    [[ "$output" != *"value."* ]]
}

@test "show: no application reference prints no inputs path" {
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    run cloudify_deployment_show unknown-dep
    [ "$status" -eq 0 ]
    [[ "$output" == *"inputs: <none: no application reference>"* ]]
}
