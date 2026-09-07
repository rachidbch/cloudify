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

# Remote shell helper: print the RDP parameters of the connection named GUI.
CONN_HOSTPORT='ds=$(curl -fsS -X POST http://127.0.0.1:8080/api/tokens --data-urlencode username=rbc --data-urlencode password=guac-itest-admin-pass1 | jq -r .dataSource); t=$(curl -fsS -X POST http://127.0.0.1:8080/api/tokens --data-urlencode username=rbc --data-urlencode password=guac-itest-admin-pass1 | jq -r .authToken); id=$(curl -fsS "http://127.0.0.1:8080/api/session/data/$ds/connections?token=$t" | jq -r --arg n GUI '\''to_entries[] | select(.value.name == $n) | .key'\''); curl -fsS "http://127.0.0.1:8080/api/session/data/$ds/connections/$id/parameters?token=$t" | jq -r '\''.hostname + ":" + .port'\'''

@test "cloudify --on $TEST_HOST install guacamole succeeds (docker dep + stack)" {
    run cloudify --no-defaults --on "$TEST_HOST" install guacamole
    [ "$status" -eq 0 ]
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
    [ "$status" -eq 0 ]
    local pg_before="$output"

    run cloudify --no-defaults --on "$TEST_HOST" install guacamole
    [ "$status" -eq 0 ]

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
