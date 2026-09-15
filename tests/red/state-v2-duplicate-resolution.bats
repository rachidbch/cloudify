#!/usr/bin/env bats
# State model v2 - duplicate-resolution proof.
#
# This directory is NOT globbed by `task test-unit` (`bats --recursive
# tests/unit/`) or by `task test` (`bats tests/unit/ tests/integration/...`).
# See tests/red/README.md.
#
# The files state the intended v2 contract:
#   1. one dispatch resolves one declared value ONCE, so the value that reaches
#      the remote payload, the value recorded in the registry and the value
#      recorded in the run snapshot all agree. Implemented in Phase 2 (this case
#      is a regression guard now).
#   2. one application input mapped to two package variable names reaches both
#      packages. Implemented in Phase 3 slice 3A and driven through the REAL
#      engine path: a canonical fixture runbook
#      (runbooks/<app>/<flavor>/runbook.md with `inputs:`/`map:`) whose steps
#      dispatch the two fixture packages from a separate `cloudify` process.
#
# The setup steps are asserted before the contract assertions, so a broken
# fixture cannot masquerade as a contract gap.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/creds"
    mkdir -p "$HOME" "$CLOUDIFY_CREDENTIALS_DIR"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/packages.sh
    source lib/targets.sh
    source lib/remote.sh
    source lib/registry.sh
    source lib/runbooks.sh

    export CLOUDIFY_REMOTE_USER=testuser
    export CLOUDIFY_REMOTE_PWD=dummy
    export CLOUDIFY_IS_LOCAL=true
    export DEBUG=false

    cloudify_init_log

    DEP="red-dep"
    export CLOUDIFY_APPLICATION="redapp" CLOUDIFY_FLAVOR="default" CLOUDIFY_DEPLOYMENT_NAME="red-dep"

    CAPTURE_DIR="$(mktemp -d "$CLOUDIFY_TMP/capture.XXXXXX")"
    export CAPTURE_DIR
    ssh() {
        local host="" arg
        for arg in "$@"; do
            [[ "$arg" == *@* ]] && host="${arg#*@}"
        done
        cat > "$CAPTURE_DIR/payload-$host"
        return 0
    }

    # A separate `cloudify` process (a runbook step body) cannot see the shell
    # function above, so it dispatches through an executable stub tree: a real
    # router shim, an ssh capture stub, and an ivps stub that forces the plain
    # host path. The repo root is resolved from this test file.
    export CLOUDIFY_REPO="${CLOUDIFY_SCRIPT_DIR:-/root/cloudify}/cloudify"
    STUB_DIR="$(mktemp -d "$CLOUDIFY_TMP/stub.XXXXXX")"
    export STUB_DIR
    cat > "$STUB_DIR/cloudify" <<'STUB'
#!/bin/bash
exec bash "$CLOUDIFY_REPO" "$@"
STUB
    cat > "$STUB_DIR/ssh" <<'STUB'
#!/bin/bash
host=""
for arg in "$@"; do [[ "$arg" == *@* ]] && host="${arg#*@}"; done
cat > "$CAPTURE_DIR/payload-$host"
STUB
    cat > "$STUB_DIR/ivps" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$STUB_DIR/cloudify" "$STUB_DIR/ssh" "$STUB_DIR/ivps"
    export PATH="$STUB_DIR:$PATH"
}

teardown() {
    teardown_test_env
}

_declare() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

_field() {
    local line
    line=$(grep -m1 "^$1:" <<< "$2") || return 0
    line="${line#*:}"
    line="${line# }"
    printf '%s' "$line"
}

_make_runbook() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

_snapshot() {
    ls "$CLOUDIFY_DEPLOYMENTS_DIR/$1/runs/"*.yaml
}

_snapshot_value() {
    sed -n "s/^value\\.$2: //p" "$1"
}

_payload_value() {
    sed -n "s/.*export $2='\\(.*\\)'.$/\\1/p" "$1" | head -1
}

@test "V2 contract: one dispatch, one resolution - payload, registry and snapshot agree" {
    rubric "one declared name: caller value must reach the payload, the registry and the snapshot"
    _declare redpkg SHARED_INPUT
    printf 'SHARED_INPUT: global-value\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    cloudify_vars_pkg_write redpkg SHARED_INPUT package-value
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" SHARED_INPUT deployment-value
    export CLOUDIFY_DEPLOYMENT="$DEP"
    export SHARED_INPUT=caller-value

    subrubric "build the three records (the same dispatch, one value)"
    cloudify_remote_sync charhost install redpkg >/dev/null 2>&1
    local payload="$CAPTURE_DIR/payload-charhost"
    local record registry_value rb snap snapshot_value payload_value
    record=$(cloudify_registry_record_build install "$DEP" "" "" charhost redpkg)
    registry_value=$(_field var.SHARED_INPUT "$record")

    rb="$CLOUDIFY_TMP/red.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: red-dep
targets: guest
---
```bash step=install target=guest pkg=redpkg id=one
echo ok
```
EOF
    run cloudify_runbook_execute "$rb" --target guest=charhost

    subrubric "setup sanity (must pass; a failure here would be the wrong red)"
    [ "$status" -eq 0 ]
    [ -f "$payload" ]
    snap=$(_snapshot "$DEP")
    [ -f "$snap" ]

    payload_value=$(_payload_value "$payload" SHARED_INPUT)
    snapshot_value=$(_snapshot_value "$snap" SHARED_INPUT)
    step "payload=$payload_value registry=$registry_value snapshot=$snapshot_value"

    subrubric "v2: every record carries the one resolved value"
    if [[ "$payload_value" != "$registry_value" ]]; then
        echo "v2 contract violated: payload has '$payload_value', registry has '$registry_value' for SHARED_INPUT (one dispatch, two walks)" >&2
        return 1
    fi
    if [[ "$registry_value" != "$snapshot_value" ]]; then
        echo "v2 contract violated: registry has '$registry_value', snapshot has '$snapshot_value' for SHARED_INPUT (the snapshot reads the deployment store alone)" >&2
        return 1
    fi
}

@test "V2 contract: one application input mapped to two package variable names" {
    rubric "application input APP_SHARED_INPUT mapped to PKG_A_TARGET and PKG_B_TARGET"
    _declare redpkg-a PKG_A_TARGET
    _declare redpkg-b PKG_B_TARGET
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" APP_SHARED_INPUT mapped-value
    export CLOUDIFY_DEPLOYMENT="$DEP"
    unset PKG_A_TARGET PKG_B_TARGET

    subrubric "a canonical runbook whose two steps dispatch the two fixture packages"
    local rb="$CLOUDIFY_DIR/runbooks/redapp/default/runbook.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: red-dep
targets: a, b
inputs: APP_SHARED_INPUT
map: PKG_A_TARGET=APP_SHARED_INPUT, PKG_B_TARGET=APP_SHARED_INPUT
---
```bash step=install target=a pkg=redpkg-a id=a
cloudify --on "$TARGET_A" install redpkg-a
```
```bash step=install target=b pkg=redpkg-b id=b
cloudify --on "$TARGET_B" install redpkg-b
```
EOF
    [ -f "$rb" ]

    subrubric "the real engine runs both steps; each dispatches in its own cloudify process"
    run cloudify_runbook_execute "$rb" --target a=host-a --target b=host-b
    if [[ "$status" -ne 0 ]]; then
        echo "engine status=$status" >&2
        echo "$output" >&2
    fi
    [ "$status" -eq 0 ]

    subrubric "setup sanity (must pass; a failure here would be the wrong red)"
    [ -f "$CAPTURE_DIR/payload-host-a" ]
    [ -f "$CAPTURE_DIR/payload-host-b" ]

    subrubric "v2: the mapped input reaches both package variables"
    if ! grep -q "export PKG_A_TARGET='mapped-value'" "$CAPTURE_DIR/payload-host-a"; then
        echo "v2 contract not implemented: application input APP_SHARED_INPUT is not mapped onto package variable PKG_A_TARGET (payload has no PKG_A_TARGET export)" >&2
        return 1
    fi
    if ! grep -q "export PKG_B_TARGET='mapped-value'" "$CAPTURE_DIR/payload-host-b"; then
        echo "v2 contract not implemented: application input APP_SHARED_INPUT is not mapped onto package variable PKG_B_TARGET (payload has no PKG_B_TARGET export)" >&2
        return 1
    fi
}
