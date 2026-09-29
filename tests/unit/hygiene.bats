#!/usr/bin/env bats
# State-tree hygiene (plan: adoption-honesty item 8): `deployment delete`
# (reliance-checked) and `deployment sweep` (_direct by age, orphaned
# instance records keyed to ivps liveness - an offline instance is not
# deleted; liveness is ivps's word).

source tests/helpers/common.bash

setup() {
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    export IVPS_CONFIG_DIR="$CLOUDIFY_TMP/ivps"
    export CLOUDIFY_DEVELOPMENT_OVERRIDE=1

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    source lib/runbooks.sh

    # The ivps inventory: one node (cloudai) with a live and a dead instance.
    export NODE_DIR="$IVPS_CONFIG_DIR/nodes/n1"
    mkdir -p "$NODE_DIR" "$IVPS_CONFIG_DIR"
    printf '%s\n' 'IVPS_DEFAULT_NODE=cloudai' > "$IVPS_CONFIG_DIR/config.env"
    _mk_instance() { # _mk_instance <id> <name>
        mkdir -p "$NODE_DIR/instances/$1"
        printf '{"id":"%s","name":"%s","engine":"incus"}' "$1" "$2" \
            > "$NODE_DIR/instances/$1/instance.json"
    }
    _mk_instance live1 alpha
    _mk_instance dead1 gone-twin

    _mk_node() {
        printf '{"id":"n1","name":"cloudai"}' > "$NODE_DIR/node.json"
    }
    _mk_node

    # The ivps stub: `list` reports the live instance only; `node path` maps.
    ivps() {
        case "${1:-} ${2:-}" in
            "node path")
                case "$3" in
                    cloudai|cloudai:alpha) echo "$NODE_DIR" ;;
                    *) return 1 ;;
                esac
                ;;
            "list ")
                printf '  cloudai:alpha Running\n'
                ;;
            *) return 1 ;;
        esac
    }

    _bindings() {
        printf 'server\tcloudai:alpha\tcloudai\talpha\talpha\n' > "$CLOUDIFY_TMP/b.tsv"
        printf '%s\n' "$CLOUDIFY_TMP/b.tsv"
    }

    _record() { # _record <host-dir> <app> <flavor> <name> <pkg>
        local d
        d="$NODE_DIR/instances/$1/deployments/$2/$3/$4/packages/$5/default"
        mkdir -p "$d"
        : > "$d/state.json"
    }
}

teardown() {
    teardown_test_env
}

@test "deployment delete: sweeps the manifest and records, keeps events and inputs" {
    rubric "reliance-checked delete - the audit and the operator's inputs survive"
    local b="$CLOUDIFY_TMP/b.tsv"
    printf 'server\tcloudai:alpha\tcloudai\talpha\talpha\n' > "$b"
    cloudify_manifest_write myapp default main installed \
        0123456789abcdef0123456789abcdef01234567 false "$b"
    _record live1 myapp default main web

    run cloudify_deployment_delete myapp default main
    [ "$status" -eq 0 ]
    [ ! -f "$(cloudify_state_manifest_file myapp default main)" ]
    [ ! -d "$NODE_DIR/instances/live1/deployments/myapp" ]
    # Desired inputs stay (operator data).
    [ -d "$CLOUDIFY_DEPLOYMENTS_DIR/myapp/default/main" ] || true
}

@test "deployment delete: another deployment's record on the same installation refuses" {
    rubric "a shared physical installation is a reliance - named refusal"
    local b="$CLOUDIFY_TMP/b.tsv"
    printf 'server\tcloudai:alpha\tcloudai\talpha\talpha\n' > "$b"
    cloudify_manifest_write myapp default main installed \
        0123456789abcdef0123456789abcdef01234567 false "$b"
    cloudify_manifest_write other default main installed \
        0123456789abcdef0123456789abcdef01234567 false "$b"
    _record live1 myapp default main web
    _record live1 other default main web

    run cloudify_deployment_delete myapp default main
    [ "$status" -ne 0 ]
    [[ "$output" == *"reliance"* ]]
    [ -f "$(cloudify_state_manifest_file myapp default main)" ]
    [ -d "$NODE_DIR/instances/live1/deployments/myapp" ]
}

@test "deployment sweep: an instance absent from the live list is swept, a live one kept" {
    rubric "liveness is ivps's word - deleted means absent from the list"
    _record dead1 myapp default twin affine
    _record live1 myapp default main web

    run cloudify_deployment_sweep
    [ "$status" -eq 0 ]
    [ ! -d "$NODE_DIR/instances/dead1/deployments/myapp" ]
    [ -d "$NODE_DIR/instances/live1/deployments/myapp" ]
}

@test "deployment sweep: a timed-out inventory refuses (an offline instance is not deleted)" {
    rubric "an incomplete list never sweeps"
    _record dead1 myapp default twin affine
    ivps() {
        case "${1:-}" in
            list) printf '  cloudai TIMEOUT\n' ;;
            *) return 1 ;;
        esac
    }

    run cloudify_deployment_sweep
    [ "$status" -ne 0 ]
    [[ "$output" == *"timed-out"* ]]
    [ -d "$NODE_DIR/instances/dead1/deployments/myapp" ]
}

@test "deployment sweep: _direct manifests and records past the retention are swept" {
    rubric "bare-dispatch accumulations age out; fresh ones stay"
    local b="$CLOUDIFY_TMP/b.tsv"
    printf 'direct\tcloudai:alpha\tcloudai\talpha\talpha\n' > "$b"
    cloudify_manifest_write _direct direct old-one "" "" true "$b"
    cloudify_manifest_write _direct direct fresh-one "" "" true "$b"
    touch -d '40 days ago' "$(cloudify_state_manifest_file _direct direct old-one)"
    _record live1 _direct direct old-one web
    _record live1 _direct direct fresh-one web

    run cloudify_deployment_sweep
    [ "$status" -eq 0 ]
    [ ! -f "$(cloudify_state_manifest_file _direct direct old-one)" ]
    [ -f "$(cloudify_state_manifest_file _direct direct fresh-one)" ]
    [ ! -d "$NODE_DIR/instances/live1/deployments/_direct/direct/old-one" ]
    [ -d "$NODE_DIR/instances/live1/deployments/_direct/direct/fresh-one" ]
}
