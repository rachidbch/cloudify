#!/usr/bin/env bash
# Common test helpers for cloudify bats tests

# Load bats libraries from /usr/lib/bats/ (Ubuntu 24.04 apt paths)
load '/usr/lib/bats/bats-assert/load'
load '/usr/lib/bats/bats-support/load'
load '/usr/lib/bats/bats-file/load'

# Setup a test environment with mock directories
setup_test_env() {
    # Create temp CLOUDIFY_DIR with mock pkg/inventory dirs
    export CLOUDIFY_TMP="$(mktemp -d /tmp/cloudify_test.XXXXXX)"
    export CLOUDIFY_DIR="$(mktemp -d /tmp/cloudify_dir_test.XXXXXX)"
    export CLOUDIFY_TEST_ORIG_DIR="$CLOUDIFY_DIR"

    # Create mock directories
    mkdir -p "$CLOUDIFY_DIR/pkg"
    mkdir -p "$CLOUDIFY_DIR/inventory"
    mkdir -p "$CLOUDIFY_TMP/backup"

    # Disable colors for test output
    export CLOUDIFY_DISABLE_COLORS=true

    # Skip credential prompts
    export CLOUDIFY_SKIPCREDENTIALS=true

    # Default settings
    export CLOUDIFY_IS_LOCAL=true
    export CLOUDIFY_LOCAL_BIN="$CLOUDIFY_TMP/.local/bin"
    mkdir -p "$CLOUDIFY_LOCAL_BIN"

    export CLOUDIFY_LOCAL_USER=testuser
    export CLOUDIFY_LOCAL_PWD=testpwd
    export CLOUDIFY_HOSTPWD=testpwd
    export CLOUDIFY_RECIPE_FILENAME=init.sh

    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/config"
    export CLOUDIFY_CREDENTIALS_FILE="$CLOUDIFY_CREDENTIALS_DIR/credentials"
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR"

    export CLOUDIFY_BOOTSTRAP_URL="https://gist.githubusercontent.com/rachidbch/2e10095b0042e784c557a15e2c804807/raw/3741c58d083f1463f6580e792f75ec227744a304/cloudify.sh"

    export DEBUG=false
    export CLOUDIFY_LOG_LEVEL=INFO

    # Set script dir to the real cloudify repo
    export CLOUDIFY_SCRIPT_DIR="/root/cloudify"
}

# Teardown the test environment
teardown_test_env() {
    rm -rf "$CLOUDIFY_TMP"
    rm -rf "$CLOUDIFY_DIR"
}

# Source the cloudify script (for integration tests)
# This makes all functions available without executing main()
source_cloudify() {
    # shellcheck disable=SC1090
    source "$CLOUDIFY_SCRIPT_DIR/cloudify" --source-only 2>/dev/null || true
}
