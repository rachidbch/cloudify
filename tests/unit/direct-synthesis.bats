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

@test "generated name: the package word, then -2, -3 on collision (values never name)" {
    # ADR-045: values never participate in a name, so a reconfigure keeps its
    # identity; the allocation itself is the atomic mkdir, so two parallel
    # dispatches cannot pick the same name.
    local a b c
    a=$(cloudify_state_direct_generated_name nginx)
    [ "$a" = "nginx" ]
    b=$(cloudify_state_direct_generated_name nginx)
    [ "$b" = "nginx-2" ]
    c=$(cloudify_state_direct_generated_name nginx)
    [ "$c" = "nginx-3" ]
}

@test "generated name: an over-long package segment truncates under the 255-byte cap" {
    local long out
    long=$(printf 'p%.0s' $(seq 1 300))
    out=$(cloudify_state_direct_generated_name "$long")
    [ "${#out}" -le 255 ]
    [[ "$out" =~ ^p+(-[0-9]+)?$ ]]
}

@test "synthesize: creates the deployment dir, manifest under the _direct namespace, prints the name" {
    local name
    name=$(cloudify_state_direct_synthesize nginx "" "" localhost)
    [ "$name" = "nginx" ]
    [ -d "$(cloudify_state_deployment_dir _direct direct "$name")" ]
    [ -f "$(cloudify_state_manifest_file _direct direct "$name")" ]

    cloudify_state_validate_file "$CLOUDIFY_SCRIPT_DIR/schemas/v1/deployment-manifest.schema.json" \
        "$(cloudify_state_manifest_file _direct direct "$name")"

    [ "$(cloudify_manifest_field _direct direct "$name" application)" = "_direct" ]
    [ "$(cloudify_manifest_field _direct direct "$name" flavor)" = "direct" ]
    [ "$(cloudify_manifest_field _direct direct "$name" deployment)" = "$name" ]
    [ "$(cloudify_manifest_field _direct direct "$name" status)" = "null" ]
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
