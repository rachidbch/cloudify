#!/usr/bin/env bats
# Branch 3: the remote payload travels on stdin, never argv.

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/remote.sh
}

teardown() {
    teardown_test_env
}

make_fixture() {
    mkdir -p "$CLOUDIFY_DIR/pkg/foo"
    printf 'K3S_TOKEN\n' > "$CLOUDIFY_DIR/pkg/foo/.remote-vars"
}

@test "payload and secret travel on stdin, the remote command is bash -s" {
    make_fixture
    export K3S_TOKEN=token-A
    export CLOUDIFY_REMOTE_USER=testuser
    cloudify_init_log
    ssh() { printf '%s' "$*" > "$CLOUDIFY_TMP/ssh-args"; cat > "$CLOUDIFY_TMP/payload"; return 0; }
    cloudify_remote_sync somehost install foo

    run cat "$CLOUDIFY_TMP/ssh-args"
    [[ "$output" == *"bash -s"* ]]
    [[ "$output" != *"K3S_TOKEN"* ]]
    run cat "$CLOUDIFY_TMP/payload"
    [[ "$output" == *"K3S_TOKEN='token-A'"* ]]
    [[ "$output" == *"cloudify install foo </dev/null"* ]]
}

@test "template has no global stdin detach and redirects stdin per command" {
    local payload
    payload=$(declare -f cloudify_remote_payload_template | tail -n +3 | head -n -1)
    [[ "$payload" != *"2>&1 </dev/null"* ]]
    [[ "$payload" == *"cloudify init < /dev/null"* ]]
    [[ "$payload" == *"< /dev/null"* ]]
}

@test "a failing remote command still writes a non-zero exit" {
    make_fixture
    export K3S_TOKEN=token-A
    export CLOUDIFY_REMOTE_USER=testuser
    cloudify_init_log
    ssh() { cat > /dev/null; return 7; }
    run cloudify_remote_sync somehost install foo
    [ "$status" -eq 7 ]
    [ "$(cat "$CLOUDIFY_TMP/somehost.exit")" = "7" ]
}
