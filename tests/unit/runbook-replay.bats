#!/usr/bin/env bats
# Branch 7 T6c: `deployment replay` — re-run a recorded run.
#
# Contract under test:
#   cloudify_deployment_replay <application>[/<flavor>] [--name <name>] [--at <run>] [--runbook <path>]
#                               [--target name=addr]... [--from <id>] [--dry-run] [--yes]
#     --at matches a path, a basename or a timestamp prefix under
#     the deployment's runs dir under the state tree (default: newest); dies on none/several.
#     The environment is seeded from the snapshot: target.* -> bindings (a --target
#     on the command line wins), value.<NAME> -> resolved and exported. Then the
#     same engine as `deployment run` runs. Seeded values are referred to by name
#     only, never printed, never part of argv.

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
    source lib/state.sh
    source lib/targets.sh
    source lib/context.sh
    source lib/runbooks.sh

    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    export PATH="$STUB_DIR:$PATH"

    unset CLOUDIFY_NODE IVPS_DEFAULT_NODE CLOUDIFY_DEPLOYMENT CLOUDIFY_RUNBOOK_SNAPSHOT_VALUES || true
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:xfce-test cloudai:guac cloudai:cloudify)
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

# _make_runbook <path>  (content on stdin)
_make_runbook() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

# _snapshot_write <app> <name> <runbook> [<line>...] \u2014 a hand-written run
# snapshot under the app's state-tree runs dir (flavor default, name as given).
_snapshot_write() {
    local id="$1" name="$2" rb="$3" dir l
    shift 3
    dir=$(cloudify_state_runs_dir "$id" default "$id")
    mkdir -p "$dir"
    {
        printf 'status: succeeded\nstarted_at: 2026-01-01T00:00:00Z\nfinished_at: 2026-01-01T00:00:01Z\n'
        printf 'runbook: %s\n' "$rb"
        for l in "$@"; do printf '%s\n' "$l"; done
    } > "$dir/$name"
}

# _runs <app> \u2014 snapshot basenames, sorted
_runs() {
    ls "$(cloudify_state_runs_dir "$1" default default)"
}

# ---------------------------------------------------------------
# Seeding the environment from the snapshot
# ---------------------------------------------------------------

@test "replay: a snapshot value is exported to the step, and recorded in a new snapshot" {
    rubric "value.<NAME> -> exported; the step sees it; replay writes its own snapshot"
    local rb="$CLOUDIFY_TMP/values.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'my=%s\n' "\$MYVAR" > "$CLOUDIFY_TMP/seen"
\`\`\`
EOF
    _snapshot_write replay-values 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: hello'

    run cloudify_deployment_replay replay-values --name replay-values --yes
    [ "$status" -eq 0 ] || { echo "REPLAY OUT: $output"; false; }
    [[ "$output" == *"Replay: $(cloudify_state_runs_dir replay-values default replay-values)/20260101T000000Z.yaml"* ]]
    [[ "$output" == *"Seeded values (names only): MYVAR"* ]]
    [ "$(cat "$CLOUDIFY_TMP/seen")" = "my=hello" ]

    step "new snapshot written next to the source one"
    [ "$(ls "$(cloudify_state_runs_dir replay-values default replay-values)" | wc -l)" -eq 2 ]
    local new
    new=$(ls "$(cloudify_state_runs_dir replay-values default replay-values)"/*.yaml | sort | tail -1)
    grep -q "^status: succeeded$" "$new"
    grep -q "^runbook: $rb$" "$new"
    grep -q "^target.guest: cloudai:xfce-test$" "$new"
    grep -q "^value.MYVAR: hello$" "$new"
}

@test "replay: a stored reference is resolved before export and stays a reference in the record" {
    rubric "@base64: reference -> the step sees the decoded value; the snapshot keeps the reference"
    local rb="$CLOUDIFY_TMP/ref.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'sec=%s\n' "\$SECRET_VAR" > "$CLOUDIFY_TMP/ref-seen"
\`\`\`
EOF
    _snapshot_write replay-ref 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.SECRET_VAR: @base64:aGVsbG8='

    run cloudify_deployment_replay replay-ref --name replay-ref --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/ref-seen")" = "sec=hello" ]

    step "the resolved value is never echoed; the new record keeps the reference"
    [[ "$output" != *"hello"* ]]
    local new
    new=$(ls "$(cloudify_state_runs_dir replay-ref default replay-ref)"/*.yaml | sort | tail -1)
    grep -q "^value.SECRET_VAR: @base64:aGVsbG8=$" "$new"
}

@test "replay: target bindings come from the snapshot, an explicit --target overrides one" {
    rubric "target.<name> -> --target binding; a command-line --target wins"
    local rb="$CLOUDIFY_TMP/targets.md"
    _make_runbook "$rb" <<EOF
---
targets: guest, gateway
---
\`\`\`bash step=launch target=guest id=one
printf 'guest=%s\n' "\$TARGET_GUEST" > "$CLOUDIFY_TMP/targets-seen"
printf 'gateway=%s\n' "\$TARGET_GATEWAY" >> "$CLOUDIFY_TMP/targets-seen"
\`\`\`
EOF
    _snapshot_write replay-targets 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'target.gateway: cloudai:guac'

    run cloudify_deployment_replay replay-targets --name replay-targets --yes
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CLOUDIFY_TMP/targets-seen")" = "guest=cloudai:xfce-test" ]
    [ "$(tail -1 "$CLOUDIFY_TMP/targets-seen")" = "gateway=cloudai:guac" ]
    [[ "$output" == *"Seeded targets: guest=cloudai:xfce-test,gateway=cloudai:guac"* ]]

    step "--target gateway=... overrides the snapshot binding only"
    run cloudify_deployment_replay replay-targets --name replay-targets --target gateway=cloudai:cloudify --yes
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CLOUDIFY_TMP/targets-seen")" = "guest=cloudai:xfce-test" ]
    [ "$(tail -1 "$CLOUDIFY_TMP/targets-seen")" = "gateway=cloudai:cloudify" ]
    [[ "$output" == *"Seeded targets: guest=cloudai:xfce-test"* ]]
    [[ "$output" != *"gateway=cloudai:guac"* ]]
}

@test "replay: a same-second new snapshot never overwrites the source run" {
    rubric "identical UTC names -> the new snapshot gets a -2 suffix, the source survives"
    local rb="$CLOUDIFY_TMP/collide.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf '%s' "\$MYVAR" > "$CLOUDIFY_TMP/collide-seen"
\`\`\`
EOF
    _snapshot_write replay-collide 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: oldest'

    # Freeze the clock at the source snapshot's name: the engine would write the
    # very same file (a run and its replay usually land in the same second).
    date() {
        case "$*" in
            *%Y%m%dT%H%M%SZ*) echo "20260101T000000Z" ;;
            *) command date "$@" ;;
        esac
    }

    run cloudify_deployment_replay replay-collide --name replay-collide --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/collide-seen")" = "oldest" ]
    [ "$(ls "$(cloudify_state_runs_dir replay-collide default replay-collide)" | wc -l)" -eq 2 ]
    grep -q "^value.MYVAR: oldest$" \
        "$(cloudify_state_runs_dir replay-collide default replay-collide)/20260101T000000Z.yaml"
    grep -q "^value.MYVAR: oldest$" \
        "$(cloudify_state_runs_dir replay-collide default replay-collide)/20260101T000000Z-2.yaml"
}

@test "replay: the runbook defaults to the snapshot's, --runbook overrides it" {
    rubric "runbook: from the snapshot; --runbook points elsewhere"
    local rb="$CLOUDIFY_TMP/snap-rb.md"
    local other="$CLOUDIFY_TMP/other-rb.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'snap' > "$CLOUDIFY_TMP/rb-seen"
\`\`\`
EOF
    _make_runbook "$other" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'other' > "$CLOUDIFY_TMP/rb-seen"
\`\`\`
EOF
    _snapshot_write replay-rb 20260101T000000Z.yaml "$rb" 'target.guest: cloudai:xfce-test'

    run cloudify_deployment_replay replay-rb --name replay-rb --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/rb-seen")" = "snap" ]

    run cloudify_deployment_replay replay-rb --name replay-rb --runbook "$other" --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/rb-seen")" = "other" ]

    step "a snapshot whose runbook is gone dies pointing at --runbook"
    _snapshot_write replay-rb 20270101T000000Z.yaml "$CLOUDIFY_TMP/gone.md" 'target.guest: cloudai:xfce-test'
    run cloudify_deployment_replay replay-rb --name replay-rb --at 2027 --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"runbook '$CLOUDIFY_TMP/gone.md'"* ]]
    [[ "$output" == *"--runbook"* ]]
}

# ---------------------------------------------------------------
# Snapshot selection (--at)
# ---------------------------------------------------------------

@test "replay: --at selects a run; the default is the newest" {
    rubric "--at path/basename/prefix; no --at -> the lexicographically last (UTC name)"
    local rb="$CLOUDIFY_TMP/at.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf '%s' "\$MYVAR" > "$CLOUDIFY_TMP/at-seen"
\`\`\`
EOF
    _snapshot_write replay-at 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: oldest'
    _snapshot_write replay-at 20260102T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: middle'
    _snapshot_write replay-at 20260103T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: newest'

    run cloudify_deployment_replay replay-at --name replay-at --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/at-seen")" = "newest" ]

    run cloudify_deployment_replay replay-at --name replay-at --at 20260101 --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/at-seen")" = "oldest" ]

    run cloudify_deployment_replay replay-at --name replay-at --at 20260102T000000Z.yaml --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/at-seen")" = "middle" ]

    run cloudify_deployment_replay replay-at --name replay-at \
        --at "$(cloudify_state_runs_dir replay-at default replay-at)/20260103T000000Z.yaml" --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$CLOUDIFY_TMP/at-seen")" = "newest" ]
}

@test "replay: no runs, no match and an ambiguous --at all die" {
    rubric "fail closed: never a silent pick"
    run cloudify_deployment_replay never-ran --name never-ran
    [ "$status" -ne 0 ]
    [[ "$output" == *"no runs under"* ]]

    local rb="$CLOUDIFY_TMP/amb.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
echo ran
\`\`\`
EOF
    _snapshot_write replay-amb 20260101T000000Z.yaml "$rb" 'target.guest: cloudai:xfce-test'
    _snapshot_write replay-amb 20260102T000000Z.yaml "$rb" 'target.guest: cloudai:xfce-test'

    run cloudify_deployment_replay replay-amb --name replay-amb --at 202601
    [ "$status" -ne 0 ]
    [[ "$output" == *"ambiguous"* ]]
    [[ "$output" == *"20260101T000000Z.yaml"* ]]
    [[ "$output" == *"20260102T000000Z.yaml"* ]]

    run cloudify_deployment_replay replay-amb --name replay-amb --at 2099
    [ "$status" -ne 0 ]
    [[ "$output" == *"no run snapshot matching '2099'"* ]]

    step "a file that is not a run snapshot dies"
    printf 'status: succeeded\n' > "$CLOUDIFY_TMP/not-a-run.yaml"
    run cloudify_deployment_replay replay-amb --name replay-amb --at "$CLOUDIFY_TMP/not-a-run.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a run snapshot"* ]]
}

# ---------------------------------------------------------------
# --dry-run, and values that must never be seeded
# ---------------------------------------------------------------

@test "replay: --dry-run prints the plan, names the seeded values, executes nothing" {
    rubric "names only, no resolved value in the output, no step, no new snapshot"
    local rb="$CLOUDIFY_TMP/dry.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'ran' > "$CLOUDIFY_TMP/dry-marker"
\`\`\`
EOF
    _snapshot_write replay-dry 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: s3cr3t'

    run cloudify_deployment_replay replay-dry --name replay-dry --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Seeded values (names only): MYVAR"* ]]
    [[ "$output" == *"Deployment: replay-dry"* ]] || { echo "DRY OUT: $output"; false; }
    [[ "$output" == *"one  launch"* ]]
    [[ "$output" != *"s3cr3t"* ]]
    [ ! -f "$CLOUDIFY_TMP/dry-marker" ]
    [ "$(ls "$(cloudify_state_runs_dir replay-dry default replay-dry)" | wc -l)" -eq 1 ]
}

@test "replay: a framework-owned or malformed value name is refused before anything runs" {
    rubric "value.CLOUDIFY_FORCE / value.9BAD -> die, no step executed"
    local rb="$CLOUDIFY_TMP/owned.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'ran' > "$CLOUDIFY_TMP/owned-marker"
\`\`\`
EOF
    _snapshot_write replay-owned 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.CLOUDIFY_FORCE: true'
    run cloudify_deployment_replay replay-owned --name replay-owned --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"framework-owned var 'CLOUDIFY_FORCE'"* ]]
    [ ! -f "$CLOUDIFY_TMP/owned-marker" ]

    _snapshot_write replay-owned 20260102T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.9BAD: x'
    run cloudify_deployment_replay replay-owned --name replay-owned --at 20260102 --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed value name '9BAD'"* ]]
    [ ! -f "$CLOUDIFY_TMP/owned-marker" ]
}

# ---------------------------------------------------------------
# Real router
# ---------------------------------------------------------------

@test "real router: deployment replay selects, seeds, executes and snapshots" {
    rubric "router path -> select/seed/plan/execute; new snapshot; old one kept"
    _create_ivps_stub
    local cf="$CLOUDIFY_TMP/router-replay"
    mkdir -p "$cf/pkg" "$cf/tmp"
    local rb="$CLOUDIFY_TMP/router-replay.md"
    _make_runbook "$rb" <<EOF
---
targets: guest
---
\`\`\`bash step=launch target=guest id=one
printf 'saw=%s\n' "\$MYVAR" >> "$cf/tmp/replay-marker"
\`\`\`
EOF
    _snapshot_write demo 20260101T000000Z.yaml "$rb" \
        'target.guest: cloudai:xfce-test' 'value.MYVAR: from-snapshot'
    local snapdir
    snapdir=$(cloudify_state_runs_dir demo default demo)

    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true CLOUDIFY_IS_LOCAL=true
        export CLOUDIFY_DIR='$cf' CLOUDIFY_TMP='$cf/tmp' CLOUDIFY_CREDENTIALS_DIR='$cf/creds'
        export CLOUDIFY_REMOTE_USER=root CLOUDIFY_REMOTE_PWD=test
        cd '$PWD' && bash cloudify deployment replay demo --name demo --yes 2>&1
    "
    [ "$status" -eq 0 ] || { echo "ROUTER OUT: $output"; false; }
    [[ "$output" == *"Replay: $snapdir/20260101T000000Z.yaml"* ]]
    [[ "$output" == *"Seeded values (names only): MYVAR"* ]]
    [ "$(cat "$cf/tmp/replay-marker")" = "saw=from-snapshot" ]
    [ "$(ls "$snapdir" | wc -l)" -eq 2 ]
}

@test "real router: usage lists deployment replay" {
    rubric "cloudify help documents the verb"
    PATH="$STUB_DIR:$PATH" run bash -c "
        export CLOUDIFY_DISABLE_COLORS=true CLOUDIFY_SKIPCREDENTIALS=true
        cd '$PWD' && bash cloudify help 2>&1
    "
    [[ "$output" == *"cloudify deployment replay <id>"* ]]
}
