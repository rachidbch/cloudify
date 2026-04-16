#!/usr/bin/env bats
# Tests for lib/colors.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "cloudify_setup_colors is defined after sourcing colors.sh" {
    source lib/colors.sh
    [ "$(type -t cloudify_setup_colors)" = "function" ]
}

@test "colors are empty when CLOUDIFY_DISABLE_COLORS is true" {
    export CLOUDIFY_DISABLE_COLORS=true
    source lib/colors.sh
    cloudify_setup_colors
    [ -z "$RESET" ]
    [ -z "$RED" ]
    [ -z "$GREEN" ]
}

@test "colors are set when terminal is available and colors enabled" {
    export CLOUDIFY_DISABLE_COLORS=false
    export CLOUDIFY_FORCE_COLORS=true
    source lib/colors.sh
    cloudify_setup_colors
    [ "$RESET" = '\033[0m' ]
    [ "$RED" = '\033[0;31m' ]
    [ "$GREEN" = '\033[0;32m' ]
}

@test "colors are empty in dumb terminal" {
    export CLOUDIFY_DISABLE_COLORS=false
    export CLOUDIFY_FORCE_COLORS=false
    export TERM=dumb
    source lib/colors.sh
    cloudify_setup_colors
    [ -z "$RESET" ]
    [ -z "$RED" ]
}

@test "module guard prevents double-sourcing" {
    source lib/colors.sh
    source lib/colors.sh
    [ "$(type -t cloudify_setup_colors)" = "function" ]
}
