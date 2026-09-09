#!/usr/bin/env bats
# Integration: pkg/guacamole (split pkg, ADR-008) on a real host.
# Lifecycle: install provisions, configure configures (incl. DB credential
# convergence), uninstall tears down. Admin default is guacadmin (trap 7).
# Secrets are fixed fixtures exported per-file and forwarded via .remote-vars.
# The webapp bind comes from config (operator pkgs yaml or recipe default), so
# every HTTP call derives its base URL from the on-disk .env, like verify does.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Timestamped rubric report (tests/helpers/report.bash)
source tests/helpers/report.bash

export CLOUDIFY_GUACAMOLE_DB_PASSWORD='guac-itest-db-pass1'
export CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD='guac-itest-admin-pass1'
export CLOUDIFY_GUACAMOLE_RDP_PASSWORD='guac-itest-rdp-pass1'
export CLOUDIFY_GUACAMOLE_RDP_HOST='10.99.99.11'
export PKG_VERIFY_TIMEOUT=300

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

# Base URL from the deployed .env (bind/port are config, not test constants).
base_url() {
    $TEST_SSH "root@$TEST_HOST" 'set -a; . /root/guacamole/.env 2>/dev/null; echo "http://${GUACAMOLE_BIND:-127.0.0.1}:${GUACAMOLE_PORT:-8080}"'
}

# Print "host:port" of the RDP connection named GUI via the REST API.
conn_hostport() {
    local base="$1"
    $TEST_SSH "root@$TEST_HOST" "BASE='$base' bash -s" <<'EOS'
ds=$(curl -fsS -X POST "$BASE/api/tokens" --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1 | jq -r .dataSource)
t=$(curl -fsS -X POST "$BASE/api/tokens" --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1 | jq -r .authToken)
id=$(curl -fsS "$BASE/api/session/data/$ds/connections?token=$t" | jq -r --arg n GUI 'to_entries[] | select(.value.name == $n) | .key')
curl -fsS "$BASE/api/session/data/$ds/connections/$id/parameters?token=$t" | jq -r '.hostname + ":" + .port'
EOS
}

# Run a long command in the background, stream its last line as a report step
# (fd 9 = live), fail loudly on stall (300s, covers image pulls) or after 1800s.
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
        if [ "$elapsed" -ge 1800 ]; then
            step "[$tag TIMEOUT after 1800s]"
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

@test "install provisions and configures the stack" {
    rubric "install provisions and configures the stack"
    subrubric "cloudify --on $TEST_HOST install guacamole (first run pulls images)"
    run_stream install cloudify --no-defaults --on "$TEST_HOST" install guacamole
    local rc=$?
    [ "$rc" -eq 0 ]
    step "install returned 0"
}

@test "webapp answers HTTP and .env is mode 600" {
    rubric "webapp answers and .env is private"
    local base
    base="$(base_url)"
    step "base url: $base"
    run $TEST_SSH "root@$TEST_HOST" "curl -s -o /dev/null -w '%{http_code}' '$base/'"
    step "http code: [$output]"
    [[ "$output" =~ ^[23] ]]
    run $TEST_SSH "root@$TEST_HOST" 'stat -c "%a" /root/guacamole/.env'
    [ "$output" = "600" ]
    step ".env 600"
}

@test "admin guacadmin gets a token and the connection targets the fixture host" {
    rubric "admin default guacadmin works and the RDP record is right"
    local base
    base="$(base_url)"
    run $TEST_SSH "root@$TEST_HOST" "curl -fsS -X POST '$base/api/tokens' --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1 | jq -r '.authToken | length > 0'"
    step "token check: [$output]"
    [ "$output" = "true" ]
    step "admin token ok"
    run conn_hostport "$base"
    [ "$output" = "10.99.99.11:3389" ]
    step "connection targets 10.99.99.11:3389"
}

@test "configure converges a changed DB password (auth still works)" {
    rubric "configure converges a changed DB password"
    subrubric "change CLOUDIFY_GUACAMOLE_DB_PASSWORD and configure"
    export CLOUDIFY_GUACAMOLE_DB_PASSWORD='guac-itest-db-pass2'
    run_stream reconfigure cloudify --no-defaults --on "$TEST_HOST" configure guacamole
    local rc=$?
    [ "$rc" -eq 0 ]

    subrubric "webapp + admin still work after convergence"
    local base
    base="$(base_url)"
    run $TEST_SSH "root@$TEST_HOST" "curl -s -o /dev/null -w '%{http_code}' '$base/'"
    step "http code: [$output]"
    [[ "$output" =~ ^[23] ]]
    run $TEST_SSH "root@$TEST_HOST" "curl -fsS -X POST '$base/api/tokens' --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1 | jq -r '.authToken | length > 0'"
    [ "$output" = "true" ]
    step "auth survived the DB password change"
}

@test "FORCE reinstall preserves the database" {
    rubric "FORCE reinstall preserves the database"
    local base
    base="$(base_url)"
    run $TEST_SSH "root@$TEST_HOST" "curl -fsS -X POST '$base/api/tokens' --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1 | jq -r '.authToken | length > 0'"
    [ "$output" = "true" ]

    run_stream reinstall cloudify --no-defaults --on "$TEST_HOST" install guacamole
    local rc=$?
    [ "$rc" -eq 0 ]

    subrubric "data survived: admin login and connection still work"
    base="$(base_url)"
    run $TEST_SSH "root@$TEST_HOST" "curl -fsS -X POST '$base/api/tokens' --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1 | jq -r '.authToken | length > 0'"
    [ "$output" = "true" ]
    run conn_hostport "$base"
    [ "$output" = "10.99.99.11:3389" ]
    step "admin + connection intact after FORCE reinstall"
}

@test "uninstall tears down the stack, the volume and the project dir" {
    rubric "uninstall tears down completely"
    run_stream uninstall cloudify --no-defaults --on "$TEST_HOST" uninstall guacamole
    local rc=$?
    [ "$rc" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test ! -d /root/guacamole'
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test -z "$(docker volume ls -q --filter name=guacamole)"'
    [ "$status" -eq 0 ]
    step "dir and volume gone"
}

@test "verify fails after uninstall" {
    rubric "verify fails after uninstall"
    # Short timeout: the stack is gone, no point retrying for 300s.
    run env PKG_VERIFY_TIMEOUT=5 cloudify --no-defaults --on "$TEST_HOST" verify guacamole
    [ "$status" -ne 0 ]
    step "verify correctly failed"
}
