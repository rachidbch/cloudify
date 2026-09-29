# Tests for the adoption command (plan: adoption-honesty item 4).
# Adoption is an operator action: the operator infers, cloudify supplies the
# shape - records (mechanical), events (writer: operator), a derived manifest
# status, and a read-only seeded verify whose failure never unwrites it.

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

    mkdir -p "$CLOUDIFY_DIR/pkg/affine"
    printf '1.1.0\n' > "$CLOUDIFY_DIR/pkg/affine/.version"

    # The runbook the deployment identity hangs from: one target slot.
    mkdir -p "$CLOUDIFY_DIR/runbooks/affine/default"
    cat > "$CLOUDIFY_DIR/runbooks/affine/default/runbook.md" <<'RB'
---
targets: server
---

# Runbook: affine

Steps arrive here.
RB

    # The verify child: a stub that records its argv and reports by fixture.
    mkdir -p "$CLOUDIFY_TMP/fakebin"
    cat > "$CLOUDIFY_TMP/fakebin/cloudify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${CLOUDIFY_TMP:-/tmp}/verify-args"
printf 'app=%s flavor=%s name=%s\n' "${CLOUDIFY_APPLICATION:-}" "${CLOUDIFY_FLAVOR:-}" "${CLOUDIFY_DEPLOYMENT_NAME:-}" \
    > "${CLOUDIFY_TMP:-/tmp}/verify-env"
exit "${CLOUDIFY_ADOPT_STUB_RC:-0}"
STUB
    chmod +x "$CLOUDIFY_TMP/fakebin/cloudify"
    export PATH="$CLOUDIFY_TMP/fakebin:$PATH"
    export CLOUDIFY_OPERATOR=rachid

    # The ivps inventory: node cloudai with instance affine at a fixed dir.
    NODE_DIR="$CLOUDIFY_TMP/nodes/n1"
    mkdir -p "$NODE_DIR"
    cat > "$CLOUDIFY_TMP/fakebin/ivps" <<STUB
#!/bin/bash
if [[ "\$1" = node && "\$2" = path ]]; then
    case "\$3" in
        cloudai|cloudai:affine) echo "$NODE_DIR" ;;
        *) exit 1 ;;
    esac
elif [[ "\$1" = list ]]; then
    echo "cloudai:affine"
else
    exit 9
fi
STUB
    chmod +x "$CLOUDIFY_TMP/fakebin/ivps"
}

teardown() {
    teardown_test_env
}

# affine_facts <line...> - the adoption stdin, one TSV fact per line.
affine_facts() {
    printf '%s\n' "$@" > "$CLOUDIFY_TMP/facts"
}

@test "adoption record: mechanical records, operator event, derived manifest" {
    rubric "the operator supplies the inference, cloudify supplies the shape"
    affine_facts 'version	affine	1.1.0' 'value	affine	AFFINE_PORT	8787	recipe'
    run cloudify_adoption_record affine/default/main --on cloudai:affine --notes "adopted from observation: server verified on :8787" affine < "$CLOUDIFY_TMP/facts"
    [ "$status" -eq 0 ] || { echo "OUTPUT: $output"; false; }

    # The manifest: created unproved (null commit beside the development
    # override - adoption pins no commit), then derived to adopted by the event.
    [ "$(cloudify_manifest_field affine default main status)" = "adopted" ]
    [ "$(cloudify_manifest_field affine default main application_commit)" = "null" ]
    [ "$(cloudify_manifest_field affine default main development_override)" = "true" ]
    [ "$(cloudify_manifest_field affine default main last_event_id)" != "null" ]

    # The record: revision 1, applied values with provenance, no attempt, health unknown.
    local rec
    rec=$(cloudify_state_record_dir cloudai affine affine default main affine default)/state.json
    [ -f "$rec" ]
    [ "$(jq -r .revision "$rec")" = "1" ]
    [ "$(jq -r .applied.version "$rec")" = "1.1.0" ]
    [ "$(jq -r .applied.values.AFFINE_PORT.source_form "$rec")" = "8787" ]
    [ "$(jq -r .applied.values.AFFINE_PORT.source "$rec")" = "recipe" ]
    [ "$(jq -r .applied.values.AFFINE_PORT.secret "$rec")" = "false" ]
    [ "$(jq -r .last_attempt "$rec")" = "null" ]
    [ "$(jq -r .health.status "$rec")" = "unknown" ]

    # The event: writer is the operator (a name, not a process), kind adopt.
    local eid ev
    eid=$(cloudify_manifest_field affine default main last_event_id)
    ev="$HOME/.local/state/cloudify/events/${eid:0:4}-${eid:4:2}/$eid.json"
    [ -f "$ev" ]
    [ "$(jq -r .writer.kind "$ev")" = "operator" ]
    [ "$(jq -r .writer.name "$ev")" = "rachid" ]
    [ "$(jq -r .command_kind "$ev")" = "adopt" ]
    [ "$(jq -r .application_commit "$ev")" = "null" ]
    [ "$(jq -r .outcome.summary "$ev")" = "adopted from observation: server verified on :8787" ]
    [ "$(jq -r .values.AFFINE_PORT.source_form "$ev")" = "8787" ]
}

@test "adoption record: the seeded verify dispatches read-only under the deployment identity" {
    rubric "the machine's first touch is a read: verify, seeded with the tuple"
    affine_facts 'version	affine	1.1.0' 'value	affine	AFFINE_PORT	8787	recipe'
    run cloudify_adoption_record affine/default/main --on cloudai:affine --notes "n" affine < "$CLOUDIFY_TMP/facts"
    [ "$status" -eq 0 ]

    # The verify child ran with the deployment identity and the target: the
    # dispatch's own worker projects health and the word (pinned by worker.bats).
    [ -f "$CLOUDIFY_TMP/verify-args" ]
    grep -q -- "--on cloudai:affine" "$CLOUDIFY_TMP/verify-args"
    grep -q "verify affine" "$CLOUDIFY_TMP/verify-args"
    grep -q "app=affine flavor=default name=main" "$CLOUDIFY_TMP/verify-env"
}

@test "adoption record: a failed verify leaves the adoption standing" {
    rubric "a failed verify never unwrites the adoption"
    export CLOUDIFY_ADOPT_STUB_RC=7
    affine_facts 'version	affine	1.1.0' 'value	affine	AFFINE_PORT	8787	recipe'
    run cloudify_adoption_record affine/default/main --on cloudai:affine --notes "n" affine < "$CLOUDIFY_TMP/facts"
    [ "$status" -eq 0 ]

    # Records and the event stand; the word stays adopted. (The health write
    # belongs to the verify dispatch's own worker - pinned by worker.bats.)
    local rec
    rec=$(cloudify_state_record_dir cloudai affine affine default main affine default)/state.json
    [ -f "$rec" ]
    [ "$(jq -r .applied.version "$rec")" = "1.1.0" ]
    [ "$(cloudify_manifest_field affine default main status)" = "adopted" ]
}

@test "adoption record: refuses secret forms, unknown sources, missing notes" {
    rubric "honesty guards before anything is written"
    affine_facts 'version	affine	1.1.0' 'value	affine	AFFINE_PORT	8787	recipe'
    run cloudify_adoption_record affine/default/main --on cloudai:affine affine < "$CLOUDIFY_TMP/facts"
    [ "$status" -ne 0 ]

    affine_facts 'version	affine	1.1.0' 'value	affine	AFFINE_TOKEN	@vault:kv/t	recipe'
    run cloudify_adoption_record affine/default/main --on cloudai:affine --notes "n" affine < "$CLOUDIFY_TMP/facts"
    [ "$status" -ne 0 ]
    [ ! -f "$(cloudify_state_record_dir cloudai affine affine default main affine default)/state.json" ]

    affine_facts 'version	affine	1.1.0' 'value	affine	AFFINE_PORT	8787	gossip'
    run cloudify_adoption_record affine/default/main --on cloudai:affine --notes "n" affine < "$CLOUDIFY_TMP/facts"
    [ "$status" -ne 0 ]

    run cloudify_adoption_record affine/default/main --on cloudai:affine --notes "n" nosuchpkg \
        <<< "$(facts 'version	nosuchpkg	1.0.0')"
    [ "$status" -ne 0 ]
}
