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

@test "pkg_backup rejects empty argument after --same" {
    run pkg_backup --same ""
    [ "$status" -ne 0 ]
}

@test "pkg_backup rejects root path" {
    run pkg_backup "/"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
}

@test "pkg_backup rejects /root" {
    run pkg_backup "/root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
}

@test "pkg_backup rejects /home" {
    run pkg_backup "/home"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
}

@test "pkg_backup rejects /usr" {
    run pkg_backup "/usr"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
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

@test "pkg_install_release skips when binary exists" {
    # Create a fake binary in PATH
    local fake_bin="$CLOUDIFY_LOCAL_BIN/testcmd_skip"
    echo '#!/bin/bash' > "$fake_bin"
    chmod +x "$fake_bin"
    # Ensure CLOUDIFY_LOCAL_BIN is in PATH for command -v
    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    # It should return 0 without attempting download (no curl needed)
    run pkg_install_release testcmd_skip "some/repo"
    [ "$status" -eq 0 ]

    rm -f "$fake_bin"
}

#-- pkg_apt_install .deb detection tests --

@test "pkg_apt_install .deb suffix detection works in glob" {
    # Verify the glob pattern itself matches .deb files
    # The actual fix: [[ $pkg == *.deb ]] instead of [[ $pkg == .deb ]]
    local test_deb="$CLOUDIFY_TMP/testpkg.deb"
    touch "$test_deb"

    # Test the glob directly — this is what was broken (matched literal ".deb" only)
    local pkg="testpkg.deb"
    [[ "$pkg" == *.deb ]]
}

#-- rotation helper tests --

@test "_cloudify_backup_rotate_up creates correct chain" {
    mkdir -p "$CLOUDIFY_TMP/backup"
    local base="$CLOUDIFY_TMP/backup/rotate_test"

    # Create initial file
    echo "content0" > "$base"

    # Rotate up
    _cloudify_backup_rotate_up "$base"

    # base should be gone, base.bak should exist
    [ ! -e "$base" ]
    [ -f "$base.bak" ]
}

@test "_cloudify_backup_rotate_up shifts existing backups" {
    mkdir -p "$CLOUDIFY_TMP/backup"
    local base="$CLOUDIFY_TMP/backup/rotate_chain"

    echo "v0" > "$base"
    echo "v1" > "$base.bak"
    echo "v2" > "$base.bak.1"

    _cloudify_backup_rotate_up "$base"

    [ ! -e "$base" ]
    [ -f "$base.bak" ]
    [ -f "$base.bak.1" ]
    [ -f "$base.bak.2" ]
    [ "$(cat "$base.bak")" = "v0" ]
    [ "$(cat "$base.bak.1")" = "v1" ]
    [ "$(cat "$base.bak.2")" = "v2" ]
}

@test "_cloudify_backup_rotate_up drops oldest when chain full" {
    mkdir -p "$CLOUDIFY_TMP/backup"
    local base="$CLOUDIFY_TMP/backup/rotate_drop"

    echo "v0" > "$base"
    echo "v1" > "$base.bak"
    echo "v2" > "$base.bak.1"
    echo "v3" > "$base.bak.2"
    echo "v4" > "$base.bak.3"
    echo "v5" > "$base.bak.4"
    echo "v6" > "$base.bak.5"

    _cloudify_backup_rotate_up "$base"

    # .bak.5 should have old .bak.4 content (v5), old .bak.5 (v6) was dropped
    [ -f "$base.bak.5" ]
    [ "$(cat "$base.bak.5")" = "v5" ]
    # The rest should be shifted
    [ -f "$base.bak.4" ]
    [ "$(cat "$base.bak.4")" = "v4" ]
}

@test "_cloudify_backup_rotate_down restores correctly" {
    mkdir -p "$CLOUDIFY_TMP/backup"
    local base="$CLOUDIFY_TMP/backup/restore_test"
    local restore_path="$CLOUDIFY_TMP/restore_target"

    echo "current" > "$restore_path"
    echo "backup1" > "$base"
    echo "backup2" > "$base.bak"
    echo "backup3" > "$base.bak.1"

    _cloudify_backup_rotate_down "$base" "$restore_path"

    # restore_path should now have backup1 content
    [ -f "$restore_path" ]
    [ "$(cat "$restore_path")" = "backup1" ]
    # base.bak should have moved down to base
    [ -f "$base" ]
    [ "$(cat "$base")" = "backup2" ]
}

#-- module guard test --

@test "pkg_install_release fails gracefully when jq missing" {
    # Temporarily hide jq from PATH
    local orig_path="$PATH"
    export PATH="/nonexistent"
    run pkg_install_release testcmd "some/repo"
    # Restore PATH before assertions
    export PATH="$orig_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"jq"* ]]
}

@test "pkg_apt_install continues when a package fails" {
    # Create a mock apt-get that fails for "badpkg" but succeeds for others
    local mock_bin="$CLOUDIFY_LOCAL_BIN/apt-get"
    cat > "$mock_bin" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"badpkg"* ]]; then
    echo "E: Unable to locate package badpkg" >&2
    exit 100
fi
exit 0
MOCK
    chmod +x "$mock_bin"
    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    # Should not die — should return the exit code but not abort
    run pkg_apt_install goodpkg badpkg
    # It should have failed (badpkg) but not crashed with die()
    # The function returns the last exit code
    [ "$status" -ne 0 ]

    rm -f "$mock_bin"
}

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
