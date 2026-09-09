#!/usr/bin/env bats
# Integration: pkg/xfce (split pkg, ADR-008) on a real host.
# Lifecycle: install provisions, configure re-asserts, uninstall tears down
# (packages + service; the account only with explicit intent, home preserved).
# Password: env-passed used verbatim and never printed; else generated + printed
# once. Defaults are exercised (user gui, session startxfce4, chrome on).

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Timestamped rubric report (tests/helpers/report.bash)
source tests/helpers/report.bash

export PKG_VERIFY_TIMEOUT=600

setup_file() {
    rubric "prepare $TEST_HOST"
    step "wait for ssh readiness"
    local i
    for i in $(seq 1 45); do
        $TEST_SSH "root@$TEST_HOST" true 2>/dev/null && break
        sleep 2
    done
    $TEST_SSH "root@$TEST_HOST" true 2>/dev/null || { step "ssh never came up"; return 1; }
    step "host ready"
}

# Run a long command in the background, stream its last line as a report step
# (fd 9 = live). apt is slow and near-silent, so the stall window is 300s; the
# cap is 1500s. Slow != stuck.
run_stream() {
    local tag="$1"; shift
    local logf
    logf=$(mktemp)
    ( "$@" > "$logf" 2>&1 ) &
    local pid=$! last=0 idle=0 elapsed=0 size line rc
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        size=$(wc -c < "$logf")
        if [ "$size" -gt "$last" ]; then
            idle=0; last=$size
            line=$(tail -1 "$logf" | tr -d '\033' | sed 's/\[[0-9;]*m//g')
            step "[$tag ${elapsed}s] $line"
        else
            idle=$((idle + 5))
            if [ "$idle" -ge 300 ]; then
                step "[$tag STALLED - no output for 300s]"
                tail -3 "$logf"
                kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
                rm -f "$logf"
                return 124
            fi
        fi
        if [ "$elapsed" -ge 1500 ]; then
            step "[$tag TIMEOUT after 1500s]"
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            rm -f "$logf"
            return 124
        fi
    done
    wait "$pid"; rc=$?
    step "[$tag done in ${elapsed}s, exit $rc]"
    rm -f "$logf"
    return "$rc"
}

# Read the stored password from the on-guest state file.
STATE_PW='awk -F"'\''" "/^XFCE_PASSWORD=/{print \$2}" /etc/cloudify/xfce-user.env'

@test "install succeeds with a generated password" {
    rubric "install succeeds with a generated password"
    run_stream install cloudify --no-defaults --on "$TEST_HOST" install xfce
    local rc=$?
    [ "$rc" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [[ "$output" =~ ^[A-Za-z0-9]{24,}$ ]]
    step "generated password stored"
}

@test "endpoint health (user, session, xrdp, key.pem, chrome)" {
    rubric "endpoint health after install"
    run $TEST_SSH "root@$TEST_HOST" 'getent passwd gui | cut -d: -f1'
    [ "$output" = "gui" ]
    run $TEST_SSH "root@$TEST_HOST" 'cat /home/gui/.xsession'
    [ "$output" = "startxfce4" ]
    run $TEST_SSH "root@$TEST_HOST" 'systemctl is-active xrdp'
    [ "$output" = "active" ]
    run $TEST_SSH "root@$TEST_HOST" 'ss -ltn | grep -c ":3389 "'
    [ "$output" -ge 1 ]
    run $TEST_SSH "root@$TEST_HOST" 'test -e /etc/xrdp/key.pem && getent group ssl-cert | grep -qw xrdp && echo OK'
    [ "$output" = "OK" ]
    run $TEST_SSH "root@$TEST_HOST" 'command -v google-chrome >/dev/null && grep -q "WebBrowser=google-chrome" /home/gui/.config/xfce4/helpers.rc && echo OK'
    [ "$output" = "OK" ]
    step "all endpoint checks passed"
}

@test "FORCE reinstall preserves the password" {
    rubric "FORCE reinstall preserves the password"
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    local pw_before="$output"
    run_stream reinstall cloudify --no-defaults --on "$TEST_HOST" install xfce
    local rc=$?
    [ "$rc" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [ "$output" = "$pw_before" ]
    step "password unchanged"
}

@test "configure re-runs without touching the password" {
    rubric "configure re-runs without touching the password"
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    local pw_before="$output"
    run cloudify --no-defaults --on "$TEST_HOST" configure xfce
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [ "$output" = "$pw_before" ]
    step "password unchanged"
}

@test "env-passed password is used verbatim for a new user" {
    rubric "env-passed password is used verbatim for a new user"
    export CLOUDIFY_XFCE_USER='guib'
    export CLOUDIFY_XFCE_USER_PASSWORD='xfce-itest-pass-42'
    run_stream install2 cloudify --no-defaults --on "$TEST_HOST" install xfce
    local rc=$?
    [ "$rc" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [ "$output" = "xfce-itest-pass-42" ]
    run $TEST_SSH "root@$TEST_HOST" 'getent passwd guib | cut -d: -f1'
    [ "$output" = "guib" ]
    step "env-passed password used, user guib created"
}

@test "uninstall purges packages and service, keeps the account and home" {
    rubric "uninstall purges packages + service, keeps account and home"
    run_stream uninstall cloudify --no-defaults --on "$TEST_HOST" uninstall xfce
    local rc=$?
    [ "$rc" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'command -v xfce4-session >/dev/null && echo present || echo absent'
    [ "$output" = "absent" ]
    run $TEST_SSH "root@$TEST_HOST" 'systemctl is-active xrdp 2>/dev/null || echo inactive'
    [ "$output" != "active" ]
    run $TEST_SSH "root@$TEST_HOST" 'test ! -f /etc/cloudify/xfce-user.env'
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'getent passwd guib | cut -d: -f1'
    [ "$output" = "guib" ]
    run $TEST_SSH "root@$TEST_HOST" 'test -d /home/guib'
    [ "$status" -eq 0 ]
    step "packages/service gone, account + home preserved"
}

@test "uninstall with explicit intent removes the account, never the home" {
    rubric "explicit uninstall removes the account, never the home"
    run env CLOUDIFY_XFCE_USER=guib CLOUDIFY_XFCE_UNINSTALL_USER=true cloudify --no-defaults --on "$TEST_HOST" uninstall xfce
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'getent passwd guib || echo absent'
    [ "$output" = "absent" ]
    run $TEST_SSH "root@$TEST_HOST" 'test -d /home/guib'
    [ "$status" -eq 0 ]
    step "account removed, home preserved"
}
