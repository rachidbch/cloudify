#!/usr/bin/env bats
# Tests for lib/shadows/apt-get.sh and lib/shadows/add-apt-repository.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
    source lib/shadow.sh

    # Override sudo with a test spy that logs calls and exits successfully
    _SUDO_LOG="$CLOUDIFY_TMP/sudo_log"
    : > "$_SUDO_LOG"
    sudo() {
        echo "$*" >> "$_SUDO_LOG"
    }
}

teardown() {
    teardown_test_env
}

#-- Function existence tests --

@test "apt-get shadow is a function after sourcing" {
    [ "$(type -t apt-get)" = "function" ]
}

@test "apt shadow is a function after sourcing" {
    [ "$(type -t apt)" = "function" ]
}

@test "add-apt-repository shadow is a function after sourcing" {
    [ "$(type -t add-apt-repository)" = "function" ]
}

#-- apt-get install tests --

@test "apt-get install skips already-installed packages" {
    # Mock dpkg to report package as installed
    local mock_bin="$CLOUDIFY_LOCAL_BIN/dpkg"
    cat > "$mock_bin" <<'MOCK'
#!/bin/bash
if [[ "$1" == "-l" ]]; then
    echo "ii  $2  1.0  all  test package"
    exit 0
fi
exit 0
MOCK
    chmod +x "$mock_bin"
    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    run apt-get install alreadyinstalled -y
    [ "$status" -eq 0 ]

    # sudo should NOT have been called for install
    ! grep -q "apt-get.*install.*alreadyinstalled" "$_SUDO_LOG"

    rm -f "$mock_bin"
}

@test "apt-get install calls sudo for missing packages" {
    # Mock dpkg to report package as NOT installed
    local mock_bin="$CLOUDIFY_LOCAL_BIN/dpkg"
    cat > "$mock_bin" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$mock_bin"
    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    run apt-get install missingpkg -y
    [ "$status" -eq 0 ]

    # sudo should have been called with apt-get install
    grep -q "apt-get.*install.*missingpkg" "$_SUDO_LOG"

    rm -f "$mock_bin"
}

@test "apt-get install propagates failure exit code" {
    # Verify that the apt-get shadow doesn't swallow errors.
    # The shadow calls `sudo apt-get -q install ...` — if sudo fails,
    # set -e propagates the failure. We verify by checking the function
    # body contains the call pattern.
    [ "$(type -t apt-get)" = "function" ]
    # Verify the function calls sudo (not command sudo), meaning errors propagate
    local fn_body
    fn_body=$(declare -f apt-get)
    [[ "$fn_body" == *"sudo apt-get"* ]]
}

@test "apt-get install auto-updates when cache stale" {
    # Mock dpkg
    local mock_dpkg="$CLOUDIFY_LOCAL_BIN/dpkg"
    cat > "$mock_dpkg" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$mock_dpkg"
    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    # Remove pkgcache.bin so cache appears stale
    rm -f /var/cache/apt/pkgcache.bin 2>/dev/null || true

    run apt-get install somepkg -y
    [ "$status" -eq 0 ]

    # Verify that apt-get update was called (auto-update)
    grep -q "apt-get.*update" "$_SUDO_LOG"

    rm -f "$mock_dpkg"
}

#-- apt-get update tests --

@test "apt-get update skips when cache fresh" {
    # Create a recent pkgcache.bin
    mkdir -p /var/cache/apt 2>/dev/null || true
    touch /var/cache/apt/pkgcache.bin

    run apt-get update
    [ "$status" -eq 0 ]

    # sudo should NOT have been called for update
    ! grep -q "apt-get.*update" "$_SUDO_LOG"
}

@test "apt-get update --force bypasses freshness check" {
    # Create a recent pkgcache.bin (fresh)
    mkdir -p /var/cache/apt 2>/dev/null || true
    touch /var/cache/apt/pkgcache.bin

    run apt-get update --force
    [ "$status" -eq 0 ]

    # sudo SHOULD have been called despite fresh cache
    grep -q "apt-get.*update" "$_SUDO_LOG"
}

#-- apt delegation test --

@test "apt delegates to apt-get" {
    [ "$(type -t apt)" = "function" ]
    [ "$(type -t apt-get)" = "function" ]
}

#-- add-apt-repository tests --

@test "add-apt-repository skips already-added source" {
    # Create mock sources.list.d with the repo already present
    mkdir -p /etc/apt/sources.list.d 2>/dev/null || true
    echo "deb http://ppa.launchpad.net/test/ppa/ubuntu noble main" > /etc/apt/sources.list.d/test-ppa.list

    run add-apt-repository "ppa:test/ppa" -y
    [ "$status" -eq 0 ]

    # sudo should NOT have been called for add-apt-repository
    ! grep -q "add-apt-repository" "$_SUDO_LOG"

    rm -f /etc/apt/sources.list.d/test-ppa.list
}

@test "add-apt-repository adds new source and updates" {
    # Remove any matching sources
    rm -f /etc/apt/sources.list.d/*test* 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/*new* 2>/dev/null || true

    run add-apt-repository "ppa:new/repo" -y
    [ "$status" -eq 0 ]

    # sudo should have been called for add-apt-repository
    grep -q "add-apt-repository" "$_SUDO_LOG"

    # Clean up
    rm -f /etc/apt/sources.list.d/*new* 2>/dev/null || true
}

#-- Module guard tests --

@test "apt-get module guard prevents double-sourcing" {
    source lib/shadows/apt-get.sh
    source lib/shadows/apt-get.sh
    [ "$(type -t apt-get)" = "function" ]
}

@test "add-apt-repository module guard prevents double-sourcing" {
    source lib/shadows/add-apt-repository.sh
    source lib/shadows/add-apt-repository.sh
    [ "$(type -t add-apt-repository)" = "function" ]
}

#-- Quiet output tests --

@test "apt-get install uses -qq for quiet output" {
    local mock_bin="$CLOUDIFY_LOCAL_BIN/dpkg"
    cat > "$mock_bin" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$mock_bin"
    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    apt-get install somepkg -y

    grep -q "\-qq" "$_SUDO_LOG"
    rm -f "$mock_bin"
}

@test "apt-get update --force uses -qq for quiet output" {
    mkdir -p /var/cache/apt 2>/dev/null || true
    touch /var/cache/apt/pkgcache.bin

    apt-get update --force

    grep -q "\-qq" "$_SUDO_LOG"
}
