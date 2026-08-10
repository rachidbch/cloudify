#!/usr/bin/env bats
# Integration tests for install/run split (ADR-008) on a real host.
# fixture-split: install.sh + configure.sh + verify.sh.
# fixture-legacy: init.sh only — must install exactly as before the split.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

setup() {
    # Fresh markers per test (fixture recipes append)
    run $TEST_SSH "root@$TEST_HOST" 'rm -f /tmp/fixture-split-log /tmp/fixture-split-installed /tmp/fixture-legacy-log'
}

@test "install of a split pkg runs install.sh then configure.sh" {
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'cat /tmp/fixture-split-log'
    [[ "$output" == *"INSTALL_RAN"* ]]
    [[ "$output" == *"CONFIGURE_RAN"* ]]
}

@test "re-install (explicit, FORCE) re-runs install.sh + configure.sh" {
    # Explicit installs set FORCE (ADR-003) — re-install is intentional and
    # re-runs both phases; configure.sh always re-runs either way.
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'cat /tmp/fixture-split-log'
    [ "$(echo "$output" | grep -c INSTALL_RAN)" -eq 2 ]
    [ "$(echo "$output" | grep -c CONFIGURE_RAN)" -eq 2 ]
}

@test "configure runs only configure.sh (no install phase, no re-download)" {
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]
    run cloudify --no-defaults --on "$TEST_HOST" configure fixture-split
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'cat /tmp/fixture-split-log'
    [[ "$output" == *"INSTALL_RAN"* ]]
    [[ "$output" == *"CONFIGURE_RAN"* ]]
    # exactly one INSTALL_RAN: configure did NOT re-run the install phase
    [ "$(echo "$output" | grep -c INSTALL_RAN)" -eq 1 ]
    [ "$(echo "$output" | grep -c CONFIGURE_RAN)" -eq 2 ]
}

@test "configure forwards caller env vars to the run phase" {
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]
    run env K3S_TOKEN=rotated-token cloudify --no-defaults --on "$TEST_HOST" configure fixture-split
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'tail -1 /tmp/fixture-split-log'
    [[ "$output" == *"rotated-token"* ]]
}

@test "verify-hook runs after configure (a verify failure fails the configure)" {
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]
    # Break what verify checks (install marker gone) — configure.sh still runs
    # and writes CONFIGURE_RAN, but the post-configure verify hook must fail it.
    run $TEST_SSH "root@$TEST_HOST" 'rm -f /tmp/fixture-split-log /tmp/fixture-split-installed'
    run cloudify --no-defaults --on "$TEST_HOST" configure fixture-split
    [ "$status" -ne 0 ]
}

@test "configure on a non-split pkg errors clearly" {
    run cloudify --no-defaults --on "$TEST_HOST" configure bat
    [ "$status" -ne 0 ]
    [[ "$output" == *"no configure.sh"* ]]
}

@test "init-only pkg installs exactly as before the split (no configure phase)" {
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-legacy
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'cat /tmp/fixture-legacy-log'
    [[ "$output" == *"LEGACY_INIT_RAN"* ]]
    run $TEST_SSH "root@$TEST_HOST" 'test ! -f /tmp/fixture-split-log'
    [ "$status" -eq 0 ]
}
