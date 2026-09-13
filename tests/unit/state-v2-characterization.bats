#!/usr/bin/env bats
# State model v2 characterization (workstream B), green as-is.
#
# Pins the duplicate-resolution defect's history: pre-Phase-2, one dispatch
# resolved one declared name twice (the forwarding walker built the payload and
# the registry writer walked the same name again with its own implementation).
# Both walkers are deleted; the dispatch context (lib/context.sh, reached
# through lib/remote.sh:_cloudify_dispatch_vars) is now the ONE resolution, and
# the registry writer reads its values from that context.
#   - case 1.1 (one pkg, one target, four conflicting sources): Phase 2 made the
#     snapshot agree with the payload and the registry, so all three now carry
#     the caller value. The assertions below pin that agreement; the pre-Phase-2
#     divergence is preserved in the plan's characterization notes, not here.
#   - case 1.2 part one: two packages on two targets consume one deployment
#     input, with no prior package state.
#   - case 1.2 part two: package defaults stay independent when no mapping
#     exists.
# The intended v2 contract (one resolution, all three agree; application input
# mapped to two package variable names) lives in tests/red/, which the default
# suite does not glob.
#
# Every assertion is against the real code path: the real dispatch, the real
# record builder and the real runbook engine. Nothing here is re-implemented.

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

    DEP="char-dep"
    export CLOUDIFY_APPLICATION=charapp CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=char-dep

    # One captured payload per dispatch, keyed by ssh host: the ssh stub reads
    # the payload from stdin (the real transport) and writes it to a file. No
    # network, no ssh binary.
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

# _declare <pkg> <name>... - a bare (required) declaration, the shape the
# dispatch and the registry both enumerate.
_declare() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

# _field <key> <record-text> - the value of one flat `key: value` line.
_field() {
    local line
    line=$(grep -m1 "^$1:" <<< "$2") || return 0
    line="${line#*:}"
    line="${line# }"
    printf '%s' "$line"
}

# _make_runbook <path>  (content on stdin)
_make_runbook() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

# _snapshot <id> - the single run snapshot path for <id>.
_snapshot() {
    ls "$CLOUDIFY_DEPLOYMENTS_DIR/$1/runs/"*.yaml
}

# _snapshot_value <snapshot> <name> - the value recorded on the value.<name> line.
_snapshot_value() {
    sed -n "s/^value\\.$2: //p" "$1"
}

# ---------------------------------------------------------------
# 1.1 one dispatch, four conflicting sources
# ---------------------------------------------------------------

@test "1.1 one declared name: payload=registry=snapshot=caller" {
    rubric "one package, one target, one name from caller env + deployment + package + global"
    _declare charpkg SHARED_INPUT
    printf 'SHARED_INPUT: global-value\n' > "$CLOUDIFY_CREDENTIALS_DIR/remote-vars.yaml"
    cloudify_vars_pkg_write charpkg SHARED_INPUT package-value
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" SHARED_INPUT deployment-value
    export CLOUDIFY_DEPLOYMENT="$DEP"
    export SHARED_INPUT=caller-value
    # A placeholder secret that is never declared: it must not leak anywhere.
    export CLOUDIFY_CHAR_UNMAPPED_SECRET=placeholder-secret-must-not-leak

    subrubric "dispatch -> remote payload"
    cloudify_remote_sync charhost install charpkg >/dev/null 2>&1
    local payload="$CAPTURE_DIR/payload-charhost"
    [ -f "$payload" ]
    step "payload exists ($(wc -l < "$payload") lines); caller value must be the one forwarded"
    grep -q "export SHARED_INPUT='caller-value'" "$payload"
    local payload_value
    payload_value=$(sed -n "s/.*export SHARED_INPUT='\\(.*\\)'.$/\\1/p" "$payload" | head -1)

    subrubric "registry record (independent raw walk over the same name)"
    local record registry_value
    record=$(cloudify_registry_record_build install "$DEP" "" "" charhost charpkg)
    registry_value=$(_field var.SHARED_INPUT "$record")
    step "registry var.SHARED_INPUT=$registry_value"
    [ "$registry_value" = "caller-value" ]

    subrubric "run snapshot (deployment store + the resolver view)"
    local rb="$CLOUDIFY_TMP/char.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: char-dep
targets: guest
---
```bash step=install target=guest pkg=charpkg id=one
echo ok
```
EOF
    run cloudify_runbook_execute "$rb" --target guest=charhost
    [ "$status" -eq 0 ]
    local snap snapshot_value
    snap=$(_snapshot "$DEP")
    snapshot_value=$(_snapshot_value "$snap" SHARED_INPUT)
    step "snapshot value.SHARED_INPUT=$snapshot_value"
    [ "$snapshot_value" = "caller-value" ]

    subrubric "v2: one resolution feeds all three records"
    step "payload=$payload_value registry=$registry_value snapshot=$snapshot_value"
    [ "$registry_value" = "$payload_value" ]
    [ "$registry_value" = "$snapshot_value" ]

    subrubric "no literal secret in payload or log"
    ! grep -q "placeholder-secret-must-not-leak" "$payload"
    ! grep -rq "placeholder-secret-must-not-leak" "$CLOUDIFY_TMP/logs"
}

# ---------------------------------------------------------------
# 1.2 part one: one deployment input, two packages, two targets, no state
# ---------------------------------------------------------------

@test "1.2a two packages on two targets consume one deployment input before either has state" {
    rubric "one deployment input shared by two first installs, with no prior package state"
    _declare charpkg-a SHARED_APP_INPUT
    _declare charpkg-b SHARED_APP_INPUT
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" SHARED_APP_INPUT shared-app-value
    export CLOUDIFY_DEPLOYMENT="$DEP"
    unset SHARED_APP_INPUT

    subrubric "no package has any state yet"
    local rec_a rec_b
    rec_a=$(cloudify_registry_file "$DEP" "" "" host-a charpkg-a)
    rec_b=$(cloudify_registry_file "$DEP" "" "" host-b charpkg-b)
    step "record paths absent: $rec_a / $rec_b"
    [ ! -e "$rec_a" ]
    [ ! -e "$rec_b" ]

    subrubric "the deployment input is the only providing source"
    [ "$(_cloudify_vars_source_of SHARED_APP_INPUT charpkg-a)" = "deployment" ]
    [ "$(_cloudify_vars_source_of SHARED_APP_INPUT charpkg-b)" = "deployment" ]

    subrubric "both first installs receive the value"
    cloudify_remote_sync host-a install charpkg-a >/dev/null 2>&1
    unset SHARED_APP_INPUT
    cloudify_remote_sync host-b install charpkg-b >/dev/null 2>&1
    grep -q "export SHARED_APP_INPUT='shared-app-value'" "$CAPTURE_DIR/payload-host-a"
    grep -q "export SHARED_APP_INPUT='shared-app-value'" "$CAPTURE_DIR/payload-host-b"

    subrubric "still no package state: the value did not come from any record"
    [ ! -e "$rec_a" ]
    [ ! -e "$rec_b" ]
}

# ---------------------------------------------------------------
# 1.2 part two: package defaults stay independent without a mapping
# ---------------------------------------------------------------

@test "1.2b package defaults stay independent when no mapping exists" {
    rubric "two packages with one default each and no application mapping"
    _declare charpkg-a PKG_A_ONLY
    _declare charpkg-b PKG_B_ONLY
    cloudify_vars_pkg_write charpkg-a PKG_A_ONLY default-a
    cloudify_vars_pkg_write charpkg-b PKG_B_ONLY default-b
    export CLOUDIFY_DEPLOYMENT="$DEP"
    unset PKG_A_ONLY PKG_B_ONLY

    subrubric "no application input exists to couple the two packages"
    step "deployment store holds no input line"
    ! grep -q . "$(_cloudify_deployment_config)"

    subrubric "each package keeps its own default"
    cloudify_remote_sync host-a install charpkg-a >/dev/null 2>&1
    unset PKG_A_ONLY
    cloudify_remote_sync host-b install charpkg-b >/dev/null 2>&1
    grep -q "export PKG_A_ONLY='default-a'" "$CAPTURE_DIR/payload-host-a"
    grep -q "export PKG_B_ONLY='default-b'" "$CAPTURE_DIR/payload-host-b"

    subrubric "neither default leaks into the other package's dispatch"
    ! grep -q "PKG_B_ONLY" "$CAPTURE_DIR/payload-host-a"
    ! grep -q "PKG_A_ONLY" "$CAPTURE_DIR/payload-host-b"
}
