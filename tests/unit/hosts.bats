#!/usr/bin/env bats
# Tests for lib/hosts.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/hosts.sh
}

teardown() {
    teardown_test_env
}

# Helper: create mock inventory entries
_create_mock_inventory() {
    mkdir -p "$CLOUDIFY_DIR/inventory/testhost/@default"
    mkdir -p "$CLOUDIFY_DIR/inventory/testhost/@web"
    mkdir -p "$CLOUDIFY_DIR/inventory/anotherhost/@default"
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
# Module guard
# ---------------------------------------------------------------

@test "module guard prevents double-sourcing" {
    source lib/hosts.sh
    source lib/hosts.sh
    [ "$(type -t cloudify_is_host_in_inventory)" = "function" ]
}
