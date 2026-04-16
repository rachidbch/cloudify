#!/usr/bin/env bats
# Integration test: install digitalocean (doctl) package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package digitalocean succeeds" {
    run cloudify_install_package digitalocean
    [ "$status" -eq 0 ]
}

@test "doctl binary exists after install" {
    [ -x "/usr/local/bin/doctl" ]
}

@test "doctl binary runs" {
    command -v doctl
    run doctl version
    [ "$status" -eq 0 ]
}
