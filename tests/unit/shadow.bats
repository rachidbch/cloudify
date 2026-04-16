#!/usr/bin/env bats
# Tests for lib/shadow.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/shadow.sh
}

teardown() {
    teardown_test_env
}

@test "all shadow functions are defined after sourcing" {
    [ "$(type -t sudo)" = "function" ]
    [ "$(type -t cloudify_git_authenticate)" = "function" ]
    [ "$(type -t cloudify_git_deauthenticate)" = "function" ]
    [ "$(type -t cloudify_git_same_remote)" = "function" ]
    [ "$(type -t git)" = "function" ]
}

@test "cloudify_git_same_remote matches identical URLs" {
    cloudify_git_same_remote "https://github.com/user/repo" "https://github.com/user/repo"
    [ "$?" -eq 0 ]
}

@test "cloudify_git_same_remote matches ssh vs https for same repo" {
    cloudify_git_same_remote "git@github.com:user/repo.git" "https://github.com/user/repo.git"
    [ "$?" -eq 0 ]
}

@test "cloudify_git_same_remote rejects different repos" {
    run cloudify_git_same_remote "https://github.com/user/repo" "https://github.com/other/different-repo"
    [ "$status" -ne 0 ]
}

@test "module guard prevents double-sourcing" {
    source lib/shadow.sh
    source lib/shadow.sh
    [ "$(type -t sudo)" = "function" ]
    [ "$(type -t git)" = "function" ]
}
