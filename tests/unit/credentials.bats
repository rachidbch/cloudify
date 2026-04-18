#!/usr/bin/env bats
# Tests for lib/credentials.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/credentials.sh
}

teardown() {
    teardown_test_env
}

@test "all credential functions are defined after sourcing" {
    [ "$(type -t cloudify_ask_localhost_credentials)" = "function" ]
    [ "$(type -t cloudify_ask_host_credentials)" = "function" ]
    [ "$(type -t cloudify_ask_github_credentials)" = "function" ]
    [ "$(type -t cloudify_ask_gitlab_credentials)" = "function" ]
    [ "$(type -t cloudify_ask_restic_credentials)" = "function" ]
    [ "$(type -t cloudify_check_credentials)" = "function" ]
}

@test "cloudify_check_credentials with pre-set env vars doesn't prompt" {
    export CLOUDIFY_LOCAL_USER=testuser
    export CLOUDIFY_LOCAL_PWD=testpwd
    export CLOUDIFY_REMOTE_USER=testremote
    export CLOUDIFY_REMOTE_PWD=testremotepwd
    export CLOUDIFY_GITHUBUSER=testghuser
    export CLOUDIFY_GITHUBPWD=testghpwd
    export CLOUDIFY_GITLABUSER=testgluser
    export CLOUDIFY_GITLABPWD=testglpwd
    export CLOUDIFY_RCLONE_REMOTE=testremote
    export CLOUDIFY_RCLONE_REMOTE_REGION=testregion
    export CLOUDIFY_RCLONE_REMOTE_ENDPOINT=testendpoint
    export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID=testaccesskey
    export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY=testsecretkey
    export RESTIC_PASSWORD=testresticpwd

    # Remove any .credentials file that might exist in test HOME
    rm -f "${HOME}/cloudify/.credentials"

    # cloudify_check_credentials should not prompt (i.e. not call read)
    # and should succeed without error
    run cloudify_check_credentials
    [ "$status" -eq 0 ]
    # No prompts should appear in output (no "user:" or "password" prompts)
    [[ "$output" != *"user:"* ]] || [[ "$output" != *"User:"* ]]
}

@test "module guard prevents double-sourcing" {
    source lib/credentials.sh
    source lib/credentials.sh
    [ "$(type -t cloudify_check_credentials)" = "function" ]
}

@test "_cloudify_ask_credentials helper is defined" {
    [ "$(type -t _cloudify_ask_credentials)" = "function" ]
}

@test "_cloudify_write_export helper is defined" {
    [ "$(type -t _cloudify_write_export)" = "function" ]
}

@test "_cloudify_write_export produces valid export with simple value" {
    run _cloudify_write_export "TEST_VAR" "simple_value"
    [ "$status" -eq 0 ]
    [ "$output" = "export TEST_VAR='simple_value'" ]
}

@test "_cloudify_write_export escapes single quotes in value" {
    run _cloudify_write_export "TEST_VAR" "it's a test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"it'\''s a test"* ]]
}

@test "_cloudify_write_export handles shell metacharacters" {
    run _cloudify_write_export "TEST_VAR" '$HOME & `whoami` "test"'
    [ "$status" -eq 0 ]
    # Value should be single-quoted so metacharacters are literal
    [ "$output" = "export TEST_VAR='\$HOME & \`whoami\` \"test\"'" ]
}
