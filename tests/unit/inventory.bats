#!/usr/bin/env bats
# Tests for the inventory path helpers (4.2.1): the tree lives on the node,
# under the id-keyed directory ivps hands back; the host lock sits beside it.

source tests/helpers/common.bash

fake_bin=""
node_dir=""
inst_dir=""

# A stub ivps that answers `node path` for the two shapes the tests use.
_fake_ivps() {
    node_dir="$CLOUDIFY_TMP/nodes/n1"
    inst_dir="$node_dir/instances/i9"
    fake_bin="$CLOUDIFY_TMP/bin"
    mkdir -p "$fake_bin" "$node_dir" "$inst_dir"
    cat > "$fake_bin/ivps" <<STUB
#!/bin/bash
[[ "\$1" = node && "\$2" = path ]] || exit 9
case "\$3" in
    web1) echo "$node_dir" ;;
    web1:app1) echo "$inst_dir" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$fake_bin/ivps"
    export PATH="$fake_bin:$PATH"
}

setup() {
    setup_test_env
    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh
    _fake_ivps
}

teardown() {
    teardown_test_env
}

@test "inventory paths follow ivps node path; the lock sits beside deployments" {
    [ "$(cloudify_state_inventory_root web1)" = "$node_dir/deployments" ]
    [ "$(cloudify_state_inventory_root web1 app1)" = "$inst_dir/deployments" ]
    [ "$(cloudify_state_record_dir web1 app1 k3s default main guacamole default)" \
        = "$inst_dir/deployments/k3s/default/main/packages/guacamole/default" ]
    [ "$(cloudify_state_host_lock_path web1)" = "$node_dir/cloudify/.host-mutation.lock" ]
    [ "$(cloudify_state_host_lock_path web1 app1)" = "$inst_dir/cloudify/.host-mutation.lock" ]
}

@test "inventory paths refuse bad components with named errors" {
    run cloudify_state_record_dir web1 app1 ../evil default main guacamole default
    [ "$status" -ne 0 ]
    run cloudify_state_record_dir web1 app1 k3s default main GUAC default
    [ "$status" -ne 0 ]
    run cloudify_state_record_dir web1 app1 k3s default main guacamole "has space"
    [ "$status" -ne 0 ]
}

@test "inventory paths fail with a named error on an unresolvable host" {
    run cloudify_state_inventory_root ghost
    [ "$status" -ne 0 ]
    [[ "$output" == *"ivps inventory cannot resolve"* ]]
}
