#!/usr/bin/env bats
# Tests for lib/packages.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/package-api.sh
    source lib/packages.sh
}

teardown() {
    teardown_test_env
}

# Helper: create a mock package directory with optional tags/hashtag files
# Usage: create_mock_pkg <name> [tag_or_hashtag...]
# e.g. create_mock_pkg testpkg @default #linux
create_mock_pkg() {
    local pkgname="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkgname"
    for tag in "$@"; do
        touch "$CLOUDIFY_DIR/pkg/$pkgname/$tag"
    done
}

@test "cloudify_is_package returns 0 for existing package" {
    create_mock_pkg testpkg
    cloudify_is_package testpkg
    [ "$?" -eq 0 ]
}

@test "cloudify_is_package returns empty stdout for missing package" {
    # ls error goes to stderr; stdout is empty (no package found).
    [ -z "$(cloudify_is_package nonexistentpkg 2>/dev/null)" ]
}

@test "cloudify_package_has_recipe returns 0 when init.sh exists" {
    create_mock_pkg testpkg
    touch "$CLOUDIFY_DIR/pkg/testpkg/init.sh"
    cloudify_package_has_recipe testpkg
    [ "$?" -eq 0 ]
}

@test "cloudify_package_has_recipe returns 1 when no recipe" {
    create_mock_pkg testpkg
    run cloudify_package_has_recipe testpkg
    [ "$status" -ne 0 ]
}

@test "cloudify_package_recipe_path returns correct specific path" {
    create_mock_pkg testpkg
    local os
    os=$(cloudify_osdetect --os)
    # Create the os-specific init file
    touch "$CLOUDIFY_DIR/pkg/testpkg/${os}.init.sh"

    run cloudify_package_recipe_path testpkg
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/testpkg/${os}.init.sh" ]
}

@test "cloudify_package_recipe_path returns simpler path when only that exists" {
    create_mock_pkg testpkg
    # Only create the generic init.sh (no os/distro/version specific ones)
    touch "$CLOUDIFY_DIR/pkg/testpkg/init.sh"

    run cloudify_package_recipe_path testpkg
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/testpkg/init.sh" ]
}

@test "cloudify_package_recipe_path returns distro.os path when only that exists" {
    create_mock_pkg testpkg
    local os distro
    os=$(cloudify_osdetect --os)
    distro=$(cloudify_osdetect --distro)
    # Only create distro.os init, not version.distro.os
    touch "$CLOUDIFY_DIR/pkg/testpkg/${distro}.${os}.init.sh"

    run cloudify_package_recipe_path testpkg
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/pkg/testpkg/${distro}.${os}.init.sh" ]
}

@test "cloudify_list_packages_by_tags returns all packages when no tags given" {
    create_mock_pkg testpkg
    create_mock_pkg anotherpkg

    run cloudify_list_packages_by_tags
    [ "$status" -eq 0 ]
    [[ "$output" == *"testpkg"* ]]
    [[ "$output" == *"anotherpkg"* ]]
}

@test "cloudify_list_default_packages lists default tagged packages" {
    local os
    os=$(cloudify_osdetect --os)
    create_mock_pkg testpkg @default "#${os}"
    create_mock_pkg anotherpkg @default "#${os}"
    create_mock_pkg nondefault "#${os}"

    run cloudify_list_default_packages
    [ "$status" -eq 0 ]
    [[ "$output" == *"testpkg"* ]]
    [[ "$output" == *"anotherpkg"* ]]
    [[ "$output" != *"nondefault"* ]]
}

@test "module guard prevents double-sourcing" {
    source lib/packages.sh
    source lib/packages.sh
    [ "$(type -t cloudify_is_package)" = "function" ]
}
