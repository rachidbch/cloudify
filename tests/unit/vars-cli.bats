#!/usr/bin/env bats
# Branch 1b: vars CLI surface, declaration kinds, `vars declared`,
# write-time reference validation, JSON list escaping.
# Pinned tests (deployments/remote-vars/vars) stay unmodified.

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/deployments.sh
    source lib/remote.sh
    unset _CLOUDIFY_VARS_LEDGER _CLOUDIFY_VARS_DECLARED
}

teardown() {
    teardown_test_env
}

# --- T1/T2: declaration kinds ---

@test "declaration: bare NAME is required, NAME=value defaulted, NAME= optional" {
    mkdir -p "$CLOUDIFY_DIR/pkg/kinds"
    cat > "$CLOUDIFY_DIR/pkg/kinds/.remote-vars" <<'EOF'
REQ_VAR
DEF_VAR=fallback
OPT_VAR=
EOF
    printf 'REQ_VAR: g\nDEF_VAR: g\nOPT_VAR: g\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    unset REQ_VAR DEF_VAR OPT_VAR
    _cloudify_pkg_remote_vars install kinds > /dev/null 2>&1
    [ "$REQ_VAR" = "g" ]
    [ "$DEF_VAR" = "g" ]
    [ "$OPT_VAR" = "g" ]
}

@test "declaration: default value is never exported as a value source (L1b2)" {
    mkdir -p "$CLOUDIFY_DIR/pkg/kinds"
    printf 'DEF_ONLY=mirror-default\n' > "$CLOUDIFY_DIR/pkg/kinds/.remote-vars"
    unset DEF_ONLY
    _cloudify_pkg_remote_vars install kinds > /dev/null 2>&1
    [ -z "${DEF_ONLY:-}" ]
}

@test "declaration: warn fires only for a required name with no value (R1b-4)" {
    mkdir -p "$CLOUDIFY_DIR/pkg/kinds"
    printf 'REQ_VAR\nDEF_VAR=mirror\nOPT_VAR=\n' > "$CLOUDIFY_DIR/pkg/kinds/.remote-vars"
    unset REQ_VAR DEF_VAR OPT_VAR
    _cloudify_pkg_remote_vars install kinds > /dev/null 2> "$CLOUDIFY_TMP/err"
    grep -q "REQ_VAR" "$CLOUDIFY_TMP/err"
    ! grep -q "DEF_VAR" "$CLOUDIFY_TMP/err"
    ! grep -q "OPT_VAR" "$CLOUDIFY_TMP/err"
}

@test "declaration: tabs and CRLF are tolerated (R1b-5)" {
    mkdir -p "$CLOUDIFY_DIR/pkg/kinds"
    printf 'TAB_VAR\t\r\n' > "$CLOUDIFY_DIR/pkg/kinds/.remote-vars"
    printf 'TAB_VAR: g\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    unset TAB_VAR
    _cloudify_pkg_remote_vars install kinds > /dev/null 2>&1
    [ "$TAB_VAR" = "g" ]
}

@test "declaration: bare NAME back-compat still takes the caller env value (I1b1)" {
    mkdir -p "$CLOUDIFY_DIR/pkg/kinds"
    printf 'BARE\n' > "$CLOUDIFY_DIR/pkg/kinds/.remote-vars"
    export BARE=fromenv
    _cloudify_pkg_remote_vars install kinds > /dev/null 2>&1
    [ "$BARE" = "fromenv" ]
}

# --- T3/T4: scope parsing ---

@test "parse_args: scope flags and positionals" {
    _cloudify_vars_parse_args set MYKEY myval --global
    [ "$_CV_SCOPE" = global ]
    [ "${_CV_POS[0]}" = set ] || true
}

@test "parse_args: --pkg consumes its name, --deployment its id" {
    _cloudify_vars_parse_args K V --pkg mypkg
    [ "$_CV_SCOPE" = pkg ]
    [ "$_CV_SCOPE_ARG" = mypkg ]
    [ "${_CV_POS[0]}" = K ]
    [ "${_CV_POS[1]}" = V ]
    _cloudify_vars_parse_args K V --deployment dep1
    [ "$_CV_SCOPE" = deployment ]
    [ "$_CV_SCOPE_ARG" = dep1 ]
}

@test "parse_args: scope flags are mutually exclusive" {
    run _cloudify_vars_parse_args K V --global --pkg x
    [ "$status" -ne 0 ]
}

@test "parse_args: --stdin and --file are mutually exclusive" {
    run _cloudify_vars_parse_args K --stdin --file /tmp/x
    [ "$status" -ne 0 ]
}

@test "parse_args: -- sentinel makes a flag-looking value positional" {
    _cloudify_vars_parse_args K -- --weird
    [ "${_CV_POS[0]}" = K ]
    [ "${_CV_POS[1]}" = --weird ]
    [ "$_CV_VALUE_MODE" = literal ]
}

@test "parse_args: unknown flag dies" {
    run _cloudify_vars_parse_args K V --nope
    [ "$status" -ne 0 ]
}

# --- T5/T7: store ops, validation, JSON ---

@test "store: set/get round-trip, missing key is empty with rc 0" {
    _cloudify_vars_file_set "$CLOUDIFY_TMP/store.yaml" KEEPER "value one" 1
    [ "$(_cloudify_vars_store_get "$CLOUDIFY_TMP/store.yaml" KEEPER)" = "value one" ]
    run _cloudify_vars_store_get "$CLOUDIFY_TMP/store.yaml" MISSING
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "store: list --json escapes quotes and backslashes, skips comments" {
    cat > "$CLOUDIFY_TMP/store.yaml" <<'EOF'
# a comment
PLAIN: simple
QUOTED: he said "hi"
BACK: a\b
EOF
    run _cloudify_vars_store_list "$CLOUDIFY_TMP/store.yaml" --json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -m json.tool >/dev/null
    echo "$output" | grep -q '"PLAIN": "simple"'
    ! echo "$output" | grep -q 'a comment'
}

@test "store: delete removes only the key" {
    _cloudify_vars_file_set "$CLOUDIFY_TMP/store.yaml" K1 v1 1
    _cloudify_vars_file_set "$CLOUDIFY_TMP/store.yaml" K2 v2 1
    _cloudify_vars_store_delete "$CLOUDIFY_TMP/store.yaml" K1
    [ -z "$(_cloudify_vars_store_get "$CLOUDIFY_TMP/store.yaml" K1)" ]
    [ "$(_cloudify_vars_store_get "$CLOUDIFY_TMP/store.yaml" K2)" = "v2" ]
}

@test "write: global/pkg reject lowercase keys, deployment allows them (R1b-9)" {
    run cloudify_vars_global_write lower value
    [ "$status" -ne 0 ]
    run cloudify_vars_pkg_write mypkg lower value
    [ "$status" -ne 0 ]
    cloudify_deployment_create dep
    export CLOUDIFY_DEPLOYMENT=dep
    run cloudify_vars_deployment_write lower value
    [ "$status" -eq 0 ]
}

@test "write: literal @ value dies with the @@ hint, @@ and @base64: are accepted (R1b-7 A)" {
    run cloudify_vars_global_write AT_PLAIN "@notaref"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "@@"
    run cloudify_vars_global_write AT_ESC "@@literal"
    [ "$status" -eq 0 ]
    run cloudify_vars_global_write AT_B64 "@base64:YWJj"
    [ "$status" -eq 0 ]
    run cloudify_vars_global_write AT_UNKNOWN "@nope:x"
    [ "$status" -ne 0 ]
}

# --- T6: vars declared ---

@test "declared: three kinds, sources, masking" {
    mkdir -p "$CLOUDIFY_DIR/pkg/decl"
    cat > "$CLOUDIFY_DIR/pkg/decl/.remote-vars" <<'EOF'
REQ
DEF=fallback
OPT=
API_TOKEN=secret-default
EOF
    printf 'DEF: fromglobal\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    export REQ=fromenv
    run cloudify_vars_declared decl
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "REQ"
    echo "$output" | grep -qx "DEF=fallback"
    echo "$output" | grep -qx "OPT="
    echo "$output" | grep -qxF "API_TOKEN=***"
    run cloudify_vars_declared decl --sources
    echo "$output" | grep -qP '^REQ\tenv$'
    echo "$output" | grep -qP '^DEF=fallback\tglobal$'
    echo "$output" | grep -qP '^OPT=\trecipe-default$'
}

@test "declared: unknown package dies, no declaration prints a notice" {
    run cloudify_vars_declared nope
    [ "$status" -ne 0 ]
    mkdir -p "$CLOUDIFY_DIR/pkg/empty"
    run cloudify_vars_declared empty
    [ "$status" -eq 0 ]
    [ "$output" = "(no declared vars)" ]
}

# --- router wiring (subprocess; shell-router.bats has no vars coverage) ---

run_router() {
    mkdir -p "$CLOUDIFY_TMP/home"
    run env HOME="$CLOUDIFY_TMP/home" \
        CLOUDIFY_DIR="$CLOUDIFY_DIR" \
        CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_CREDENTIALS_DIR" \
        CLOUDIFY_CREDENTIALS_FILE="$CLOUDIFY_CREDENTIALS_FILE" \
        CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_DISABLE_COLORS=true DEBUG=false \
        bash "$CLOUDIFY_SCRIPT_DIR/cloudify" "$@"
}

@test "router: scoped set/show/list --global" {
    run_router vars set MY_GLOBAL myval --global
    [ "$status" -eq 0 ]
    run_router vars show MY_GLOBAL --global
    [ "$status" -eq 0 ]
    [ "$output" = "myval" ]
    run_router vars list --json --global
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"MY_GLOBAL": "myval"'
}

@test "router: --stdin preserves trailing newlines (R1b-10)" {
    printf 'a\n\n' > "$CLOUDIFY_TMP/in"
    run_router vars set STDIN_VAR --stdin --global < "$CLOUDIFY_TMP/in"
    [ "$status" -eq 0 ]
    local stored
    stored=$(grep '^STDIN_VAR:' "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml" | sed 's/^STDIN_VAR: //')
    [[ "$stored" == @base64:* ]]
    printf '%s' "${stored#@base64:}" | base64 -d > "$CLOUDIFY_TMP/out"
    cmp -s "$CLOUDIFY_TMP/in" "$CLOUDIFY_TMP/out"
}

@test "router: literal @ value dies with the hint (R1b-7)" {
    run_router vars set AT_VAR "@foo" --global
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "@@"
}

@test "router: vars declared end to end" {
    mkdir -p "$CLOUDIFY_DIR/pkg/decl"
    printf 'REQ\nDEF=fb\nOPT=\n' > "$CLOUDIFY_DIR/pkg/decl/.remote-vars"
    run_router vars declared decl
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "REQ"
    echo "$output" | grep -qx "DEF=fb"
    echo "$output" | grep -qx "OPT="
}

# --- R9 (re-anchored): printing secrets is opt-in; --resolve ships ---

@test "router: secret values masked by default, --reveal prints them" {
    run_router vars set MY_TOKEN tok --global
    [ "$status" -eq 0 ]
    run_router vars show MY_TOKEN --global
    [ "$output" = "***" ]
    run_router vars show MY_TOKEN --global --reveal
    [ "$output" = "tok" ]
    run_router vars list --global
    echo "$output" | grep -q "MY_TOKEN: ***"
    run_router vars list --global --reveal
    echo "$output" | grep -q "MY_TOKEN: tok"
    run_router vars list --json --global
    echo "$output" | grep -q '"MY_TOKEN": "***"'
}

@test "router: --resolve decodes a reference, still masked unless --reveal" {
    local b64
    b64=$(printf 's3cr3t' | base64 -w0)
    run_router vars set REF_SECRET "@base64:$b64" --global
    [ "$status" -eq 0 ]
    run_router vars show REF_SECRET --global
    [ "$output" = "***" ]
    run_router vars show REF_SECRET --global --resolve
    [ "$output" = "***" ]
    run_router vars show REF_SECRET --global --resolve --reveal
    [ "$output" = "s3cr3t" ]
}

@test "router: --resolve on a non-secret name prints plaintext" {
    local b64
    b64=$(printf 'https://host:6443' | base64 -w0)
    run_router vars set ENDPOINT_URL "@base64:$b64" --global
    [ "$status" -eq 0 ]
    run_router vars show ENDPOINT_URL --global --resolve
    [ "$output" = "https://host:6443" ]
}

@test "router: vars declared --reveal shows a masked default" {
    mkdir -p "$CLOUDIFY_DIR/pkg/decl"
    printf 'API_TOKEN=secret-default\n' > "$CLOUDIFY_DIR/pkg/decl/.remote-vars"
    run_router vars declared decl
    echo "$output" | grep -qxF "API_TOKEN=***"
    run_router vars declared decl --reveal
    echo "$output" | grep -qxF "API_TOKEN=secret-default"
}

@test "router: vars list rejects --resolve" {
    run_router vars list --global --resolve
    [ "$status" -ne 0 ]
}
