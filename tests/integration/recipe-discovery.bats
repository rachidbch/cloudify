#!/usr/bin/env bats
# Integration tests for recipe discovery — proves the init.sh bug
# bats test_tags=integration

setup() {
    source tests/helpers/integration.bash
    setup_integration_env
}

teardown() {
    teardown_integration_env
}

@test "cloudify_package_has_recipe finds recipe for basics package" {
    run cloudify_package_has_recipe basics
    [ "$status" -eq 0 ]
}

@test "cloudify_package_has_recipe finds recipe for bat package" {
    run cloudify_package_has_recipe bat
    [ "$status" -eq 0 ]
}

@test "cloudify_package_recipe_path returns correct path for basics" {
    run cloudify_package_recipe_path basics
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/basics/init.sh" ]
}

@test "cloudify_package_recipe_path returns correct path for bat" {
    run cloudify_package_recipe_path bat
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/bat/init.sh" ]
}

@test "cloudify_is_package finds real basics package" {
    run cloudify_is_package basics
    [ "$status" -eq 0 ]
    [ "$output" = "basics" ]
}

@test "cloudify_is_package finds real bat package" {
    run cloudify_is_package bat
    [ "$status" -eq 0 ]
    [ "$output" = "bat" ]
}
