#!/usr/bin/env bats
# The recorded-state screen and the unset escape (state convergence S2;
# ADR-030 as amended): show renders hosts (from the manifest bindings) ->
# packages -> settings, the USER column marks user-forced names only, secrets
# show the **** marker (never a value, digest, or provider location), and the
# footer names the exact release command. --user-values filters to forced
# names. unset removes the forced bit event-first (revision bump under the
# host lock); the recorded value text stays exactly what the machine holds; a
# var that is not user-forced dies named; the released name stops seeding the
# next reconfigure.

source tests/helpers/common.bash

NODE_DIR=""
NODE2_DIR=""

_fake_ivps() {
    NODE_DIR="$CLOUDIFY_TMP/nodes/n1"
    NODE2_DIR="$CLOUDIFY_TMP/nodes/n2"
    local fake_bin="$CLOUDIFY_TMP/bin"
    mkdir -p "$fake_bin" "$NODE_DIR" "$NODE2_DIR"
    cat > "$fake_bin/ivps" <<STUB
#!/bin/bash
[[ "\$1" = node && "\$2" = path ]] || exit 9
case "\$3" in
    web1) echo "$NODE_DIR" ;;
    db1) echo "$NODE2_DIR" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$fake_bin/ivps"
    export PATH="$fake_bin:$PATH"
}

setup() {
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    unset XDG_STATE_HOME
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    export CLOUDIFY_DISABLE_COLORS=true

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    _fake_ivps

    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
}

teardown() {
    teardown_test_env
}

# _seed_record <node> <pkg> <settings-json> [user-forced-json] - one valid
# lean record on the host tree for web/default/main, instance default.
_seed_record() {
    local node="$1" pkg="$2" settings="$3" forced="${4:-[]}" dir
    dir=$(cloudify_state_record_dir "$node" "" web default main "$pkg" default)
    mkdir -p "$dir"
    jq -n --argjson settings "$settings" --argjson forced "$forced" \
        '{schema_version: 1, target: "direct", revision: 1,
          version: "1.24.0", user_forced: $forced} + $settings' > "$dir/state.json"
}

_manifest() { # _manifest <binding-line...>
    local bf="$CLOUDIFY_TMP/bf"
    printf '%s\n' "$@" > "$bf"
    cloudify_manifest_write web default main installed \
        0123456789abcdef0123456789abcdef01234567 false "$bf"
}

@test "show: hosts -> packages -> settings; USER marks user-forced names only; secrets are markers" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "8080", "TOKEN": "****"}' '["TOKEN"]'
    _seed_record web1 openssl '{"MODE": "fast"}' '["MODE"]'

    run cloudify_deployment_show main
    [ "$status" -eq 0 ]

    # Host section for the single binding: plain host line.
    printf '%s\n' "$output" | grep -qx "  web1"
    # Package headers with version and the lean state word.
    printf '%s\n' "$output" | grep -q "nginx.*1.24.0.*recorded"
    printf '%s\n' "$output" | grep -q "openssl.*1.24.0.*recorded"
    # Settings under their packages; USER only on user-forced ones.
    printf '%s\n' "$output" | grep -q "PORT.*8080"
    printf '%s\n' "$output" | grep -q "MODE.*fast.*USER"
    # The secret: the marker, never a value or a digest fragment.
    [[ "$output" == *"********"* ]]
    [[ "$output" != *"plain"* ]]
    # Header count and the release command with the full signature.
    [[ "$output" == *"nginx TOKEN"* ]]
    [[ "$output" == *"unset web/default/main"* ]]

    # The USER marker appears exactly twice (TOKEN, MODE) and never on PORT.
    local n_user
    n_user=$(grep -c "USER" <<<"$output")
    [ "$n_user" -eq 2 ]
}

@test "show: a passed 0 (the router's default flag) is not user-only mode" {
    # Proven live: the router passes 0 for --user-values, and "non-empty" made
    # every plain `deployment show` render the user-only header and drop the
    # recorded values.
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "8080"}' '[]'

    run cloudify_deployment_show main 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"values in effect:"* ]]
    [[ "$output" != *"user only"* ]]
    printf '%s\n' "$output" | grep -q "PORT.*8080"
}

@test "list: one rich line per deployment - status, pkgs, hosts, user values" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "8080", "TOKEN": "abc"}' '["TOKEN"]'
    _seed_record web1 openssl '{}'

    run cloudify_deployment_list
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "web/default/main.*installed.*2 pkgs.*1 host.*1 user value"
}

@test "show: multiple bindings render slot -> host; per-host values stay nested" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1' $'db\tlocalhost\tdb1\t\tdb1'
    _seed_record web1 nginx '{"PORT": "8080"}'
    _seed_record db1 nginx '{"PORT": "5432"}'

    run cloudify_deployment_show main
    [ "$status" -eq 0 ]
    [[ "$output" == *"primary -> web1"* ]]
    [[ "$output" == *"db -> db1"* ]]
    [[ "$output" == *"8080"* ]]
    [[ "$output" == *"5432"* ]]
}

@test "show --user-values: only user-forced values and their packages" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "8080", "TOKEN": "abc"}' '["TOKEN"]'
    _seed_record web1 openssl '{"MODE": "fast"}'

    run cloudify_deployment_show main 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"TOKEN"* ]]
    [[ "$output" == *"USER"* ]]
    [[ "$output" != *"8080"* ]]
    [[ "$output" != *"fast"* ]]
    # The package with no user values drops its value block.
    [[ "$output" == *"nginx"* ]]
    [[ "$output" != *"openssl"* ]]
}

@test "unset: removes the forced bit event-first; the recorded value text stays" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "4000", "TOKEN": "8080"}' '["PORT"]'
    local rec
    rec=$(cloudify_state_record_dir web1 "" web default main nginx default)/state.json

    run cloudify_deployment_unset main nginx PORT
    [ "$status" -eq 0 ]

    [ "$(jq -r .revision "$rec")" = "2" ]
    [ "$(jq -r '.user_forced | index("PORT") == null' "$rec")" = "true" ]
    [ "$(jq -r .PORT "$rec")" = "4000" ]

    # One unset event exists, command_kind unset, phase null.
    local ev
    ev=$(find "$HOME/.local/state/cloudify/events" -name '*.json' -exec jq -r 'select(.command_kind=="unset") | input_filename' {} \;)
    [ -n "$ev" ]
    [ "$(jq -r .phase "$ev")" = "null" ]
    [ "$(jq -r .step_id "$ev")" = "unset" ]

    # The behavioral payoff: the released name no longer seeds a reconfigure,
    # and the secret marker never seeded at all.
    local seed
    seed=$(cloudify_context_applied_seed reconfigure web1 "" web default main)
    if grep -q "^PORT" "$seed"; then false; fi
    if grep -q "^TOKEN" "$seed"; then false; fi
}

@test "unset: a var that is not user-forced dies named, nothing changes" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "8080"}'
    local rec
    rec=$(cloudify_state_record_dir web1 "" web default main nginx default)/state.json
    local before
    before=$(jq -S . "$rec")

    run cloudify_deployment_unset main nginx PORT
    [ "$status" -ne 0 ]
    [[ "$output" == *"PORT"* ]]
    [ "$(jq -S . "$rec")" = "$before" ]
}

@test "unset: unknown deployment or package dies named" {
    _manifest $'primary\tlocalhost\tweb1\t\tweb1'
    _seed_record web1 nginx '{"PORT": "4000"}' '["PORT"]'

    # An id resolves only outside an active application reference (the
    # reference wins otherwise) - the operator-shell case.
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    run cloudify_deployment_unset nosuch nginx PORT
    [ "$status" -ne 0 ]
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    run cloudify_deployment_unset main nosuchpkg PORT
    [ "$status" -ne 0 ]
}
