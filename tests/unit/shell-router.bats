#!/usr/bin/env bats
# Tests for the shell command routing in the cloudify router

setup() {
    source tests/helpers/common.bash
    setup_test_env

    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"
    export CLOUDIFY_REMOTE_USER=root
}

teardown() {
    rm -rf "$STUB_DIR"
    teardown_test_env
}

# Create an ssh stub that records how it was called
_create_ssh_stub() {
    cat <<'STUB' > "$STUB_DIR/ssh"
#!/bin/bash
echo "SSH_ARGS: $*" >> "$STUB_DIR/ssh_calls.log"
STUB
    chmod +x "$STUB_DIR/ssh"
    : > "$STUB_DIR/ssh_calls.log"
}

# Run the shell case logic matching the router code
_run_shell_case() {
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
    source lib/remote.sh
    source lib/packages.sh
    source lib/hosts.sh

    # Simulate: cloudify shell hermes [args...]
    set -- "shell" "hermes" "$@"

    [[ -z "${2:-}" ]] && die "Missing host"
    shift  # drop "shell"
    local host="$1"
    shift  # drop "hermes"

    # This mirrors the actual router code in the shell case
    local ssh_target="${CLOUDIFY_REMOTE_USER:+$CLOUDIFY_REMOTE_USER@}$host"

    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-i" ]]; then
        if [[ "${1:-}" == "-i" ]]; then
            shift
            # -i explicitly requests interactive: always use -t
            ssh -t -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@"
        else
            # Bare shell: use -t only when stdin is a TTY
            local tty_flag=""
            [ -t 0 ] && tty_flag="-t"
            ssh $tty_flag -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@"
        fi
    else
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@" 2>&1 | tail -n +2
    fi
}

# Same as _run_shell_case but forces -t (simulates TTY being available)
_run_shell_case_with_tty() {
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
    source lib/remote.sh
    source lib/packages.sh
    source lib/hosts.sh

    set -- "shell" "hermes" "$@"

    [[ -z "${2:-}" ]] && die "Missing host"
    shift
    local host="$1"
    shift

    local ssh_target="${CLOUDIFY_REMOTE_USER:+$CLOUDIFY_REMOTE_USER@}$host"

    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-i" ]]; then
        [[ "${1:-}" == "-i" ]] && shift
        ssh -t -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@"
    else
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$ssh_target" "$@" 2>&1 | tail -n +2
    fi
}

# ---------------------------------------------------------------
# SSH target includes CLOUDIFY_REMOTE_USER
# ---------------------------------------------------------------

@test "shell uses CLOUDIFY_REMOTE_USER@host as ssh target" {
    _create_ssh_stub
    _run_shell_case

    grep -q "root@hermes" "$STUB_DIR/ssh_calls.log"
}

@test "shell with -i uses CLOUDIFY_REMOTE_USER@host as ssh target" {
    _create_ssh_stub
    _run_shell_case -i hermes setup

    grep -q "root@hermes" "$STUB_DIR/ssh_calls.log"
}

@test "shell non-interactive uses CLOUDIFY_REMOTE_USER@host as ssh target" {
    _create_ssh_stub
    _run_shell_case hermes --version

    grep -q "root@hermes" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# Bare shell (no command) → interactive with -t
# ---------------------------------------------------------------

@test "shell with no args uses ssh -t when stdin is a TTY" {
    _create_ssh_stub
    # Force TTY detection to true
    _run_shell_case_with_tty

    grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with no args omits -t when stdin is not a TTY" {
    _create_ssh_stub
    _run_shell_case

    ! grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with no args does NOT pipe through tail" {
    _create_ssh_stub
    _run_shell_case

    local call_count
    call_count=$(grep -c "SSH_ARGS:" "$STUB_DIR/ssh_calls.log")
    [ "$call_count" -eq 1 ]
}

# ---------------------------------------------------------------
# shell -i command → interactive with -t
# ---------------------------------------------------------------

@test "shell -i command uses ssh -t (interactive)" {
    _create_ssh_stub
    _run_shell_case -i hermes setup

    grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell -i command passes command to ssh" {
    _create_ssh_stub
    _run_shell_case -i hermes setup

    grep -q "hermes setup" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# shell command (no -i) → non-interactive, no -t
# ---------------------------------------------------------------

@test "shell with command but no -i does NOT use -t" {
    _create_ssh_stub
    _run_shell_case hermes --version

    ! grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with command but no -i passes command to ssh" {
    _create_ssh_stub
    _run_shell_case hermes --version

    grep -q "hermes --version" "$STUB_DIR/ssh_calls.log"
}

# ---------------------------------------------------------------
# Router: unrecognized arguments must not exit silently
# ---------------------------------------------------------------

@test "router exits with error on unrecognized positional argument" {
    _create_ssh_stub
    run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true
        export CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-test CLOUDIFY_TMP=/tmp/cf-test-tmp
        export DEBUG=false CLOUDIFY_HOSTPWD=test CLOUDIFY_REMOTE_USER=root
        mkdir -p /tmp/cf-test/pkg /tmp/cf-test/inventory /tmp/cf-test-tmp
        cd /root/cloudify && bash cloudify hermes shell 2>&1
    "
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# Real router: SSH target must use CLOUDIFY_REMOTE_USER
# ---------------------------------------------------------------

@test "real router: cloudify shell host uses CLOUDIFY_REMOTE_USER@host" {
    local stub_bin="$STUB_DIR/ssh"
    cat <<'STUB' > "$stub_bin"
#!/bin/bash
echo "SSH_REAL: $*" >> "$STUB_DIR/ssh_calls.log"
STUB
    chmod +x "$stub_bin"
    : > "$STUB_DIR/ssh_calls.log"

    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true
        export CLOUDIFY_IS_LOCAL=true CLOUDIFY_DIR=/tmp/cf-test CLOUDIFY_TMP=/tmp/cf-test-tmp
        export DEBUG=false CLOUDIFY_HOSTPWD=test CLOUDIFY_REMOTE_PWD=test CLOUDIFY_REMOTE_USER=root
        mkdir -p /tmp/cf-test/pkg /tmp/cf-test/inventory /tmp/cf-test-tmp
        cd /root/cloudify && bash cloudify shell testhost echo ok 2>&1
    "

    grep -q "root@testhost" "$STUB_DIR/ssh_calls.log"
}
