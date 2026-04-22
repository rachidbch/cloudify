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

@test "cloudify_get_password dies on empty argument" {
    run cloudify_get_password ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"no argument"* ]]
}

@test "cloudify_get_password dies on space in argument" {
    run cloudify_get_password "my pwd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"space"* ]]
}

#-- _cloudify_sed_escape tests --

@test "_cloudify_sed_escape escapes forward slash" {
    run _cloudify_sed_escape "a/b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a\\/b"* ]]
}

@test "_cloudify_sed_escape escapes square brackets" {
    run _cloudify_sed_escape "a[b]c"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a\\[b\\]c"* ]]
}

@test "_cloudify_sed_escape escapes ampersand" {
    run _cloudify_sed_escape "a&b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a\\&b"* ]]
}

@test "_cloudify_sed_escape escapes backslash" {
    run _cloudify_sed_escape 'a\b'
    [ "$status" -eq 0 ]
    [[ "$output" == *"a\\\\b"* ]]
}

@test "_cloudify_sed_escape handles plain text without special chars" {
    run _cloudify_sed_escape "hello world"
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
}

@test "module guard prevents double-sourcing" {
    source lib/utils.sh
    source lib/utils.sh
    [ "$(type -t msg)" = "function" ]
}

#-- cloudify_init_log tests --

@test "cloudify_init_log creates log directory" {
    cloudify_init_log
    [ -d "$CLOUDIFY_TMP/logs" ]
}

@test "cloudify_init_log creates log file" {
    cloudify_init_log
    [ -f "$CLOUDIFY_LOG_FILE" ]
}

@test "cloudify_init_log exports CLOUDIFY_LOG_FILE with timestamp" {
    cloudify_init_log
    [[ "$CLOUDIFY_LOG_FILE" == *".log" ]]
    [[ "$CLOUDIFY_LOG_FILE" == "$CLOUDIFY_TMP/logs/"* ]]
}

@test "cloudify_init_log creates empty log file when no cmdline" {
    cloudify_init_log
    [ ! -s "$CLOUDIFY_LOG_FILE" ]
}

@test "cloudify_init_log writes command header to log file" {
    _CLOUDIFY_CMDLINE="launch cloudai:testbox"
    cloudify_init_log
    grep -q "# cloudify launch cloudai:testbox" "$CLOUDIFY_LOG_FILE"
}

#-- cleanup preserving logs tests --

@test "cleanup preserves logs directory when DEBUG=false" {
    cloudify_init_log
    # Create a non-log file that should be removed
    touch "$CLOUDIFY_TMP/somefile"
    mkdir -p "$CLOUDIFY_TMP/somedir"
    touch "$CLOUDIFY_TMP/somedir/nested"

    CLOUDIFY_LOG_LEVEL=INFO cleanup

    [ -d "$CLOUDIFY_TMP/logs" ]
    [ ! -e "$CLOUDIFY_TMP/somefile" ]
    [ ! -e "$CLOUDIFY_TMP/somedir" ]
}

@test "cleanup removes everything when no logs directory exists" {
    touch "$CLOUDIFY_TMP/somefile"
    CLOUDIFY_LOG_LEVEL=INFO cleanup
    [ ! -d "$CLOUDIFY_TMP" ]
}

@test "cleanup skips removal when DEBUG=true" {
    touch "$CLOUDIFY_TMP/somefile"
    CLOUDIFY_LOG_LEVEL=DEBUG cleanup
    [ -e "$CLOUDIFY_TMP/somefile" ]
}

#-- Log level system --

@test "_cloudify_log_level_num returns correct numeric values" {
    [ "$(_cloudify_log_level_num "SILENT")" -eq 0 ]
    [ "$(_cloudify_log_level_num "CRITICAL")" -eq 1 ]
    [ "$(_cloudify_log_level_num "ERROR")" -eq 2 ]
    [ "$(_cloudify_log_level_num "WARN")" -eq 3 ]
    [ "$(_cloudify_log_level_num "INFO")" -eq 4 ]
    [ "$(_cloudify_log_level_num "DEBUG")" -eq 5 ]
}

@test "_cloudify_log_level_num defaults to INFO for unknown" {
    [ "$(_cloudify_log_level_num "UNKNOWN")" -eq 4 ]
    [ "$(_cloudify_log_level_num "")" -eq 4 ]
}

@test "_cloudify_log_level returns 0 when level should display" {
    CLOUDIFY_LOG_LEVEL=INFO
    run _cloudify_log_level "CRITICAL"
    [ "$status" -eq 0 ]
    run _cloudify_log_level "INFO"
    [ "$status" -eq 0 ]
}

@test "_cloudify_log_level returns 1 when level should suppress" {
    CLOUDIFY_LOG_LEVEL=INFO
    run _cloudify_log_level "DEBUG"
    [ "$status" -eq 1 ]
}

@test "SILENT suppresses everything" {
    CLOUDIFY_LOG_LEVEL=SILENT
    run _cloudify_log_level "CRITICAL"
    [ "$status" -eq 1 ]
}

@test "DEBUG shows everything" {
    CLOUDIFY_LOG_LEVEL=DEBUG
    run _cloudify_log_level "DEBUG"
    [ "$status" -eq 0 ]
    run _cloudify_log_level "CRITICAL"
    [ "$status" -eq 0 ]
}

@test "log_critical outputs at CRITICAL level" {
    CLOUDIFY_LOG_LEVEL=CRITICAL
    run log_critical "test"
    [[ "$output" == *"[CRITICAL]"*"test"* ]]
}

@test "log_critical silent at SILENT" {
    CLOUDIFY_LOG_LEVEL=SILENT
    run log_critical "test"
    [ -z "$output" ]
}

@test "log_error outputs at ERROR level" {
    CLOUDIFY_LOG_LEVEL=ERROR
    run log_error "test"
    [[ "$output" == *"[ERROR]"*"test"* ]]
}

@test "log_error silent at CRITICAL" {
    CLOUDIFY_LOG_LEVEL=CRITICAL
    run log_error "test"
    [ -z "$output" ]
}

@test "log_warn outputs at WARN level" {
    CLOUDIFY_LOG_LEVEL=WARN
    run log_warn "test"
    [[ "$output" == *"[WARN]"*"test"* ]]
}

@test "log_warn silent at ERROR" {
    CLOUDIFY_LOG_LEVEL=ERROR
    run log_warn "test"
    [ -z "$output" ]
}

@test "log_info outputs at INFO level" {
    CLOUDIFY_LOG_LEVEL=INFO
    run log_info "test"
    [[ "$output" == *"[INFO]"*"test"* ]]
}

@test "log_info silent at WARN" {
    CLOUDIFY_LOG_LEVEL=WARN
    run log_info "test"
    [ -z "$output" ]
}

@test "log_debug outputs at DEBUG level" {
    CLOUDIFY_LOG_LEVEL=DEBUG
    run log_debug "test"
    [[ "$output" == *"[DEBUG]"*"test"* ]]
}

@test "log_debug silent at INFO" {
    CLOUDIFY_LOG_LEVEL=INFO
    run log_debug "test"
    [ -z "$output" ]
}

@test "cleanup preserves temp when CLOUDIFY_LOG_LEVEL=DEBUG" {
    cloudify_init_log
    touch "$CLOUDIFY_TMP/somefile"
    CLOUDIFY_LOG_LEVEL=DEBUG cleanup
    [ -e "$CLOUDIFY_TMP/somefile" ]
}

@test "cleanup preserves logs when CLOUDIFY_LOG_LEVEL=INFO" {
    cloudify_init_log
    touch "$CLOUDIFY_TMP/somefile"
    CLOUDIFY_LOG_LEVEL=INFO cleanup
    [ -d "$CLOUDIFY_TMP/logs" ]
    [ ! -e "$CLOUDIFY_TMP/somefile" ]
}

#-- log file writing tests --

@test "cloudify_init_log is idempotent" {
    cloudify_init_log
    local first_log="$CLOUDIFY_LOG_FILE"
    cloudify_init_log
    [[ "$CLOUDIFY_LOG_FILE" == "$first_log" ]]
}

@test "log_info writes to CLOUDIFY_LOG_FILE" {
    CLOUDIFY_LOG_LEVEL=INFO
    cloudify_init_log
    log_info "test log message"
    grep -q "test log message" "$CLOUDIFY_LOG_FILE"
}

@test "log_info does not write to log file when CLOUDIFY_LOG_FILE unset" {
    CLOUDIFY_LOG_LEVEL=INFO
    unset CLOUDIFY_LOG_FILE
    run log_info "test"
    [ "$status" -eq 0 ]
}

@test "log_debug writes to CLOUDIFY_LOG_FILE at DEBUG level" {
    CLOUDIFY_LOG_LEVEL=DEBUG
    cloudify_init_log
    log_debug "debug msg"
    grep -q "debug msg" "$CLOUDIFY_LOG_FILE"
}

@test "log_warn does not write to file at ERROR level" {
    CLOUDIFY_LOG_LEVEL=ERROR
    cloudify_init_log
    log_warn "should not appear"
    ! grep -q "should not appear" "$CLOUDIFY_LOG_FILE"
}
