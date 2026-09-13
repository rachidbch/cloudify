#!/usr/bin/env bats
# Slice 2B-i wiring: the remote payload and the local dispatch take their value
# names and exported literals from cloudify_context_build (lib/context.sh)
# instead of the legacy _cloudify_pkg_remote_vars walker, and the payload TEXT
# stays byte-identical for every fixture case in the matrix below. The
# CLOUDIFY_LEGACY_VARS=1 rollback switch restores the walker unchanged.
#
# The real transport is exercised: a stubbed ssh reads the payload from stdin
# (never argv) and records both the payload and the ssh argument string.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/targets.sh
    source lib/runbooks.sh
    source lib/context.sh
    source lib/remote.sh

    export CLOUDIFY_REMOTE_USER=testuser
    export CLOUDIFY_REMOTE_PWD=dummy
    export DEBUG=false
    export CLOUDIFY_CONTEXT_TARGET=$'local\t\tlocalhost'
    cloudify_init_log

    unset CLOUDIFY_NODE IVPS_DEFAULT_NODE
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:xfce-test)
    IVPS_LIST_RC=0

    export DEP="wiring-dep"
    cloudify_deployment_create "$DEP" >/dev/null
    export CLOUDIFY_DEPLOYMENT="$DEP"

    CAP_DIR="$CLOUDIFY_TMP/capture"
    mkdir -p "$CAP_DIR"
    export CAP_DIR

    unset CLOUDIFY_CONTEXT_FILE CLOUDIFY_LEGACY_VARS
    unset FIX_ENV_ONLY FIX_DEP_ONLY FIX_PKG_ONLY FIX_GLOBAL_ONLY FIX_REF_SECRET
    unset FIX_MULTILINE FIX_SHARED FIX_DEP_VALUE FIX_ALPHA_ONLY

    # Payload on stdin, argv into a file: no value may appear in argv (inv 2/13).
    ssh() {
        printf '%s' "$*" > "$CAP_OUT.argv"
        cat > "$CAP_OUT.payload"
        return 0
    }
}

teardown() {
    teardown_test_env
}

# ivps stub as a shell function (shadows any real ivps in PATH): the runbook
# preflight needs target resolution, nothing else.
ivps() {
    local sub="${1:-}" e r
    case "$sub" in
        node)
            for e in ${IVPS_NODES[@]+"${IVPS_NODES[@]}"}; do
                [[ "$e" == "${3:-}" ]] && { echo "/ivps/nodes/${3:-}"; return 0; }
            done
            return 1
            ;;
        list)
            [[ "${IVPS_LIST_RC:-0}" -eq 0 ]] || return "$IVPS_LIST_RC"
            echo "  REMOTE:NAME      STATUS"
            for r in ${IVPS_ROWS[@]+"${IVPS_ROWS[@]}"}; do
                printf '  %-30s Running\n' "$r"
            done
            return 0
            ;;
        *) return 1 ;;
    esac
}

# --- fixtures ---------------------------------------------------------------

declare_pkg() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

recipe_for() {
    local pkg="$1"
    shift
    printf 'pkg_depends %s\n' "$*" > "$CLOUDIFY_DIR/pkg/$pkg/install.sh"
}

set_deployment() { _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" "$1" "$2"; }
set_pkg() { cloudify_vars_pkg_write "$1" "$2" "$3"; }
set_global() { cloudify_vars_global_write "$1" "$2"; }

reset_stores() {
    rm -f "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    rm -rf "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    : > "$(_cloudify_deployment_config "$DEP")"
}

b64() { printf '%s' "$1" | base64 -w0; }

# --- harness ----------------------------------------------------------------

# capture <legacy|context> <name> <remote command words...>
# One dispatch per subshell, so the resolved exports never leak into the test
# shell and both runs start from the same stores and caller environment.
capture() {
    local mode="$1" name="$2"
    shift 2
    if [[ "$mode" == legacy ]]; then
        ( export CLOUDIFY_LEGACY_VARS=1
          CAP_OUT="$CAP_DIR/$name.legacy"
          cloudify_remote_sync somehost "$@" ) > "$CAP_DIR/$name.log" 2>&1
    else
        ( CAP_OUT="$CAP_DIR/$name.context"
          cloudify_remote_sync somehost "$@" ) > "$CAP_DIR/$name.log" 2>&1
    fi
}

# assert_identical <name> - the two captured payloads are byte-equal
assert_identical() {
    local name="$1"
    [ -f "$CAP_DIR/$name.legacy.payload" ]
    [ -f "$CAP_DIR/$name.context.payload" ]
    if ! cmp -s "$CAP_DIR/$name.legacy.payload" "$CAP_DIR/$name.context.payload"; then
        diff -u "$CAP_DIR/$name.legacy.payload" "$CAP_DIR/$name.context.payload" || true
        return 1
    fi
    step "payload $name: $(wc -c < "$CAP_DIR/$name.legacy.payload") bytes, byte-identical"
}

# assert_case <name> <expected export line> - the line is present in BOTH
# payloads (no false 'both empty' pass) and the two files are byte-equal.
assert_case() {
    local name="$1" expected="$2"
    grep -qF "$expected" "$CAP_DIR/$name.legacy.payload"
    grep -qF "$expected" "$CAP_DIR/$name.context.payload"
    assert_identical "$name"
}

# --- the fixture matrix: legacy payload == context payload -------------------

@test "matrix caller env only: payload byte-identical" {
    declare_pkg foo FIX_ENV_ONLY
    reset_stores
    export FIX_ENV_ONLY=env-value
    capture legacy env install foo
    capture context env install foo
    unset FIX_ENV_ONLY
    assert_case env "export FIX_ENV_ONLY='env-value'"
}

@test "matrix deployment store only: payload byte-identical" {
    declare_pkg foo FIX_DEP_ONLY
    reset_stores
    set_deployment FIX_DEP_ONLY deployment-value
    capture legacy dep install foo
    capture context dep install foo
    assert_case dep "export FIX_DEP_ONLY='deployment-value'"
}

@test "matrix package yaml only: payload byte-identical" {
    declare_pkg foo FIX_PKG_ONLY
    reset_stores
    set_pkg foo FIX_PKG_ONLY package-value
    capture legacy pkg install foo
    capture context pkg install foo
    assert_case pkg "export FIX_PKG_ONLY='package-value'"
}

@test "matrix global only: payload byte-identical" {
    declare_pkg foo FIX_GLOBAL_ONLY
    reset_stores
    set_global FIX_GLOBAL_ONLY global-value
    capture legacy global install foo
    capture context global install foo
    assert_case global "export FIX_GLOBAL_ONLY='global-value'"
}

@test "matrix @base64 reference in the deployment store: payload byte-identical" {
    declare_pkg foo FIX_REF_SECRET
    reset_stores
    set_deployment FIX_REF_SECRET "@base64:$(b64 'admin-secret')"
    capture legacy ref install foo
    capture context ref install foo
    assert_case ref "export FIX_REF_SECRET='admin-secret'"
}

@test "matrix multiline stored value: payload byte-identical" {
    declare_pkg foo FIX_MULTILINE
    reset_stores
    set_deployment FIX_MULTILINE $'line-one\nline-two'
    capture legacy multiline install foo
    capture context multiline install foo
    grep -qF "export FIX_MULTILINE='line-one" "$CAP_DIR/multiline.context.payload"
    grep -qF "line-two'" "$CAP_DIR/multiline.context.payload"
    assert_identical multiline
}

@test "matrix two packages, rightmost wins: payload byte-identical" {
    declare_pkg alpha FIX_SHARED
    declare_pkg beta FIX_SHARED
    reset_stores
    set_pkg alpha FIX_SHARED from-alpha
    set_pkg beta FIX_SHARED from-beta
    capture legacy rightmost install alpha beta
    capture context rightmost install alpha beta
    assert_case rightmost "export FIX_SHARED='from-beta'"
    ! grep -qF 'from-alpha' "$CAP_DIR/rightmost.legacy.payload"
    ! grep -qF 'from-alpha' "$CAP_DIR/rightmost.context.payload"
}

@test "matrix package with a dependency: payload byte-identical" {
    declare_pkg alpha FIX_ALPHA_ONLY
    declare_pkg dep FIX_DEP_VALUE
    recipe_for alpha dep
    reset_stores
    set_pkg alpha FIX_ALPHA_ONLY alpha-value
    set_pkg dep FIX_DEP_VALUE dep-value
    capture legacy dependency install alpha
    capture context dependency install alpha
    assert_case dependency "export FIX_ALPHA_ONLY='alpha-value'"
    grep -qF "export FIX_DEP_VALUE='dep-value'" "$CAP_DIR/dependency.context.payload"
}

# --- transport: nothing new in ssh argv, no path, no value ------------------

@test "the ssh argv is only the host and 'bash -s'" {
    declare_pkg foo FIX_DEP_ONLY
    reset_stores
    set_deployment FIX_DEP_ONLY deployment-value
    capture context argv-check install foo
    local argv stripped
    argv=$(cat "$CAP_DIR/argv-check.context.argv")
    stripped=$(printf '%s' "$argv" | sed -E \
        's/-o (UserKnownHostsFile=[^ ]*|StrictHostKeyChecking=no|ConnectTimeout=[0-9]+)//g; s/^ +//; s/ +$//; s/ +/ /g')
    step "argv after the documented -o options: $stripped"
    [ "$stripped" = "testuser@somehost bash -s" ]
    subrubric "no context path and no value in argv"
    [[ "$argv" != *"cloudify-context"* ]]
    [[ "$argv" != *"deployment-value"* ]]
}

@test "the parent-created context file is filled by the child, mode 600, no plaintext" {
    declare_pkg foo FIX_REF_SECRET
    reset_stores
    set_deployment FIX_REF_SECRET "@base64:$(b64 'fixture-secret-xyz')"
    local ctx="$CAP_DIR/parent-context.yaml"
    : > "$ctx"
    chmod 600 "$ctx"
    export CLOUDIFY_CONTEXT_FILE="$ctx"
    capture context kept install foo
    unset CLOUDIFY_CONTEXT_FILE

    subrubric "the child filled the parent's file"
    [ -s "$ctx" ]
    [ "$(stat -c '%a' "$ctx")" = "600" ]
    [ "$(cloudify_context_read "$ctx" value.FIX_REF_SECRET.source)" = "deployment" ]
    [ "$(cloudify_context_read "$ctx" value.FIX_REF_SECRET.form)" = "reference" ]
    [ "$(cloudify_context_read "$ctx" value.FIX_REF_SECRET.reference)" = "@base64:$(b64 'fixture-secret-xyz')" ]

    subrubric "metadata only: the literal appears nowhere in the file or the log"
    ! grep -q 'fixture-secret-xyz' "$ctx"
    ! grep -rq 'fixture-secret-xyz' "$CLOUDIFY_TMP/logs"
}

# --- the dispatch-facing wrapper --------------------------------------------

@test "_cloudify_dispatch_vars exports the resolved literals into the caller shell" {
    declare_pkg foo FIX_DEP_ONLY
    reset_stores
    set_deployment FIX_DEP_ONLY deployment-value
    unset FIX_DEP_ONLY
    local ctx="$CAP_DIR/helper-ctx.yaml" names="$CAP_DIR/helper-names"
    : > "$ctx"
    chmod 600 "$ctx"
    export CLOUDIFY_CONTEXT_FILE="$ctx"

    # Called in THIS shell (never $()): the export must survive (inv 1).
    _cloudify_dispatch_vars "$names" install "$DEP" install foo
    [ "$FIX_DEP_ONLY" = "deployment-value" ]
    [ "$(cat "$names")" = "FIX_DEP_ONLY" ]
    unset FIX_DEP_ONLY CLOUDIFY_CONTEXT_FILE
}

@test "_cloudify_dispatch_vars honours CLOUDIFY_LEGACY_VARS for the same dispatch" {
    declare_pkg foo FIX_DEP_ONLY
    reset_stores
    set_deployment FIX_DEP_ONLY deployment-value
    set_pkg foo FIX_DEP_ONLY package-value
    unset FIX_DEP_ONLY
    local ctx="$CAP_DIR/switch-ctx.yaml"
    : > "$ctx"
    chmod 600 "$ctx"
    export CLOUDIFY_CONTEXT_FILE="$ctx"

    _cloudify_dispatch_vars "$CAP_DIR/switch-context.names" install "$DEP" install foo
    local ctx_value="$FIX_DEP_ONLY"
    unset FIX_DEP_ONLY
    export CLOUDIFY_LEGACY_VARS=1
    _cloudify_dispatch_vars "$CAP_DIR/switch-legacy.names" install "$DEP" install foo
    unset CLOUDIFY_LEGACY_VARS CLOUDIFY_CONTEXT_FILE
    local legacy_value="$FIX_DEP_ONLY"
    unset FIX_DEP_ONLY

    step "context='$ctx_value' legacy='$legacy_value'"
    [ "$ctx_value" = "deployment-value" ]
    [ "$legacy_value" = "$ctx_value" ]
    cmp -s "$CAP_DIR/switch-context.names" "$CAP_DIR/switch-legacy.names"
}

@test "cloudify_remote creates the context file in the parent and exports its path" {
    cloudify_remote_sync() { :; }
    _CLOUDIFY_BG_PIDS=()
    _CLOUDIFY_BG_HOSTS=()
    unset CLOUDIFY_CONTEXT_FILE

    cloudify_remote somehost "install foo"

    [ -n "${CLOUDIFY_CONTEXT_FILE:-}" ]
    [[ "$CLOUDIFY_CONTEXT_FILE" == "$CLOUDIFY_TMP/"* ]]
    [ -f "$CLOUDIFY_CONTEXT_FILE" ]
    [ "$(stat -c '%a' "$CLOUDIFY_CONTEXT_FILE")" = "600" ]
}

@test "CLOUDIFY_LEGACY_VARS=1 leaves the context path unset (rollback)" {
    cloudify_remote_sync() { :; }
    _CLOUDIFY_BG_PIDS=()
    _CLOUDIFY_BG_HOSTS=()
    unset CLOUDIFY_CONTEXT_FILE
    export CLOUDIFY_LEGACY_VARS=1

    cloudify_remote somehost "install foo"
    unset CLOUDIFY_LEGACY_VARS

    [ -z "${CLOUDIFY_CONTEXT_FILE:-}" ]
}

# --- router wiring (the router always runs main, so it is not sourcable) ----

@test "the router's local install dispatch creates and fills a 0600 context file" {
    # Black-box: the real router, a stubbed @default package and one fixture
    # package whose recipe reports the forwarded value. The parent removes the
    # dispatch context after the registry write (design section 5), so the test
    # snapshots it while the run is in flight: the file is created before the
    # background dispatch and filled atomically (mv) by the child, so a copy
    # taken while it is non-empty is the child's context.
    local home cfg
    home=$(mktemp -d "$CLOUDIFY_TMP/home.XXXXXX")
    cfg="$CLOUDIFY_TMP/lp-config"
    mkdir -p "$cfg/pkgs" "$CLOUDIFY_DIR/pkg/basics" "$CLOUDIFY_DIR/pkg/localtest"
    printf '# no-op basics (test stub)\n' > "$CLOUDIFY_DIR/pkg/basics/init.sh"
    cat > "$CLOUDIFY_DIR/pkg/localtest/init.sh" <<EOF
echo "\${LOCAL_VAR:-unset}" > "$CLOUDIFY_TMP/local-var-out"
EOF
    printf 'LOCAL_VAR: fromyaml\n' > "$cfg/pkgs/localtest.yaml"

    # The router pins CLOUDIFY_TMP (cloudify constants, overriding the env), so
    # the dispatch context lands there. Only files this run creates are captured.
    local ctx_root before_file saved ctx_path ctx_pid ctx
    ctx_root=$(sed -n 's/^export CLOUDIFY_TMP=//p' "$CLOUDIFY_SCRIPT_DIR/cloudify" | head -1)
    # The router creates this on its first run (cloudify:123), so a fresh
    # container must not make this test depend on an earlier run having done it.
    mkdir -p "$ctx_root"
    [ -d "$ctx_root" ]
    before_file="$CLOUDIFY_TMP/ctx-before"
    ls "$ctx_root"/cloudify-context-* > "$before_file" 2>/dev/null || true
    saved="$CLOUDIFY_TMP/ctx-captured"
    ctx_path="$CLOUDIFY_TMP/ctx-path"
    (
        for ((_i = 0; _i < 2000; _i++)); do
            for _f in "$ctx_root"/cloudify-context-*; do
                [[ -f "$_f" && -s "$_f" ]] || continue
                # The @default pre-pass fills the same file first (an empty name
                # set); wait for the fixture's name to appear.
                grep -q '^value.LOCAL_VAR.source:' "$_f" 2>/dev/null || continue
                if grep -qxF "$_f" "$before_file"; then continue; fi
                cp -p "$_f" "$saved"
                printf '%s\n' "$_f" > "$ctx_path"
                exit 0
            done
            sleep 0.01
        done
        exit 1
    ) &
    ctx_pid=$!

    run env HOME="$home" \
        CLOUDIFY_DIR="$CLOUDIFY_DIR" \
        CLOUDIFY_CREDENTIALS_DIR="$cfg" \
        CLOUDIFY_CREDENTIALS_FILE="$cfg/credentials" \
        CLOUDIFY_TMP="$CLOUDIFY_TMP" \
        CLOUDIFY_LOCAL_BIN="$CLOUDIFY_TMP/.local/bin" \
        CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_SCRIPT_DIR" \
        CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_DISABLE_COLORS=true DEBUG=true \
        bash "$CLOUDIFY_SCRIPT_DIR/cloudify" --no-defaults --no-verify install localtest
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/local-var-out")" = "fromyaml" ]

    wait "$ctx_pid" || true
    ctx=$(cat "$ctx_path" 2>/dev/null || true)
    step "context file: ${ctx:-none} (captured while in flight)"
    [ -n "$ctx" ]
    [ "$(stat -c '%a' "$saved")" = "600" ]
    [ "$(cloudify_context_read "$saved" action)" = "install" ]
    [ "$(cloudify_context_read "$saved" value.LOCAL_VAR.source)" = "package" ]
    [ "$(cloudify_context_read "$saved" value.LOCAL_VAR.form)" = "literal" ]

    subrubric "the parent removed the context after the registry write"
    [ ! -e "$ctx" ]
    rm -f "$saved" "$ctx_path"
}

@test "the router builds the context in the parent and records the path per pid" {
    local router="$BATS_TEST_DIRNAME/../../cloudify"
    [ -f "$router" ]

    subrubric "the local dispatch paths and the @default pre-pass resolve via the context"
    [ "$(grep -c '_cloudify_dispatch_vars' "$router")" -eq 4 ]
    [ "$(grep -c '_cloudify_context_file_init' "$router")" -eq 1 ]

    subrubric "the walker is no longer called from the router"
    ! grep -q '_cloudify_pkg_remote_vars' "$router"

    subrubric "the context path is pid-keyed metadata for the registry write"
    grep -q 'local -A _CLOUDIFY_BG_CONTEXT=()' "$router"
    grep -q '_CLOUDIFY_BG_CONTEXT\[\$pid\]="\$context"' "$router"
    grep -q '_cloudify_note_bg "\$!" "\$action" "\${pkgs\[\*\]}"' "$router"

    subrubric "remote dispatch records the parent's path too"
    grep -q '"${CLOUDIFY_CONTEXT_FILE:-}"' "$router"

    subrubric "lib/remote.sh keeps the walker only behind the legacy switch"
    grep -q '_cloudify_pkg_remote_vars "\$action" "${pkgs\[@\]}"' "$BATS_TEST_DIRNAME/../../lib/remote.sh"
    grep -q 'cloudify_context_build' "$BATS_TEST_DIRNAME/../../lib/remote.sh"
}

# --- preflight selects through the dispatcher's single label implementation ---

@test "preflight and a real dispatch select the same source for every declared name" {
    rubric "one label implementation (cloudify_context_source_of): preflight == the context's value.<NAME>.source"
    declare_pkg preflight-pkg FIX_PRE_ENV FIX_PRE_DEP FIX_PRE_PKG FIX_PRE_GLOBAL FIX_PRE_MISSING
    reset_stores
    export FIX_PRE_ENV=env-value
    set_deployment FIX_PRE_DEP dep-value
    set_pkg preflight-pkg FIX_PRE_PKG pkg-value
    set_global FIX_PRE_GLOBAL global-value
    unset FIX_PRE_DEP FIX_PRE_PKG FIX_PRE_GLOBAL FIX_PRE_MISSING

    local rb="$CAP_DIR/preflight.md"
    cat > "$rb" <<'EOF'
---
deployment: wiring-dep
targets: guest
---
```bash step=install target=guest pkg=preflight-pkg
echo ok
```
EOF

    subrubric "preflight fails listing exactly the name no source provides"
    run cloudify_runbook_preflight "$rb" --target guest=cloudai:xfce-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"preflight-pkg: FIX_PRE_MISSING"* ]]
    [[ "$output" != *"FIX_PRE_ENV"* ]]
    [[ "$output" != *"FIX_PRE_DEP"* ]]
    [[ "$output" != *"FIX_PRE_PKG"* ]]
    [[ "$output" != *"FIX_PRE_GLOBAL"* ]]

    subrubric "the same dispatch labels those names with those sources"
    local ctx="$CAP_DIR/preflight-context.yaml"
    : > "$ctx"
    chmod 600 "$ctx"
    export CLOUDIFY_CONTEXT_FILE="$ctx"
    capture context preflight install preflight-pkg
    unset CLOUDIFY_CONTEXT_FILE

    local name expected
    while IFS='=' read -r name expected; do
        [ "$(cloudify_context_read "$ctx" "value.$name.source")" = "$expected" ]
        step "$name -> $(cloudify_context_read "$ctx" "value.$name.source")"
    done <<'EOF'
FIX_PRE_ENV=environment
FIX_PRE_DEP=deployment
FIX_PRE_PKG=package
FIX_PRE_GLOBAL=global
EOF

    subrubric "the name preflight judged unresolved has no context block either"
    ! cloudify_context_read "$ctx" value.FIX_PRE_MISSING.source
    unset FIX_PRE_ENV
}

@test "DEBUG=true prints names and sources, never the payload text" {
    rubric "debug output carries no rendered payload and no secret value"
    local pkg="dbgtest"
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf 'FIX_DBG_TOKEN\nFIX_DBG_PLAIN\n' > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" FIX_DBG_TOKEN "fixture-dbg-secret"
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" FIX_DBG_PLAIN "fixture-dbg-plain"
    export CLOUDIFY_DEPLOYMENT="$DEP"
    unset FIX_DBG_TOKEN FIX_DBG_PLAIN

    # `capture` redirects the dispatch's stdout/stderr into its own log file.
    DEBUG=true capture context dbg install "$pkg" || true
    local out="$CAP_DIR/dbg.log"
    [ -f "$out" ]

    subrubric "no rendered export line and no value text reaches the output"
    step "asserting absence of payload lines and both fixture values"
    ! grep -q "export FIX_DBG_TOKEN=" "$out"
    ! grep -q "export FIX_DBG_PLAIN=" "$out"
    ! grep -q "fixture-dbg-secret" "$out"
    ! grep -q "fixture-dbg-plain" "$out"

    subrubric "names, source labels and redaction status are printed instead"
    grep -q "FIX_DBG_TOKEN source=deployment secret=true" "$out"
    grep -q "FIX_DBG_PLAIN source=deployment secret=false" "$out"
}
