#!/usr/bin/env bats
# Integration test: install bat package (GitHub release path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package bat succeeds" {
    # bat package uses pkg_install_release from GitHub
    run cloudify_install_package bat
    [ "$status" -eq 0 ]
}

@test "bat binary exists after install" {
    [ -x "/usr/local/bin/bat" ] || [ -x "/usr/bin/bat" ]
}

@test "bat binary runs" {
    command -v bat
    run bat --version
    [ "$status" -eq 0 ]
}
