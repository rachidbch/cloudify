#!/usr/bin/env bats
# Tests for lib/containers.sh — thin ivps abstraction

setup() {
    source tests/helpers/common.bash
    setup_test_env

    # Create a stub ivps binary in a temp PATH dir
    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
}

teardown() {
    rm -rf "$STUB_DIR"
    teardown_test_env
}

# Helper: create an ivps stub that records calls
_create_ivps_stub() {
    cat <<'STUB' > "$STUB_DIR/ivps"
#!/bin/bash
echo "IVPS_CALL: $*" >> "$STUB_DIR/ivps_calls.log"
case "$1" in
    ip)
        if [[ "$*" == *"--family inet6"* ]]; then
            echo "fd42:1:2:3::1"
        else
            echo "10.0.1.42"
        fi
        ;;
    launch)
        echo "LAUNCHED"
        ;;
    delete)
        echo "DELETED"
        ;;
    *)
        echo "UNKNOWN: $*" >&2
        exit 1
        ;;
esac
STUB
    chmod +x "$STUB_DIR/ivps"
    : > "$STUB_DIR/ivps_calls.log"
}

# Helper: make ivps unavailable
_remove_ivps_stub() {
    rm -f "$STUB_DIR/ivps"
}

# ---------------------------------------------------------------
# cloudify_require_ivps
# ---------------------------------------------------------------

@test "cloudify_require_ivps succeeds when ivps is in PATH" {
    _create_ivps_stub
    run cloudify_require_ivps
    [ "$status" -eq 0 ]
}

@test "cloudify_require_ivps fails when ivps is not in PATH" {
    _remove_ivps_stub
    run cloudify_require_ivps
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# cloudify_container_ip
# ---------------------------------------------------------------

@test "cloudify_container_ip delegates to ivps ip" {
    _create_ivps_stub
    run cloudify_container_ip "myhost"
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.1.42" ]
    grep -q "ip myhost" "$STUB_DIR/ivps_calls.log"
}

@test "cloudify_container_ip returns bare IP" {
    _create_ivps_stub
    result=$(cloudify_container_ip "testhost")
    [ "$result" = "10.0.1.42" ]
}

# ---------------------------------------------------------------
# cloudify_container_ipv6
# ---------------------------------------------------------------

@test "cloudify_container_ipv6 delegates to ivps ip --family inet6" {
    _create_ivps_stub
    run cloudify_container_ipv6 "myhost"
    [ "$status" -eq 0 ]
    [ "$output" = "fd42:1:2:3::1" ]
    grep -q "ip myhost --family inet6" "$STUB_DIR/ivps_calls.log"
}

# ---------------------------------------------------------------
# cloudify_container_launch
# ---------------------------------------------------------------

@test "cloudify_container_launch delegates to ivps launch" {
    _create_ivps_stub
    run cloudify_container_launch "myhost"
    [ "$status" -eq 0 ]
    grep -q "launch myhost" "$STUB_DIR/ivps_calls.log"
}

@test "cloudify_container_launch passes image and extra args" {
    _create_ivps_stub
    run cloudify_container_launch "myhost" "ubuntu/22.04" "--profile" "custom"
    [ "$status" -eq 0 ]
    grep -q "launch myhost ubuntu/22.04 --profile custom" "$STUB_DIR/ivps_calls.log"
}

# ---------------------------------------------------------------
# cloudify_container_delete
# ---------------------------------------------------------------

@test "cloudify_container_delete delegates to ivps delete" {
    _create_ivps_stub
    run cloudify_container_delete "myhost"
    [ "$status" -eq 0 ]
    grep -q "delete myhost" "$STUB_DIR/ivps_calls.log"
}

@test "cloudify_container_delete passes extra args" {
    _create_ivps_stub
    run cloudify_container_delete "myhost" "--caddy"
    [ "$status" -eq 0 ]
    grep -q "delete myhost --caddy" "$STUB_DIR/ivps_calls.log"
}

# ---------------------------------------------------------------
# Module guard
# ---------------------------------------------------------------

@test "module guard prevents double-sourcing" {
    source lib/containers.sh
    source lib/containers.sh
    [ "$(type -t cloudify_require_ivps)" = "function" ]
}

# ---------------------------------------------------------------
# No direct lxc/incus/LXDSERVER/cloudhorse references
# ---------------------------------------------------------------

@test "lib/containers.sh does not reference lxc or incus directly" {
    run grep -E 'lxc\b|incus\b' lib/containers.sh
    [ "$status" -ne 0 ]
}

@test "cloudify router has no LXDSERVER or cloudhorse references" {
    run bash -c "grep -E 'LXDSERVER|cloudhorse|CLOUDIFY_LXDSERVER' cloudify"
    [ "$status" -ne 0 ]
}

@test "lib/hosts.sh has no direct lxc calls" {
    run bash -c "grep -E 'lxc\b' lib/hosts.sh | grep -v '^#'"
    [ "$status" -ne 0 ]
}

@test "lib/ has no LXDSERVER or cloudhorse references" {
    run bash -c "grep -rn 'LXDSERVER\|cloudhorse\|CLOUDIFY_LXDSERVER' lib/ --include='*.sh' | grep -v '^#' || true"
    [ -z "$output" ]
}
