#!/usr/bin/env bats
# Tests for the git shadow clone-arg parsing (lib/shadows/git.sh).
# Regression for the quoted-literal "-*" bug: git clone OPTIONS were fed to
# cloudify_is_git_url and rejected, aborting every optioned clone (fzf,
# bash-it, dotfiles, affine).

setup() {
    source tests/helpers/common.bash
    setup_test_env
    export DEBUG=true
    export CLOUDIFY_LOG_LEVEL=DEBUG  # PKG_DEBUG messages distinguish the parse path
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/shadow.sh
}

teardown() {
    teardown_test_env
}

# Discriminator: a target path whose parent dir does NOT exist.
# - bug: the option hits first -> "Not a valid git url", return 1
# - fixed: URL parsed, then "path ... doesn't exist" branch fires, return 1
@test "git clone with --depth=1 parses URL, does not reject the option" {
    run git clone --depth=1 https://github.com/user/repo.git /nonexistent-dir-xyz/repo
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "path /nonexistent-dir-xyz doesn't exist"
    echo "$output" | grep -qv "Not a valid git url"
}

@test "git clone with space-separated option (--depth 1) parses URL" {
    run git clone --depth 1 https://github.com/user/repo.git /nonexistent-dir-xyz/repo
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "path /nonexistent-dir-xyz doesn't exist"
    echo "$output" | grep -qv "Not a valid git url"
}

@test "git clone with --recurse-submodules parses URL" {
    run git clone --recurse-submodules https://github.com/user/repo.git /nonexistent-dir-xyz/repo
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "path /nonexistent-dir-xyz doesn't exist"
    echo "$output" | grep -qv "Not a valid git url"
}

@test "non-optioned git clone still parses URL (regression)" {
    run git clone https://github.com/user/repo.git /nonexistent-dir-xyz/repo
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "path /nonexistent-dir-xyz doesn't exist"
    echo "$output" | grep -qv "Not a valid git url"
}

@test "git clone with URL first, then path + trailing option" {
    run git clone https://github.com/user/repo.git /nonexistent-dir-xyz/repo -b main
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "path /nonexistent-dir-xyz doesn't exist"
    echo "$output" | grep -qv "Not a valid git url"
}
