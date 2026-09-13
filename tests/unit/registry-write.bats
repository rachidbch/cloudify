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
    source lib/packages.sh
    source lib/deployments.sh
    source lib/vars.sh
    source lib/registry.sh
    source lib/context.sh

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
    declare -gA _CLOUDIFY_BG_CONTEXT=()
    unset CLOUDIFY_DEPLOYMENT CLOUDIFY_LEGACY_VARS
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

# _ctx <pkg...> - build a REAL dispatch context (lib/context.sh) for the current
# stores and caller env, exactly as a dispatch would; print its path. The build
# exports into a subshell so no resolved literal leaks into the test shell.
_ctx() {
    local ctx cand p
    ctx=$(mktemp "$CLOUDIFY_TMP/dispatch-context-XXXXXX")
    chmod 600 "$ctx"
    cand=$(mktemp)
    for p in "$@"; do
        _cloudify_context_emit_declared "$p" >> "$cand"
    done
    ( export CLOUDIFY_CONTEXT_FILE="$ctx"
      cloudify_context_build install "$DEP" install "$cand" "$@" > /dev/null )
    rm -f "$cand"
    printf '%s\n' "$ctx"
}

# _reset_stores - empty every var store so one matrix case cannot leak into the
# next.
_reset_stores() {
    rm -f "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    rm -rf "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    rm -f "$(_cloudify_deployment_config "$DEP")"
}

# _norm <record-text> - blank the write-time timestamps, which depend on the
# clock and not on the value source, before comparing two records.
_norm() {
    sed -E 's/^(installed_at|configured_at|removed_at):.*/\1: <ts>/' <<< "$1"
}

# _equiv <label> <pkg> - build the record twice (legacy walker vs dispatch
# context) and require equal record texts. Prints both records on mismatch.
_equiv() {
    local label="$1" pkg="$2" ctx legacy context
    ctx=$(_ctx "$pkg")
    legacy=$(CLOUDIFY_LEGACY_VARS=1 cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" "$pkg" 2>/dev/null)
    context=$(cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" "$pkg" "$ctx" 2>/dev/null)
    rm -f "$ctx"
    if [[ "$(_norm "$legacy")" != "$(_norm "$context")" ]]; then
        printf '\ncase %s: legacy record:\n%s\ncase %s: context record:\n%s\n' \
            "$label" "$legacy" "$label" "$context" >&2
        return 1
    fi
    step "case $label: equal ($(grep -c '^var\.' <<< "$context" || true) var line(s))"
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
# var snapshot (context-free calls: the legacy value source, kept reachable
# behind CLOUDIFY_LEGACY_VARS=1; the context-driven path is covered by the
# equivalence + context-record tests above)
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
    _CLOUDIFY_BG_CONTEXT[7]=$(_ctx bats-test vim)
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

# ---------------------------------------------------------------
# Context-driven record (slice 2B-ii)
# ---------------------------------------------------------------

@test "equivalence: the context-driven record equals the legacy record for the matrix" {
    rubric "every var.<NAME> row is identical whether it comes from _cloudify_registry_raw_var or the dispatch context"
    IVPS_NODES=(cloudai)

    # 1. caller env only
    _declare eq-env 'EQ_ENV'
    _reset_stores
    export EQ_ENV=env-value
    _equiv "caller env only" eq-env || return 1
    unset EQ_ENV

    # 2. deployment store only
    _declare eq-dep 'EQ_DEP'
    _reset_stores
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" EQ_DEP deployment-value
    _equiv "deployment only" eq-dep || return 1

    # 3. package yaml only
    _declare eq-pkg 'EQ_PKG'
    _reset_stores
    cloudify_vars_pkg_write eq-pkg EQ_PKG package-value
    _equiv "package only" eq-pkg || return 1

    # 4. global store only
    _declare eq-global 'EQ_GLOBAL'
    _reset_stores
    cloudify_vars_global_write EQ_GLOBAL global-value
    _equiv "global only" eq-global || return 1

    # 5. caller env plus a conflicting deployment value (the red case)
    _declare eq-conflict 'EQ_CONFLICT'
    _reset_stores
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" EQ_CONFLICT deployment-value
    export EQ_CONFLICT=caller-value
    _equiv "caller env beats deployment" eq-conflict || return 1
    unset EQ_CONFLICT

    # 6. a @base64: reference from a store
    _declare eq-ref 'EQ_REF'
    _reset_stores
    cloudify_vars_pkg_write eq-ref EQ_REF '@base64:aGVsbG8='
    _equiv "@base64 reference" eq-ref || return 1

    # 7. a multiline stored value
    _declare eq-multi 'EQ_MULTI'
    _reset_stores
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" EQ_MULTI $'line one\nline two'
    _equiv "multiline stored value" eq-multi || return 1

    # 8. a declared name no source provides
    _declare eq-gone 'EQ_GONE'
    _reset_stores
    unset EQ_GONE
    _equiv "declared but unprovided" eq-gone || return 1

    # 9. an undeclared ambient name never enters either record
    _declare eq-ambient 'EQ_DECLARED'
    _reset_stores
    export EQ_DECLARED=declared-value EQ_AMBIENT=ambient-leak
    _equiv "undeclared ambient name" eq-ambient || return 1
    local ctx
    ctx=$(_ctx eq-ambient)
    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" eq-ambient "$ctx"
    rm -f "$ctx"
    [[ "$output" != *"EQ_AMBIENT"* ]]
    unset EQ_DECLARED EQ_AMBIENT
    _reset_stores
}

@test "context record: the reference form is recorded verbatim (raw, inv 18)" {
    rubric "a store's @base64: text reaches var.<NAME> unchanged, from the context"
    IVPS_NODES=(cloudai)
    _declare ctx-ref 'CTX_REF'
    _reset_stores
    cloudify_vars_pkg_write ctx-ref CTX_REF '@base64:aGVsbG8='
    local ctx
    ctx=$(_ctx ctx-ref)
    run cloudify_registry_record_build install "$DEP" "$NODE" "" "$HOST" ctx-ref "$ctx"
    rm -f "$ctx"
    [ "$status" -eq 0 ]
    [ "$(_field var.CTX_REF "$output")" = "@base64:aGVsbG8=" ]
}

@test "wait loop: a missing or unreadable context writes no record and warns" {
    rubric "no context -> no record, never a second walk (design section 5)"
    IVPS_NODES=(cloudai)
    _declare absent-pkg 'ABSENT_VAR'
    export ABSENT_VAR=leak
    export CLOUDIFY_DEPLOYMENT="$DEP"

    _CLOUDIFY_BG_ACTION[11]=install
    _CLOUDIFY_BG_PKGS[11]=absent-pkg
    _CLOUDIFY_BG_TARGET[11]=$'cloudai\t\tcloudify'
    _CLOUDIFY_BG_CONTEXT[11]="$CLOUDIFY_TMP/does-not-exist.yaml"
    run _cloudify_registry_record_bg 11
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing or unreadable"* ]]

    _CLOUDIFY_BG_ACTION[12]=install
    _CLOUDIFY_BG_PKGS[12]=absent-pkg
    _CLOUDIFY_BG_TARGET[12]=$'cloudai\t\tcloudify'
    _CLOUDIFY_BG_CONTEXT[12]=""
    run _cloudify_registry_record_bg 12
    unset ABSENT_VAR
    [ "$status" -eq 0 ]
    [[ "$output" == *"missing or unreadable"* ]]

    [ ! -e "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/absent-pkg/config.yaml" ]
}

@test "wait loop: the dispatch context is removed after the write" {
    rubric "the parent owns the context file (design section 5)"
    IVPS_NODES=(cloudai)
    _declare ctx-owned 'CTX_OWNED'
    local ctx
    ctx=$(_ctx ctx-owned)
    [ -f "$ctx" ]
    _CLOUDIFY_BG_ACTION[15]=install
    _CLOUDIFY_BG_PKGS[15]=ctx-owned
    _CLOUDIFY_BG_TARGET[15]=$'cloudai\t\tcloudify'
    _CLOUDIFY_BG_CONTEXT[15]="$ctx"
    export CLOUDIFY_DEPLOYMENT="$DEP"

    run _cloudify_registry_record_bg 15
    [ "$status" -eq 0 ]
    [ ! -e "$ctx" ]
    [ -f "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/ctx-owned/config.yaml" ]
}

@test "wait loop: CLOUDIFY_LEGACY_VARS=1 writes the record with no context" {
    rubric "rollback switch -> the pre-Phase-2 walker, unchanged (design section 6.7)"
    IVPS_NODES=(cloudai)
    _declare legacy-pkg 'LEGACY_VAR'
    export LEGACY_VAR=legacy-value CLOUDIFY_DEPLOYMENT="$DEP" CLOUDIFY_LEGACY_VARS=1
    _CLOUDIFY_BG_ACTION[13]=install
    _CLOUDIFY_BG_PKGS[13]=legacy-pkg
    _CLOUDIFY_BG_TARGET[13]=$'cloudai\t\tcloudify'
    _CLOUDIFY_BG_CONTEXT[13]=""

    run _cloudify_registry_record_bg 13
    [ "$status" -eq 0 ]
    grep -q "^var.LEGACY_VAR: legacy-value$" \
        "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/legacy-pkg/config.yaml"
}
