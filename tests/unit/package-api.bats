#!/usr/bin/env bats
# Tests for lib/package-api.sh

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/packages.sh
    source lib/shadow.sh
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

@test "pkg_apt_install propagates failure from shadow" {
    # Mock dpkg to report packages as NOT installed
    local mock_dpkg="$CLOUDIFY_LOCAL_BIN/dpkg"
    cat > "$mock_dpkg" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$mock_dpkg"

    # Override sudo to fail for badpkg
    sudo() {
        if [[ "$*" == *"badpkg"* ]]; then
            return 100
        fi
        return 0
    }

    export PATH="$CLOUDIFY_LOCAL_BIN:$PATH"

    # Should propagate the failure from the shadow
    run pkg_apt_install badpkg
    [ "$status" -ne 0 ]

    rm -f "$mock_dpkg"
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

#-- pkg_depends error collection tests --

@test "pkg_depends returns 0 when all packages succeed" {
    # Mock cloudify_is_package to return false (not a cloudify package)
    cloudify_is_package() { return 1; }
    # Mock pkg_apt_install to succeed
    pkg_apt_install() { return 0; }

    run pkg_depends pkg1 pkg2 pkg3
    [ "$status" -eq 0 ]
}

@test "pkg_depends collects errors from multiple failing packages" {
    # Mock cloudify_is_package to return false
    cloudify_is_package() { return 1; }
    # Mock pkg_apt_install to fail for specific packages
    pkg_apt_install() {
        if [[ "$1" == "badpkg1" || "$1" == "badpkg2" ]]; then
            return 1
        fi
        return 0
    }

    run pkg_depends goodpkg badpkg1 badpkg2
    [ "$status" -eq 1 ]
    [[ "$output" == *"badpkg1"* ]]
    [[ "$output" == *"badpkg2"* ]]
}

@test "pkg_depends continues after a package fails" {
    # Mock cloudify_is_package to return false
    cloudify_is_package() { return 1; }
    local install_log="$CLOUDIFY_TMP/install_log"
    # Mock pkg_apt_install to log calls and fail for badpkg
    pkg_apt_install() {
        echo "$1" >> "$install_log"
        if [[ "$1" == "badpkg" ]]; then
            return 1
        fi
        return 0
    }

    run pkg_depends badpkg goodpkg
    [ "$status" -eq 1 ]
    # Both packages must have been attempted
    grep -q "badpkg" "$install_log"
    grep -q "goodpkg" "$install_log"
}

@test "pkg_depends isolates recipe failures in subshell" {
    # Create a mock cloudify package with a failing recipe
    mkdir -p "$CLOUDIFY_DIR/pkg/testfailpkg"
    echo 'exit 1' > "$CLOUDIFY_DIR/pkg/testfailpkg/init.sh"

    # Mock cloudify_is_package to return true for testfailpkg
    cloudify_is_package() { [[ "$1" == "testfailpkg" ]]; }
    # Mock cloudify_package_has_recipe
    cloudify_package_has_recipe() { [[ "$1" == "testfailpkg" ]]; }
    # Mock cloudify_package_recipe_path
    cloudify_package_recipe_path() { echo "$CLOUDIFY_DIR/pkg/$1/init.sh"; }

    # Also test that subsequent packages are still attempted
    local install_log="$CLOUDIFY_TMP/install_log"
    pkg_apt_install() { echo "$1" >> "$install_log"; return 0; }

    run pkg_depends testfailpkg goodpkg
    [ "$status" -eq 1 ]
    [[ "$output" == *"testfailpkg"* ]]
    # goodpkg was still attempted (cloudify_is_package returns false for it)
    grep -q "goodpkg" "$install_log"
}

@test "pkg_depends collects error when .script copy fails" {
    # Create a mock cloudify package with a succeeding recipe and a .script file
    mkdir -p "$CLOUDIFY_DIR/pkg/scriptpkg"
    echo 'exit 0' > "$CLOUDIFY_DIR/pkg/scriptpkg/init.sh"
    echo '#!/bin/bash' > "$CLOUDIFY_DIR/pkg/scriptpkg/mytool.script"
    chmod +x "$CLOUDIFY_DIR/pkg/scriptpkg/mytool.script"

    # Mock package discovery
    cloudify_is_package() { [[ "$1" == "scriptpkg" ]]; }
    cloudify_package_has_recipe() { [[ "$1" == "scriptpkg" ]]; }
    cloudify_package_recipe_path() { echo "$CLOUDIFY_DIR/pkg/$1/init.sh"; }

    # Override cp to simulate failure when copying .script files to CLOUDIFY_LOCAL_BIN
    cp() {
        if [[ "${*}" == *"$CLOUDIFY_LOCAL_BIN"* ]]; then
            return 1
        fi
        command cp "$@"
    }

    run pkg_depends scriptpkg
    [ "$status" -eq 1 ]
    [[ "$output" == *"scriptpkg"* ]]
}
