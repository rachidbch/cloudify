#!/usr/bin/env bats
# Integration: pkg/octop (split pkg, ADR-008) on a real host.
# Lifecycle: install runs the official installer (pinned 1.0.1), first-boots
# the server under its own systemd user unit with the one-time wizard
# password; configure converges the env file; uninstall keeps state, and
# --clear-data wipes. Health truth: GET /api/health -> {"ok":true,...}.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Timestamped rubric report (tests/helpers/report.bash)
source tests/helpers/report.bash

export PKG_VERIFY_TIMEOUT=120

setup_file() {
    rubric "prepare $TEST_HOST"
    step "wait for ssh readiness"
    for _ in $(seq 1 45); do
        $TEST_SSH "root@$TEST_HOST" true 2>/dev/null && break
        sleep 2
    done
    $TEST_SSH "root@$TEST_HOST" true 2>/dev/null || { step "ssh never came up"; return 1; }
    step "host ready"
}

@test "octop install succeeds on $TEST_HOST" {
    rubric "official installer + first boot under systemd user unit"
    run cloudify --on "$TEST_HOST" install octop
    [ "$status" -eq 0 ]
}

@test "octop service is active on $TEST_HOST" {
    rubric "octop-owned user unit answers systemctl is-active"
    run $TEST_SSH "root@$TEST_HOST" 'systemctl --user is-active octop'
    [ "$status" -eq 0 ]
    [ "$output" = "active" ]
}

@test "octop /api/health answers ok:true on $TEST_HOST" {
    rubric "real health endpoint (README's /health is SPA-swallowed)"
    run $TEST_SSH "root@$TEST_HOST" 'curl -s --max-time 5 http://127.0.0.1:8088/api/health'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"ok":true'* ]]
}

@test "first-run wizard password file exists on $TEST_HOST" {
    rubric "one-time setup-wizard secret minted at first boot (0600)"
    run $TEST_SSH "root@$TEST_HOST" 'test -s /root/octop-login.txt && stat -c "%a" /root/octop-login.txt'
    [ "$status" -eq 0 ]
    [ "$output" = "600" ]
}

@test "env file carries the managed knobs on $TEST_HOST" {
    rubric "install writes the dotenv the server loads itself"
    run $TEST_SSH "root@$TEST_HOST" 'grep -c "^OCTOP_\(PORT\|BIND_HOST\|LOG_LEVEL\)=" /root/.octop/env'
    [ "$status" -eq 0 ]
    [ "$output" -ge 3 ]
}

@test "configure converges a port change and stays healthy on $TEST_HOST" {
    rubric "env upsert + restart-only-on-change convergence"
    run bash -c "OCTOP_PORT=8090 cloudify --on '$TEST_HOST' configure octop"
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'curl -s --max-time 5 http://127.0.0.1:8090/api/health'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"ok":true'* ]]
}

@test "octop uninstall keeps state; --clear-data wipes it on $TEST_HOST" {
    rubric "teardown semantics: state is data, wipe is explicit"
    run cloudify --on "$TEST_HOST" uninstall octop
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'systemctl --user is-active octop; ls -d /root/.octop'
    [ "$status" -eq 0 ]
    [ "$output" = "inactive
/root/.octop" ]
    run cloudify --on "$TEST_HOST" --clear-data uninstall octop
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test -e /root/.octop || test -e /root/octop-login.txt'
    [ "$status" -ne 0 ]
}
