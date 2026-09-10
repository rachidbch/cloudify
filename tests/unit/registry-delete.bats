#!/usr/bin/env bats
# Tests for cloudify_registry_delete_deployment (Branch 7 T4) and its wiring
# into `cloudify deployment delete`.
#
# Records live OUTSIDE the deployment store:
#   node target      <bucket root>/deployments/<id>/pkgs/...
#   instance target  <bucket root>/<instance>/deployments/<id>/pkgs/...
# Bucket roots = every dir under ${IVPS_CONFIG_DIR:-<xdg>/ivps}/nodes and under
# ${CLOUDIFY_CREDENTIALS_DIR}/registry/hosts. A candidate is only removed when it
# holds a `pkgs/` subdir, so a same-named unrelated directory is never touched.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/deployments.sh
    source lib/registry.sh

    # Hermetic: node dirs, fallback bucket and the deployment store all temp
    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export IVPS_CONFIG_DIR="$CLOUDIFY_TMP/ivps"
    NODE_ROOT="$IVPS_CONFIG_DIR/nodes"
    FALLBACK_HOSTS="$CLOUDIFY_CREDENTIALS_DIR/registry/hosts"

    DEP_X="xfce-gui"
    DEP_Y="other-app"
}

teardown() {
    teardown_test_env
}

# A fake registry record dir: <dir>/pkgs/vim/config.yaml
_make_record() {
    mkdir -p "$1/pkgs/vim"
    printf 'status: installed\n' > "$1/pkgs/vim/config.yaml"
}

# ---------------------------------------------------------------
# cloudify_registry_delete_deployment
# ---------------------------------------------------------------

@test "node-target record under the ivps node dir is removed" {
    rubric "node target: <nodes>/<node>/deployments/<id> is removed"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
}

@test "instance-target record under the ivps node dir is removed" {
    rubric "instance target: <nodes>/<node>/<instance>/deployments/<id> is removed"
    _make_record "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_X" ]
}

@test "fallback-bucket records (node and instance target) are removed" {
    rubric "plain host: <creds>/registry/hosts/<host>[/<instance>]/deployments/<id> is removed"
    _make_record "$FALLBACK_HOSTS/host1/deployments/$DEP_X"
    _make_record "$FALLBACK_HOSTS/host1/inst/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$FALLBACK_HOSTS/host1/deployments/$DEP_X" ]
    [ ! -e "$FALLBACK_HOSTS/host1/inst/deployments/$DEP_X" ]
}

@test "every candidate bucket is swept: all four layouts at once" {
    rubric "one call cleans node/instance targets on every node and host"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"
    _make_record "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_X"
    _make_record "$NODE_ROOT/cloudstation/deployments/$DEP_X"
    _make_record "$FALLBACK_HOSTS/host1/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
    [ ! -e "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_X" ]
    [ ! -e "$NODE_ROOT/cloudstation/deployments/$DEP_X" ]
    [ ! -e "$FALLBACK_HOSTS/host1/deployments/$DEP_X" ]
}

@test "another deployment's records are untouched" {
    rubric "scoping: only <id> is swept, a sibling id survives everywhere"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_Y"
    _make_record "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_Y"
    _make_record "$FALLBACK_HOSTS/host1/deployments/$DEP_Y"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
    [ -f "$NODE_ROOT/cloudai/deployments/$DEP_Y/pkgs/vim/config.yaml" ]
    [ -f "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_Y/pkgs/vim/config.yaml" ]
    [ -f "$FALLBACK_HOSTS/host1/deployments/$DEP_Y/pkgs/vim/config.yaml" ]
}

@test "a same-named dir without pkgs/ is never touched" {
    rubric "the pkgs/ guard protects an unrelated dir named like the id"
    # node-shaped and instance-shaped impostors, plus a real record elsewhere
    mkdir -p "$NODE_ROOT/cloudai/deployments/$DEP_X"
    touch "$NODE_ROOT/cloudai/deployments/$DEP_X/notes.txt"
    mkdir -p "$NODE_ROOT/cloudai/somewhere/deployments/$DEP_X"
    touch "$NODE_ROOT/cloudai/somewhere/deployments/$DEP_X/notes.txt"
    _make_record "$NODE_ROOT/other-node/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ -f "$NODE_ROOT/cloudai/deployments/$DEP_X/notes.txt" ]
    [ -f "$NODE_ROOT/cloudai/somewhere/deployments/$DEP_X/notes.txt" ]
    [ ! -e "$NODE_ROOT/other-node/deployments/$DEP_X" ]
}

@test "an absent id is a no-op with rc 0" {
    rubric "idempotent: no buckets, no records, no error"
    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
}

@test "unsafe ids are rejected before any scan" {
    rubric "path separators never reach a glob"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "../$DEP_X"
    [ "$status" -ne 0 ]
    [ -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
}

@test "no ivps process is invoked: the node dirs are globbed" {
    rubric "read-only wrt ivps: no shelling out to \`ivps node path\`"
    ivps() { echo "IVPS CALLED"; return 1; }
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [[ "$output" != *"IVPS CALLED"* ]]
    [ ! -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
    unset -f ivps
}

@test "the node-dir root honours IVPS_CONFIG_DIR, then XDG_CONFIG_HOME" {
    rubric "IVPS_CONFIG_DIR wins; XDG_CONFIG_HOME drives the default (ivps' own layout)"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"

    unset IVPS_CONFIG_DIR
    export XDG_CONFIG_HOME="$CLOUDIFY_TMP/xdg"
    _make_record "$XDG_CONFIG_HOME/ivps/nodes/n1/deployments/$DEP_X"

    run cloudify_registry_delete_deployment "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$XDG_CONFIG_HOME/ivps/nodes/n1/deployments/$DEP_X" ]
    # IVPS_CONFIG_DIR removed: the override root is out of scope now
    [ -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
}

# ---------------------------------------------------------------
# wiring: cloudify deployment delete
# ---------------------------------------------------------------

@test "cloudify deployment delete trashes the store dir and the records" {
    rubric "cloudify_deployment_delete <id> -> store dir + node/instance records gone"
    cloudify_deployment_create "$DEP_X"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"
    _make_record "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_X"

    run cloudify_deployment_delete "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -d "$CLOUDIFY_DEPLOYMENTS_DIR/$DEP_X" ]
    [ ! -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
    [ ! -e "$NODE_ROOT/cloudai/cloudify/deployments/$DEP_X" ]
}

@test "cloudify deployment delete of an absent id still cleans orphan records" {
    rubric "records outlive a hand-deleted store dir -> delete still sweeps them"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"

    run cloudify_deployment_delete "$DEP_X"
    [ "$status" -eq 0 ]
    [ ! -e "$NODE_ROOT/cloudai/deployments/$DEP_X" ]
}

@test "cloudify deployment delete leaves other deployments and the node dir alone" {
    rubric "no collateral: node.json, sibling records and the bucket survive"
    cloudify_deployment_create "$DEP_X"
    mkdir -p "$NODE_ROOT/cloudai"
    printf '{}\n' > "$NODE_ROOT/cloudai/node.json"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_X"
    _make_record "$NODE_ROOT/cloudai/deployments/$DEP_Y"

    run cloudify_deployment_delete "$DEP_X"
    [ "$status" -eq 0 ]
    [ -f "$NODE_ROOT/cloudai/node.json" ]
    [ -f "$NODE_ROOT/cloudai/deployments/$DEP_Y/pkgs/vim/config.yaml" ]
}

# ---------------------------------------------------------------
# Module
# ---------------------------------------------------------------

@test "the cleanup API is exported by lib/registry.sh" {
    rubric "cloudify_registry_delete_deployment is a function (module guard intact)"
    source lib/registry.sh
    [ "$(type -t cloudify_registry_delete_deployment)" = "function" ]
}
