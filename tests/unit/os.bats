#!/usr/bin/env bats
# Tests for lib/os.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/os.sh
}

teardown() {
    teardown_test_env
}

@test "cloudify_osdetect is defined after sourcing os.sh" {
    [ "$(type -t cloudify_osdetect)" = "function" ]
}

@test "cloudify_osdetect --os returns non-empty value" {
    result=$(cloudify_osdetect --os)
    [ -n "$result" ]
}

@test "cloudify_osdetect --distro returns non-empty value" {
    result=$(cloudify_osdetect --distro)
    [ -n "$result" ]
}

@test "cloudify_osdetect --version returns something" {
    result=$(cloudify_osdetect --version)
    # version may be empty on some systems, so we just verify it runs
    cloudify_osdetect --version
}

@test "cloudify_osdetect --arch returns non-empty value" {
    result=$(cloudify_osdetect --arch)
    [ -n "$result" ]
    # Should look like an architecture string (e.g. x86_64, aarch64)
    [[ "$result" =~ ^[a-z0-9_]+$ ]]
}

@test "cloudify_osdetect with no args returns a multi-word string" {
    result=$(cloudify_osdetect)
    [ -n "$result" ]
    # Default output should contain at least two words (os + distro)
    local word_count=$(echo "$result" | wc -w)
    [ "$word_count" -ge 2 ]
}

@test "module guard prevents double-sourcing" {
    source lib/os.sh
    source lib/os.sh
    [ "$(type -t cloudify_osdetect)" = "function" ]
}

@test "cloudify_ver_cmp is defined after sourcing os.sh" {
    [ "$(type -t cloudify_ver_cmp)" = "function" ]
}

@test "cloudify_ver_cmp >= returns true for greater version" {
    cloudify_ver_cmp "24.04" ">=" "18.04"
}

@test "cloudify_ver_cmp >= returns true for equal versions" {
    cloudify_ver_cmp "24.04" ">=" "24.04"
}

@test "cloudify_ver_cmp >= returns false for lesser version" {
    run cloudify_ver_cmp "18.04" ">=" "24.04"
    [ "$status" -eq 1 ]
}

@test "cloudify_ver_cmp < returns true for lesser version" {
    cloudify_ver_cmp "18.04" "<" "24.04"
}

@test "cloudify_ver_cmp == returns true for equal versions" {
    cloudify_ver_cmp "24.04" "==" "24.04"
}

@test "cloudify_ver_cmp != returns true for different versions" {
    cloudify_ver_cmp "18.04" "!=" "24.04"
}
