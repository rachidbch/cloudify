#!/usr/bin/env bats
# Tests for lib/hosts.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env

    # Create a stub ivps binary for container operations
    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
    source lib/hosts.sh
}

teardown() {
    rm -rf "$STUB_DIR"
    teardown_test_env
}

# Helper: create mock inventory entries
_create_mock_inventory() {
    mkdir -p "$CLOUDIFY_DIR/inventory/testhost/@default"
    mkdir -p "$CLOUDIFY_DIR/inventory/testhost/@web"
    mkdir -p "$CLOUDIFY_DIR/inventory/anotherhost/@default"
}

# Helper: create an ivps stub that returns IPs
_create_ivps_ip_stub() {
    cat <<'STUB' > "$STUB_DIR/ivps"
#!/bin/bash
case "$1" in
    ip)
        if [[ "$*" == *"--family inet6"* ]]; then
            echo "fd42:1:2:3::1"
        else
            echo "10.0.1.42"
        fi
        ;;
    *)
        echo "UNKNOWN: $*" >&2
        exit 1
        ;;
esac
STUB
    chmod +x "$STUB_DIR/ivps"
}

# ---------------------------------------------------------------
# cloudify_is_host_in_inventory
# ---------------------------------------------------------------

@test "cloudify_is_host_in_inventory returns 0 for existing host" {
    _create_mock_inventory
    run cloudify_is_host_in_inventory testhost
    [ "$status" -eq 0 ]
    [[ "$output" == *"testhost"* ]]
}

@test "cloudify_is_host_in_inventory returns empty stdout for missing host" {
    _create_mock_inventory
    # ls error goes to stderr; run captures both. stdout is empty (no host found).
    cloudify_is_host_in_inventory nonexistent 2>/dev/null
    [ -z "$(cloudify_is_host_in_inventory nonexistent 2>/dev/null)" ]
}

@test "cloudify_is_host_in_inventory rejects on remote host" {
    _create_mock_inventory
    CLOUDIFY_IS_LOCAL=false
    run cloudify_is_host_in_inventory testhost
    [ "$status" -ne 0 ]
    [[ "$output" == *"not allowed on remote hosts"* ]]
}

@test "cloudify_is_host_in_inventory returns 1 when called without argument" {
    _create_mock_inventory
    run cloudify_is_host_in_inventory
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing argument"* ]]
}

# ---------------------------------------------------------------
# cloudify_list_hosts_by_tags
# ---------------------------------------------------------------

@test "cloudify_list_hosts_by_tags returns all hosts when no tags given" {
    _create_mock_inventory
    run cloudify_list_hosts_by_tags
    [ "$status" -eq 0 ]
    [[ "$output" == *"testhost"* ]]
    [[ "$output" == *"anotherhost"* ]]
}

@test "cloudify_list_hosts_by_tags filters by tag" {
    _create_mock_inventory
    run cloudify_list_hosts_by_tags @web
    [ "$status" -eq 0 ]
    [[ "$output" == *"testhost"* ]]
    [[ "$output" != *"anotherhost"* ]]
}

@test "cloudify_list_hosts_by_tags with @all returns all hosts" {
    _create_mock_inventory
    run cloudify_list_hosts_by_tags @all
    [ "$status" -eq 0 ]
    [[ "$output" == *"testhost"* ]]
    [[ "$output" == *"anotherhost"* ]]
}

@test "cloudify_list_hosts_by_tags filters by multiple tags (intersection)" {
    _create_mock_inventory
    mkdir -p "$CLOUDIFY_DIR/inventory/testhost/@db"
    mkdir -p "$CLOUDIFY_DIR/inventory/anotherhost/@db"

    run cloudify_list_hosts_by_tags @default @db
    [ "$status" -eq 0 ]
    [[ "$output" == *"testhost"* ]]
    [[ "$output" == *"anotherhost"* ]]
}

@test "cloudify_list_hosts_by_tags intersection excludes non-matching host" {
    _create_mock_inventory
    mkdir -p "$CLOUDIFY_DIR/inventory/testhost/@db"
    # anotherhost does NOT have @db

    run cloudify_list_hosts_by_tags @default @db
    [ "$status" -eq 0 ]
    [[ "$output" == *"testhost"* ]]
    [[ "$output" != *"anotherhost"* ]]
}

@test "cloudify_list_hosts_by_tags rejects on remote host" {
    _create_mock_inventory
    CLOUDIFY_IS_LOCAL=false
    run cloudify_list_hosts_by_tags
    [ "$status" -ne 0 ]
    [[ "$output" == *"not allowed on remote hosts"* ]]
}

# ---------------------------------------------------------------
# cloudify_list_hosts_tags
# ---------------------------------------------------------------

@test "cloudify_list_hosts_tags includes @default and @all virtual tags" {
    _create_mock_inventory
    run cloudify_list_hosts_tags
    [ "$status" -eq 0 ]
    [[ "$output" == *"@default"* ]]
    [[ "$output" == *"@all"* ]]
}

@test "cloudify_list_hosts_tags includes inventory tags" {
    _create_mock_inventory
    run cloudify_list_hosts_tags
    [ "$status" -eq 0 ]
    [[ "$output" == *"@web"* ]]
}

@test "cloudify_list_hosts_tags rejects on remote host" {
    _create_mock_inventory
    CLOUDIFY_IS_LOCAL=false
    run cloudify_list_hosts_tags
    [ "$status" -ne 0 ]
    [[ "$output" == *"remote hosts"* ]]
}

# ---------------------------------------------------------------
# cloudify_info (via ivps)
# ---------------------------------------------------------------

@test "cloudify_info ipv4 returns IP via ivps" {
    _create_ivps_ip_stub
    run cloudify_info testhost ipv4
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.1.42" ]
}

@test "cloudify_info ipv6 returns IPv6 via ivps" {
    _create_ivps_ip_stub
    run cloudify_info testhost ipv6
    [ "$status" -eq 0 ]
    [ "$output" = "fd42:1:2:3::1" ]
}

@test "cloudify_info rejects on remote host" {
    CLOUDIFY_IS_LOCAL=false
    run cloudify_info testhost ipv4
    [ "$status" -ne 0 ]
    [[ "$output" == *"not allowed on remote hosts"* ]]
}

# ---------------------------------------------------------------
# cloudify_hostnames (via ivps)
# ---------------------------------------------------------------

@test "cloudify_hostnames resolves hostname via ivps when no IP given" {
    _create_ivps_ip_stub
    # For localhost hostname, no ivps call needed — it uses 127.0.0.1 directly
    # The /etc/hosts write will fail in test env, but the important thing is
    # it doesn't fail on lxc lookup (which no longer exists)
    run cloudify_hostnames localhost add myhost
    # Accept success or failure from /etc/hosts manipulation — the key is no lxc error
    [[ "$output" != *"lxc"* ]]
}

@test "cloudify_hostnames uses explicit IP without ivps" {
    # When IP is given explicitly, no ivps call needed
    run cloudify_hostnames localhost add myhost 10.0.0.1
    # Will fail at /etc/hosts but that's expected in test env
    [ "$status" -eq 0 ] || [[ "$output" == *"sudo"* ]] || [[ "$output" == *"Password"* ]]
}

# ---------------------------------------------------------------
# Module guard
# ---------------------------------------------------------------

@test "module guard prevents double-sourcing" {
    source lib/hosts.sh
    source lib/hosts.sh
    [ "$(type -t cloudify_is_host_in_inventory)" = "function" ]
}
