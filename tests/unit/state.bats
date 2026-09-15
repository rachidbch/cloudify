#!/usr/bin/env bats
# lib/state.sh - the Cloudify state root and the deployment manifest
# (state model v2, Phase 3 slice 3B).
#
# Contract under test:
#   cloudify_state_root              ${XDG_STATE_HOME:-$HOME/.local/state}/cloudify
#   cloudify_state_deployment_dir    one validated component per level
#   cloudify_manifest_write          one flock per manifest, atomic rename,
#                                    exactly the schemas/v1 fields
#   cloudify_manifest_validate_file  fail closed with the one schema checker
#   cloudify_commit_of / cloudify_tree_unreproducible

setup() {
    source tests/helpers/common.bash
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/state.sh

    BINDINGS="$CLOUDIFY_TMP/bindings.tsv"
    printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\tcloudify\n' > "$BINDINGS"
}

teardown() {
    teardown_test_env
}

# _clean_repo <dir> - a one-commit git repository, so the commit gate passes.
_clean_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# The reference validator from the tree (jq + schema-check.jq), the same one
# schemas/v1/validate.sh uses. Calls it directly because validate.sh has no
# single-file mode.
_reference_check() {
    jq -e --slurpfile schema schemas/v1/deployment-manifest.schema.json \
        -f schemas/v1/lib/schema-check.jq "$1" >/dev/null
}

# --- State root ---

@test "state root: CLOUDIFY_STATE_DIR wins, else XDG_STATE_HOME, else HOME" {
    rubric "one helper for ${XDG_STATE_HOME:-$HOME/.local/state}/cloudify"

    run cloudify_state_root
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_STATE_DIR" ]

    unset CLOUDIFY_STATE_DIR
    XDG_STATE_HOME="$CLOUDIFY_TMP/xdgstate" run cloudify_state_root
    [ "$output" = "$CLOUDIFY_TMP/xdgstate/cloudify" ]

    XDG_STATE_HOME="" run cloudify_state_root
    [ "$output" = "$HOME/.local/state/cloudify" ]
}

@test "state paths: components are validated before any directory exists" {
    rubric "a rejected component creates no directory, no file, no record"

    run cloudify_state_deployment_dir "app" "default" "prod"
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_STATE_DIR/deployments/app/default/prod" ]

    run cloudify_state_manifest_file "app" "default" "prod"
    [ "$output" = "$CLOUDIFY_STATE_DIR/deployments/app/default/prod/manifest.json" ]

    run cloudify_state_deployment_dir "../escape" "default" "prod"
    [ "$status" -ne 0 ]
    run cloudify_state_deployment_dir "app" "a/b" "prod"
    [ "$status" -ne 0 ]
    run cloudify_state_deployment_dir "app" "default" ""
    [ "$status" -ne 0 ]
    run cloudify_state_deployment_dir "app" "default" ". "
    [ "$status" -ne 0 ]
    [ ! -d "$CLOUDIFY_STATE_DIR/deployments" ]
}

@test "state ensure_dir creates 0700 directories" {
    rubric "mode 0700"
    local dir
    dir=$(cloudify_state_deployment_dir app default prod)
    cloudify_state_ensure_dir "$dir"
    [ -d "$dir" ]
    [ "$(stat -c '%a' "$dir")" = "700" ]
}

# --- Git identity ---

@test "commit: a clean repository gives 40 hex, a dirty one is unreproducible" {
    rubric "cloudify_commit_of + cloudify_tree_unreproducible"
    local repo="$CLOUDIFY_TMP/repo"
    _clean_repo "$repo"

    local commit
    commit=$(cloudify_commit_of "$repo")
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
    run cloudify_tree_unreproducible "$repo"
    [ "$status" -eq 1 ]

    touch "$repo/dirty-file"
    run cloudify_tree_unreproducible "$repo"
    [ "$status" -eq 0 ]

    # Not a repository at all: unidentified, hence unreproducible.
    mkdir -p "$CLOUDIFY_TMP/notrepo"
    run cloudify_tree_unreproducible "$CLOUDIFY_TMP/notrepo"
    [ "$status" -eq 0 ]
    run cloudify_commit_of "$CLOUDIFY_TMP/notrepo"
    [ -z "$output" ]
}

# --- Manifest ---

@test "manifest: write lands exactly the schema fields and passes the reference validator" {
    rubric "one flock, atomic rename, schemas/v1/deployment-manifest.schema.json"
    local commit="0123456789abcdef0123456789abcdef01234567"
    cloudify_manifest_write app default prod applying "$commit" false "$BINDINGS"

    local file
    file=$(cloudify_state_manifest_file app default prod)
    [ -f "$file" ]
    [ "$(stat -c '%a' "$file")" = "600" ]
    [ "$(stat -c '%a' "$(dirname "$file")")" = "700" ]

    run cloudify_manifest_validate_file "$file"
    [ "$status" -eq 0 ]

    run cloudify_manifest_field app default prod schema_version
    [ "$output" = "1" ]
    run cloudify_manifest_field app default prod application_commit
    [ "$output" = "$commit" ]
    run cloudify_manifest_field app default prod development_override
    [ "$output" = "false" ]
    run cloudify_manifest_field app default prod status
    [ "$output" = "applying" ]
    run cloudify_manifest_field app default prod last_run_id
    [ "$output" = "null" ]
    run cloudify_manifest_field app default prod last_event_id
    [ "$output" = "null" ]

    # no applied package value and no extra field
    ! grep -q '"var\.' "$file"
    ! grep -q '"values"' "$file"
    [ "$(grep -c '":' "$file")" -ge 11 ]

    run cloudify_manifest_bindings app default prod
    [ "$output" = "$(printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\tcloudify')" ]

    # The reference validator (schemas/v1) accepts what the writer produced.
    if command -v jq >/dev/null 2>&1; then
        run _reference_check "$file"
        [ "$status" -eq 0 ]
    fi
}

@test "manifest: created_at survives a status update, bindings and last IDs are kept" {
    rubric "update_status keeps created_at and bindings"
    local commit="0123456789abcdef0123456789abcdef01234567"
    cloudify_manifest_write app default prod applying "$commit" false "$BINDINGS"
    local created
    created=$(cloudify_manifest_field app default prod created_at)
    sleep 1
    cloudify_manifest_update_status app default prod active "$commit" false
    [ "$(cloudify_manifest_field app default prod created_at)" = "$created" ]
    [ "$(cloudify_manifest_field app default prod status)" = "active" ]
    [ "$(cloudify_manifest_field app default prod last_run_id)" = "null" ]
    run cloudify_manifest_bindings app default prod
    [ "$output" = "$(printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\tcloudify')" ]
}

@test "manifest: the lock is exclusive, so writers serialize" {
    rubric "flock per deployment manifest"
    local lock
    lock=$(cloudify_state_lock_file app default prod)
    cloudify_state_ensure_dir "$(dirname "$lock")"

    # Hold the lock in the background, then a bounded second writer must fail.
    (
        flock -x 201
        sleep 2
    ) 201>"$lock" &
    local holder=$!
    sleep 0.4

    CLOUDIFY_LOCK_TIMEOUT=0 run _cloudify_state_run_locked "$lock" true
    [ "$status" -ne 0 ]
    [[ "$output" == *"held by another process"* ]]

    wait "$holder"
    run _cloudify_state_run_locked "$lock" true
    [ "$status" -eq 0 ]
}

@test "manifest: validate rejects a tampered file and an unknown top-level field" {
    rubric "fail closed: the schema is the one validator"
    local commit="0123456789abcdef0123456789abcdef01234567"
    cloudify_manifest_write app default prod applying "$commit" false "$BINDINGS"
    local file
    file=$(cloudify_state_manifest_file app default prod)

    sed -i 's/^  "status": "applying",$/  "status": "bogus",/' "$file"
    run cloudify_manifest_validate_file "$file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rejected by the schema"* ]]

    sed -i 's/^  "status": "bogus",$/  "status": "applying",/' "$file"
    run cloudify_manifest_validate_file "$file"
    [ "$status" -eq 0 ]

    sed -i 's/^  "schema_version": 1,$/  "schema_version": 1,\n  "extra": 1,/' "$file"
    run cloudify_manifest_validate_file "$file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected: extra"* ]]
}

@test "manifest: a missing schema tree fails before creating the deployment directory" {
    rubric "the prerequisite is checked before any filesystem write"
    CLOUDIFY_SCHEMA_DIR="$CLOUDIFY_TMP/no-schema" run cloudify_manifest_write app default prod \
        applying 0123456789abcdef0123456789abcdef01234567 false "$BINDINGS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"schema checker is missing"* ]]
    [ ! -d "$CLOUDIFY_STATE_DIR/deployments" ]
}

@test "manifest: a bindings line without five fields is refused, never shifted" {
    rubric "arity is checked in the renderer, so a malformed row cannot become fields"
    local b="$CLOUDIFY_TMP/short.tsv"
    printf 'guest\tcloudai:cloudify\tcloudai\tcloudify\n' > "$b"
    run cloudify_manifest_write app default prod applying 0123456789abcdef0123456789abcdef01234567 false "$b"
    [ "$status" -ne 0 ]
    [ ! -f "$(cloudify_state_manifest_file app default prod)" ]
}

@test "manifest: describe fails loudly when the bindings are unreadable" {
    rubric "a reader failure is never swallowed into an empty binding list"
    local commit="0123456789abcdef0123456789abcdef01234567"
    cloudify_manifest_write app default prod applying "$commit" false "$BINDINGS"
    local file
    file=$(cloudify_state_manifest_file app default prod)
    jq '.bindings = "not-an-object"' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    run cloudify_manifest_bindings app default prod
    [ "$status" -ne 0 ]
    run cloudify_manifest_describe app default prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read the recorded bindings"* ]]
}

@test "manifest: an external binding and a backslash address round-trip" {
    rubric "null node/instance keep their fields, and no byte is re-escaped"
    local commit="0123456789abcdef0123456789abcdef01234567"
    local b="$CLOUDIFY_TMP/mixed.tsv"
    printf 'ext\tssh.example.com\t\t\tssh.example.com\nback\ta\\b\tcloudai\tinst\tinst\n' > "$b"
    cloudify_manifest_write app default prod applying "$commit" false "$b"

    run cloudify_manifest_bindings app default prod
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'ext\tssh.example.com\t\t\tssh.example.com\nback\ta\\b\tcloudai\tinst\tinst')" ]

    run cloudify_manifest_describe app default prod
    [ "$status" -eq 0 ]
    [[ "$output" == *"binding ext: ssh.example.com (node=<none> instance=<none> ssh=ssh.example.com)"* ]]
    [[ "$output" == *"binding back: a\\b (node=cloudai instance=inst ssh=inst)"* ]]

    # A status update re-reads the bindings and must not shift or re-escape them.
    cloudify_manifest_update_status app default prod active "$commit" false
    run cloudify_manifest_bindings app default prod
    [ "$output" = "$(printf 'ext\tssh.example.com\t\t\tssh.example.com\nback\ta\\b\tcloudai\tinst\tinst')" ]
}

@test "manifest: list and describe expose identity, bindings and replayability, never a value" {
    rubric "cloudify_state_list_manifests + cloudify_manifest_describe"
    local commit="0123456789abcdef0123456789abcdef01234567"
    cloudify_manifest_write app default prod applying "$commit" true "$BINDINGS"

    run cloudify_state_list_manifests
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'app\tdefault\tprod\t%s' "$(cloudify_state_manifest_file app default prod)")" ]

    run cloudify_manifest_describe app default prod
    [ "$status" -eq 0 ]
    [[ "$output" == *"status: applying"* ]]
    [[ "$output" == *"development_override: true"* ]]
    [[ "$output" == *"replayable: no"* ]]
    [[ "$output" == *"binding guest: cloudai:cloudify"* ]]
    [[ "$output" == *"state: applying"* ]]
}

@test "manifest: write rejects an invalid component and creates nothing" {
    rubric "validation before the first writer lands"
    run cloudify_manifest_write "../app" default prod applying 0123456789abcdef0123456789abcdef01234567 false "$BINDINGS"
    [ "$status" -ne 0 ]
    [ ! -d "$CLOUDIFY_STATE_DIR/deployments" ]
}

@test "manifest: the schema checker is the one validator and jq is required" {
    rubric "no second copy of the schema rules; a jq-less host fails loudly"
    command -v jq >/dev/null 2>&1 || skip "jq unavailable"
    local commit="0123456789abcdef0123456789abcdef01234567"
    cloudify_manifest_write app default prod applying "$commit" false "$BINDINGS"
    local file
    file=$(cloudify_state_manifest_file app default prod)

    # The checker from the module's own tree accepts what the writer produced.
    run _cloudify_manifest_reference_check "$file"
    [ "$status" -eq 0 ]

    sed -i 's/^  "status": "applying",$/  "status": "bogus",/' "$file"
    run _cloudify_manifest_reference_check "$file"
    [ "$status" -eq 2 ]
    [[ "$output" == *"rejected by the schema"* ]]

    # And the public validator uses it: the same file is refused.
    run cloudify_manifest_validate_file "$file"
    [ "$status" -ne 0 ]

    # A missing checker is unusable, never a silent pass.
    CLOUDIFY_SCHEMA_DIR="$CLOUDIFY_TMP/nope" run _cloudify_manifest_reference_check "$file"
    [ "$status" -eq 1 ]
    CLOUDIFY_SCHEMA_DIR="$CLOUDIFY_TMP/nope" run cloudify_manifest_validate_file "$file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs jq and the schema checker"* ]]
}

@test "manifest: an unproved commit is real null, only with the development override" {
    rubric "the zero sentinel is gone; the schema's cross-field rule is the gate"
    cloudify_manifest_write app default prod applying "" true "$BINDINGS"
    local file
    file=$(cloudify_state_manifest_file app default prod)
    [ "$(cloudify_manifest_field app default prod application_commit)" = "null" ]
    grep -q '"application_commit": null' "$file"
    run cloudify_manifest_validate_file "$file"
    [ "$status" -eq 0 ]

    # null without development_override is refused, and nothing lands.
    run cloudify_manifest_write app default stage applying "" false "$BINDINGS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rejected by the schema"* ]]
    [ ! -f "$(cloudify_state_manifest_file app default stage)" ]
}
