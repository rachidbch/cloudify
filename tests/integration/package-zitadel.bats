#!/usr/bin/env bats
# Integration: pkg/zitadel (split pkg, ADR-008) on a real host.
# Lifecycle: install provisions the official v4 stack (external-TLS mode,
# traefik edge), configure converges, uninstall tears down volumes + dir.
# Local probes go through traefik, so every curl carries the routed Host.
# The domain fixture never resolves anywhere - Host-based routing only.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Timestamped rubric report (tests/helpers/report.bash)
source tests/helpers/report.bash

export CLOUDIFY_ZITADEL_DOMAIN='zitadel.itest.ts.net'
export CLOUDIFY_ZITADEL_PORT='8443'
export PKG_VERIFY_TIMEOUT=600

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

# Domain/port from the deployed .env (config, not test constants).
domain() {
    $TEST_SSH "root@$TEST_HOST" 'set -a; . /root/zitadel/.env 2>/dev/null; echo "${CLOUDIFY_ZITADEL_DOMAIN:-}"'
}
port() {
    $TEST_SSH "root@$TEST_HOST" 'set -a; . /root/zitadel/.env 2>/dev/null; echo "${CLOUDIFY_ZITADEL_PORT:-8080}"'
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
    subrubric "cloudify --on $TEST_HOST install zitadel (first run pulls images + runs migrations)"
    run_stream install cloudify --no-defaults --on "$TEST_HOST" install zitadel
    local rc=$?
    [ "$rc" -eq 0 ]
    step "install returned 0"
}

@test "ready + login healthy through traefik, .env is mode 600" {
    rubric "stack answers locally through traefik"
    local dom prt
    dom="$(domain)"
    prt="$(port)"
    step "domain: $dom port: $prt"
    [ -n "$dom" ]

    run $TEST_SSH "root@$TEST_HOST" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $dom' http://127.0.0.1:$prt/debug/ready"
    step "ready code: [$output]"
    [ "$output" = "200" ]

    run $TEST_SSH "root@$TEST_HOST" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $dom' http://127.0.0.1:$prt/ui/v2/login/healthy"
    step "login healthy code: [$output]"
    [ "$output" = "200" ]

    run $TEST_SSH "root@$TEST_HOST" 'stat -c "%a" /root/zitadel/.env /root/zitadel/bootstrap.pat | sort -u | tr "\n" " "'
    step "modes: [$output]"
    [ "${output// /}" = "600" ]
}

@test "bootstrap PAT authenticates against the Mgmt API" {
    rubric "bootstrap PAT is an IAM_OWNER credential"
    local dom prt
    dom="$(domain)"
    prt="$(port)"
    run $TEST_SSH "root@$TEST_HOST" "PAT=\$(cat /root/zitadel/bootstrap.pat); curl -fsS -H 'Host: $dom' -H \"Authorization: Bearer \$PAT\" http://127.0.0.1:$prt/management/v1/iam | jq -r '.iamProjectId | length > 0'"
    step "mgmt check: [$output]"
    [ "$output" = "true" ]
}

@test "configure converges idempotently (stack stays healthy)" {
    rubric "configure rerun is safe"
    run_stream reconfigure cloudify --no-defaults --on "$TEST_HOST" configure zitadel
    local rc=$?
    [ "$rc" -eq 0 ]

    local dom prt
    dom="$(domain)"
    prt="$(port)"
    run $TEST_SSH "root@$TEST_HOST" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $dom' http://127.0.0.1:$prt/debug/ready"
    step "ready code after configure: [$output]"
    [ "$output" = "200" ]
}

@test "reinstall while running skips (idempotent guard, data preserved)" {
    rubric "install guard skips a running stack"
    run_stream reinstall cloudify --no-defaults --on "$TEST_HOST" install zitadel
    local rc=$?
    [ "$rc" -eq 0 ]

    local dom prt
    dom="$(domain)"
    prt="$(port)"
    run $TEST_SSH "root@$TEST_HOST" "PAT=\$(cat /root/zitadel/bootstrap.pat); curl -fsS -H 'Host: $dom' -H \"Authorization: Bearer \$PAT\" http://127.0.0.1:$prt/management/v1/iam | jq -r '.iamProjectId | length > 0'"
    step "PAT still valid: [$output]"
    [ "$output" = "true" ]
}

@test "verify passes against the running stack" {
    rubric "cloudify verify is green"
    run_stream verify cloudify --no-defaults --on "$TEST_HOST" verify zitadel
    local rc=$?
    [ "$rc" -eq 0 ]
}

@test "uninstall tears down the stack, the volumes and the project dir" {
    rubric "uninstall tears down completely"
    run_stream uninstall cloudify --no-defaults --on "$TEST_HOST" uninstall zitadel
    local rc=$?
    [ "$rc" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test ! -d /root/zitadel'
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test -z "$(docker volume ls -q --filter name=zitadel)"'
    [ "$status" -eq 0 ]
    step "dir and volumes gone"
}

@test "verify fails after uninstall" {
    rubric "verify fails after uninstall"
    run env PKG_VERIFY_TIMEOUT=5 cloudify --no-defaults --on "$TEST_HOST" verify zitadel
    [ "$status" -ne 0 ]
    step "verify correctly failed"
}
