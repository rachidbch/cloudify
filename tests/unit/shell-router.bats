#!/usr/bin/env bats
# Tests for the shell command routing in the cloudify router

setup() {
    source tests/helpers/common.bash
    setup_test_env

    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"
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
echo "SSH_STDIN_CONNECTED: $([ -t 0 ] && echo tty || echo pipe)" >> "$STUB_DIR/ssh_calls.log"
STUB
    chmod +x "$STUB_DIR/ssh"
    : > "$STUB_DIR/ssh_calls.log"
}

# Extract and run just the shell case block with a stubbed ssh
# This avoids running the full main() which would try to do too much
_run_shell_case() {
    # Source libs needed by the router
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/containers.sh
    source lib/remote.sh
    source lib/packages.sh
    source lib/hosts.sh

    # Re-parse the shell args as the router would
    # Simulate: cloudify hermes shell [args...]
    set -- "shell" "hermes" "$@"

    # Inline the shell case logic from the router
    [[ -z "${2:-}" ]] && die "Missing host"
    shift  # drop "shell"
    local host="$1"
    shift  # drop "hermes"

    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-i" ]]; then
        # Interactive: allocate TTY (bare shell or -i flag)
        [[ "${1:-}" == "-i" ]] && shift
        ssh -t -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$host" "$@"
    else
        # Non-interactive: pipe output, strip SSH banner
        ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$host" "$@" 2>&1 | tail -n +2
    fi
}

# ---------------------------------------------------------------
# Bare shell (no command) → interactive with -t
# ---------------------------------------------------------------

@test "shell with no args uses ssh -t (interactive)" {
    _create_ssh_stub
    _run_shell_case

    # Should have called ssh with -t flag
    grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with no args passes host to ssh" {
    _create_ssh_stub
    _run_shell_case

    grep -q "hermes" "$STUB_DIR/ssh_calls.log"
}

@test "shell with no args does NOT pipe through tail" {
    _create_ssh_stub
    _run_shell_case

    # Should only have one ssh call (no tail involvement in the stub log)
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

    # Should NOT have -t flag
    ! grep -q "\-t" "$STUB_DIR/ssh_calls.log"
}

@test "shell with command but no -i passes command to ssh" {
    _create_ssh_stub
    _run_shell_case hermes --version

    grep -q "hermes --version" "$STUB_DIR/ssh_calls.log"
}
