#!/usr/bin/env bats
# Tests for lib/utils.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    # Need colors for die() and msg()
    source lib/colors.sh
    cloudify_setup_colors
    source lib/utils.sh
}

teardown() {
    teardown_test_env
}

@test "msg outputs to stderr" {
    run msg "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "msg -n suppresses newline" {
    run msg -n "hello"
    [ "$status" -eq 0 ]
    # Output goes to stderr which bats captures in output
    [ "$output" = "hello" ]
}

@test "msg_ln adds empty line before message" {
    run msg_ln "hello"
    [ "$status" -eq 0 ]
}

@test "die exits with default code 1" {
    run die "something failed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"something failed"* ]]
}

@test "die exits with custom code" {
    run die "custom error" 42
    [ "$status" -eq 42 ]
}

@test "cloudify_emptydir returns 0 for empty dir" {
    local emptydir="$CLOUDIFY_TMP/empty"
    mkdir -p "$emptydir"
    cloudify_emptydir "$emptydir"
    [ "$?" -eq 0 ]
}

@test "cloudify_emptydir returns 1 for non-empty dir" {
    local dir="$CLOUDIFY_TMP/notempty"
    mkdir -p "$dir"
    touch "$dir/file"
    run cloudify_emptydir "$dir"
    [ "$status" -eq 1 ]
}

@test "cloudify_list_contains finds item in list" {
    run cloudify_list_contains "one two three" "two"
    [ "$status" -eq 0 ]
}

@test "cloudify_list_contains returns 1 for missing item" {
    run cloudify_list_contains "one two three" "four"
    [ "$status" -eq 1 ]
}

@test "cloudify_parse_git_url parses https url" {
    run cloudify_parse_git_url "https://github.com/user/repo.git" "host"
    [ "$status" -eq 0 ]
    [ "$output" = "github.com" ]
}

@test "cloudify_parse_git_url parses ssh url" {
    run cloudify_parse_git_url "git@github.com:user/repo.git" "host"
    [ "$status" -eq 0 ]
    [ "$output" = "github.com" ]
}

@test "cloudify_parse_git_url extracts domain" {
    run cloudify_parse_git_url "https://github.com/user/repo.git" "domain"
    [ "$status" -eq 0 ]
    [ "$output" = "github.com" ]
}

@test "cloudify_parse_git_url extracts account" {
    run cloudify_parse_git_url "https://github.com/user/repo.git" "account"
    [ "$status" -eq 0 ]
    [ "$output" = "user" ]
}

@test "cloudify_parse_git_url extracts project" {
    run cloudify_parse_git_url "https://github.com/user/repo.git" "project"
    [ "$status" -eq 0 ]
    [ "$output" = "repo.git" ]
}

@test "cloudify_parse_git_url returns 1 on empty input" {
    run cloudify_parse_git_url ""
    [ "$status" -eq 1 ]
}

@test "cloudify_is_git_url recognizes valid url" {
    cloudify_is_git_url "https://github.com/user/repo.git"
    [ "$?" -eq 0 ]
}

@test "cloudify_is_git_url rejects invalid input" {
    run cloudify_is_git_url "not-a-url-at-all"
    [ "$status" -ne 0 ]
}

@test "cloudify_get_password sets password variable" {
    cloudify_get_password mypwd
    [ "$mypwd" = "testpwd" ]
}

@test "cloudify_get_password sets user and host variables" {
    cloudify_get_password mypwd myuser myhost
    [ "$mypwd" = "testpwd" ]
    [ -n "$myuser" ]
    [ -n "$myhost" ]
}

@test "cloudify_print_done runs without error" {
    run cloudify_print_done
    [ "$status" -eq 0 ]
}

@test "module guard prevents double-sourcing" {
    source lib/utils.sh
    source lib/utils.sh
    [ "$(type -t msg)" = "function" ]
}
