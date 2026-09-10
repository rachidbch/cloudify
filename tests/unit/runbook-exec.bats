#!/usr/bin/env bats
# Branch 7 T6b: runbook execution — step runner, step outputs, human gate and
# the run snapshot. Parser/binding/preflight (T6a) are covered by runbooks.bats.
#
# Contract under test:
#   cloudify_runbook_execute <path> [--target name=addr]... [--from <id>] [--yes]
#     -> steps run in order; CLOUDIFY_OUTPUTS_FILE lines become OUT_<name>;
#        snapshot ${CLOUDIFY_DEPLOYMENTS_DIR}/<id>/runs/<utc>.yaml (0600).

setup() {
    source tests/helpers/common.bash
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/creds"
    mkdir -p "$HOME" "$CLOUDIFY_CREDENTIALS_DIR"
    export IVPS_CONFIG_DIR="$CLOUDIFY_TMP/ivps"
    mkdir -p "$IVPS_CONFIG_DIR"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/targets.sh
    source lib/registry.sh
    source lib/runbooks.sh

    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"

    unset CLOUDIFY_NODE IVPS_DEFAULT_NODE CLOUDIFY_DEPLOYMENT REQUIRED_VAR || true
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:xfce-test cloudai:guac)
    IVPS_LIST_RC=0
}

teardown() {
    trash-put "$STUB_DIR" 2>/dev/null || true
    teardown_test_env
}

# ivps stub as a shell function (shadows any real ivps in PATH).
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
            [[ "$IVPS_LIST_RC" -eq 0 ]] || return "$IVPS_LIST_RC"
            echo "  REMOTE:NAME      STATUS"
            for r in ${IVPS_ROWS[@]+"${IVPS_ROWS[@]}"}; do
                printf '  %-30s Running\n' "$r"
            done
            return 0
            ;;
        *) return 1 ;;
    esac
}

# _make_runbook <path>  (content on stdin)
_make_runbook() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

# The single run snapshot for <id>.
_snapshot() {
    ls "$CLOUDIFY_DEPLOYMENTS_DIR/$1/runs/"*.yaml
}

# ---------------------------------------------------------------
# Step runner + outputs + snapshot
# ---------------------------------------------------------------

@test "execute: steps run in order, OUT_<name> reaches the next step, snapshot records value+output" {
    rubric "two steps: order, OUT_<name> export, snapshot output.* + value.*, perms 0600"
    local rb="$CLOUDIFY_TMP/two-step.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-demo
targets: guest
---
```bash step=install target=guest pkg=demo id=first
echo first >> "$CLOUDIFY_TMP/order"
echo "greeting=hello" >> "$CLOUDIFY_OUTPUTS_FILE"
```
```bash step=verify target=guest pkg=demo id=second
echo second >> "$CLOUDIFY_TMP/order"
echo "seen=$OUT_greeting" >> "$CLOUDIFY_OUTPUTS_FILE"
```
EOF
    _cloudify_vars_file_set "$(_cloudify_deployment_config exec-demo)" FOO bar

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/order")" = "$(printf 'first\nsecond')" ]

    local snap
    snap=$(_snapshot exec-demo)
    [ -f "$snap" ]
    [ "$(stat -c '%a' "$snap")" = "600" ]
    grep -q "^status: succeeded$" "$snap"
    grep -q "^target.guest: cloudai:xfce-test$" "$snap"
    grep -q "^value.FOO: bar$" "$snap"
    grep -q "^output.greeting: hello$" "$snap"
    grep -q "^output.seen: hello$" "$snap"
}

@test "execute: stops at the first failing step; later steps do not run; snapshot failed" {
    rubric "non-zero step -> break with the step id, snapshot status: failed"
    local rb="$CLOUDIFY_TMP/fail.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-fail
targets: guest
---
```bash step=install target=guest pkg=demo id=ok
echo ok >> "$CLOUDIFY_TMP/fail-order"
```
```bash step=verify target=guest pkg=demo id=boom
echo boom >> "$CLOUDIFY_TMP/fail-order"
exit 7
```
```bash step=verify target=guest pkg=demo id=never
echo never >> "$CLOUDIFY_TMP/fail-order"
```
EOF

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"'boom'"* ]]
    [ "$(cat "$CLOUDIFY_TMP/fail-order")" = "$(printf 'ok\nboom')" ]

    local snap
    snap=$(_snapshot exec-fail)
    grep -q "^status: failed$" "$snap"
}

@test "execute: human-gate prints its body; --yes proceeds; no TTY + no --yes dies" {
    rubric "human-gate: body printed; --yes skips the prompt; no TTY without --yes -> die"
    local rb="$CLOUDIFY_TMP/gate.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-gate
targets: guest
---
```bash step=human-gate id=gate
Confirm the desktop renders.
```
EOF
    _run_no_tty() { cloudify_runbook_execute "$@" </dev/null; }

    run _run_no_tty "$rb" --target guest=cloudai:xfce-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"Confirm the desktop renders."* ]]
    [[ "$output" == *"'gate'"* ]]
    grep -q "^status: failed$" "$(_snapshot exec-gate)"

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Confirm the desktop renders."* ]]
    grep -q "^status: succeeded$" "$(_snapshot exec-gate | tail -1)"
}

@test "execute: --from starts at that step and skips the earlier ones" {
    rubric "--from <id> -> earlier steps skipped, the named step and later ones run"
    local rb="$CLOUDIFY_TMP/from.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-from
targets: guest
---
```bash step=install target=guest pkg=demo id=a
echo a >> "$CLOUDIFY_TMP/from-order"
```
```bash step=verify target=guest pkg=demo id=b
echo b >> "$CLOUDIFY_TMP/from-order"
```
```bash step=verify target=guest pkg=demo id=c
echo c >> "$CLOUDIFY_TMP/from-order"
```
EOF

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test --from b
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/from-order")" = "$(printf 'b\nc')" ]
}

@test "execute: an unknown --from id dies before any step runs" {
    rubric "--from typo -> fail closed, no step body executed"
    local rb="$CLOUDIFY_TMP/from-bad.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-from-bad
targets: guest
---
```bash step=install target=guest pkg=demo id=a
echo a >> "$CLOUDIFY_TMP/from-bad-order"
```
EOF

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test --from nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no step with id 'nope'"* ]]
    [ ! -f "$CLOUDIFY_TMP/from-bad-order" ]
}

# ---------------------------------------------------------------
# Snapshot vs registry
# ---------------------------------------------------------------

@test "execute: the run snapshot is separate from the registry" {
    rubric "snapshot under deployments/<id>/runs; no registry record is written"
    local rb="$CLOUDIFY_TMP/sep.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-sep
targets: guest
---
```bash step=install target=guest pkg=demo id=one
echo done
```
EOF

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ -f "$(_snapshot exec-sep)" ]

    local rec
    rec=$(cloudify_registry_file exec-sep cloudai xfce-test xfce-test demo)
    [ ! -e "$rec" ]
}
