#!/usr/bin/env bats
# State model v2 - Phase 1 RED proof (deliberately failing).
#
# This directory is NOT globbed by `task test-unit` (`bats --recursive
# tests/unit/`) or by `task test` (`bats tests/unit/ tests/integration/...`).
# A failing test here is expected evidence that the v2 contract is not
# implemented yet, never a broken build. See tests/red/README.md.
#
# The files state the intended v2 contract:
#   1. one dispatch resolves one declared value ONCE, so the value that reaches
#      the remote payload, the value recorded in the registry and the value
#      recorded in the run snapshot all agree (today they do not: see
#      tests/unit/state-v2-characterization.bats, case 1.1).
#   2. one application input mapped to two package variable names reaches both
#      packages (today there is no mapping concept at all).
#
# Both are expected to fail on the assertions below, not on setup: the setup
# steps are asserted first so a broken fixture cannot masquerade as the
# intended red.

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
    cloudify_deployment_create "$DEP" >/dev/null

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
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" SHARED_INPUT deployment-value
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
    _cloudify_vars_file_set "$(_cloudify_deployment_config "$DEP")" APP_SHARED_INPUT mapped-value
    # Provisional v2 mapping shape (Phase 3.1 freezes the real one): one
    # application input -> the package variable names it feeds. No reader exists
    # today, which is exactly what this red proof asserts.
    local dep_dir="$CLOUDIFY_DEPLOYMENTS_DIR/$DEP"
    printf 'APP_SHARED_INPUT: PKG_A_TARGET PKG_B_TARGET\n' > "$dep_dir/mappings.yaml"
    export CLOUDIFY_DEPLOYMENT="$DEP"
    unset PKG_A_TARGET PKG_B_TARGET

    subrubric "dispatch both packages (first install, no prior state)"
    cloudify_remote_sync host-a install redpkg-a >/dev/null 2>&1
    unset PKG_A_TARGET
    cloudify_remote_sync host-b install redpkg-b >/dev/null 2>&1

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
