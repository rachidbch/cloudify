#!/usr/bin/env bats
# Integration test: pkg/guacamole (split pkg, ADR-008) on a real host.
# Installs the Apache Guacamole stack (docker dep pulled first-run), asserts
# the webapp + admin API + RDP connection record, then proves FORCE reinstall
# and configure preserve the database (container not recreated, creds valid).
#
# Secret values are FIXED fixtures exported per-file (bats re-sources this
# file per test). They travel to the host via pkg .remote-vars (ADR-007), the
# same channel production uses. Defaults (bind 127.0.0.1:8080, dir
# /root/guacamole, admin rbc, connection GUI) are used on purpose: the test
# exercises the recipe defaults + only the .remote-vars names.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

export CLOUDIFY_GUACAMOLE_DB_PASSWORD='guac-itest-db-pass1'
export CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD='guac-itest-admin-pass1'
export CLOUDIFY_GUACAMOLE_RDP_PASSWORD='guac-itest-rdp-pass1'
export CLOUDIFY_GUACAMOLE_RDP_HOST='10.99.99.11'
export PKG_VERIFY_TIMEOUT=300

# After a snapshot restore the container needs time to boot + rejoin the
# tailnet; wait for ssh readiness before every test so the first install is
# not racing the boot window.
setup() {
    local i=0
    until $TEST_SSH "root@$TEST_HOST" 'true' >/dev/null 2>&1; do
        i=$((i + 1))
        ((i < 45)) || { echo "ssh to $TEST_HOST never came up" >&3; return 1; }
        sleep 2
    done
}

# Streaming runner for the heavy installs: no silent black box. Runs the
# command in the background, polls its log every 5s, and reports progress
# (elapsed + last line) to /tmp/guac-itest-progress.log and FD3. Fails fast
# and loudly on stall (no output for 90s) or after the 900s cap, so a slow
# install is distinguishable from a stuck one.
PROGRESS_FILE="/tmp/guac-itest-progress.log"
run_install() {
    local tag="$1"; shift
    local logf="/tmp/guac-${tag}.log"
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
            if [ "$idle" -ge 90 ]; then
                echo "[$tag STALLED - no output for 90s]" | tee -a "$PROGRESS_FILE" >&3
                tail -3 "$logf" | tee -a "$PROGRESS_FILE" >&3
                kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
                return 124
            fi
        fi
        if [ "$elapsed" -ge 900 ]; then
            echo "[$tag TIMEOUT after 900s]" | tee -a "$PROGRESS_FILE" >&3
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            return 124
        fi
    done
    wait "$pid"; rc=$?
    echo "[$tag done in ${elapsed}s, exit $rc]" | tee -a "$PROGRESS_FILE" >&3
    return "$rc"
}

# Remote shell helper: print the RDP parameters of the connection named GUI.
CONN_HOSTPORT='ds=$(curl -fsS -X POST http://127.0.0.1:8080/api/tokens --data-urlencode username=rbc --data-urlencode password=guac-itest-admin-pass1 | jq -r .dataSource); t=$(curl -fsS -X POST http://127.0.0.1:8080/api/tokens --data-urlencode username=rbc --data-urlencode password=guac-itest-admin-pass1 | jq -r .authToken); id=$(curl -fsS "http://127.0.0.1:8080/api/session/data/$ds/connections?token=$t" | jq -r --arg n GUI '\''to_entries[] | select(.value.name == $n) | .key'\''); curl -fsS "http://127.0.0.1:8080/api/session/data/$ds/connections/$id/parameters?token=$t" | jq -r '\''.hostname + ":" + .port'\'''

@test "cloudify --on $TEST_HOST install guacamole succeeds (docker dep + stack)" {
    run_install install cloudify --no-defaults --on "$TEST_HOST" install guacamole
    local rc=$?
    echo "install rc=$rc" >&3
    [ "$rc" -eq 0 ]
}

@test "webapp answers HTTP and .env is mode 600 on $TEST_HOST" {
    run $TEST_SSH "root@$TEST_HOST" 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/'
    [ "$output" = "200" ]
    run $TEST_SSH "root@$TEST_HOST" 'stat -c "%a" /root/guacamole/.env'
    [ "$output" = "600" ]
}

@test "admin API token works and connection record targets the fixture host" {
    run $TEST_SSH "root@$TEST_HOST" 'curl -fsS -X POST http://127.0.0.1:8080/api/tokens --data-urlencode username=rbc --data-urlencode password=guac-itest-admin-pass1 | jq -r ".authToken | length > 0"'
    [ "$output" = "true" ]
    run $TEST_SSH "root@$TEST_HOST" "$CONN_HOSTPORT"
    [ "$output" = "10.99.99.11:3389" ]
}

@test "FORCE reinstall preserves the database (postgres container not recreated, creds valid)" {
    run $TEST_SSH "root@$TEST_HOST" 'docker compose -f /root/guacamole/docker-compose.yml ps -q postgres'
    if [ "$status" -ne 0 ]; then echo "pg capture failed: $output" >&3; fi
    [ "$status" -eq 0 ]
    local pg_before="$output"

    run_install reinstall cloudify --no-defaults --on "$TEST_HOST" install guacamole
    local rc=$?
    echo "reinstall rc=$rc" >&3
    [ "$rc" -eq 0 ]

    run $TEST_SSH "root@$TEST_HOST" 'docker compose -f /root/guacamole/docker-compose.yml ps -q postgres'
    [ "$output" = "$pg_before" ]
    run $TEST_SSH "root@$TEST_HOST" "$CONN_HOSTPORT"
    [ "$output" = "10.99.99.11:3389" ]
}

@test "configure with a new RDP host updates the record without data loss" {
    export CLOUDIFY_GUACAMOLE_RDP_HOST='10.99.99.12'
    run cloudify --no-defaults --on "$TEST_HOST" configure guacamole
    [ "$status" -eq 0 ]

    run $TEST_SSH "root@$TEST_HOST" "$CONN_HOSTPORT"
    [ "$output" = "10.99.99.12:3389" ]
    # Admin credentials still valid => database survived the reconfigure.
    run $TEST_SSH "root@$TEST_HOST" 'curl -fsS -X POST http://127.0.0.1:8080/api/tokens --data-urlencode username=rbc --data-urlencode password=guac-itest-admin-pass1 | jq -r ".authToken | length > 0"'
    [ "$output" = "true" ]
}
