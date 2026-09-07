#!/usr/bin/env bats
# Integration test: pkg/xfce (split pkg, ADR-008) on a real host.
# Installs XFCE + xrdp on the test container, asserts local endpoint health,
# then proves: FORCE reinstall preserves the generated password, configure
# re-runs without touching it, and an env-passed password is used verbatim
# (never printed) when provided for a new user.
#
# Defaults are used on purpose (user gui, session startxfce4, port 3389,
# chrome on): the test exercises recipe defaults. Only the password is
# exercised in both modes (generated + env-passed).
#
# First install is apt-heavy (xfce4 desktop) and apt runs near-silently, so
# the stall detector is relaxed via RUN_STALL/RUN_TIMEOUT - a live apt is
# slow but producing no output; a stuck run still fails loudly.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
export PKG_VERIFY_TIMEOUT=600
export RUN_STALL=300
export RUN_TIMEOUT=1500

# After a snapshot restore the container needs time to boot + rejoin the
# tailnet; wait for ssh readiness before every test.
setup() {
    local i=0
    until $TEST_SSH "root@$TEST_HOST" 'true' >/dev/null 2>&1; do
        i=$((i + 1))
        ((i < 45)) || { echo "ssh to $TEST_HOST never came up" >&3; return 1; }
        sleep 2
    done
}

# Streaming runner: no silent steps. Polls the command log every 5s, reports
# progress to /tmp/xfce-itest-progress.log + FD3. Fails loudly on stall
# (no output for RUN_STALL) or after RUN_TIMEOUT. Slow != stuck.
PROGRESS_FILE="/tmp/xfce-itest-progress.log"
STALL="${RUN_STALL:-90}"
TIMEOUT="${RUN_TIMEOUT:-900}"
run_install() {
    local tag="$1"; shift
    local logf="/tmp/xfce-${tag}.log"
    : > "$logf"
    ( "$@" > "$logf" 2>&1 ) &
    local pid=$! last=0 idle=0 elapsed=0 line size rc
    echo "[$tag starting]" >> "$PROGRESS_FILE"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5; elapsed=$((elapsed + 5))
        size=$(wc -c < "$logf")
        if [ "$size" -gt "$last" ]; then
            idle=0; last=$size
            line=$(tail -1 "$logf" | tr -d '\033' | sed 's/\[[0-9;]*m//g')
            echo "[$tag ${elapsed}s] $line" | tee -a "$PROGRESS_FILE" >&3
        else
            idle=$((idle + 5))
            if [ "$idle" -ge "$STALL" ]; then
                echo "[$tag STALLED - no output for ${STALL}s]" | tee -a "$PROGRESS_FILE" >&3
                tail -3 "$logf" | tee -a "$PROGRESS_FILE" >&3
                kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
                return 124
            fi
        fi
        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            echo "[$tag TIMEOUT after ${TIMEOUT}s]" | tee -a "$PROGRESS_FILE" >&3
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            return 124
        fi
    done
    wait "$pid"; rc=$?
    echo "[$tag done in ${elapsed}s, exit $rc]" | tee -a "$PROGRESS_FILE" >&3
    return "$rc"
}

# Read the stored password from the on-guest state file.
STATE_PW='awk -F"'\''" "/^XFCE_PASSWORD=/{print \$2}" /etc/cloudify/xfce-user.env'

@test "cloudify --on $TEST_HOST install xfce succeeds (generated password)" {
    run_install install cloudify --no-defaults --on "$TEST_HOST" install xfce
    local rc=$?
    echo "install rc=$rc" >&3
    [ "$rc" -eq 0 ]
    # Generated password: 24+ URL-safe chars in the state file, printed once.
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [[ "$output" =~ ^[A-Za-z0-9]{24,}$ ]]
    grep -q "GENERATED password" /tmp/xfce-install.log
}

@test "endpoint health on $TEST_HOST (user, session, xrdp, key.pem, chrome)" {
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
    run $TEST_SSH "root@$TEST_HOST" 'command -v google-chrome && grep -q "WebBrowser=google-chrome" /home/gui/.config/xfce4/helpers.rc && echo OK'
    [ "$output" = "OK" ]
}

@test "FORCE reinstall preserves the password (user exists, never regenerated)" {
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    local pw_before="$output"

    run_install reinstall cloudify --no-defaults --on "$TEST_HOST" install xfce
    local rc=$?
    [ "$rc" -eq 0 ]

    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [ "$output" = "$pw_before" ]
    grep -q "password preserved" /tmp/xfce-reinstall.log
    ! grep -q "GENERATED password" /tmp/xfce-reinstall.log
}

@test "configure re-runs without touching the password" {
    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    local pw_before="$output"

    run cloudify --no-defaults --on "$TEST_HOST" configure xfce
    [ "$status" -eq 0 ]

    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [ "$output" = "$pw_before" ]
}

@test "env-passed password is used verbatim for a new user and never printed" {
    export CLOUDIFY_XFCE_USER='guib'
    export CLOUDIFY_XFCE_USER_PASSWORD='xfce-itest-pass-42'

    run_install install2 cloudify --no-defaults --on "$TEST_HOST" install xfce
    local rc=$?
    [ "$rc" -eq 0 ]

    run $TEST_SSH "root@$TEST_HOST" "$STATE_PW"
    [ "$output" = "xfce-itest-pass-42" ]
    ! grep -q "GENERATED password" /tmp/xfce-install2.log
    run $TEST_SSH "root@$TEST_HOST" 'getent passwd guib | cut -d: -f1'
    [ "$output" = "guib" ]
}
