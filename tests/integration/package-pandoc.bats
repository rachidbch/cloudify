#!/usr/bin/env bats
# Integration test: install pandoc package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package pandoc succeeds" {
    run cloudify_install_package pandoc
    [ "$status" -eq 0 ]
}

@test "pandoc binary exists after install" {
    command -v pandoc
}

@test "pandoc binary runs" {
    run pandoc --version
    [ "$status" -eq 0 ]
}
