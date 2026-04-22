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
    [ "$(type -t cloudify_ask_host_credentials)" = "function" ]
    [ "$(type -t cloudify_ask_github_credentials)" = "function" ]
    [ "$(type -t cloudify_ask_gitlab_credentials)" = "function" ]
    [ "$(type -t cloudify_credentials_ensure_dir)" = "function" ]
    [ "$(type -t cloudify_credentials_save)" = "function" ]
    [ "$(type -t cloudify_credentials_load)" = "function" ]
    [ "$(type -t cloudify_credentials_check)" = "function" ]
    [ "$(type -t cloudify_credentials_setup)" = "function" ]
}

@test "module guard prevents double-sourcing" {
    source lib/credentials.sh
    source lib/credentials.sh
    [ "$(type -t cloudify_credentials_save)" = "function" ]
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

#== NEW CREDENTIAL MANAGEMENT TESTS ==

@test "cloudify_credentials_ensure_dir creates directory" {
    local test_dir="$CLOUDIFY_TMP/test_config"
    CLOUDIFY_CREDENTIALS_DIR="$test_dir"
    cloudify_credentials_ensure_dir
    [ -d "$test_dir" ]
}

@test "cloudify_credentials_ensure_dir sets chmod 700" {
    local test_dir="$CLOUDIFY_TMP/test_config2"
    CLOUDIFY_CREDENTIALS_DIR="$test_dir"
    cloudify_credentials_ensure_dir
    local perms
    perms=$(stat -c '%a' "$test_dir")
    [ "$perms" = "700" ]
}

@test "cloudify_credentials_save creates credentials file" {
    export CLOUDIFY_REMOTE_USER=testuser
    export CLOUDIFY_REMOTE_PWD=testpwd
    cloudify_credentials_save remote
    [ -f "$CLOUDIFY_CREDENTIALS_FILE" ]
}

@test "cloudify_credentials_save writes correct format" {
    export CLOUDIFY_REMOTE_USER=testuser
    export CLOUDIFY_REMOTE_PWD=testpwd
    cloudify_credentials_save remote
    grep -q "^export CLOUDIFY_REMOTE_USER='testuser'" "$CLOUDIFY_CREDENTIALS_FILE"
    grep -q "^export CLOUDIFY_REMOTE_PWD='testpwd'" "$CLOUDIFY_CREDENTIALS_FILE"
}

@test "cloudify_credentials_save sets chmod 600" {
    export CLOUDIFY_REMOTE_USER=testuser
    export CLOUDIFY_REMOTE_PWD=testpwd
    cloudify_credentials_save remote
    local perms
    perms=$(stat -c '%a' "$CLOUDIFY_CREDENTIALS_FILE")
    [ "$perms" = "600" ]
}

@test "cloudify_credentials_load reads saved credentials" {
    export CLOUDIFY_REMOTE_USER=loaduser
    export CLOUDIFY_REMOTE_PWD=loadpwd
    cloudify_credentials_save remote

    # Unset the vars
    unset CLOUDIFY_REMOTE_USER
    unset CLOUDIFY_REMOTE_PWD

    cloudify_credentials_load
    [ "$CLOUDIFY_REMOTE_USER" = "loaduser" ]
    [ "$CLOUDIFY_REMOTE_PWD" = "loadpwd" ]
}

@test "cloudify_credentials_load does not overwrite existing env vars" {
    export CLOUDIFY_REMOTE_USER=original
    export CLOUDIFY_REMOTE_PWD=saved_pwd
    cloudify_credentials_save remote

    export CLOUDIFY_REMOTE_USER=overridden
    cloudify_credentials_load
    [ "$CLOUDIFY_REMOTE_USER" = "overridden" ]
}

@test "cloudify_credentials_load returns 0 when file missing" {
    CLOUDIFY_CREDENTIALS_FILE="$CLOUDIFY_TMP/nonexistent"
    cloudify_credentials_load
}

@test "cloudify_credentials_save updates existing values" {
    export CLOUDIFY_REMOTE_USER=user1
    export CLOUDIFY_REMOTE_PWD=pwd1
    cloudify_credentials_save remote

    export CLOUDIFY_REMOTE_USER=user2
    export CLOUDIFY_REMOTE_PWD=pwd2
    cloudify_credentials_save remote

    # Should have only one line per var
    local user_count
    user_count=$(grep -c "^export CLOUDIFY_REMOTE_USER=" "$CLOUDIFY_CREDENTIALS_FILE")
    [ "$user_count" -eq 1 ]
    grep -q "^export CLOUDIFY_REMOTE_USER='user2'" "$CLOUDIFY_CREDENTIALS_FILE"
    grep -q "^export CLOUDIFY_REMOTE_PWD='pwd2'" "$CLOUDIFY_CREDENTIALS_FILE"
}

@test "cloudify_credentials_check reports OK when all set" {
    export CLOUDIFY_REMOTE_USER=u
    export CLOUDIFY_REMOTE_PWD=p
    export CLOUDIFY_GITHUBUSER=u
    export CLOUDIFY_GITHUBPWD=p
    export CLOUDIFY_GITLABUSER=u
    export CLOUDIFY_GITLABPWD=p

    run cloudify_credentials_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"remote:  OK"* ]]
    [[ "$output" == *"github:  OK"* ]]
    [[ "$output" == *"gitlab:  OK"* ]]
}

@test "cloudify_credentials_check reports INCOMPLETE when missing" {
    unset CLOUDIFY_REMOTE_USER
    unset CLOUDIFY_REMOTE_PWD
    unset CLOUDIFY_GITHUBUSER
    unset CLOUDIFY_GITHUBPWD

    run cloudify_credentials_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"remote:  INCOMPLETE"* ]]
    [[ "$output" == *"github:  INCOMPLETE"* ]]
}

@test "cloudify_credentials_save saves all sections when no argument" {
    export CLOUDIFY_REMOTE_USER=ruser
    export CLOUDIFY_REMOTE_PWD=rpwd
    export CLOUDIFY_GITHUBUSER=ghuser
    export CLOUDIFY_GITHUBPWD=ghpwd
    export CLOUDIFY_GITLABUSER=gluser
    export CLOUDIFY_GITLABPWD=glpwd

    cloudify_credentials_save

    grep -q "CLOUDIFY_REMOTE_USER" "$CLOUDIFY_CREDENTIALS_FILE"
    grep -q "CLOUDIFY_GITHUBUSER" "$CLOUDIFY_CREDENTIALS_FILE"
    grep -q "CLOUDIFY_GITLABUSER" "$CLOUDIFY_CREDENTIALS_FILE"
}

@test "cloudify_credentials_save saves only specified section" {
    export CLOUDIFY_REMOTE_USER=ruser
    export CLOUDIFY_REMOTE_PWD=rpwd
    export CLOUDIFY_GITHUBUSER=ghuser
    export CLOUDIFY_GITHUBPWD=ghpwd

    cloudify_credentials_save remote

    grep -q "CLOUDIFY_REMOTE_USER" "$CLOUDIFY_CREDENTIALS_FILE"
    # GitHub should NOT be in the file
    ! grep -q "CLOUDIFY_GITHUBUSER" "$CLOUDIFY_CREDENTIALS_FILE"
}
