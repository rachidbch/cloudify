#!/usr/bin/env bats
# Deployment matching on the lean record (state convergence S2; design
# "Deployment identity and matching"): a run with no name converges the
# deployment of the same application and flavor whose recorded settings
# (root scalars, "****" for secret names) and bindings equal the run's
# resolved value source forms and resolved bindings - non-secret scalars
# compare by value, secret names by presence only. No match creates a
# generated `<application>-<flavor>-<UTC-timestamp>[-suffix]` deployment and
# prints the name. Explicit --name never reaches the matcher (identity by
# resolve); bare `_direct` installs never match (synthesize-always); matching
# never crosses the `_direct` namespace.

source tests/helpers/common.bash

NODE_DIR=""

# A stub ivps that answers `node path` for the one shape the tests use.
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
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    source lib/matching.sh
    _fake_ivps
}

teardown() {
    teardown_test_env
}

# --- fixture helpers -------------------------------------------------------

# _ctx_value <name> <form> <secret> <declaration> <reference> <digest> <raw>
# One context value block, exactly the shapes the builder writes.
_ctx_value() {
    printf 'value.%s.source: environment\n' "$1"
    printf 'value.%s.form: %s\n' "$1" "$2"
    printf 'value.%s.secret: %s\n' "$1" "$3"
    printf 'value.%s.declaration: %s\n' "$1" "$4"
    printf 'value.%s.reference: %s\n' "$1" "$5"
    printf 'value.%s.digest: %s\n' "$1" "$6"
    printf 'value.%s.raw: %s\n' "$1" "$7"
}

# _write_context [extra lines on stdin] - the run's dispatch context, target
# web1 (plain host, no instance) at localhost. Prints the file path.
_write_context() {
    local ctx="$CLOUDIFY_TMP/run-context"
    {
        printf 'context_version: 1\n'
        printf 'action: install\n'
        printf 'deployment: \n'
        printf 'phase: install\n'
        printf 'target: web1\t\tlocalhost\n'
        printf 'top_kind: package\n'
        cat
    } > "$ctx"
    printf '%s\n' "$ctx"
}

# _run_bindings [slot lines...] - the run's resolved bindings file.
_run_bindings() {
    local f="$CLOUDIFY_TMP/run-bindings"
    printf '%s\n' "$@" > "$f"
    printf '%s\n' "$f"
}

# _literal <text> - the lean recorded form of a non-secret literal: the text.
_literal() {
    jq -Rn --arg v "$1" '$v'
}

# _secret - the lean recorded form of any classified secret: the marker.
_secret() {
    printf '"****"'
}

# _seed_manifest <app> <flavor> <name> <binding-line...> - a candidate's
# manifest: proved commit, bindings as given.
_seed_manifest() {
    local app="$1" flavor="$2" name="$3"
    shift 3
    local bf="$CLOUDIFY_TMP/seeded-bindings-$name"
    printf '%s\n' "$@" > "$bf"
    cloudify_manifest_write "$app" "$flavor" "$name" installed \
        0123456789abcdef0123456789abcdef01234567 false "$bf"
}

# _seed_record <app> <flavor> <name> <pkg> <inst> <settings-json>
#              [failed] - one valid lean inventory record on the host tree.
_seed_record() {
    local app="$1" flavor="$2" name="$3" pkg="$4" inst="$5" settings="$6"
    local failed="${7:-}" dir
    dir=$(cloudify_state_record_dir web1 "" "$app" "$flavor" "$name" "$pkg" "$inst")
    mkdir -p "$dir"
    jq -n --argjson settings "$settings" --arg failed "$failed" \
        '{schema_version: 1, target: "direct", revision: 1,
          version: "1.24.0", user_forced: []} + $settings
        | if $failed == "failed" then . + {failed: true} else . end' > "$dir/state.json"
}

# _record_count <app> <flavor> - manifests of one application/flavor.
_record_count() {
    cloudify_state_list_manifests | awk -F'\t' -v a="$1" -v f="$2" '$1==a && $2==f' | wc -l
}

# --- generated names -------------------------------------------------------

@test "generated name: <application>-<flavor>-<UTC-timestamp>, unique against existing deployments" {
    local a b
    a=$(cloudify_state_deployment_generated_name web default)
    [[ "$a" =~ ^web-default-[0-9]{8}T[0-9]{6}Z$ ]]

    mkdir -p "$(cloudify_state_deployment_dir web default "$a")"
    b=$(cloudify_state_deployment_generated_name web default)
    [[ "$b" =~ ^web-default-[0-9]{8}T[0-9]{6}Z(-[0-9a-f]{4})?$ ]]
    [ "$a" != "$b" ]
    [ ! -d "$(cloudify_state_deployment_dir web default "$b")" ]
}

@test "generated name: application and flavor segments truncate to the 255-byte component cap" {
    local out
    subrubric "a long-but-valid application truncates in the generated name"
    local long
    long=$(printf 'a%.0s' $(seq 1 250))
    out=$(cloudify_state_deployment_generated_name "$long" flavorx)
    [ "${#out}" -le 255 ]
    [[ "$out" == aaa* ]]
    [[ "$out" =~ -flavorx-[0-9]{8}T[0-9]{6}Z$ ]]

    subrubric "an application that cannot be a component at all dies named, before any write"
    local huge
    huge=$(printf 'a%.0s' $(seq 1 300))
    run cloudify_state_deployment_generated_name "$huge" flavorx
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid application"* ]]
}

# --- matching --------------------------------------------------------------

@test "match: identical values and bindings converge the existing deployment, no new artefact" {
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"PORT\":$(_literal 8080)}" succeeded \
        "{\"version\":\"1.24.0\",\"at\":\"2026-09-21T00:00:00Z\",\"event_id\":\"20260101T000000Z-00000002\",\"values\":{}}"

    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')

    got=$(cloudify_state_match_deployment web default "$ctx" "$bf")
    [ "$got" = "main" ]
    [ "$(_record_count web default)" -eq 1 ]
}

@test "match: a failed first install still matches (settings recorded, failed marked)" {
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"PORT\":$(_literal 8080)}" failed

    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')

    got=$(cloudify_state_match_deployment web default "$ctx" "$bf")
    [ "$got" = "main" ]
}

@test "no match: a differing value refuses - a second deployment requires a name" {
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"PORT\":$(_literal 9090)}"

    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')

    run cloudify_state_match_deployment web default "$ctx" "$bf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]
    [[ "$output" == *"--name"* ]]
    [ "$(_record_count web default)" -eq 1 ]
}

@test "no match: bindings differ - refuses, a second deployment requires a name" {
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"PORT\":$(_literal 8080)}"

    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tother\t\totherhost')

    run cloudify_state_match_deployment web default "$ctx" "$bf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]
    [ "$(_record_count web default)" -eq 1 ]
}

@test "match: secret names compare as markers - never by value, digest, or provider location" {
    local ctx bf got

    subrubric "a recorded secret reference converges on the name marker alone"
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"TOKEN\":$(_secret)}"
    ctx=$(_write_context <<EOF
$( _ctx_value TOKEN reference true explicit '@vault:prod/token' '' 't:@vault:prod/token' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')
    got=$(cloudify_state_match_deployment web default "$ctx" "$bf")
    [ "$got" = "main" ]

    subrubric "a recorded literal secret also converges on the name marker alone"
    rm -rf "$(cloudify_state_deployment_dir web default main)"
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"TOKEN\":$(_secret)}"
    ctx=$(_write_context <<EOF
$( _ctx_value TOKEN literal true explicit '' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 't:redacted' )
package.nginx.instance: default
EOF
    )
    got=$(cloudify_state_match_deployment web default "$ctx" "$bf")
    [ "$got" = "main" ]
}

@test "no match: covered package set must equal the candidate's recorded set" {
    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')

    subrubric "a candidate with an extra recorded package does not match"
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main nginx default "{\"PORT\":$(_literal 8080)}"
    _seed_record web default main redis default '{}'
    run cloudify_state_match_deployment web default "$ctx" "$bf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]

    subrubric "a candidate missing a covered package does not match"
    rm -rf "$(cloudify_state_deployment_dir web default main)" \
        "$(cloudify_state_record_dir web1 '' web default main nginx default)" \
        "$(cloudify_state_record_dir web1 '' web default main redis default)"
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'
    _seed_record web default main redis default '{}'
    run cloudify_state_match_deployment web default "$ctx" "$bf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]
}

@test "no match: an interrupted candidate refuses - re-running it needs a name" {
    _seed_manifest web default main $'primary\tlocalhost\tweb1\t\tlocalhost'

    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')

    run cloudify_state_match_deployment web default "$ctx" "$bf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]
    [ "$(_record_count web default)" -eq 1 ]
}

@test "namespace: matching never crosses _direct" {
    local ctx bf got
    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')

    subrubric "a _direct deployment with identical records is not a candidate"
    _seed_manifest _direct direct d1 $'direct\tlocalhost\tweb1\t\tlocalhost'
    _seed_record _direct direct d1 nginx default "{\"PORT\":$(_literal 8080)}"
    got=$(cloudify_state_match_deployment web default "$ctx" "$bf")
    [[ "$got" =~ ^web-default- ]]

    subrubric "the matcher refuses to run for the _direct application"
    run cloudify_state_match_deployment _direct direct "$ctx" "$bf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"_direct"* ]]
}

@test "namespace: an explicit name never matches - resolve is identity and creates nothing" {
    # The router resolves an explicit --name without consulting the matcher;
    # the unit-freeze pins the resolve contract: identity, nothing created.
    mkdir -p "$CLOUDIFY_STATE_DIR/deployments"
    local before after
    before=$(find "$CLOUDIFY_STATE_DIR/deployments" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l)
    local tuple
    tuple=$(cloudify_state_direct_resolve main nginx)
    [ "$tuple" = $'_direct\tdirect\tmain' ]
    after=$(find "$CLOUDIFY_STATE_DIR/deployments" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | wc -l)
    [ "$before" = "$after" ]
}

@test "create: the generated deployment's manifest follows the uniform commit rule" {
    git init -q "$CLOUDIFY_TMP/repo"
    git -C "$CLOUDIFY_TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
    local ctx bf got commit
    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/repo"
    commit=$(git -C "$CLOUDIFY_TMP/repo" rev-parse HEAD)

    ctx=$(_write_context <<EOF
$( _ctx_value PORT literal false none '' '' 't:8080' )
package.nginx.instance: default
EOF
    )
    bf=$(_run_bindings $'primary\tlocalhost\tweb1\t\tlocalhost')
    got=$(cloudify_state_match_deployment web default "$ctx" "$bf")
    [ "$(cloudify_manifest_field web default "$got" application_commit)" = "$commit" ]
    [ "$(cloudify_manifest_field web default "$got" development_override)" = "false" ]
}
