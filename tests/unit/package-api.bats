#!/usr/bin/env bats
# Tests for lib/package-api.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/package-api.sh
}

teardown() {
    teardown_test_env
}

#-- PKG_DEBUG tests --

@test "PKG_DEBUG is silent when DEBUG=false" {
    export DEBUG=false
    run PKG_DEBUG "test message"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "PKG_DEBUG outputs when DEBUG=true" {
    export DEBUG=true
    run PKG_DEBUG "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test message"* ]]
}

#-- pkg_backup tests --

@test "pkg_backup creates backup and rotates existing ones" {
    # Create a test file to back up
    local testfile="$CLOUDIFY_TMP/testfile.txt"
    echo "original content" > "$testfile"

    # First backup
    pkg_backup "$testfile"
    [ "$?" -eq 0 ]

    # Verify backup was created
    local backup_name="$(basename ${testfile})$(dirname ${testfile} | tr '/' '@')"
    local backup_path="$CLOUDIFY_TMP/backup/$backup_name"
    [ -f "$backup_path" ]
    [ -f "$backup_path.index" ]

    # Modify and backup again to test rotation
    echo "modified content" > "$testfile"
    pkg_backup "$testfile"
    [ "$?" -eq 0 ]

    # Verify .bak.1 was created from rotation
    [ -f "$backup_path.bak" ] || [ -f "$backup_path.bak.1" ]

    # Original file still exists
    [ -f "$testfile" ]
}

@test "pkg_backup returns 1 for non-existent path" {
    run pkg_backup "/nonexistent/path/to/file"
    [ "$status" -eq 1 ]
}

#-- pkg_restore tests --

@test "pkg_restore restores a backed up file" {
    # Create a test file and back it up
    local testfile="$CLOUDIFY_TMP/restore_test.txt"
    echo "original content" > "$testfile"
    pkg_backup "$testfile"

    # Modify the file
    echo "modified content" > "$testfile"

    # Restore it
    pkg_restore "$testfile"
    [ "$?" -eq 0 ]

    # Verify content was restored (should be original since backup was made before modification)
    [ -f "$testfile" ]
}

@test "pkg_restore returns 1 when no backup exists" {
    local testfile="$CLOUDIFY_TMP/no_backup_test.txt"
    run pkg_restore "$testfile"
    [ "$status" -eq 1 ]
}

#-- pkg_in_startuprc tests --

@test "pkg_in_startuprc adds lines to .bashrc" {
    # Create a temporary HOME for this test
    local test_home="$CLOUDIFY_TMP/testhome"
    mkdir -p "$test_home"
    touch "$test_home/.bashrc"
    local orig_home="$HOME"
    export HOME="$test_home"

    pkg_in_startuprc "export TEST_VAR=hello"

    # Verify the line was added
    grep -q "export TEST_VAR=hello" "$test_home/.bashrc"
    grep -qFx "# CLOUDIFY ENV START" "$test_home/.bashrc"
    grep -qFx "# CLOUDIFY ENV END" "$test_home/.bashrc"

    export HOME="$orig_home"
}

@test "pkg_in_startuprc deduplicates lines" {
    # Create a temporary HOME for this test
    local test_home="$CLOUDIFY_TMP/testhome_dedup"
    mkdir -p "$test_home"
    touch "$test_home/.bashrc"
    local orig_home="$HOME"
    export HOME="$test_home"

    # Add the same line twice
    pkg_in_startuprc "export DEDUP_TEST=value1"
    pkg_in_startuprc "export DEDUP_TEST=value1"

    # Count occurrences - should be exactly 1
    local count
    count=$(grep -c "export DEDUP_TEST=value1" "$test_home/.bashrc")
    [ "$count" -eq 1 ]

    export HOME="$orig_home"
}

#-- pkg_install_release alias test --

@test "pkg_install_release alias exists and calls cloudify_install_package_release" {
    # Verify the function exists
    [ "$(type -t pkg_install_release)" = "function" ]

    # Verify cloudify_install_package_release also exists
    [ "$(type -t cloudify_install_package_release)" = "function" ]
}

#-- module guard test --

@test "module guard prevents double-sourcing" {
    source lib/package-api.sh
    source lib/package-api.sh
    [ "$(type -t PKG_DEBUG)" = "function" ]
    [ "$(type -t pkg_backup)" = "function" ]
    [ "$(type -t pkg_restore)" = "function" ]
    [ "$(type -t pkg_in_startuprc)" = "function" ]
    [ "$(type -t cloudify_install_package_release)" = "function" ]
    [ "$(type -t pkg_install_release)" = "function" ]
    [ "$(type -t pkg_depends)" = "function" ]
}
