#!/usr/bin/env bats
# E2E for pkg .remote-vars (ADR-007): two concurrent installs of the same
# fixture pkg, each with its own K3S_TOKEN — each host must receive its own
# value. Regression guard: if values ever route through a shared on-disk file
# again, these two installs race and one host ends up with the other's token.

TEST_HOST="cloudify"
TEST_HOST2="cloudify2"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
FIXTURE_DIR="pkg/fixture-env"

setup_file() {
    # Second host: launched once per file, deleted at the end. The container
    # boots from GitHub master, so the fixture recipe is pushed in after the
    # bootstrap test below.
    if ! ivps list 2>/dev/null | grep -qw "$TEST_HOST2"; then
        cloudify launch "cloudai:$TEST_HOST2"
    fi
}

teardown_file() {
    if ivps list 2>/dev/null | grep -qw "$TEST_HOST2"; then
        ivps delete "cloudai:$TEST_HOST2"
    fi
}

@test "$TEST_HOST2 is a working cloudify host (bootstrap from master)" {
    # First remote call bootstraps the fresh container: clone cloudify from
    # GitHub (master), cloudify init, then install bat (a master recipe).
    run cloudify --no-defaults --on "$TEST_HOST2" install bat
    [ "$status" -eq 0 ]
}

@test "fixture-env recipe is pushed onto $TEST_HOST2" {
    run $TEST_SSH "root@$TEST_HOST2" "mkdir -p /root/cloudify/$FIXTURE_DIR"
    [ "$status" -eq 0 ]
    cat "$FIXTURE_DIR/init.sh" | $TEST_SSH "root@$TEST_HOST2" "cat > /root/cloudify/$FIXTURE_DIR/init.sh"
    run $TEST_SSH "root@$TEST_HOST2" "test -f /root/cloudify/$FIXTURE_DIR/init.sh"
    [ "$status" -eq 0 ]
}

@test "parallel installs forward each caller's own K3S_TOKEN" {
    local token_prod="token-prod-$(date +%s)"
    local token_dev="token-dev-$(date +%s)"

    # Two concurrent cloudify processes, one per host, each exporting its own
    # token. The whole point of .remote-vars: no shared file, so no race.
    ( K3S_TOKEN="$token_prod" cloudify --no-defaults --on "$TEST_HOST" install fixture-env \
        > /tmp/cloudify-par-prod.log 2>&1 ) &
    local p1=$!
    ( K3S_TOKEN="$token_dev" cloudify --no-defaults --on "$TEST_HOST2" install fixture-env \
        > /tmp/cloudify-par-dev.log 2>&1 ) &
    local p2=$!

    local rc1=0 rc2=0
    wait "$p1" || rc1=$?
    wait "$p2" || rc2=$?
    [ "$rc1" -eq 0 ] || cat /tmp/cloudify-par-prod.log
    [ "$rc2" -eq 0 ] || cat /tmp/cloudify-par-dev.log

    run $TEST_SSH "root@$TEST_HOST" 'cat /tmp/cloudify-env-forwarded'
    [ "$output" = "$token_prod" ]
    run $TEST_SSH "root@$TEST_HOST2" 'cat /tmp/cloudify-env-forwarded'
    [ "$output" = "$token_dev" ]
}
