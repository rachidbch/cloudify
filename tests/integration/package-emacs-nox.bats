#!/usr/bin/env bats
# Integration test: install emacs-nox package (apt path)
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_install_package emacs-nox succeeds" {
    run cloudify_install_package emacs-nox
    [ "$status" -eq 0 ]
}

@test "emacs binary exists after install" {
    command -v emacs
}

@test "emacs binary runs" {
    run emacs --version
    [ "$status" -eq 0 ]
}
