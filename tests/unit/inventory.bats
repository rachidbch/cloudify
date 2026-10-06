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

_ivps_show_stub() {
    # _fake_ivps + `node show web1:app1 --json` with the instance record
    _fake_ivps
    cat > "$fake_bin/ivps" <<STUB
#!/bin/bash
[[ "\$1" = node && "\$2" = show && "\$3" = web1:app1 ]] && \
    { echo '{"id":"i9","name":"app1","engine":"incus","image":"sha256:abc123","uuid":"u-1","created_at":"2026-01-01T00:00:00Z"}'; exit 0; }
[[ "\$1" = node && "\$2" = path ]] || exit 9
case "\$3" in
    web1) echo "$node_dir" ;;
    web1:app1) echo "$inst_dir" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$fake_bin/ivps"
}

@test "host baseline: init once from ivps (discovered), idempotent, check enforces continuity" {
    _fake_ivps
    _ivps_show_stub
    local root d
    d=$(cloudify_state_inventory_root web1 app1)
    root=$(dirname "$d")

    export CLOUDIFY_BASELINE_TARGET=web1:app1
    run cloudify_state_host_baseline_init "$root" discovered
    [ "$status" -eq 0 ]
    local bp="$root/cloudify/host.json"
    [ -f "$bp" ]
    jq -e '.origin.mode == "discovered" and .origin.image == "sha256:abc123"' "$bp"
    jq -e '.continuity.host_id == "i9"' "$bp"
    local before
    before=$(jq -S . "$bp")
    run cloudify_state_host_baseline_init "$root" discovered
    [ "$status" -eq 0 ]
    [ "$(jq -S . "$bp")" = "$before" ]

    subrubric "continuity: same boot id passes, a changed one is a named refusal"
    run cloudify_state_host_baseline_check "$root" "boot-A"
    [ "$status" -eq 0 ]
    jq -e '.continuity.boot_id == "boot-A"' "$bp"
    run cloudify_state_host_baseline_check "$root" "boot-B"
    [ "$status" -eq 2 ]
    [[ "$output" == *"rewound or replaced"* ]]
}

@test "host baseline: unknown origin when ivps cannot answer; absent baseline refuses the check" {
    _fake_ivps
    local root
    root=$(dirname "$(cloudify_state_inventory_root web1 app1)")
    run cloudify_state_host_baseline_check "$root" "boot-A"
    [ "$status" -eq 1 ]
    run cloudify_state_host_baseline_init "$root" discovered
    [ "$status" -eq 0 ]
    jq -e '.origin.mode == "unknown"' "$root/cloudify/host.json"
}

@test "host lock: bounded wait, holder metadata on the file, released cleanly" {
    export CLOUDIFY_LOCK_TIMEOUT=10
    local lp="$inst_dir/cloudify/.host-mutation.lock"

    # The lock is held in THIS shell (exporter idiom: never via run subshells).
    cloudify_state_host_lock web1 app1
    [ -f "$lp" ]
    jq -e '.host | length > 0' "$lp"
    jq -e '.host_key == "web1:app1"' "$lp"
    cloudify_state_host_unlock web1 app1

    subrubric "a concurrent holder times out fast and prints the holder metadata"
    ( CLOUDIFY_LOCK_TIMEOUT=10 cloudify_state_host_lock web1 app1; sleep 4 ) &
    local holder=$!
    sleep 0.5
    export CLOUDIFY_LOCK_TIMEOUT=1
    run cloudify_state_host_lock web1 app1
    [ "$status" -ne 0 ]
    # the holder metadata the timeout would print is the lock file itself
    jq -e '.pid > 0 and .host_key == "web1:app1"' "$lp"
    export CLOUDIFY_LOCK_TIMEOUT=10
    wait "$holder" 2>/dev/null || true

    subrubric "release and re-acquire"
    cloudify_state_host_lock web1 app1
    cloudify_state_host_unlock web1 app1
}
