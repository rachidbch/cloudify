#!/usr/bin/env bats
# Applied seeding on the lean record (state convergence S2; ADR-030 as
# amended): reconfigure seeds the deployment's user-forced values between the
# caller environment and the defaults files (a value you set outranks the
# stores until you unset it); non-forced values never seed (the store
# re-supplies them, a deleted entry lets the recipe default return). Verify
# and teardown seed ALL recorded values, below the stores, so inputs resupply
# over them. A "****" entry is a secret-name marker: it never seeds a value
# and demands resupply by name - the lean record carries no digest, so there
# is no equality check (environment-only secrets, ADR-037).

source tests/helpers/common.bash

NODE_DIR=""

_fake_ivps() {
    NODE_DIR="$CLOUDIFY_TMP/nodes/n1"
    local fake_bin="$CLOUDIFY_TMP/bin"
    mkdir -p "$fake_bin" "$NODE_DIR"
    cat > "$fake_bin/ivps" <<STUB
#!/bin/bash
[[ "\$1" = node && "\$2" = path ]] || exit 9
case "\$3" in
    web1) echo "$NODE_DIR" ;;
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

    # One cloudify package with the declared names the tests use.
    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf 'PORT=\nMODE=\nTOKEN=\nTOKREF=\nASET=\nBSTORE=\n' > "$CLOUDIFY_DIR/pkg/nginx/.remote-vars"

    export CLOUDIFY_CONTEXT_FILE="$CLOUDIFY_TMP/ctx"
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
}

teardown() {
    teardown_test_env
}

# _seed_record <user-forced-json-array> <settings-json-object> - one valid
# lean record on the host tree for web/default/main, package nginx.
_seed_record() {
    local forced="$1" settings="$2" dir
    dir=$(cloudify_state_record_dir web1 "" web default main nginx default)
    mkdir -p "$dir"
    jq -n --argjson forced "$forced" --argjson settings "$settings" \
        '{schema_version: 1, target: "direct", revision: 1,
          version: "1.24.0", user_forced: $forced} + $settings' \
        > "$dir/state.json"
}

# _store <key> <value> - a deployment-rank store entry (above the seed at
# verify/teardown; superseded by user-forced seeds at reconfigure).
_store() {
    local f
    f=$(cloudify_deployment_values_file web default main)
    mkdir -p "$(dirname "$f")"
    printf '%s: %s\n' "$1" "$2" >> "$f"
}

# _build <phase> - run the context build with the applied seed set.
_build() {
    local phase="$1" declared="$CLOUDIFY_TMP/declared"
    cloudify_context_candidate_names nginx > "$declared"
    export CLOUDIFY_APPLIED_SEED
    CLOUDIFY_APPLIED_SEED=$(cloudify_context_applied_seed "${2:-$phase}" web1 "" web default main)
    cloudify_context_build configure deployment "$phase" "$declared" nginx > /dev/null
}

@test "seed producer: user_forced filter for reconfigure, full set for verify and teardown" {
    _seed_record '["PORT"]' '{"PORT": "4000", "MODE": "8080", "TOKEN": "****", "TOKREF": "****"}'

    local f names
    f=$(cloudify_context_applied_seed reconfigure web1 "" web default main)
    [ -f "$f" ]
    names=$(cut -d$'\x1f' -f1 "$f" | sort | paste -sd,)
    [ "$names" = "PORT,TOKEN,TOKREF" ]
    subrubric "the user-forced value seeds; the recorded secrets are demand markers only"
    grep -aq $'^PORT\x1fvalue\x1f\x1ft:4000$' "$f"
    grep -aq $'^TOKEN\x1fsecret\x1f\x1f$' "$f"
    grep -aq $'^TOKREF\x1fsecret\x1f\x1f$' "$f"

    f=$(cloudify_context_applied_seed verify web1 "" web default main)
    names=$(cut -d$'\x1f' -f1 "$f" | sort | paste -sd,)
    [ "$names" = "MODE,PORT,TOKEN,TOKREF" ]
}

@test "reconfigure: a user-forced value outranks the defaults file; caller env outranks the seed" {
    _seed_record '["PORT"]' '{"PORT": "4000"}'
    _store PORT 8080

    subrubric "seed beats the defaults file"
    unset PORT
    _build reconfigure
    [ "${PORT:-}" = "4000" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.PORT.raw)" = "t:4000" ]

    subrubric "caller env beats the seed"
    export PORT=5000
    _build reconfigure
    [ "$PORT" = "5000" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.PORT.raw)" = "t:5000" ]
}

@test "reconfigure: non-forced values never seed - the defaults file supplies, a deleted entry falls to the recipe default" {
    _seed_record '[]' '{"MODE": "8080"}'

    subrubric "defaults-file value lands, provenance defaults"
    _store MODE 9090
    _build reconfigure
    [ "${MODE:-}" = "9090" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.MODE.source)" = "deployment" ]

    subrubric "defaults entry deleted - the name is absent (recipe default on the host)"
    rm -f "$(cloudify_deployment_values_file web default main)"
    rm -f "$CLOUDIFY_CONTEXT_FILE"
    unset MODE
    _build reconfigure
    [ -z "${MODE:-}" ]
    run cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.MODE.source
    [ "$status" -ne 0 ]
}

@test "reconfigure: a recorded secret name demands resupply by name, never by value equality" {
    _seed_record '[]' '{"TOKEN": "****"}'

    subrubric "unsupplied: dies named before any dispatch"
    unset TOKEN
    run _build reconfigure
    [ "$status" -ne 0 ]
    [[ "$output" == *"TOKEN"* ]]

    subrubric "resupplied: passes and forwards (no digest comparison exists)"
    export TOKEN=whatever-current
    _build reconfigure
    [ "$TOKEN" = "whatever-current" ]
}

@test "verify and teardown: all recorded values seed below the defaults files; inputs resupply over them" {
    _seed_record '["ASET"]' '{"ASET": "4000", "BSTORE": "8080"}'
    _store BSTORE 9090

    local phase
    for phase in verify teardown; do
        rm -f "$CLOUDIFY_CONTEXT_FILE"
        unset ASET BSTORE
        _build "$phase"
        # ASET: no defaults entry, the seed supplies it (label `applied`).
        [ "${ASET:-}" = "4000" ]
        [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.ASET.source)" = "applied" ]
        # BSTORE: the defaults file outranks the seed at verify/teardown.
        [ "${BSTORE:-}" = "9090" ]
        [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.BSTORE.source)" = "deployment" ]
    done
}
