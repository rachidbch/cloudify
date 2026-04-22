#!/usr/bin/env bash
# Integration test helpers for cloudify bats tests
# Uses the REAL environment (real pkg/ directory, real lib modules)

# Load bats libraries from /usr/lib/bats/ (Ubuntu 24.04 apt paths)
load '/usr/lib/bats/bats-assert/load'
load '/usr/lib/bats/bats-support/load'
load '/usr/lib/bats/bats-file/load'

# Setup integration test environment pointing to the real cloudify repo
setup_integration_env() {
    # Point to the real cloudify repo in the container
    export CLOUDIFY_DIR="/root/cloudify"
    export CLOUDIFY_SCRIPT_DIR="/root/cloudify"
    export CLOUDIFY_TMP="$(mktemp -d /tmp/cloudify_int_test.XXXXXX)"
    mkdir -p "$CLOUDIFY_TMP/backup"

    # Disable colors for test output
    export CLOUDIFY_DISABLE_COLORS=true

    # Skip credential prompts
    export CLOUDIFY_SKIPCREDENTIALS=true

    # Set password for sudo (NOPASSWD is configured in container, but code expects a value)
    export CLOUDIFY_HOSTPWD="root"
    export CLOUDIFY_LOCAL_USER=root
    export CLOUDIFY_LOCAL_PWD=root

    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/config"
    export CLOUDIFY_CREDENTIALS_FILE="$CLOUDIFY_CREDENTIALS_DIR/credentials"
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR"

    # Default settings
    export CLOUDIFY_IS_LOCAL=true
    export CLOUDIFY_LOCAL_BIN="$CLOUDIFY_TMP/.local/bin"
    mkdir -p "$CLOUDIFY_LOCAL_BIN"

    export DEBUG=false

    # Recipe filename — must match the cloudify main script default
    export CLOUDIFY_RECIPE_FILENAME=init.sh

    # Bootstrap URL for remote execution
    export CLOUDIFY_BOOTSTRAP_URL="https://gist.githubusercontent.com/rachidbch/2e10095b0042e784c557a15e2c804807/raw/3741c58d083f1463f6580e792f75ec227744a304/cloudify.sh"

    # Source all lib modules
    source "$CLOUDIFY_SCRIPT_DIR/lib/colors.sh" && cloudify_setup_colors
    source "$CLOUDIFY_SCRIPT_DIR/lib/utils.sh"
    source "$CLOUDIFY_SCRIPT_DIR/lib/os.sh"
    source "$CLOUDIFY_SCRIPT_DIR/lib/package-api.sh"
    source "$CLOUDIFY_SCRIPT_DIR/lib/credentials.sh"
    source "$CLOUDIFY_SCRIPT_DIR/lib/shadow.sh"
    source "$CLOUDIFY_SCRIPT_DIR/lib/packages.sh"
}

# Teardown integration test environment
teardown_integration_env() {
    rm -rf "$CLOUDIFY_TMP"
}
