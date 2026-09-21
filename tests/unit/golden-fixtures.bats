#!/usr/bin/env bats
# Byte-exact golden fixtures for the dispatch payload (the transport-integrity
# tripwire). The legacy registry-record goldens moved to
# tests/fixtures/legacy-registry/ with the retired writer (4.3, 2026-09-20);
# (plans/archived/state-model-v2-phase2-attempt-design.md section 9). The legacy walkers
# (_cloudify_pkg_remote_vars, _cloudify_registry_raw_var) are deleted, so the
# payload text and the record text are pinned by DATA instead of by the code
# that first produced them: this suite rebuilds both from the surviving v2 path
# and compares byte for byte against tests/fixtures/golden/.
#
# A diff here means the payload or the record format changed. That is a
# deliberate act, never an accident: re-capture only with a reviewer's eyes on
# the diff. See tests/fixtures/golden/README.md.
#
# Capture mode (GOLDEN_CAPTURE=1) writes the fixtures instead of comparing:
#   bats tests/unit/golden-fixtures.bats   # default: compare
#   GOLDEN_CAPTURE=1 bats tests/unit/golden-fixtures.bats
# Capture happens on the branch where the fixtures do not exist yet; it is not
# part of the normal suite run.
#
# The payload is captured through the REAL transport: cloudify_remote_sync with
# a stubbed ssh that reads the payload from stdin (never argv).

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
    source lib/vars.sh
    source lib/deployments.sh
    source lib/targets.sh
    source lib/runbooks.sh
    source lib/context.sh
    source lib/registry.sh
    source lib/remote.sh

    export CLOUDIFY_REMOTE_USER=testuser
    export CLOUDIFY_REMOTE_PWD=dummy
    export CLOUDIFY_CONTEXT_TARGET=$'local\t\tlocalhost'
    cloudify_init_log
    # A fixed log filename keeps the payload deterministic: cloudify_remote_sync
    # forwards its basename (CLOUDIFY_LOG_BASENAME), which would otherwise carry
    # a timestamp.
    export CLOUDIFY_LOG_FILE="$CLOUDIFY_TMP/logs/golden.log"
    mkdir -p "$CLOUDIFY_TMP/logs"
    : > "$CLOUDIFY_LOG_FILE"

    unset CLOUDIFY_NODE IVPS_DEFAULT_NODE CLOUDIFY_CONTEXT_FILE
    IVPS_NODES=(cloudai)
    IVPS_NODE_ROOT="$CLOUDIFY_TMP/ivps/nodes"
    IVPS_NODE_PATH_RC=0

    export DEP="golden-dep"
    export CLOUDIFY_DEPLOYMENT="$DEP"
    export CLOUDIFY_APPLICATION="goldenapp" CLOUDIFY_FLAVOR="default" CLOUDIFY_DEPLOYMENT_NAME="default"

    NODE="cloudai"
    HOST="cloudify"

    GOLDEN="$BATS_TEST_DIRNAME/../fixtures/golden"
    export GOLDEN
    CAP_DIR="$CLOUDIFY_TMP/capture"
    mkdir -p "$CAP_DIR"
    export CAP_DIR

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

set_deployment() { _cloudify_vars_file_set "$(_cloudify_deployment_config)" "$1" "$2"; }
set_pkg() { cloudify_vars_pkg_write "$1" "$2" "$3"; }
set_global() { cloudify_vars_global_write "$1" "$2"; }

reset_stores() {
    rm -f "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    rm -rf "$CLOUDIFY_CREDENTIALS_DIR/pkgs"
    rm -f "$(_cloudify_deployment_config)"
}

b64() { printf '%s' "$1" | base64 -w0; }

# --- harness ----------------------------------------------------------------

# _golden <fixture-relative-path> <actual-file>: compare byte for byte, or write
# the fixture in capture mode. Never a lenient compare: a one-byte diff fails.
_golden() {
    local rel="$1" actual="$2" fixture="$GOLDEN/$1"
    if [[ "${GOLDEN_CAPTURE:-}" == "1" ]]; then
        mkdir -p "$(dirname "$fixture")"
        cp "$actual" "$fixture"
        step "captured $rel ($(wc -c < "$fixture") bytes)"
        return 0
    fi
    [ -f "$fixture" ] || { echo "missing golden fixture: $fixture" >&2; return 1; }
    if ! cmp -s "$actual" "$fixture"; then
        echo "--- golden $rel (expected) vs rebuilt (actual) ---" >&2
        diff -u "$fixture" "$actual" >&2 || true
        return 1
    fi
    step "$rel: $(wc -c < "$fixture") bytes, byte-identical"
}

# golden_payload <case> <cloudify command words...>
# One dispatch in a subshell, so the resolved exports never leak into the test
# shell; the stubbed ssh writes the payload to <capture>/<case>.payload.
golden_payload() {
    local case="$1"
    shift
    local out="$CAP_DIR/$case"
    ( CAP_OUT="$out"; cloudify_remote_sync somehost "$@" ) > "$CAP_DIR/$case.log" 2>&1
    [ -s "$out.payload" ]
    _golden "payload/$case.txt" "$out.payload"
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

# --- payload matrix: caller env, deployment, package, global, reference,
#     multiline, rightmost package wins, package with a dependency -----------

@test "golden payload: caller env only" {
    declare_pkg foo FIX_ENV_ONLY
    reset_stores
    export FIX_ENV_ONLY=env-value
    golden_payload caller-env install foo
    grep -qF "export FIX_ENV_ONLY='env-value'" "$CAP_DIR/caller-env.payload"
    unset FIX_ENV_ONLY
}

@test "golden payload: deployment store only" {
    declare_pkg foo FIX_DEP_ONLY
    reset_stores
    set_deployment FIX_DEP_ONLY deployment-value
    golden_payload deployment-only install foo
    grep -qF "export FIX_DEP_ONLY='deployment-value'" "$CAP_DIR/deployment-only.payload"
}

@test "golden payload: package yaml only" {
    declare_pkg foo FIX_PKG_ONLY
    reset_stores
    set_pkg foo FIX_PKG_ONLY package-value
    golden_payload package-only install foo
    grep -qF "export FIX_PKG_ONLY='package-value'" "$CAP_DIR/package-only.payload"
}

@test "golden payload: global only" {
    declare_pkg foo FIX_GLOBAL_ONLY
    reset_stores
    set_global FIX_GLOBAL_ONLY global-value
    golden_payload global-only install foo
    grep -qF "export FIX_GLOBAL_ONLY='global-value'" "$CAP_DIR/global-only.payload"
}

@test "golden payload: @base64 reference from a store" {
    declare_pkg foo FIX_REF_SECRET
    reset_stores
    set_deployment FIX_REF_SECRET "@base64:$(b64 'admin-secret')"
    golden_payload base64-reference install foo
    grep -qF "export FIX_REF_SECRET='admin-secret'" "$CAP_DIR/base64-reference.payload"
}

@test "golden payload: multiline stored value" {
    declare_pkg foo FIX_MULTILINE
    reset_stores
    set_deployment FIX_MULTILINE $'line-one\nline-two'
    golden_payload multiline install foo
    grep -qF "export FIX_MULTILINE='line-one" "$CAP_DIR/multiline.payload"
    grep -qF "line-two'" "$CAP_DIR/multiline.payload"
}

@test "golden payload: two packages, rightmost wins" {
    declare_pkg alpha FIX_SHARED
    declare_pkg beta FIX_SHARED
    reset_stores
    set_pkg alpha FIX_SHARED from-alpha
    set_pkg beta FIX_SHARED from-beta
    golden_payload rightmost-package-wins install alpha beta
    grep -qF "export FIX_SHARED='from-beta'" "$CAP_DIR/rightmost-package-wins.payload"
    ! grep -qF 'from-alpha' "$CAP_DIR/rightmost-package-wins.payload"
}

@test "golden payload: package with a dependency" {
    declare_pkg alpha FIX_ALPHA_ONLY
    declare_pkg dep FIX_DEP_VALUE
    recipe_for alpha dep
    reset_stores
    set_pkg alpha FIX_ALPHA_ONLY alpha-value
    set_pkg dep FIX_DEP_VALUE dep-value
    golden_payload dependency install alpha
    grep -qF "export FIX_ALPHA_ONLY='alpha-value'" "$CAP_DIR/dependency.payload"
    grep -qF "export FIX_DEP_VALUE='dep-value'" "$CAP_DIR/dependency.payload"
}
