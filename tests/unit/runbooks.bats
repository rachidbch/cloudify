#!/usr/bin/env bats
# Branch 7 T6a: playable runbooks — parse, discovery, target binding, preflight
# and `cloudify_deployment_run --dry-run`. No step is executed (that is T6b).
#
# The machine contract under test:
#   cloudify_runbook_parse  -> type \t id \t target \t pkg \t body-b64
#   cloudify_runbook_meta   -> deployment \t targets-csv
#   cloudify_runbook_find   -> the single matching runbook path
#   cloudify_runbook_bind_targets -> name \t node \t instance \t ssh_host
#   cloudify_runbook_preflight    -> rc 0 or die listing missing pkg: NAME

setup() {
    source tests/helpers/common.bash
    setup_test_env

    export HOME="$CLOUDIFY_TMP/home"
    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/creds"
    mkdir -p "$HOME" "$CLOUDIFY_CREDENTIALS_DIR"
    export IVPS_CONFIG_DIR="$CLOUDIFY_TMP/ivps"
    mkdir -p "$IVPS_CONFIG_DIR"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/targets.sh
    source lib/context.sh
    source lib/runbooks.sh

    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"

    unset CLOUDIFY_NODE IVPS_DEFAULT_NODE CLOUDIFY_DEPLOYMENT REQUIRED_VAR || true
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:xfce-test cloudai:guac)
    IVPS_LIST_RC=0
    RUNBOOKS="tests/fixtures/runbooks"
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

# An executable ivps stub for the real-router tests (a new process, no functions).
_create_ivps_stub() {
    cat > "$STUB_DIR/ivps" <<STUB
#!/bin/bash
case "\${1:-}" in
    node)
        [[ "\${3:-}" == "local" || "\${3:-}" == "cloudai" ]] || exit 1
        echo "$STUB_DIR/nodes/\${3:-}"
        ;;
    list)
        echo "  REMOTE:NAME      STATUS"
        echo "  cloudai:xfce-test Running"
        echo "  cloudai:guac Running"
        ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$STUB_DIR/ivps"
}

# _field <line> <0-based index> — one tab-separated field, empty fields preserved
# (read with IFS=tab collapses them; parameter expansion does not).
_field() {
    local rest="$1" i
    for ((i = 0; i < $2; i++)); do rest="${rest#*$'\t'}"; done
    printf '%s' "${rest%%$'\t'*}"
}

# _make_runbook <path>  (content on stdin)
_make_runbook() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

# Declare <names> in a fixture package under the mock pkg dir
_declare() {
    local pkg="$1"
    shift
    mkdir -p "$CLOUDIFY_DIR/pkg/$pkg"
    printf '%s\n' "$@" > "$CLOUDIFY_DIR/pkg/$pkg/.remote-vars"
}

# ---------------------------------------------------------------
# Parse: front-matter + steps
# ---------------------------------------------------------------

@test "meta: front-matter yields deployment and declared targets" {
    rubric "cloudify_runbook_meta -> deployment<TAB>targets-csv"
    run cloudify_runbook_meta "$RUNBOOKS/valid.md"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'demo\tguest,gateway')" ]
}

@test "parse: 3 typed steps, auto ids, explicit id, multi-line body b64" {
    rubric "one machine line per step: type,id,target,pkg,body-b64"
    run cloudify_runbook_parse "$RUNBOOKS/valid.md"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]

    [ "$(_field "${lines[0]}" 0)" = "install" ]
    [ "$(_field "${lines[0]}" 1)" = "01" ]
    [ "$(_field "${lines[0]}" 2)" = "guest" ]
    [ "$(_field "${lines[0]}" 3)" = "demo-pkg" ]
    local body
    body=$(printf '%s' "$(_field "${lines[0]}" 4)" | base64 -d)
    [ "$body" = "$(printf 'cloudify --on "$TARGET_GUEST" install demo-pkg\n# a second body line so multi-line bodies round-trip\necho done')" ]

    [ "$(_field "${lines[1]}" 0)" = "verify" ]
    [ "$(_field "${lines[1]}" 1)" = "check-guest" ]
    [ "$(_field "${lines[1]}" 2)" = "guest" ]
    [ "$(_field "${lines[1]}" 3)" = "demo-pkg" ]

    [ "$(_field "${lines[2]}" 0)" = "human-gate" ]
    [ "$(_field "${lines[2]}" 1)" = "03" ]
    [ -z "$(_field "${lines[2]}" 2)" ]
    [ -z "$(_field "${lines[2]}" 3)" ]
    [ "$(printf '%s' "$(_field "${lines[2]}" 4)" | base64 -d)" = "Open the URL and confirm the desktop renders." ]
}

@test "parse accepts a generic run step (no target, no pkg)" {
    rubric "run is a passthrough: target and pkg optional"
    local f="$CLOUDIFY_TMP/run.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=run phase=install
ivps expose-direct localhost 8080
```
```bash step=run target=guest phase=verify
echo "$TARGET_GUEST"
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "$(_field "${lines[0]}" 0)" = "run" ]
    [ -z "$(_field "${lines[0]}" 2)" ]
    [ "$(_field "${lines[1]}" 2)" = "guest" ]
}

# ---------------------------------------------------------------
# Parse: rejections (runbook path + line/step in the message)
# ---------------------------------------------------------------

@test "parse rejects an unknown step type" {
    rubric "unknown type -> die naming the runbook path and line"
    local f="$CLOUDIFY_TMP/unknown.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=frobnicate target=guest pkg=x
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$f"* ]]
    [[ "$output" == *"line 5"* ]]
    [[ "$output" == *"unknown step type 'frobnicate'"* ]]
}

@test "parse rejects a step with no target" {
    rubric "missing target -> die"
    local f="$CLOUDIFY_TMP/no-target.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install pkg=x
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing 'target='"* ]]
}

@test "parse rejects a pkg-consuming step with no pkg" {
    rubric "missing pkg for install/configure/verify/uninstall -> die"
    local f="$CLOUDIFY_TMP/no-pkg.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install target=guest
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing 'pkg='"* ]]
}

@test "parse rejects a target not declared in the front-matter" {
    rubric "undeclared target -> die (names are front-matter-scoped)"
    local f="$CLOUDIFY_TMP/undeclared.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install target=other pkg=x
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"target 'other' is not declared"* ]]
}

@test "parse rejects a duplicate step id" {
    rubric "duplicate id -> die (explicit or colliding with an auto id)"
    local f="$CLOUDIFY_TMP/dup.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install target=guest pkg=x id=dup
echo one
```
```bash step=verify target=guest pkg=x id=dup
echo two
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate step id 'dup'"* ]]
}

@test "parse rejects an unknown step attribute" {
    rubric "unknown attribute -> die (fail closed on typos)"
    local f="$CLOUDIFY_TMP/bad-attr.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install target=guest pkg=x timeout=5
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown step attribute 'timeout=5'"* ]]
}

@test "parse rejects a runbook with no front-matter" {
    rubric "no front-matter -> die with a clear message"
    local f="$CLOUDIFY_TMP/no-fm.md"
    _make_runbook "$f" <<'EOF'
# Just prose, no front-matter
```bash step=install target=guest pkg=x
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing front-matter"* ]]
}

# ---------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------

@test "find: the single runbook declaring the deployment" {
    rubric "only a canonical runbooks/<app>/<flavor>/runbook.md is discoverable"
    local root="$CLOUDIFY_TMP/scan"
    _make_runbook "$root/one/default/runbook.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    _make_runbook "$root/other/default/runbook.md" <<'EOF'
---
deployment: other
targets: guest
---
EOF
    run cloudify_runbook_find demo "$root"
    [ "$status" -eq 0 ]
    [ "$output" = "$root/one/default/runbook.md" ]
}

@test "find: a Markdown file that is not runbook.md is invisible" {
    rubric "a non-canonical name is never discoverable, whatever its front matter"
    local root="$CLOUDIFY_TMP/scan-name"
    _make_runbook "$root/notes/default/other.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    run cloudify_runbook_find demo "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No runbook found for deployment 'demo'"* ]]
}

@test "find: no match dies" {
    rubric "no matching runbook -> die"
    local root="$CLOUDIFY_TMP/scan-none"
    _make_runbook "$root/other/default/runbook.md" <<'EOF'
---
deployment: other
targets: guest
---
EOF
    run cloudify_runbook_find demo "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No runbook found for deployment 'demo'"* ]]
}

@test "find: two matches dies listing both" {
    rubric "two runbooks for one deployment -> die, never a silent pick"
    local root="$CLOUDIFY_TMP/scan-two"
    _make_runbook "$root/a/default/runbook.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    _make_runbook "$root/b/default/runbook.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    run cloudify_runbook_find demo "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Multiple runbooks"* ]]
    [[ "$output" == *"$root/a/default/runbook.md"* ]]
    [[ "$output" == *"$root/b/default/runbook.md"* ]]
}

@test "find: the default root is \$CLOUDIFY_DIR/runbooks" {
    rubric "no root argument -> the repo runbooks dir, like pkg/"
    _make_runbook "$CLOUDIFY_DIR/runbooks/app/default/runbook.md" <<'EOF'
---
deployment: demo-default
targets: guest
---
EOF
    run cloudify_runbook_find demo-default
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/runbooks/app/default/runbook.md" ]
}

# ---------------------------------------------------------------
# Target binding
# ---------------------------------------------------------------

@test "bind: --target overrides for each declared target, in order" {
    rubric "CLI binding wins; output is name<TAB>node<TAB>instance<TAB>ssh_host"
    run cloudify_runbook_bind_targets "$RUNBOOKS/valid.md" \
        --target guest=cloudai:xfce-test --target gateway=cloudai:guac
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(printf 'guest\tcloudai\txfce-test\txfce-test')" ]
    [ "${lines[1]}" = "$(printf 'gateway\tcloudai\tguac\tguac')" ]
}

@test "bind: falls back to the deployment-store var TARGET_<NAME>" {
    rubric "no --target -> TARGET_GUEST from the deployment store of the active application reference"
    export CLOUDIFY_APPLICATION=bindapp CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=default
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" TARGET_GUEST "cloudai:xfce-test"
    run cloudify_runbook_bind_targets "$RUNBOOKS/guest-only.md"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'guest\tcloudai\txfce-test\txfce-test')" ]
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
}

@test "bind: an unbound target dies listing it" {
    rubric "neither --target nor the store -> die listing the needed binding"
    run cloudify_runbook_bind_targets "$RUNBOOKS/guest-only.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unbound target(s)"* ]]
    [[ "$output" == *"guest"* ]]
    [[ "$output" == *"TARGET_"* ]]
}

@test "bind: a binding for an undeclared target dies" {
    rubric "typo'd --target name -> die, fail closed"
    run cloudify_runbook_bind_targets "$RUNBOOKS/guest-only.md" --target nope=cloudai:guac
    [ "$status" -ne 0 ]
    [[ "$output" == *"'nope' is not a declared target"* ]]
}

# ---------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------

@test "preflight: a missing required var fails listing pkg: NAME" {
    rubric "bare required name unresolved -> die listing it (optional is ignored)"
    _declare demo-pkg 'REQUIRED_VAR' 'OPTIONAL_VAR='
    run cloudify_runbook_preflight "$RUNBOOKS/guest-only.md" --target guest=cloudai:xfce-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"demo-pkg: REQUIRED_VAR"* ]]
    [[ "$output" != *"OPTIONAL_VAR"* ]]
}

@test "preflight: all required vars resolved passes silently" {
    rubric "required name provided by the deployment store -> rc 0, no output"
    _declare demo-pkg 'REQUIRED_VAR' 'OPTIONAL_VAR='
    export CLOUDIFY_APPLICATION=bindapp CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=default
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" REQUIRED_VAR provided
    run cloudify_runbook_preflight "$RUNBOOKS/guest-only.md" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    unset CLOUDIFY_APPLICATION CLOUDIFY_FLAVOR CLOUDIFY_DEPLOYMENT_NAME
}

# ---------------------------------------------------------------
# cloudify_deployment_run (T6a: plan only)
# ---------------------------------------------------------------

@test "deployment_run: --from rejects an unknown step id" {
    rubric "a --from typo fails before anything could run"
    run cloudify_deployment_run demo --dry-run --runbook "$RUNBOOKS/valid.md" --from nope \
        --target guest=cloudai:xfce-test --target gateway=cloudai:guac
    [ "$status" -ne 0 ]
    [[ "$output" == *"no step with id 'nope'"* ]]
}

@test "real router: app run --dry-run prints the plan and exits 0" {
    rubric "router path -> find/parse/bind/preflight/plan, nothing executed"
    _create_ivps_stub
    local cf="$CLOUDIFY_TMP/router"
    mkdir -p "$cf/pkg" "$cf/inventory" "$cf/tmp" "$cf/creds" "$cf/runbooks/demo/default"
    cp "$RUNBOOKS/valid.md" "$cf/runbooks/demo/default/runbook.md"

    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true
        export CLOUDIFY_DIR='$cf' CLOUDIFY_TMP='$cf/tmp' CLOUDIFY_CREDENTIALS_DIR='$cf/creds'
        export CLOUDIFY_REMOTE_USER=root CLOUDIFY_REMOTE_PWD=test
        cd '$PWD' && bash cloudify app run demo --dry-run \
            --target guest=cloudai:xfce-test --target gateway=cloudai:guac 2>&1
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Application: demo/default"* ]]
    [[ "$output" == *"Deployment: demo"* ]]
    [[ "$output" == *"guest -> node=cloudai instance=xfce-test ssh=xfce-test"* ]]
    [[ "$output" == *"check-guest"* ]]
    [[ "$output" == *"human-gate"* ]]
}

@test "deployment_run: the engine executes the steps after the plan" {
    rubric "parse/bind/preflight/plan then execute, snapshot written"
    _create_ivps_stub
    local rb="$CLOUDIFY_TMP/exec-runbook.md"
    _make_runbook "$rb" <<EOF
---
deployment: demo
targets: guest
---
\`\`\`bash step=install target=guest pkg=demo-pkg id=one
echo ran >> "$CLOUDIFY_TMP/exec-marker"
\`\`\`
EOF

    run cloudify_deployment_run demo --runbook "$rb" \
        --target guest=cloudai:xfce-test --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment: demo"* ]]
    [[ "$output" == *"succeeded"* ]]
    [ -f "$CLOUDIFY_TMP/exec-marker" ]
    [ -n "$(ls "$CLOUDIFY_DEPLOYMENTS_DIR/demo/runs/"*.yaml 2>/dev/null)" ]
}

# ---------------------------------------------------------------
# Canonical tree, application inputs and phases (state model v2 Phase 3)
# ---------------------------------------------------------------

@test "identity: application and flavor come from the canonical path" {
    rubric "runbooks/<application>/<flavor>/runbook.md, not the front-matter deployment"
    local f="$CLOUDIFY_DIR/runbooks/myapp/prod/runbook.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo-id
targets: guest
---
EOF
    run cloudify_runbook_identity "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'myapp\tprod')" ]

    run cloudify_runbook_identity "$CLOUDIFY_TMP/plain.md"
    [ "$status" -ne 0 ]
}

@test "meta: deployment: front-matter is optional, CLOUDIFY_DEPLOYMENT fills it" {
    rubric "one rule for every runbook path"
    local f="$CLOUDIFY_DIR/runbooks/myapp/default/runbook.md"
    _make_runbook "$f" <<'EOF'
---
targets: guest
---
EOF
    export CLOUDIFY_DEPLOYMENT=from-env
    run cloudify_runbook_meta "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'from-env\tguest')" ]

    unset CLOUDIFY_DEPLOYMENT
    run cloudify_runbook_meta "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CLOUDIFY_DEPLOYMENT is not set"* ]]

    run cloudify_runbook_meta "$RUNBOOKS/guest-only.md"
    [ "$status" -eq 0 ]
}

@test "parse: default phase per step type" {
    rubric "launch/install -> install, configure -> reconfigure, verify -> verify, uninstall -> teardown"
    local f="$CLOUDIFY_TMP/phases.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=launch target=guest pkg=x id=l
echo l
```
```bash step=install target=guest pkg=x id=i
echo i
```
```bash step=configure target=guest pkg=x id=c
echo c
```
```bash step=verify target=guest pkg=x id=v
echo v
```
```bash step=uninstall target=guest pkg=x id=u
echo u
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -eq 0 ]
    [ "$(_field "${lines[0]}" 5)" = "install" ]
    [ "$(_field "${lines[1]}" 5)" = "install" ]
    [ "$(_field "${lines[2]}" 5)" = "reconfigure" ]
    [ "$(_field "${lines[3]}" 5)" = "verify" ]
    [ "$(_field "${lines[4]}" 5)" = "teardown" ]
}

@test "parse: a run/human-gate step must declare a phase" {
    rubric "run and human-gate have no default phase"
    local f="$CLOUDIFY_DIR/runbooks/app/default/runbook.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=run target=guest id=r
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must declare phase="* ]]

    local g="$CLOUDIFY_TMP/run-no-phase.md"
    _make_runbook "$g" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=run target=guest id=r
echo hi
```
EOF
    run cloudify_runbook_parse "$g"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must declare phase="* ]]
}

@test "parse: unknown phases and contradictory type-phase pairs are rejected" {
    rubric "fail closed before execution"
    local f="$CLOUDIFY_TMP/phase-bad.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=run target=guest id=r phase=bogus
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown phase 'bogus'"* ]]

    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install target=guest pkg=x id=i phase=teardown
echo hi
```
EOF
    run cloudify_runbook_parse "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot run in phase 'teardown'"* ]]
}

@test "inputs/map: frozen flat syntax parses; a mapping input must be declared" {
    rubric "inputs: NAME[, ...] and map: PACKAGE_VAR=APPLICATION_INPUT[, ...]"
    local f="$CLOUDIFY_DIR/runbooks/app/default/runbook.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
inputs: SHARED, RDP_PASSWORD
map: SPEC=SHARED, OTHER=RDP_PASSWORD
---
```bash step=install target=guest pkg=x id=i
echo hi
```
EOF
    run cloudify_runbook_inputs "$f"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "SHARED" ]
    [ "${lines[1]}" = "RDP_PASSWORD" ]

    run cloudify_runbook_map "$f"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(printf 'SPEC\tSHARED')" ]
    [ "${lines[1]}" = "$(printf 'OTHER\tRDP_PASSWORD')" ]

    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
inputs: SHARED
map: SPEC=NOT_DECLARED
---
```bash step=install target=guest pkg=x id=i
echo hi
```
EOF
    run _cloudify_runbook_export_app_spec "$f" demo
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not declared"* ]]

    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
inputs: SHARED
map: bad/name=SHARED
---
```bash step=install target=guest pkg=x id=i
echo hi
```
EOF
    run _cloudify_runbook_export_app_spec "$f" demo
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid mapped package variable"* ]]
}

@test "phases: a bare canonical run selects install then verify, never teardown" {
    rubric "cloudify_runbook_phases_for + the selected step list"
    local f="$CLOUDIFY_DIR/runbooks/app/default/runbook.md"
    _make_runbook "$f" <<'EOF'
---
deployment: demo
targets: guest
---
```bash step=install target=guest pkg=x id=i
echo i
```
```bash step=verify target=guest pkg=x id=v
echo v
```
```bash step=uninstall target=guest pkg=x id=u
echo u
```
EOF
    run cloudify_runbook_phases_for "$f"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "install" ]
    [ "${lines[1]}" = "verify" ]
    [ "${#lines[@]}" -eq 2 ]

    local po
    po=$(cloudify_runbook_parse "$f")
    run _cloudify_runbook_select_steps "$f" "$po"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\tu'* ]]
    [[ "$output" == *$'\ti\t'* ]]
    [[ "$output" == *$'\tv\t'* ]]

    run _cloudify_runbook_select_steps "$f" "$po" teardown
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\tu'* ]]

    run cloudify_runbook_phases_for "$f" bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown phase 'bogus'"* ]]
}

@test "find_app: the canonical path is the only discoverable runbook" {
    rubric "runbooks/<application>/<flavor>/runbook.md"
    local canonical="$CLOUDIFY_DIR/runbooks/myapp/default/runbook.md"
    _make_runbook "$canonical" <<'EOF'
---
deployment: one
targets: guest
---
EOF
    run cloudify_runbook_find_app myapp default
    [ "$status" -eq 0 ]
    [ "$output" = "$canonical" ]

    run cloudify_runbook_find_app myapp prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"No runbook found for application"* ]]

    run cloudify_runbook_find_app missing default
    [ "$status" -ne 0 ]
    [[ "$output" == *"No runbook found for application"* ]]
}

# ---------------------------------------------------------------
# Application commands, the deployment manifest and phases
# (state model v2 Phase 3 slice 3B)
# ---------------------------------------------------------------

# A clean Cloudify tree: the manifest commit gate needs an identified commit.
_clean_tree() {
    git -C "$CLOUDIFY_DIR" init -q
    git -C "$CLOUDIFY_DIR" -c user.email=t@t -c user.name=t add -A
    git -C "$CLOUDIFY_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# An app runbook at the canonical path, with an install and a verify step.
_make_app_runbook() {
    local app="$1" flavor="$2" deploy="$3" body_install="${4:-true}" body_verify="${5:-true}"
    mkdir -p "$CLOUDIFY_DIR/runbooks/$app/$flavor"
    cat > "$CLOUDIFY_DIR/runbooks/$app/$flavor/runbook.md" <<EOF
---
deployment: $deploy
targets: guest
---
\`\`\`bash step=install target=guest pkg=demo id=one
$body_install
\`\`\`
\`\`\`bash step=verify target=guest pkg=demo id=two
$body_verify
\`\`\`
EOF
}

# --- Tuple derivation ---

@test "tuple: application and flavor come from the path, name defaults to default" {
    rubric "runbooks/<application>/<flavor>/runbook.md"
    local canonical="$CLOUDIFY_DIR/runbooks/myapp/prod/runbook.md"
    _make_runbook "$canonical" <<'EOF'
---
deployment: my-dep
targets: guest
---
EOF
    run _cloudify_runbook_tuple_for "$canonical"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'myapp\tprod\tdefault')" ]

    run _cloudify_runbook_tuple_for "$canonical" "named"
    [ "$output" = "$(printf 'myapp\tprod\tnamed')" ]

    # A runbook outside the canonical shape carries no application identity: no
    # manifest.
    run _cloudify_runbook_tuple_for "$RUNBOOKS/valid.md"
    [ "$status" -ne 0 ]

    # A path component the identity rules reject fails closed.
    run _cloudify_runbook_tuple_for "$CLOUDIFY_DIR/runbooks/myapp/../runbook.md"
    [ "$status" -ne 0 ]
}

# --- app run surface ---

@test "app run: default flavor and default deployment name, printed in the plan" {
    rubric "cloudify app run <application> -> <application>/default --name default"
    _make_app_runbook myapp default my-dep
    _clean_tree

    run cloudify_app_run myapp --dry-run --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Application: myapp/default"* ]]
    [[ "$output" == *"Deployment: default"* ]]
    [[ "$output" == *"phase=install"* ]]
    # The plan prints the phase, never the base64 step body.
    [[ "$output" != *"$(printf 'dHJ1ZQ==' )"* ]]
}

@test "app run: exports CLOUDIFY_APPLICATION, CLOUDIFY_FLAVOR and CLOUDIFY_DEPLOYMENT_NAME to the steps" {
    rubric "the child dispatch carries the tuple"
    _make_app_runbook myapp prod my-dep \
        "echo \"TUPLE=\$CLOUDIFY_APPLICATION/\$CLOUDIFY_FLAVOR/\$CLOUDIFY_DEPLOYMENT_NAME DEP=\$CLOUDIFY_DEPLOYMENT\" > \"\$CLOUDIFY_TMP/tuple.txt\"" \
        true
    _clean_tree
    run cloudify_app_run myapp/prod --name named --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/tuple.txt")" = "TUPLE=myapp/prod/named DEP=my-dep" ]
}

@test "app run: rejects a three-segment reference and a bad component" {
    rubric "exactly one '/', validated components"
    run cloudify_app_run a/b/c
    [ "$status" -ne 0 ]
    [[ "$output" == *"more than one '/'"* ]]

    run cloudify_app_run ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: cloudify app run"* ]]

    run cloudify_app_run "/default"
    [ "$status" -ne 0 ]
    run cloudify_app_run "myapp/"
    [ "$status" -ne 0 ]

    run cloudify_app_run myapp --name ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"--name needs a value"* ]]
}

@test "app run: no runbook dies naming the full reference and deployment name" {
    rubric "every error carries the reference and the deployment name"
    run cloudify_app_run missing/app --name prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"app run missing/app --name prod"* ]]
}

@test "app: reconfigure, verify and teardown are reserved until Phase 4" {
    run cloudify_app_reserved reconfigure
    [ "$status" -ne 0 ]
    [[ "$output" == *"not yet available"* ]]
    [[ "$output" == *"Phase 4"* ]]

    run cloudify_app_reserved verify
    [ "$status" -ne 0 ]
    run cloudify_app_reserved teardown
    [ "$status" -ne 0 ]
}

# --- Manifest lifecycle ---

@test "manifest: exists as applying before the first mutating step, active after install+verify" {
    rubric "creation before mutation, applying -> active"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep \
        "test -f \"\$CLOUDIFY_STATE_DIR/deployments/myapp/default/default/manifest.json\" && grep -q '\"status\": \"applying\"' \"\$CLOUDIFY_STATE_DIR/deployments/myapp/default/default/manifest.json\""
    _clean_tree
    run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cloudify_manifest_field myapp default default status)" = "active" ]
    [ "$(cloudify_manifest_field myapp default default last_run_id)" = "null" ]
    # the compatibility snapshot is still written where it always was
    [ -n "$(ls "$CLOUDIFY_DEPLOYMENTS_DIR/my-dep/runs/"*.yaml 2>/dev/null)" ]
}

@test "manifest: an install-only run never becomes active" {
    rubric "active requires install and verify, not install alone"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep
    _clean_tree
    run cloudify_deployment_run my-dep --target guest=cloudai:xfce-test --phase install
    [ "$status" -eq 0 ]
    # The manifest was created applying and keeps that recorded status: only a
    # run that selected both install and verify may end active.
    [ "$(cloudify_manifest_field myapp default default status)" = "applying" ]
}

@test "manifest: an observed failure marks the deployment degraded" {
    rubric "degraded on failure, and it stays discoverable"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep "exit 3"
    _clean_tree
    run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -ne 0 ]
    [ "$(cloudify_manifest_field myapp default default status)" = "degraded" ]
    run cloudify_deployment_show my-dep
    [[ "$output" == *"status: degraded"* ]]
}

@test "manifest: a run killed between steps stays applying and show reveals it" {
    rubric "interrupted: no status update, manifest still applying"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    local marker="$CLOUDIFY_TMP/killed"
    _make_app_runbook myapp default my-dep \
        "touch \"$marker\"; sleep 5" \
        true
    _clean_tree

    ( cloudify_app_run myapp --target guest=cloudai:xfce-test ) &
    local pid=$!
    local i=0
    while [[ ! -f "$marker" ]] && ((i < 100)); do sleep 0.1; i=$((i + 1)); done
    [ -f "$marker" ]
    # Kill the engine while it is inside the first step: it never reaches the
    # status update, so the manifest stays applying.
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    [ "$(cloudify_manifest_field myapp default default status)" = "applying" ]
    run cloudify_deployment_show my-dep
    [[ "$output" == *"status: applying"* ]]
    [[ "$output" == *"interrupted"* ]]
    # No run or event record is fabricated in Phase 3.
    [ ! -d "$CLOUDIFY_STATE_DIR/deployments/myapp/default/default/runs" ]
}

@test "manifest: two applications with deployment name default never collide" {
    rubric "distinct manifests and distinct nested input stores"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook alpha default alpha-dep
    _make_app_runbook beta default beta-dep
    _clean_tree

    run cloudify_app_run alpha --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    run cloudify_app_run beta --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]

    local alpha beta
    alpha=$(cloudify_state_manifest_file alpha default default)
    beta=$(cloudify_state_manifest_file beta default default)
    [ "$alpha" != "$beta" ]
    [ -f "$alpha" ]
    [ -f "$beta" ]
    [ "$(cloudify_deployment_values_file alpha default default)" != "$(cloudify_deployment_values_file beta default default)" ]
}

# --- Bindings ---

@test "bindings: a rerun without --target reuses the recorded binding" {
    rubric "recorded bindings instead of re-prompting"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep \
        "printf '%s\\n' \"\$TARGET_GUEST\" >> \"\$CLOUDIFY_TMP/targets.txt\"" \
        "printf '%s\\n' \"\$TARGET_GUEST\" >> \"\$CLOUDIFY_TMP/targets.txt\""
    _clean_tree
    run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    # Second run: no --target at all, the stored binding from the manifest is used.
    run cloudify_app_run myapp
    [ "$status" -eq 0 ]
    [ "$(sort -u "$CLOUDIFY_TMP/targets.txt")" = "cloudai:xfce-test" ]
}

@test "bindings: a differing --target is refused unless --migrate-targets" {
    rubric "rebinding is a migration, not a rerun"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep
    _clean_tree
    run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]

    run cloudify_app_run myapp --target guest=cloudai:guac
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to rebind"* ]]
    [[ "$output" == *"--migrate-targets"* ]]
    run cloudify_manifest_bindings myapp default default
    [[ "$output" == *"cloudai:xfce-test"* ]]

    run cloudify_app_run myapp --target guest=cloudai:guac --migrate-targets
    [ "$status" -eq 0 ]
    run cloudify_manifest_bindings myapp default default
    [[ "$output" == *"cloudai:guac"* ]]
}

# --- Source commit ---

@test "commit: a dirty tree needs the explicit development override and is never replayable" {
    rubric "CLOUDIFY_DEVELOPMENT_OVERRIDE, development_override, replayable: no"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep
    _clean_tree
    touch "$CLOUDIFY_DIR/dirty-file"

    run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"CLOUDIFY_DEVELOPMENT_OVERRIDE=1"* ]]

    CLOUDIFY_DEVELOPMENT_OVERRIDE=1 run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cloudify_manifest_field myapp default default development_override)" = "true" ]
    [[ "$(cloudify_manifest_field myapp default default application_commit)" =~ ^[0-9a-f]{40}$ ]]
    run cloudify_manifest_describe myapp default default
    [[ "$output" == *"replayable: no"* ]]
}

@test "commit: an unidentified tree records a real null commit with the override" {
    rubric "no repository + CLOUDIFY_DEVELOPMENT_OVERRIDE=1 -> null, never a zero commit"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep
    # No git init: there is no commit to prove.
    CLOUDIFY_DEVELOPMENT_OVERRIDE=1 run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cloudify_manifest_field myapp default default development_override)" = "true" ]
    [ "$(cloudify_manifest_field myapp default default application_commit)" = "null" ]
    run cloudify_manifest_describe myapp default default
    [ "$status" -eq 0 ]
    [[ "$output" == *"replayable: no"* ]]
    [[ "$output" == *"application_commit: null"* ]]
}

@test "commit: a clean tree records a real commit and is replayable" {
    rubric "development_override false"
    export CLOUDIFY_STATE_DIR="$CLOUDIFY_TMP/state"
    _make_app_runbook myapp default my-dep
    _clean_tree
    run cloudify_app_run myapp --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ "$(cloudify_manifest_field myapp default default development_override)" = "false" ]
    [[ "$(cloudify_manifest_field myapp default default application_commit)" == "$(git -C "$CLOUDIFY_DIR" rev-parse HEAD)" ]]
    run cloudify_manifest_describe myapp default default
    [[ "$output" == *"replayable: yes"* ]]
}

@test "preflight: only the selected phases are inspected" {
    rubric "a teardown-only value cannot block an install run"
    local f="$CLOUDIFY_DIR/runbooks/phaseapp/default/runbook.md"
    _make_runbook "$f" <<'EOF'
---
deployment: phase-dep
targets: guest
---
```bash step=install target=guest pkg=instpkg id=i
true
```
```bash step=uninstall target=guest pkg=teardownpkg id=u
true
```
EOF
    _declare instpkg REQ_INSTALL
    _declare teardownpkg REQ_TEARDOWN
    export CLOUDIFY_APPLICATION=phaseapp CLOUDIFY_FLAVOR=default CLOUDIFY_DEPLOYMENT_NAME=default
    _cloudify_vars_file_set "$(_cloudify_deployment_config)" REQ_INSTALL yes

    # A bare canonical run selects install then verify: the teardown-only
    # requirement is never inspected.
    run cloudify_runbook_preflight "$f" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]

    run cloudify_runbook_preflight "$f" --target guest=cloudai:xfce-test --phase teardown
    [ "$status" -ne 0 ]
    [[ "$output" == *"teardownpkg: REQ_TEARDOWN"* ]]
    [[ "$output" != *"instpkg: REQ_INSTALL"* ]]
}
