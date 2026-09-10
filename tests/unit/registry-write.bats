#!/usr/bin/env bats
# Branch 7 T3: registry write — record schema, merge semantics and the
# var snapshot baked into the record.
# The builder is pure (reads the existing record, prints); the router's wait
# loop calls _cloudify_registry_record_bg on a successful dispatch.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    # Repoint the stores before sourcing deployments.sh (it computes the dir)
    export HOME="$CLOUDIFY_TMP/home"
    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/creds"
    mkdir -p "$HOME" "$CLOUDIFY_CREDENTIALS_DIR"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/deployments.sh
    source lib/registry.sh

    IVPS_NODE_ROOT="$CLOUDIFY_TMP/ivps/nodes"
    IVPS_NODES=()
    IVPS_NODE_PATH_RC=0

    DEP="xfce-gui"
    NODE="cloudai"
    INSTANCE=""
    HOST="cloudify"
    PKG="bats-test"

    # Router-side metadata consumed by _cloudify_registry_record_bg
    declare -gA _CLOUDIFY_BG_ACTION=()
    declare -gA _CLOUDIFY_BG_PKGS=()
    declare -gA _CLOUDIFY_BG_TARGET=()
    unset CLOUDIFY_DEPLOYMENT
}

teardown() {
    teardown_test_env
}

# ivps stub as a shell function (shadows any real ivps in PATH).
ivps() {
    local sub="${1:-}" e
    case "$sub" in
        node)
            [[ "${2:-}" == "path" ]] || return 1
            [[ "${IVPS_NODE_PATH_RC:-0}" -eq 0 ]] || return "$IVPS_NODE_PATH_RC"
            for e in ${IVPS_NODES[@]+"${IVPS_NODES[@]}"}; do
                [[ "$e" == "${3:-}" ]] && { echo "$IVPS_NODE_ROOT/${3:-}"; return 0; }
            done
            return 1
            ;;
        *) return 1 ;;
    esac
}

# _field <key> <content> — the value of one flat `key: value` line
_field() {
    local line
    line=$(grep -m1 "^$1:" <<< "$2") || return 0
    line="${line#*:}"
    line="${line# }"
    printf '%s' "$line"
}

# Declare <names> in a fixture package under the pkg dir
_declare() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

# ---------------------------------------------------------------
# Install record
# ---------------------------------------------------------------

@test "install record: schema, target identity and a UTC installed_at" {
    rubric "install -> status installed + installed_at, every schema field present"
    IVPS_NODES=(cloudai)

    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "# cloudify registry record (observation); do not edit by hand" ]
    [ "$(_field status "$output")" = installed ]
    [ "$(_field deployment "$output")" = "$DEP" ]
    [ "$(_field node "$output")" = "$NODE" ]
    [ "$(_field instance "$output")" = "" ]
    [ "$(_field package "$output")" = "$PKG" ]
    [ "$(_field version "$output")" = "" ]
    [ -z "$(_field configured_at "$output")" ]
    [ -z "$(_field removed_at "$output")" ]
    printf '%s\n' "$output" | grep -qE '^installed_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

@test "an unknown action dies instead of writing a record" {
    rubric "build rejects anything but install/configure/uninstall"
    IVPS_NODES=(cloudai)

    run cloudify_registry_record_build bogus "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown action"* ]]
}

@test "the record is written 600 inside a 700 dir" {
    rubric "apply -> 0700 dir / 0600 record (I7-5)"
    IVPS_NODES=(cloudai)

    run cloudify_registry_record_apply install "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    local file
    file=$(cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG")
    [ -f "$file" ]
    [ "$(stat -c '%a' "$file")" = "600" ]
    [ "$(stat -c '%a' "${file%/*}")" = "700" ]
}

# ---------------------------------------------------------------
# Merge
# ---------------------------------------------------------------

@test "configure merge keeps installed_at and adds configured_at" {
    rubric "merge: configure preserves the earlier install timestamp"
    IVPS_NODES=(cloudai)

    run cloudify_registry_record_apply install "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    local file installed
    file=$(cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG")
    installed=$(_field installed_at "$(< "$file")")
    [ -n "$installed" ]

    sleep 1
    run cloudify_registry_record_apply configure "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    local content
    content=$(< "$file")
    [ "$(_field status "$content")" = configured ]
    [ "$(_field installed_at "$content")" = "$installed" ]
    [ -n "$(_field configured_at "$content")" ]
}

@test "uninstall marks removed and keeps the record file" {
    rubric "teardown is a timestamp (removed_at), never a delete"
    IVPS_NODES=(cloudai)

    run cloudify_registry_record_apply install "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    local file installed
    file=$(cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG")
    installed=$(_field installed_at "$(< "$file")")

    sleep 1
    run cloudify_registry_record_apply uninstall "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ -f "$file" ]
    local content
    content=$(< "$file")
    [ "$(_field status "$content")" = removed ]
    [ "$(_field installed_at "$content")" = "$installed" ]
    [ -n "$(_field removed_at "$content")" ]
}

# ---------------------------------------------------------------
# var snapshot
# ---------------------------------------------------------------

@test "var snapshot: raw precedence env > deployment > package > global" {
    rubric "var.<NAME> takes the first providing source in that order"
    IVPS_NODES=(cloudai)
    _declare decl-pkg 'V'
    printf 'V: global\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    printf 'V: package\n' > "$CLOUDIFY_CREDENTIALS_DIR/pkgs/decl-pkg.yaml"
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" V deployment

    export V=env
    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" decl-pkg
    [ "$(_field var.V "$output")" = "env" ]
    unset V

    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" decl-pkg
    [ "$(_field var.V "$output")" = "deployment" ]

    rm -f "$(_cloudify_deployment_config "$DEP")"
    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" decl-pkg
    [ "$(_field var.V "$output")" = "package" ]

    rm -f "$CLOUDIFY_CREDENTIALS_DIR/pkgs/decl-pkg.yaml"
    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" decl-pkg
    [ "$(_field var.V "$output")" = "global" ]

    rm -f "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" decl-pkg
    [ -z "$(_field var.V "$output")" ]
}

@test "var snapshot: a stored reference stays a reference (raw, never resolved)" {
    rubric "a @backend: value is recorded verbatim, so replay can re-resolve"
    IVPS_NODES=(cloudai)
    _declare ref-pkg 'REF_VAR'
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    _cloudify_vars_file_set "$CLOUDIFY_CREDENTIALS_DIR/pkgs/ref-pkg.yaml" REF_VAR '@base64:aGVsbG8=' 1

    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" ref-pkg
    [ "$(_field var.REF_VAR "$output")" = "@base64:aGVsbG8=" ]
}

@test "var snapshot: a multi-line env value round-trips as @base64:" {
    rubric "one line per field: a newline in the raw value is encoded (var-store encoding)"
    IVPS_NODES=(cloudai)
    _declare multi-pkg 'MULTI'
    export MULTI=$'line one\nline two'

    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" multi-pkg
    local encoded
    encoded=$(_field var.MULTI "$output")
    [[ "$encoded" == @base64:* ]]
    [ "$(printf '%s' "${encoded#@base64:}" | base64 -d)" = "$MULTI" ]
}

@test "var snapshot: only declared names are recorded, in declaration order" {
    rubric "names come from pkg/<pkg>/.remote-vars; undeclared env never leaks in"
    IVPS_NODES=(cloudai)
    _declare order-pkg 'B_VAR' 'A_VAR' 'GONE_VAR'
    export B_VAR=b A_VAR=a TOP_SECRET=leak

    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" order-pkg
    local vars
    vars=$(printf '%s\n' "$output" | grep '^var\.')
    [ "$vars" = "$(printf 'var.B_VAR: b\nvar.A_VAR: a')" ]
    [[ "$output" != *"TOP_SECRET"* ]]
}

# ---------------------------------------------------------------
# Router-side gate (wait loop)
# ---------------------------------------------------------------

@test "wait loop: an unset CLOUDIFY_DEPLOYMENT writes no record" {
    rubric "no ambient deployment -> skip (I7-8), not an error"
    IVPS_NODES=(cloudai)
    _CLOUDIFY_BG_ACTION[42]=install
    _CLOUDIFY_BG_PKGS[42]=bats-test
    _CLOUDIFY_BG_TARGET[42]=$'cloudai\t\tcloudify'
    unset CLOUDIFY_DEPLOYMENT

    run _cloudify_registry_record_bg 42
    [ "$status" -eq 0 ]
    [ ! -e "$IVPS_NODE_ROOT/cloudai" ]
    [ ! -e "$CLOUDIFY_CREDENTIALS_DIR/registry" ]
}

@test "wait loop: a successful dispatch records each package on its target" {
    rubric "pid metadata -> one record per package under the target bucket"
    IVPS_NODES=(cloudai)
    _CLOUDIFY_BG_ACTION[7]=install
    _CLOUDIFY_BG_PKGS[7]="bats-test vim"
    _CLOUDIFY_BG_TARGET[7]=$'cloudai\t\tcloudify'
    export CLOUDIFY_DEPLOYMENT="$DEP"

    run _cloudify_registry_record_bg 7
    [ "$status" -eq 0 ]
    local file
    for file in bats-test vim; do
        local record="$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/$file/config.yaml"
        [ -f "$record" ]
        grep -q "^node: cloudai$" "$record"
        grep -q "^status: installed$" "$record"
    done
}

@test "wait loop: verify is observation-free (no record)" {
    rubric "verify changes no state, so it writes nothing"
    IVPS_NODES=(cloudai)
    _CLOUDIFY_BG_ACTION[9]=verify
    _CLOUDIFY_BG_PKGS[9]=bats-test
    _CLOUDIFY_BG_TARGET[9]=$'cloudai\t\tcloudify'
    export CLOUDIFY_DEPLOYMENT="$DEP"

    run _cloudify_registry_record_bg 9
    [ "$status" -eq 0 ]
    [ ! -e "$IVPS_NODE_ROOT/cloudai/deployments/$DEP" ]
}
