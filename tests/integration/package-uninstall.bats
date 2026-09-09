#!/usr/bin/env bats
# Integration: the uninstall action on a real host, and the remote verify action.
# fixture-uninstall: install.sh + uninstall.sh. fixture-legacy: no uninstall leg.

TEST_HOST="cloudify"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Timestamped rubric report (tests/helpers/report.bash)
source tests/helpers/report.bash

setup() {
    run $TEST_SSH "root@$TEST_HOST" 'rm -f /tmp/fixture-uninstall-log /tmp/fixture-uninstall-marker /tmp/fixture-legacy-log /tmp/fixture-legacy-marker'
}

@test "uninstall runs the package's uninstall.sh on a remote host" {
    rubric "uninstall runs the package uninstall leg"
    subrubric "install fixture-uninstall"
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-uninstall
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test -f /tmp/fixture-uninstall-marker'
    [ "$status" -eq 0 ]
    step "marker present after install"

    subrubric "uninstall fixture-uninstall"
    run cloudify --no-defaults --on "$TEST_HOST" uninstall fixture-uninstall
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'test ! -f /tmp/fixture-uninstall-marker'
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'grep -q UNINSTALL_RAN /tmp/fixture-uninstall-log'
    [ "$status" -eq 0 ]
    step "marker removed, UNINSTALL_RAN logged"
}

@test "uninstall refuses a package with no uninstall leg and changes nothing" {
    rubric "uninstall refuses a package with no uninstall leg"
    subrubric "install fixture-legacy (no uninstall.sh)"
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-legacy
    [ "$status" -eq 0 ]
    run $TEST_SSH "root@$TEST_HOST" 'touch /tmp/fixture-legacy-marker'

    subrubric "uninstall fixture-legacy must fail and change nothing"
    run cloudify --no-defaults --on "$TEST_HOST" uninstall fixture-legacy
    [ "$status" -ne 0 ]
    [[ "$output" == *"no uninstall.sh"* ]]
    run $TEST_SSH "root@$TEST_HOST" 'test -f /tmp/fixture-legacy-marker'
    [ "$status" -eq 0 ]
    step "refused, marker untouched"
}

@test "remote verify action verifies an installed package" {
    rubric "remote verify action"
    subrubric "install fixture-split"
    run cloudify --no-defaults --on "$TEST_HOST" install fixture-split
    [ "$status" -eq 0 ]

    subrubric "verify fixture-split on the host"
    run cloudify --no-defaults --on "$TEST_HOST" verify fixture-split
    [ "$status" -eq 0 ]
    step "verified"
}
