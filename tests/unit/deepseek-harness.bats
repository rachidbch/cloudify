#!/usr/bin/env bats
# deepseek-harness split lifecycle (ADR-008 / ADR-014): install.sh (guarded,
# token-preserving first install) + configure.sh (unguarded update verb) +
# hardened verify. External commands are PATH-shim stubs — nothing real is
# installed or restarted; shared test paths are cleaned after each test.

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/remote.sh
    export CLOUDIFY_NO_VERIFY=true
    export DSH_HOME="$BATS_TEST_TMPDIR/dsh-home"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$DSH_HOME" "$HOME/.local/bin" "$HOME/.local/share/mise/shims"

    # Stub the mise dep and the mise CLI so the recipe never touches the
    # container's runtime manager.
    pkg_depends() { :; }
    mise() { :; }

    # The recipe prepends HOME/.local/bin before the inherited PATH, so put
    # shims there rather than relying on STUB_DIR being first.
    export STUB_DIR="$HOME/.local/bin"
    cat > "$STUB_DIR/dsh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$STUB_DIR/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$STUB_NPM_LOG"
if [[ "$*" == *"ls -g @deepseek-ai/dsh"* ]]; then
    echo "root -> @deepseek-ai/dsh@0.1.0-rc.8"
fi
exit 0
EOF
    cat > "$STUB_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_SYSTEMCTL_LOG"
if [[ "$1" == "is-active" ]]; then echo "active"; fi
exit 0
EOF
    cat > "$STUB_DIR/tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "status" ]]; then echo '{"Self":{"DNSName":"unit.test."}}'; fi
exit 0
EOF
    cat > "$STUB_DIR/corepack" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${CURL_INDEX:-tags}" == "notags" ]]; then
    echo '<html><head></head><body>no plugins</body></html>'
else
    echo '<html><head><script data-plugin="dsh-loopback-pin"></script><script data-plugin="dsh-reverse-proxy"></script></head><body>ok</body></html>'
fi
exit 0
EOF
    chmod +x "$STUB_DIR"/*
    export STUB_NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    export STUB_SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    export PATH="$STUB_DIR:$PATH"

    # configure.sh requires the shipped pin plugin on disk.
    mkdir -p /opt/dsh-loopback-pin

    # Hermetic: shared system files must not leak between tests.
    rm -f /etc/systemd/system/dsh.service /usr/local/bin/dsh
}

teardown() {
    teardown_test_env
    rm -f /etc/systemd/system/dsh.service /usr/local/bin/dsh
}

write_state() {
    cat > "$DSH_HOME/reverse-proxy.json" <<'EOF'
{
  "enabled": true,
  "accessToken": "1111111111111111111111111111111111111111111111111111111111111111",
  "listenHost": "127.0.0.1",
  "listenPort": 3081
}
EOF
    chmod 600 "$DSH_HOME/reverse-proxy.json"
}

@test "install: generates reverse-proxy.json + stable ExecStart on first install" {
    run source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/install.sh"
    [ "$status" -eq 0 ]
    [ -f "$DSH_HOME/reverse-proxy.json" ]
    run jq -r '.accessToken' "$DSH_HOME/reverse-proxy.json"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
    [ -f /etc/systemd/system/dsh.service ]
    grep -q "ExecStart=/usr/local/bin/dsh" /etc/systemd/system/dsh.service
    grep -q "trusted-host unit.test" /etc/systemd/system/dsh.service
}

@test "install: preserves existing token on FORCE re-install" {
    write_state
    export CLOUDIFY_FORCE=true
    run source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/install.sh"
    [ "$status" -eq 0 ]
    run jq -r '.accessToken' "$DSH_HOME/reverse-proxy.json"
    [ "$output" = "1111111111111111111111111111111111111111111111111111111111111111" ]
}

@test "install: guard skips when already running (no FORCE), no token churn" {
    write_state
    cat > /etc/systemd/system/dsh.service <<'EOF'
[Unit]
Description=test
EOF
    run source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping"* ]]
    run jq -r '.accessToken' "$DSH_HOME/reverse-proxy.json"
    [ "$output" = "1111111111111111111111111111111111111111111111111111111111111111" ]
}

@test "install: CLEAR_DATA wipes state even when it existed" {
    write_state
    export CLOUDIFY_CLEAR_DATA=true
    run source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/install.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$DSH_HOME/reverse-proxy.json" ]
}

@test "configure: dies clearly when dsh is not installed" {
    mv "$STUB_DIR/dsh" "$STUB_DIR/.dsh.off"
    run source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/configure.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to update"* ]]
    mv "$STUB_DIR/.dsh.off" "$STUB_DIR/dsh"
}

@test "configure: update bumps npm, preserves token, restarts service" {
    write_state
    run source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/configure.sh"
    [ "$status" -eq 0 ]
    local update_output="$output"
    # npm update ran
    grep -q "npm install -g @deepseek-ai/dsh" "$STUB_NPM_LOG"
    # token + sessions preserved byte-for-byte
    run jq -r '.accessToken' "$DSH_HOME/reverse-proxy.json"
    [ "$output" = "1111111111111111111111111111111111111111111111111111111111111111" ]
    # service restarted
    grep -q "systemctl restart dsh" "$STUB_SYSTEMCTL_LOG"
    # old -> new reported with rollback hint
    [[ "$update_output" == *"updated:"* ]]
    [[ "$update_output" == *"Rollback"* ]]
}

@test "verify: green with valid state + both plugin tags served" {
    write_state
    source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/verify.sh"
    run pkg_verify
    [ "$status" -eq 0 ]
}

@test "verify: red when plugin composition is missing (version drift)" {
    write_state
    export CURL_INDEX=notags
    source "$CLOUDIFY_SCRIPT_DIR/pkg/deepseek-harness/verify.sh"
    run pkg_verify
    [ "$status" -ne 0 ]
}
