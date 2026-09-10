#!/usr/bin/env bats
# Branch 7 T6a: playable runbooks — parse, discovery, target binding, preflight
# and `deployment run --dry-run`. No step is executed (that is T6b).
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

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/vars.sh
    source lib/deployments.sh
    source lib/targets.sh
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
    rubric "scan <root>/**/*.md for a front-matter deployment match"
    local root="$CLOUDIFY_TMP/scan"
    _make_runbook "$root/a/one.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    _make_runbook "$root/b/two.md" <<'EOF'
---
deployment: other
targets: guest
---
EOF
    run cloudify_runbook_find demo "$root"
    [ "$status" -eq 0 ]
    [ "$output" = "$root/a/one.md" ]
}

@test "find: no match dies" {
    rubric "no matching runbook -> die"
    local root="$CLOUDIFY_TMP/scan-none"
    _make_runbook "$root/two.md" <<'EOF'
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
    _make_runbook "$root/a.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    _make_runbook "$root/b.md" <<'EOF'
---
deployment: demo
targets: guest
---
EOF
    run cloudify_runbook_find demo "$root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Multiple runbooks"* ]]
    [[ "$output" == *"$root/a.md"* ]]
    [[ "$output" == *"$root/b.md"* ]]
}

@test "find: the default root is \$CLOUDIFY_DIR/runbooks" {
    rubric "no root argument -> the repo runbooks dir, like pkg/"
    _make_runbook "$CLOUDIFY_DIR/runbooks/app/x.md" <<'EOF'
---
deployment: demo-default
targets: guest
---
EOF
    run cloudify_runbook_find demo-default
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_DIR/runbooks/app/x.md" ]
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
    rubric "no --target -> TARGET_GUEST from the runbook's deployment store"
    _cloudify_vars_file_set "$(_cloudify_deployment_config demo-bind)" TARGET_GUEST "cloudai:xfce-test"
    run cloudify_runbook_bind_targets "$RUNBOOKS/guest-only.md"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'guest\tcloudai\txfce-test\txfce-test')" ]
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
    _cloudify_vars_file_set "$(_cloudify_deployment_config demo-bind)" REQUIRED_VAR provided
    run cloudify_runbook_preflight "$RUNBOOKS/guest-only.md" --target guest=cloudai:xfce-test
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------
# deployment run (T6a: plan only)
# ---------------------------------------------------------------

@test "deployment run: --from rejects an unknown step id" {
    rubric "a --from typo fails before anything could run"
    run cloudify_deployment_run demo --dry-run --runbook "$RUNBOOKS/valid.md" --from nope \
        --target guest=cloudai:xfce-test --target gateway=cloudai:guac
    [ "$status" -ne 0 ]
    [[ "$output" == *"no step with id 'nope'"* ]]
}

@test "real router: deployment run --dry-run prints the plan and exits 0" {
    rubric "router path -> find/parse/bind/preflight/plan, nothing executed"
    _create_ivps_stub
    local cf="$CLOUDIFY_TMP/router"
    mkdir -p "$cf/pkg" "$cf/inventory" "$cf/tmp" "$cf/creds"

    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true
        export CLOUDIFY_DIR='$cf' CLOUDIFY_TMP='$cf/tmp' CLOUDIFY_CREDENTIALS_DIR='$cf/creds'
        export CLOUDIFY_REMOTE_USER=root CLOUDIFY_REMOTE_PWD=test
        cd '$PWD' && bash cloudify deployment run demo --dry-run \
            --runbook '$RUNBOOKS/valid.md' \
            --target guest=cloudai:xfce-test --target gateway=cloudai:guac 2>&1
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment: demo"* ]]
    [[ "$output" == *"guest -> node=cloudai instance=xfce-test ssh=xfce-test"* ]]
    [[ "$output" == *"check-guest"* ]]
    [[ "$output" == *"human-gate"* ]]
}

@test "real router: deployment run without --dry-run refuses until T6b" {
    rubric "plan prints, then die: no step execution in T6a"
    _create_ivps_stub
    local cf="$CLOUDIFY_TMP/router-nodry"
    mkdir -p "$cf/pkg" "$cf/inventory" "$cf/tmp" "$cf/creds"

    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true
        export CLOUDIFY_DIR='$cf' CLOUDIFY_TMP='$cf/tmp' CLOUDIFY_CREDENTIALS_DIR='$cf/creds'
        export CLOUDIFY_REMOTE_USER=root CLOUDIFY_REMOTE_PWD=test
        cd '$PWD' && bash cloudify deployment run demo \
            --runbook '$RUNBOOKS/valid.md' \
            --target guest=cloudai:xfce-test --target gateway=cloudai:guac 2>&1
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"T6b"* ]]
    [[ "$output" == *"Deployment: demo"* ]]
}
