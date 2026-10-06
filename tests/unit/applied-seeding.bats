#!/usr/bin/env bats
# Applied seeding freeze (state-model-v2 4.4, ADR-030): reconfigure seeds the
# deployment's applied SET values between the caller environment and the
# deployment store (a value you set outranks the store until you unset it);
# non-set values never seed (the store re-supplies them, a deleted entry lets
# the recipe default return). Verify and teardown seed ALL applied values,
# below the store, so inputs resupply over them. A set literal secret is
# digest-only and demands resupply; a mismatch dies named.

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

_v() { # _v <source> <source_form|-> <reference|-> <digest|->
    local form="null" ref="null" dig="null" red="false"
    [[ "$2" != "-" ]] && form="\"$2\""
    [[ "$3" != "-" ]] && { ref="\"$3\""; form="\"$3\""; }
    [[ "$4" != "-" ]] && { dig="\"$4\""; form="null"; red="true"; }
    printf '{"source":"%s","secret":%s,"declaration":"explicit","source_form":%s,"reference":%s,"digest":%s,"redacted":%s}' \
        "$1" "$([[ "$3" != "-" || "$4" != "-" ]] && printf true || printf false)" "$form" "$ref" "$dig" "$red"
}

_nv() { # _nv <form> - a plain non-secret value object
    printf '{"source":"%s","secret":false,"declaration":"none","source_form":"%s","reference":null,"digest":null,"redacted":false}' "$1" "$2"
}

# _seed_record <applied-values-json> - one valid applied record on the host
# tree for web/default/main, package nginx, instance default.
_seed_record() {
    local applied="$1" dir
    dir=$(cloudify_state_record_dir web1 "" web default main nginx default)
    mkdir -p "$dir"
    jq -n --argjson values "$applied" \
        '{schema_version: 1, host: "web1", host_key: "ivps:n1",
          package: "nginx", package_instance: "default",
          application: "web", flavor: "default", deployment: "main",
          step_id: "direct", revision: 1,
          applied: {version: "1.24.0", at: "2026-09-21T00:00:00Z",
                    event_id: "20260101T000000Z-00000002", values: $values},
          last_attempt: {phase: "install", outcome: "succeeded",
                         at: "2026-09-21T00:00:00Z",
                         event_id: "20260101T000000Z-00000000", requested: {}},
          health: {status: "unknown", checked_at: null,
                   event_id: "20260101T000000Z-00000001"}}' > "$dir/state.json"
}

# _store <key> <value> - the deployment desired-inputs store.
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

@test "seed producer: set filter for reconfigure, full set for verify and teardown" {
    local d
    d="sha256:$(printf 'plain' | sha256sum | cut -d' ' -f1)"
    _seed_record "{\"PORT\": $(_nv caller 4000), \"MODE\": $(_nv deployment store), \"TOKREF\": $(_v caller - @vault:kv/t -), \"TOKEN\": $(_v caller - - "$d")}"

    local f names
    f=$(cloudify_context_applied_seed reconfigure web1 "" web default main)
    [ -f "$f" ]
    names=$(cut -d$'\x1f' -f1 "$f" | sort | paste -sd,)
    [ "$names" = "PORT,TOKEN,TOKREF" ]
    grep -aq $'^TOKREF\x1fvalue\x1f\x1ft:@vault:kv/t$' "$f"
    grep -aq $'^TOKEN\x1fsecret\x1fsha256:' "$f"

    f=$(cloudify_context_applied_seed verify web1 "" web default main)
    names=$(cut -d$'\x1f' -f1 "$f" | sort | paste -sd,)
    [ "$names" = "MODE,PORT,TOKEN,TOKREF" ]
}

@test "reconfigure: a set value outranks the store; caller env outranks the seed" {
    _seed_record "{\"PORT\": $(_nv caller 4000)}"
    _store PORT 8080

    subrubric "seed beats the store"
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

@test "reconfigure: non-set values never seed - the store supplies, a deleted entry falls to the recipe default" {
    _seed_record "{\"MODE\": $(_nv deployment 8080)}"

    subrubric "store value lands, provenance deployment"
    _store MODE 9090
    _build reconfigure
    [ "${MODE:-}" = "9090" ]
    [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.MODE.source)" = "deployment" ]

    subrubric "store entry deleted - the name is absent (recipe default on the host)"
    rm -f "$(cloudify_deployment_values_file web default main)"
    rm -f "$CLOUDIFY_CONTEXT_FILE"
    unset MODE
    _build reconfigure
    [ -z "${MODE:-}" ]
    run cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.MODE.source
    [ "$status" -ne 0 ]
}

@test "reconfigure: a set literal secret demands resupply; digest must match" {
    local d
    d="sha256:$(printf 'plain' | sha256sum | cut -d' ' -f1)"
    _seed_record "{\"TOKEN\": $(_v caller - - "$d")}"

    subrubric "unsupplied: dies named before any dispatch"
    unset TOKEN
    run _build reconfigure
    [ "$status" -ne 0 ]
    [[ "$output" == *"TOKEN"* ]]

    subrubric "resupplied with the matching plaintext: passes and forwards"
    export TOKEN=plain
    _build reconfigure
    [ "$TOKEN" = "plain" ]

    subrubric "resupplied with a mismatching plaintext: dies named"
    export TOKEN=wrong
    run _build reconfigure
    [ "$status" -ne 0 ]
    [[ "$output" == *"TOKEN"* ]]
}

@test "verify and teardown: all applied values seed below the store; inputs resupply over them" {
    _seed_record "{\"ASET\": $(_nv caller 4000), \"BSTORE\": $(_nv deployment 8080)}"
    _store BSTORE 9090

    local phase
    for phase in verify teardown; do
        rm -f "$CLOUDIFY_CONTEXT_FILE"
        unset ASET BSTORE
        _build "$phase"
        # ASET: no store entry, the seed supplies it (label `applied`).
        [ "${ASET:-}" = "4000" ]
        [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.ASET.source)" = "applied" ]
        # BSTORE: the store outranks the seed at verify/teardown.
        [ "${BSTORE:-}" = "9090" ]
        [ "$(cloudify_context_read "$CLOUDIFY_CONTEXT_FILE" value.BSTORE.source)" = "deployment" ]
    done
}
