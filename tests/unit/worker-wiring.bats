#!/usr/bin/env bats
# Worker wiring (state-model-v2 4.3, the last mile): the router runs the
# dispatch worker after every dispatch. These tests pin the router-side hook
# `_cloudify_dispatch_worker` - identity resolution (active application
# reference, else the reserved `_direct` synthesis), bindings from the
# manifest, and the worker call itself. Description + non-breakage:
# tmp/worker-wiring-description.md (consent 2026-09-27).

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
    export CLOUDIFY_NO_VERIFY=true

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/results.sh
    source lib/deployments.sh
    source lib/state.sh
    source lib/context.sh
    source lib/matching.sh
    source lib/worker.sh
    _fake_ivps

    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf '1.24.0\n' > "$CLOUDIFY_DIR/pkg/nginx/.version"

    # The dispatch context: one resolved name, one covered package.
    {
        printf 'context_version: 1\n'
        printf 'action: install\n'
        printf 'deployment: \n'
        printf 'phase: install\n'
        printf 'target: web1\t\tlocalhost\n'
        printf 'top_kind: package\n'
        printf 'value.PORT.source: environment\n'
        printf 'value.PORT.form: literal\n'
        printf 'value.PORT.secret: false\n'
        printf 'value.PORT.declaration: none\n'
        printf 'value.PORT.reference: \n'
        printf 'value.PORT.digest: \n'
        printf 'value.PORT.raw: t:8080\n'
        printf 'package.nginx.instance: default\n'
    } > "$CLOUDIFY_TMP/ctx"

    : > "$CLOUDIFY_TMP/bindings"
    printf 'server\tlocalhost\tweb1\t\tlocalhost\n' > "$CLOUDIFY_TMP/bindings"

    export CLOUDIFY_DEV_COMMIT=false
}

teardown() {
    teardown_test_env
}

res() {
    printf 'result v1: parent=%s package=%s instance=default phase=%s action=%s outcome=%s exit=%s verification=%s version=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

@test "hook: a referenced dispatch projects onto its deployment from env identity" {
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    cloudify_manifest_write web default main applying \
        0123456789abcdef0123456789abcdef01234567 false "$CLOUDIFY_TMP/bindings"
    {
        printf 'checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false\n'
        printf '%s\n' "$(res - nginx install install succeeded 0 ok 1.24.0)"
    } > "$CLOUDIFY_TMP/collected"

    run _cloudify_dispatch_worker install $'web1\t\tlocalhost' "$CLOUDIFY_TMP/ctx" "$CLOUDIFY_TMP/collected" nginx
    [ "$status" -eq 0 ]

    local rec
    rec=$(cloudify_state_record_dir web1 "" web default main nginx default)/state.json
    [ -f "$rec" ]
    [ "$(cloudify_manifest_field web default main status)" = "active" ]
    [ -n "$(cloudify_manifest_field web default main last_event_id)" ]
    [ "$(cloudify_manifest_field web default main last_event_id)" != "null" ]
}

@test "hook: a bare dispatch synthesizes the reserved _direct deployment" {
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
    {
        printf 'checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false\n'
        printf '%s\n' "$(res - nginx install install succeeded 0 ok 1.24.0)"
    } > "$CLOUDIFY_TMP/collected"

    run _cloudify_dispatch_worker install $'web1\t\tlocalhost' "$CLOUDIFY_TMP/ctx" "$CLOUDIFY_TMP/collected" nginx
    [ "$status" -eq 0 ]

    # The generated name exists under _direct/direct with a record on web1.
    local found=0 d
    while IFS= read -r d; do
        [[ -f "$(cloudify_state_record_dir web1 "" _direct direct "$(basename "$d")" nginx default)/state.json" ]] && found=1
    done < <(find "$(cloudify_state_root)/deployments/_direct/direct" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    [ "$found" -eq 1 ]
}

@test "emission: a configure attempt emits one reconfigure result line" {
    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf 'echo configured
' > "$CLOUDIFY_DIR/pkg/nginx/configure.sh"
    export CLOUDIFY_NO_VERIFY=true CLOUDIFY_RESULTS_FILE="$CLOUDIFY_TMP/collected"
    : > "$CLOUDIFY_RESULTS_FILE"
    run cloudify_configure_package nginx
    [ "$status" -eq 0 ]
    grep -q '^result v1: parent=- package=nginx instance=default phase=reconfigure action=configure outcome=succeeded exit=0 verification=not-run version=1.24.0$' "$CLOUDIFY_RESULTS_FILE"
}

@test "emission: an uninstall attempt emits one teardown result line" {
    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf 'echo gone\n' > "$CLOUDIFY_DIR/pkg/nginx/uninstall.sh"
    export CLOUDIFY_RESULTS_FILE="$CLOUDIFY_TMP/collected"
    : > "$CLOUDIFY_RESULTS_FILE"
    run cloudify_uninstall_package nginx
    [ "$status" -eq 0 ]
    grep -q '^result v1: parent=- package=nginx instance=default phase=teardown action=uninstall outcome=succeeded exit=0 verification=not-run version=1.24.0$' "$CLOUDIFY_RESULTS_FILE"
}

@test "emission: a failed configure emits the failure in its result line" {
    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf 'exit 3\n' > "$CLOUDIFY_DIR/pkg/nginx/configure.sh"
    export CLOUDIFY_NO_VERIFY=true CLOUDIFY_RESULTS_FILE="$CLOUDIFY_TMP/collected"
    : > "$CLOUDIFY_RESULTS_FILE"
    run cloudify_configure_package nginx
    [ "$status" -ne 0 ]
    grep -q 'phase=reconfigure action=configure outcome=failed exit=3' "$CLOUDIFY_RESULTS_FILE"
}

@test "structural: collection paths key on BASHPID, never subshell-invariant \$\$" {
    rubric "pin the logged trap: \$\$ in a subshell reports the router pid - the wait loop would never find the collection"
    grep -q 'results-${BASHPID}' lib/remote.sh
    local n
    n=$(grep -c 'results-\${BASHPID}' cloudify)
    [ "$n" -eq 3 ]
    ! grep -q 'results-\$\$' cloudify lib/remote.sh
}

@test "hook: an empty collection fails the dispatch and writes no inventory" {
    export CLOUDIFY_APPLICATION=web CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=main
    cloudify_manifest_write web default main applying \
        0123456789abcdef0123456789abcdef01234567 false "$CLOUDIFY_TMP/bindings"
    : > "$CLOUDIFY_TMP/collected"

    run _cloudify_dispatch_worker install $'web1\t\tlocalhost' "$CLOUDIFY_TMP/ctx" "$CLOUDIFY_TMP/collected" nginx
    [ "$status" -ne 0 ]
    [ ! -e "$(cloudify_state_record_dir web1 "" web default main nginx default)/state.json" ]
}
