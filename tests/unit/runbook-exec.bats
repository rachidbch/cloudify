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
    source lib/context.sh
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

# The most recently written run snapshot for <id> (a same-second run/replay pair
# shares the timestamp prefix, so names do not order them).
_newest_snapshot() {
    ls -1t "$CLOUDIFY_DEPLOYMENTS_DIR/$1/runs/"*.yaml | head -1
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
    export CLOUDIFY_APPLICATION=execapp CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=exec-demo
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" FOO bar

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

@test "execute: a step body reading stdin does not truncate the remaining steps" {
    rubric "body stdin must not steal the step list (regression: silent truncation + false success)"
    local rb="$CLOUDIFY_TMP/stdin.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-stdin
targets: guest
---
```bash step=install target=guest pkg=demo id=one
cat >/dev/null
echo one >> "$CLOUDIFY_TMP/stdin-order"
```
```bash step=verify target=guest pkg=demo id=two
echo two >> "$CLOUDIFY_TMP/stdin-order"
```
```bash step=verify target=guest pkg=demo id=three
echo three >> "$CLOUDIFY_TMP/stdin-order"
```
EOF
    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/stdin-order")" = "$(printf 'one\ntwo\nthree')" ]
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
```bash step=human-gate id=gate phase=verify
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
    grep -q "^status: succeeded$" "$(_newest_snapshot exec-gate)"
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

@test "execute: the snapshot adds declared names and keeps every deployment key" {
    rubric "resolver view built once per run: adds the package name, corrects the env name, drops no deployment line"
    mkdir -p "$CLOUDIFY_DIR/pkg/demo"
    printf 'PKG_ONLY\nENV_WINS\n' > "$CLOUDIFY_DIR/pkg/demo/.remote-vars"
    cloudify_vars_pkg_write demo PKG_ONLY from-package
    export CLOUDIFY_APPLICATION=execapp CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=exec-add
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" DEP_KEY kept
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" ENV_WINS from-deployment
    export ENV_WINS=from-env

    local rb="$CLOUDIFY_TMP/add.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-add
targets: guest
---
```bash step=install target=guest pkg=demo id=one
echo ok
```
EOF
    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test
    unset ENV_WINS
    [ "$status" -eq 0 ]

    local snap
    snap=$(_snapshot exec-add)
    grep -q "^value.DEP_KEY: kept$" "$snap"
    grep -q "^value.PKG_ONLY: from-package$" "$snap"
    grep -q "^value.ENV_WINS: from-env$" "$snap"
    [ "$(grep -c '^value\.' "$snap")" -eq 3 ]
}

# ---------------------------------------------------------------
# Phase selection (state model v2 Phase 3)
# ---------------------------------------------------------------

@test "execute: a canonical bare run selects install+verify; --yes never reaches teardown" {
    rubric "bare run = install then verify; teardown only with --phase teardown"
    local rb="$CLOUDIFY_DIR/runbooks/app/default/runbook.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-canonical
targets: guest
---
```bash step=install target=guest pkg=demo id=i
echo install >> "$CLOUDIFY_TMP/canon-order"
```
```bash step=verify target=guest pkg=demo id=v
echo verify >> "$CLOUDIFY_TMP/canon-order"
```
```bash step=uninstall target=guest pkg=demo id=u
echo teardown >> "$CLOUDIFY_TMP/canon-order"
```
EOF
    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/canon-order")" = "$(printf 'install\nverify')" ]

    run cloudify_runbook_execute "$rb" --target guest=cloudai:xfce-test --phase teardown
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$CLOUDIFY_TMP/canon-order")" = "teardown" ]
    [ "$(grep -c teardown "$CLOUDIFY_TMP/canon-order")" -eq 1 ]
}

@test "preflight: only selected phases are inspected" {
    rubric "a teardown-only required var cannot block the install run"
    local rb="$CLOUDIFY_DIR/runbooks/app/default/runbook.md"
    _make_runbook "$rb" <<'EOF'
---
deployment: exec-phases
targets: guest
---
```bash step=install target=guest pkg=inst id=i
echo i
```
```bash step=uninstall target=guest pkg=teardown-pkg id=u
echo u
```
EOF
    mkdir -p "$CLOUDIFY_DIR/pkg/teardown-pkg"
    printf 'TEARDOWN_ONLY\n' > "$CLOUDIFY_DIR/pkg/teardown-pkg/.remote-vars"

    run cloudify_runbook_preflight "$rb" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run cloudify_runbook_preflight "$rb" --target guest=cloudai:xfce-test --phase teardown
    [ "$status" -ne 0 ]
    [[ "$output" == *"teardown-pkg: TEARDOWN_ONLY"* ]]
}
