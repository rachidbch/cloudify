#!/usr/bin/env bats
# `_direct` synthesis freeze (state-model-v2 4.3; ADR-027): a bare install
# synthesizes an ordinary deployment under the reserved `_direct` namespace -
# generated name, virtual `direct` step, manifest under the uniform commit
# rule. Bare installs never match; an explicit `--name` is that deployment.

source tests/helpers/common.bash

setup() {
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh
}

teardown() {
    teardown_test_env
}

@test "generated name: <pkg>-<UTC-timestamp>, unique against existing deployments" {
    local a b
    a=$(cloudify_state_direct_generated_name nginx)
    [[ "$a" =~ ^nginx-[0-9]{8}T[0-9]{6}Z$ ]]

    # A deployment dir already holding the proposed name forces a different
    # name: a suffix on the same second, or the next second's timestamp. The
    # contract is uniqueness against existing deployments.
    mkdir -p "$(cloudify_state_deployment_dir _direct direct "$a")"
    b=$(cloudify_state_direct_generated_name nginx)
    [[ "$b" =~ ^nginx-[0-9]{8}T[0-9]{6}Z(-[0-9a-f]{4})?$ ]]
    [ "$a" != "$b" ]
    [ ! -d "$(cloudify_state_deployment_dir _direct direct "$b")" ]
}

@test "generated name: an over-long package segment truncates to the 255-byte component cap" {
    local long out
    long=$(printf 'p%.0s' $(seq 1 300))
    out=$(cloudify_state_direct_generated_name "$long")
    [ "${#out}" -le 255 ]
    [[ "$out" == ppp* ]]
    [[ "$out" =~ -[0-9]{8}T[0-9]{6}Z$ ]]
}

@test "synthesize: creates the deployment dir, manifest under the _direct namespace, prints the name" {
    local name
    name=$(cloudify_state_direct_synthesize nginx "" "" localhost)
    [[ "$name" =~ ^nginx- ]]
    [ -d "$(cloudify_state_deployment_dir _direct direct "$name")" ]
    [ -f "$(cloudify_state_manifest_file _direct direct "$name")" ]

    cloudify_state_validate_file "$CLOUDIFY_SCRIPT_DIR/schemas/v1/deployment-manifest.schema.json" \
        "$(cloudify_state_manifest_file _direct direct "$name")"

    [ "$(cloudify_manifest_field _direct direct "$name" application)" = "_direct" ]
    [ "$(cloudify_manifest_field _direct direct "$name" flavor)" = "direct" ]
    [ "$(cloudify_manifest_field _direct direct "$name" deployment)" = "$name" ]
    [ "$(cloudify_manifest_field _direct direct "$name" status)" = "applying" ]
    # One binding for the host the direct command runs on (slot `direct`).
    cloudify_manifest_bindings _direct direct "$name" > "$CLOUDIFY_TMP/bindings"
    grep -q $'^direct\tlocalhost\t\t\tlocalhost$' "$CLOUDIFY_TMP/bindings"
}

@test "synthesize: uniform commit rule - proved commit when the tree is identified and clean" {
    # A real git tree under the scratch dir: the manifest pins its current
    # commit, no development override. (The run tree in the shim has no .git,
    # so the repo is built here.)
    git init -q "$CLOUDIFY_TMP/repo"
    git -C "$CLOUDIFY_TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
    local name commit
    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/repo" name=$(cloudify_state_direct_synthesize nginx "" "" localhost)
    commit=$(git -C "$CLOUDIFY_TMP/repo" rev-parse HEAD)
    [ "$(cloudify_manifest_field _direct direct "$name" application_commit)" = "$commit" ]
    [ "$(cloudify_manifest_field _direct direct "$name" development_override)" = "false" ]
}

@test "synthesize: unreproducible tree stores a null commit with the development override" {
    local name
    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/not-a-repo" run cloudify_state_direct_synthesize nginx "" "" localhost
    [ "$status" -eq 0 ]
    local name="$output"
    [ "$(cloudify_manifest_field _direct direct "$name" application_commit)" = "null" ]
    [ "$(cloudify_manifest_field _direct direct "$name" development_override)" = "true" ]
}

@test "synthesize: CLOUDIFY_DEVELOPMENT_OVERRIDE=1 forces the dev-push record on a clean tree" {
    # The dev-push ruling extended to bare dispatches: an operator (or the
    # integration harness, which rsync-mirrors the tree - no git identity)
    # declares the push; the manifest records the override instead of
    # pinning a commit the child cannot attest.
    git init -q "$CLOUDIFY_TMP/repo2"
    git -C "$CLOUDIFY_TMP/repo2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
    local name
    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/repo2" CLOUDIFY_DEVELOPMENT_OVERRIDE=1 \
        name=$(cloudify_state_direct_synthesize nginx "" "" localhost)
    [ "$(cloudify_manifest_field _direct direct "$name" application_commit)" = "null" ]
    [ "$(cloudify_manifest_field _direct direct "$name" development_override)" = "true" ]
}

@test "repeated bare installs synthesize distinct deployments; neither matches the other" {
    local a b
    a=$(cloudify_state_direct_synthesize nginx "" "" localhost)
    b=$(cloudify_state_direct_synthesize nginx "" "" localhost)
    [ "$a" != "$b" ]
    [ -d "$(cloudify_state_deployment_dir _direct direct "$a")" ]
    [ -d "$(cloudify_state_deployment_dir _direct direct "$b")" ]
}

@test "an explicit --name under _direct is that deployment, every time (no synthesis)" {
    # Resolution is identity: the resolver reports the tuple without creating
    # anything - the deployment is created at the first commit, like any other.
    local before after
    mkdir -p "$(cloudify_state_path deployments)"
    before=$(find "$(cloudify_state_path deployments)" -mindepth 1 | wc -l)
    cloudify_state_direct_resolve my-name nginx > "$CLOUDIFY_TMP/resolve"
    after=$(find "$(cloudify_state_path deployments)" -mindepth 1 | wc -l)
    [ "$before" -eq "$after" ]
    [ "$(cat "$CLOUDIFY_TMP/resolve")" = $'_direct\tdirect\tmy-name' ]
}
