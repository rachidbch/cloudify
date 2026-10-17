#!/usr/bin/env bats
# Real Guacamole lifecycle on the dedicated test host, inside the outer SSH run.
# Payload forwarding has separate transport/golden coverage; no self-SSH here.
source tests/helpers/report.bash

export CLOUDIFY_GUACAMOLE_DB_PASSWORD='guac-itest-db-pass1'
export CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD='guac-itest-admin-pass1'
export CLOUDIFY_GUACAMOLE_RDP_PASSWORD='guac-itest-rdp-pass1'
export CLOUDIFY_GUACAMOLE_RDP_HOST='10.99.99.11'
export PKG_VERIFY_TIMEOUT=300

setup_file() {
    rubric "check dedicated test host before mutation"
    [ "$(hostname -s)" = cloudify ]
    [ "$(id -u)" = 0 ]
    [ ! -e /root/guacamole ]
    local containers volumes
    containers=$(docker container ls -aq --filter label=com.docker.compose.project=guacamole) || return 1
    volumes=$(docker volume ls -q --filter label=com.docker.compose.project=guacamole) || return 1
    [ -z "$containers" ]
    [ -z "$volumes" ]
    export CLOUDIFY_DIR="$PWD"
    export PATH="$CLOUDIFY_DIR:$PATH"
    export CLOUDIFY_SKIPCREDENTIALS=true
    export CLOUDIFY_LOCAL_USER=root CLOUDIFY_LOCAL_PWD=dummy
    export CLOUDIFY_DEVELOPMENT_OVERRIDE=1
    export CLOUDIFY_FORCE_UPDATE=true
    export CLOUDIFY_GITHUBUSER=none CLOUDIFY_GITHUBPWD=none
    export CLOUDIFY_GITLABUSER=none CLOUDIFY_GITLABPWD=none
    export XDG_CONFIG_HOME="$BATS_FILE_TMPDIR/config"
    export XDG_STATE_HOME="$BATS_FILE_TMPDIR/state"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
}

base_url() {
    (
        # shellcheck disable=SC1091 # Created by the recipe on the test host.
        . /root/guacamole/.env
        printf 'http://%s:%s' "${GUACAMOLE_BIND:-127.0.0.1}" "${GUACAMOLE_PORT:-8080}"
    )
}

admin_auth() {
    curl -fsS -X POST "$(base_url)/api/tokens" \
        --data-urlencode username=guacadmin --data-urlencode password=guac-itest-admin-pass1
}

admin_ok() { admin_auth | jq -r '.authToken | length > 0'; }

http_status() { curl -s -o /dev/null -w '%{http_code}' "$(base_url)/"; }

conn_hostport() {
    local auth ds token id base
    base=$(base_url)
    auth=$(admin_auth)
    ds=$(jq -r .dataSource <<< "$auth")
    token=$(jq -r .authToken <<< "$auth")
    id=$(curl -fsS "$base/api/session/data/$ds/connections?token=$token" \
        | jq -r --arg n GUI 'to_entries[] | select(.value.name == $n) | .key')
    curl -fsS "$base/api/session/data/$ds/connections/$id/parameters?token=$token" \
        | jq -r '.hostname + ":" + .port'
}

# Stream every product line, without polling, filtering, or killing mutations.
run_stream() {
    step "$1"
    shift
    if [[ -e /dev/fd/9 ]]; then "$@" >&9 2>&1; else "$@"; fi
}

@test "install provisions and configures the stack" {
    rubric "install provisions and configures the stack"
    run_stream install cloudify --no-defaults install guacamole
    step "install returned 0"
}

@test "webapp answers HTTP and .env is mode 600" {
    rubric "webapp answers and .env is private"
    run http_status
    [[ "$output" =~ ^[23] ]]
    run stat -c '%a' /root/guacamole/.env
    [ "$output" = 600 ]
}

@test "admin guacadmin gets a token and the connection targets the fixture host" {
    rubric "admin default guacadmin works and the RDP record is right"
    run admin_ok
    [ "$status" -eq 0 ]
    [ "$output" = true ]
    run conn_hostport
    [ "$status" -eq 0 ]
    [ "$output" = '10.99.99.11:3389' ]
}

@test "configure converges a changed DB password (auth still works)" {
    rubric "configure converges a changed DB password"
    export CLOUDIFY_GUACAMOLE_DB_PASSWORD='guac-itest-db-pass2'
    run_stream reconfigure cloudify --no-defaults configure guacamole
    run http_status
    [[ "$output" =~ ^[23] ]]
    run admin_ok
    [ "$status" -eq 0 ]
    [ "$output" = true ]
}

@test "FORCE reinstall preserves the database" {
    rubric "FORCE reinstall preserves the database"
    run admin_ok
    [ "$status" -eq 0 ]
    [ "$output" = true ]
    run_stream reinstall cloudify --no-defaults install guacamole
    run admin_ok
    [ "$status" -eq 0 ]
    [ "$output" = true ]
    run conn_hostport
    [ "$status" -eq 0 ]
    [ "$output" = '10.99.99.11:3389' ]
}

@test "uninstall tears down the stack, the volume and the project dir" {
    rubric "uninstall tears down completely"
    run_stream uninstall cloudify --no-defaults uninstall guacamole
    [ ! -d /root/guacamole ]
    local volumes
    volumes=$(docker volume ls -q --filter label=com.docker.compose.project=guacamole) || return 1
    [ -z "$volumes" ]
}

@test "verify fails after uninstall" {
    rubric "verify fails after uninstall"
    run env PKG_VERIFY_TIMEOUT=5 cloudify --no-defaults verify guacamole
    [ "$status" -ne 0 ]
}
