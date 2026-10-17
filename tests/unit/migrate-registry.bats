# Tests for the legacy registry-record converter (S2; per-application live
# conversion, ADR-043). Investigate (default) is read-only: it resolves each
# old record's target and runs the ad-hoc (unnamed, unrecorded) verify with
# the record's non-secret values as caller env. --write converts backed by a
# restricted backup, through the one inventory transition, one migrate-registry
# event per record. Old records are never deleted here (the sweep is later).

source tests/helpers/common.bash

setup() {
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    mkdir -p "$HOME"
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
    source lib/targets.sh
    source lib/state.sh
    source lib/context.sh
    source lib/matching.sh
    source lib/worker.sh
    source lib/runbooks.sh
    source lib/adoption.sh
    source lib/migrate-registry.sh

    # The package declaration: names plus one explicit marker.
    mkdir -p "$CLOUDIFY_DIR/pkg/nginx"
    printf '1.24.0\n' > "$CLOUDIFY_DIR/pkg/nginx/.version"
    cat > "$CLOUDIFY_DIR/pkg/nginx/.remote-vars" <<'DECL'
CLOUDIFY_SERVER_NAME
CLOUDIFY_TLS
CLOUDIFY_PASSWORD
CLOUDIFY_API_KEY
CLOUDIFY_MOTD
CLOUDIFY_BANNER
secret CLOUDIFY_MARKED
DECL

    # The ivps inventory: node cloudai, instance inst-a under it. The ivps
    # config root doubles as the walk root: <IVPS_CONFIG_DIR>/nodes/<node>.
    export IVPS_CONFIG_DIR="$CLOUDIFY_TMP/ivps"
    mkdir -p "$CLOUDIFY_TMP/fakebin"
    NODE_DIR="$IVPS_CONFIG_DIR/nodes/n1"
    INST_DIR="$NODE_DIR/inst-a"
    mkdir -p "$INST_DIR"
    cat > "$CLOUDIFY_TMP/fakebin/ivps" <<STUB
#!/bin/bash
if [[ "\$1" = node && "\$2" = path ]]; then
    case "\$3" in
        cloudai) echo "$NODE_DIR" ;;
        cloudai:inst-a) echo "$INST_DIR" ;;
        *) exit 1 ;;
    esac
else
    exit 9
fi
STUB
    chmod +x "$CLOUDIFY_TMP/fakebin/ivps"

    # The verify child (nested cloudify): records argv and its environment,
    # reports by fixture. The converter must call it UNNAMED (ad-hoc verify).
    cat > "$CLOUDIFY_TMP/fakebin/cloudify" <<'STUB'
#!/usr/bin/env bash
{
    printf 'argv:%s\n' "$*"
    printf 'app=%s\n' "${CLOUDIFY_APPLICATION:-}"
    printf 'flavor=%s\n' "${CLOUDIFY_FLAVOR:-}"
    printf 'name=%s\n' "${CLOUDIFY_DEPLOYMENT_NAME:-}"
    env | sort | grep -E '^(CLOUDIFY_[A-Z_]+)=' || true
} > "${CLOUDIFY_TMP:-/tmp}/verify-child.log"
exit "${CLOUDIFY_MIGRATE_STUB_RC:-0}"
STUB
    chmod +x "$CLOUDIFY_TMP/fakebin/cloudify"
    export PATH="$CLOUDIFY_TMP/fakebin:$PATH"
    export CLOUDIFY_OPERATOR=rachid

    # One legacy registry record in the instance bucket, holding every value
    # class the mapping rules name. Values are placeholders.
    OLD="$INST_DIR/deployments/legacy-app/pkgs/nginx/config.yaml"
    mkdir -p "$(dirname "$OLD")"
    BANNER_B64='QkFOTkVSX0xJTkVfT05FCkJBTk5FUl9MSU5FX1RXTw=='
    cat > "$OLD" <<EOF
# cloudify registry record (observation); do not edit by hand
status: installed
installed_at: 2026-01-01T10:11:12Z
configured_at:
removed_at:
deployment: legacy-app
node: cloudai
instance: inst-a
package: nginx
version: 1.24.0
var.CLOUDIFY_SERVER_NAME: demo.example.com
var.CLOUDIFY_TLS: "false"
var.CLOUDIFY_PASSWORD: PLACEHOLDER_LITERAL_SECRET
var.CLOUDIFY_API_KEY: @vault:kv/cloudify/legacy/api-key
var.CLOUDIFY_MOTD: @@plain-at-text
var.CLOUDIFY_BANNER: @base64:$BANNER_B64
var.CLOUDIFY_MARKED: PLACEHOLDER_NOT_A_REAL_SECRET
EOF

    DEST="$INST_DIR/deployments/legacy/default/prod/packages/nginx/default"
    EVENTS="$HOME/.local/state/cloudify/events"
}

teardown() {
    teardown_test_env
}

@test "migrate-registry: a failed verify refuses by name and writes nothing" {
    rubric "the record must reflect the deployment; a failed probe is a named refusal"
    export CLOUDIFY_MIGRATE_STUB_RC=1

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod
    assert_failure
    assert_output --partial "verify failed, rc 1"
    assert_output --partial "nginx@cloudai:inst-a:verify-rc-1"
    assert [ ! -f "$DEST/state.json" ]

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_failure
    assert [ ! -f "$DEST/state.json" ]
    assert [ ! -d "$CLOUDIFY_CREDENTIALS_DIR/migration-backup" ]
}

@test "migrate-registry: idempotent - a converted record is skipped, not re-written" {
    rubric "re-run converts nothing already converted"
    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_success
    rev1=$(jq -r .revision "$DEST/state.json")

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_success
    assert_output --partial "already converted"
    assert_output --partial "summary converted=0 already-converted=1 refused=0"
    [[ "$(jq -r .revision "$DEST/state.json")" == "$rev1" ]]
    [[ "$(find "$EVENTS" -name '*.json' | wc -l)" == "1" ]]
}

@test "migrate-registry: removed is migration history, never an inventory" {
    rubric "a removal record refuses by name"
    sed -i 's/^status: installed$/status: removed/' "$OLD"

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_failure
    assert_output --partial "refused migration-history"
    assert_output --partial "nginx@cloudai:inst-a:removed"
    assert [ ! -f "$DEST/state.json" ]
}

@test "migrate-registry: an unresolvable target refuses by name" {
    rubric "targets derive from proven facts; an unknown target is not invented"
    cat > "$CLOUDIFY_TMP/fakebin/ivps" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$CLOUDIFY_TMP/fakebin/ivps"

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_failure
    assert_output --partial "does not resolve in the ivps inventory"
    assert_output --partial "nginx@cloudai:inst-a:target"
    assert [ ! -f "$DEST/state.json" ]
}

@test "migrate-registry: no recipe means no probe, refusal by name" {
    rubric "an unprovable record is refused, not trusted"
    trash-put "$CLOUDIFY_DIR/pkg/nginx"

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_failure
    assert_output --partial "no recipe for nginx"
    assert_output --partial "nginx@cloudai:inst-a:recipe"
    assert [ ! -f "$DEST/state.json" ]
}

@test "migrate-registry: investigate is read-only and names facts; --write lands the lean record and event" {
    rubric "investigate prints names/paths only, runs the ad-hoc verify unnamed, writes nothing"

    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod
    assert_success
    assert_output --partial "record path=$OLD"
    assert_output --partial "package=nginx"
    assert_output --partial "verify passed"
    # Value-free: no raw stored value and no secret name leakage.
    assert_output --partial "CLOUDIFY_SERVER_NAME"
    refute_output --substring "demo.example.com"
    refute_output --substring "PLACEHOLDER_LITERAL_SECRET"
    refute_output --substring "@vault:"
    # Read-only: nothing landed.
    assert [ ! -f "$DEST/state.json" ]
    # The verify child ran unnamed (ad-hoc) with the record's non-secret values.
    grep -q 'argv:--on cloudai:inst-a verify nginx' "$CLOUDIFY_TMP/verify-child.log"
    grep -q '^app=$' "$CLOUDIFY_TMP/verify-child.log"
    grep -q '^name=$' "$CLOUDIFY_TMP/verify-child.log"
    grep -q '^CLOUDIFY_SERVER_NAME=demo.example.com$' "$CLOUDIFY_TMP/verify-child.log"
    grep -q '^CLOUDIFY_MOTD=@plain-at-text$' "$CLOUDIFY_TMP/verify-child.log"
    grep -q '^CLOUDIFY_BANNER=BANNER_LINE_ONE$' "$CLOUDIFY_TMP/verify-child.log"
    ! grep -q 'PLACEHOLDER_LITERAL_SECRET' "$CLOUDIFY_TMP/verify-child.log"
    ! grep -q '@vault:' "$CLOUDIFY_TMP/verify-child.log"

    rubric "--write converts through the one inventory transition"
    run cloudify_deployment_migrate_registry legacy-app --application legacy --name prod --write
    assert_success

    # The lean record: mapped values as root scalars, provenance metadata only.
    assert [ -f "$DEST/state.json" ]
    run jq -r '.schema_version, .target, .revision, (.version|tostring), (.user_forced|tostring),
        .CLOUDIFY_SERVER_NAME, .CLOUDIFY_TLS, .CLOUDIFY_PASSWORD, .CLOUDIFY_API_KEY,
        .CLOUDIFY_MOTD, .CLOUDIFY_BANNER, .CLOUDIFY_MARKED, (has("host")|tostring)' "$DEST/state.json"
    assert_line --index 0 "1"
    assert_line --index 1 "direct"
    assert_line --index 2 "1"
    assert_line --index 3 "1.24.0"
    assert_line --index 4 "[]"
    assert_line --index 5 "demo.example.com"
    assert_line --index 6 '"false"'
    assert_line --index 7 "****"
    assert_line --index 8 "****"
    assert_line --index 9 "@plain-at-text"
    assert_line --index 10 "BANNER_LINE_ONE"
    assert_line --index 11 "BANNER_LINE_TWO"
    assert_line --index 12 "****"
    assert_line --index 13 "false"

    # One migrate-registry event beside it: phase-less, origin-tagged, operator writer.
    ev=$(find "$EVENTS" -name '*.json' | head -1)
    [ -n "$ev" ]
    run jq -r '.command_kind, (.phase|tostring), .origin, .writer.kind, .writer.name,
        .application, .flavor, .deployment, (.application_commit|tostring),
        .subject.kind, .subject.host, .subject.package, .subject.package_instance,
        .values.CLOUDIFY_PASSWORD, (.run_id|tostring), .step_id' "$ev"
    assert_line --index 0 "migrate-registry"
    assert_line --index 1 "null"
    assert_line --index 2 "old-registry"
    assert_line --index 3 "operator"
    assert_line --index 4 "rachid"
    assert_line --index 5 "legacy"
    assert_line --index 6 "default"
    assert_line --index 7 "prod"
    assert_line --index 8 "null"
    assert_line --index 9 "package"
    assert_line --index 10 "cloudai:inst-a"
    assert_line --index 11 "nginx"
    assert_line --index 12 "default"
    assert_line --index 13 "****"
    assert_line --index 14 "null"

    # Restricted backup of the old record before the write.
    backup=$(find "$CLOUDIFY_CREDENTIALS_DIR/migration-backup" -type f | head -1)
    [ -n "$backup" ]
    cmp -s "$backup" "$OLD"

    # The old record is never deleted by the conversion (the sweep is later).
    assert [ -f "$OLD" ]
}
