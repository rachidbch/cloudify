#!/usr/bin/env bats
# LIVE end-to-end gate for a two-host application.
#
# One application, two target slots, two disposable hosts. This is the only level
# that proves the whole dispatch wiring on real machines: the operator resolves
# the runbook, each host gets its own dispatch job, and the state afterwards
# describes what actually landed.
#
# Scenarios are tagged with the phase that unlocks them. A phase runs only its
# own; the rest stay visible and skipped, never deleted and never silently green.
#
# MUTATES the tailnet: it launches two throwaway containers on $REMOTE and deletes
# them in teardown_file. Nothing else on the tailnet is touched.
#
# Requirements: `cloudify` on PATH (the local branch), ivps, and SSH reach to the
# remote. Code lands on the hosts per CLOUDIFY_TEST_CODE_MODE (push by default;
# github or branch:<name> exercise the GitHub pull path - push the branch first).
#
#   PATH="$PWD:$PATH" bats tests/e2e/two-host-application.bats

REMOTE="${E2E_REMOTE:-cloudai}"
HOST_A="${E2E_HOST_A:-e2e-2h-a}"
HOST_B="${E2E_HOST_B:-e2e-2h-b}"
APP="two-host"
FLAVOR="default"
NAME="e2e"
DEPLOYMENT="two-host-e2e"
WD="${E2E_WD:-$HOME/tmp/two-host-e2e}"


# Where the app's runbook lives. The engine discovers it at
# runbooks/<application>/<flavor>/runbook.md under CLOUDIFY_DIR.
CFG_DIR="$WD/cloudify"

_ssh() { ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$1" "$2"; }

source "$PWD/tests/helpers/code-mode.bash"

setup_file() {
    export PATH="$HOME/.local/bin:$PATH"
    mkdir -p "$WD" "$CFG_DIR"
    # A stable suite token: the applied-seed digest check refuses a resupplied
    # secret whose plaintext changed between the install run and the verify
    # run, so a per-test `date +%s` token now fails verify by design.
    # Written to a file because bats runs @test in subshells where
    # setup_file exports do not propagate.
    printf 'export K3S_TOKEN=e2e-stable-%s\n' "$(date +%Y%m%d%H%M%S)" > "$WD/token.env"

    echo "── launching two disposable hosts on $REMOTE ──"
    for h in "$HOST_A" "$HOST_B"; do
        ivps launch "$REMOTE:$h" >/dev/null 2>&1 && echo "  $h launched" \
            || echo "  $h already present"
    done

    # Both must answer before any dispatch, or a failure below is ambiguous.
    for h in "$HOST_A" "$HOST_B"; do
        for _ in $(seq 1 30); do
            _ssh "$h" true 2>/dev/null && break
            sleep 5
        done
        _ssh "$h" true 2>/dev/null || { echo "FAIL: $h is not reachable"; return 1; }
    done

    # The runbook lives under a scratch CLOUDIFY_DIR so the repo's own runbook tree
    # is untouched. Give it a real git identity: an unidentifiable tree cannot be
    # recorded as a deployment, and the development override is meant for a dirty
    # tree, not for a directory that is not a repository at all.
    mkdir -p "$CFG_DIR"
    if [[ ! -d "$CFG_DIR/.git" ]]; then
        git -C "$CFG_DIR" init -q
        git -C "$CFG_DIR" -c user.email=e2e@test -c user.name=e2e \
            commit -q --allow-empty -m "e2e scratch tree"
    fi

    # The application's runbook: two target slots, the disposable fixture package.
    mkdir -p "$CFG_DIR/runbooks/$APP/$FLAVOR"
    cat > "$CFG_DIR/runbooks/$APP/$FLAVOR/runbook.md" <<'RUNBOOK'
---
targets: alpha, beta
---

# Two-host application

The disposable fixture package lands on both hosts.

```bash step=install target=alpha pkg=fixture-split
cloudify --on "$TARGET_ALPHA" install fixture-split
```

```bash step=verify target=alpha pkg=fixture-split
cloudify --on "$TARGET_ALPHA" verify fixture-split
```

```bash step=install target=beta pkg=fixture-split
cloudify --on "$TARGET_BETA" install fixture-split
```

```bash step=verify target=beta pkg=fixture-split
cloudify --on "$TARGET_BETA" verify fixture-split
```
RUNBOOK

    # The code each host runs comes from the test code mode (push by default:
    # the working tree over ssh; github/branch:<name> exercise the pull path).
    echo "── preparing cloudify code on both hosts (mode: $(tests_code_mode)) ──"
    for h in "$HOST_A" "$HOST_B"; do
        tests_code_prepare "$h" || { echo "FAIL: cannot prepare $h"; return 1; }
        echo "  $h is ready (mode $(tests_code_mode))"
    done

    export E2E_TARGETS=(--target "alpha=$HOST_A" --target "beta=$HOST_B")
}

setup() {
    # bats runs @test in subshells, so re-derive what setup_file exported.
    source "$WD/token.env"
    source "$BATS_TEST_DIRNAME/../helpers/report.bash"
    export PATH="$HOME/.local/bin:$PATH"
    export CLOUDIFY_DIR="$CFG_DIR"
    # Credentials come from the operator's real config; pointing this at the scratch
    # directory would leave the run with no remote password at all.
    export XDG_STATE_HOME="$WD/state"
    export CLOUDIFY_TMP="$WD/tmp"
    # The runbook lives under a scratch CLOUDIFY_DIR, which is not a git checkout,
    # so the commit is unknown. Recording an unreproducible deployment is the
    # intended path for that, not a workaround.
    export CLOUDIFY_DEVELOPMENT_OVERRIDE=1
    # The fixture package declares K3S_TOKEN as required, so preflight refuses
    # without it. Caller environment is the strongest source, which is fine here.
    # (The stable value comes from token.env sourced in setup().)
    mkdir -p "$XDG_STATE_HOME" "$CLOUDIFY_TMP"
    # Packages resolve from CLOUDIFY_DIR/pkg, and the runbook from
    # CLOUDIFY_DIR/runbooks, so the real package tree has to be visible here.
    ln -sfn "$OLDPWD/pkg" "$CFG_DIR/pkg" 2>/dev/null || true
    [ -d "$CFG_DIR/pkg" ] || ln -sfn "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/pkg" "$CFG_DIR/pkg"
    # Targets are given fully qualified on every call: the manifest records the
    # RESOLVED target, so a bare name on the next run would look like a rebinding.
    _app() { cloudify app run "$APP/$FLAVOR" --name "$NAME" \
        --target "alpha=$REMOTE:$HOST_A" --target "beta=$REMOTE:$HOST_B" "$@"; }
    # Read the manifest directly: it is the recorded lifecycle status, and the
    # read surface is a later phase.
    _manifest_status() {
        # THE deployment's manifest - never a find|head lottery over a state
        # tree that also carries _direct debris from bare-dispatch tests.
        local m
        m="${XDG_STATE_HOME:-$HOME/.local/state}/cloudify/deployments/$APP/$FLAVOR/$NAME/manifest.json"
        [[ -f "$m" ]] || { printf 'missing'; return 0; }
        sed -n 's/^  "status": "\(.*\)",$/\1/p' "$m"
    }
}

teardown_file() {
    echo "── teardown: the two hosts ──"
    # No teardown verb yet: releasing claims and removing the package is the
    # pinned-provenance and teardown phase (Phase 7). Until then the disposable
    # hosts going away is the whole cleanup.
    for h in "$HOST_A" "$HOST_B"; do
        ivps delete "$REMOTE:$h" >/dev/null 2>&1 && echo "  $h deleted" || echo "  ($h already gone)"
    done
}

@test "install (Phase 2 repair): both hosts receive the package" {
    run _app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    subrubric "the package ran on both hosts, and the markers prove it"
    for h in "$HOST_A" "$HOST_B"; do
        run _ssh "$h" 'cat /tmp/fixture-split-log 2>/dev/null'
        [[ "$output" == *INSTALL_RAN* ]] || { echo "$h never ran the install"; return 1; }
    done

    subrubric "the manifest records the run across both targets"
    run _manifest_status
    [[ "$output" == "verified" ]] || { echo "manifest status: $output"; return 1; }
}

@test "verify (Phase 2 repair): verification passes on both hosts" {
    # The fixture's verify hook only passes when the install AND the configure
    # both reached that host, so exit 0 here is a real end-to-end assertion.
    run _app --phase verify
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "no dispatch context survives the run, even with logging in DEBUG" {
    subrubric "these files carry resolved values; a leak is the failure this guards"
    export CLOUDIFY_LOG_LEVEL=DEBUG
    run _app --phase verify
    unset CLOUDIFY_LOG_LEVEL
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # Catches the context file, the builder's dot-prefixed temps (which hold the
    # raw source forms when a build dies mid-walk) and the runbook context. The
    # router pins CLOUDIFY_TMP to /tmp/cloudify (overriding the env), and every
    # context file lives in the swept context directory under it, so a recursive
    # scan from the router's own tmp root must find none.
    local ctx_root
    ctx_root=$(sed -n 's/^export CLOUDIFY_TMP=//p' "$(command -v cloudify)" | head -1)
    run bash -c "find '$ctx_root' \\( -name '*context*' -o -name '.cloudify-*' \\) 2>/dev/null | wc -l"
    [ "$output" -eq 0 ] || { echo "context files left behind: $output"; return 1; }
}

@test "interruption (Phase 2 repair): a killed run stays discoverable, no run record invented" {
    subrubric "kill the operator mid-run; no run record may be invented for it"
    local before after
    before=$(find "$XDG_STATE_HOME/cloudify" -name '*.yaml' -path '*runs*' 2>/dev/null | wc -l)
    local log="$WD/interrupted.log"
    ( _app >"$log" 2>&1 ) &
    local pid=$!
    sleep 20
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    after=$(find "$XDG_STATE_HOME/cloudify" -name '*.yaml' -path '*runs*' 2>/dev/null | wc -l)

    [ "$after" -le "$before" ] || { echo "a run record was written for a killed run"; return 1; }

    subrubric "and the deployment is still discoverable"
    run _manifest_status
    [ -n "$output" ] && [ "$output" != "missing" ] || { echo "the manifest vanished"; return 1; }
}

@test "reconfigure across both hosts (Phase 4)" {
    skip "unlocks with the package-state and claims phase (Phase 4)"
}

@test "two deployments claiming the same package (Phase 4)" {
    skip "unlocks with the package-state and claims phase (Phase 4)"
}

@test "conflicting claims are refused (Phase 4)" {
    skip "unlocks with the package-state and claims phase (Phase 4)"
}

@test "first teardown releases the claim, last teardown removes the package (Phase 7)" {
    skip "unlocks with the pinned-provenance and teardown phase (Phase 7)"
}

@test "a bare multi-host invocation synthesizes ONE _direct deployment (ADR-032)" {
    rubric "one invocation, one deployment, one binding per host - same shape as a runbook deployment"
    run bash -c "PATH=\$PATH cloudify --on $HOST_A $HOST_B install fixture-split"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # THIS invocation's manifest is the newest _direct fixture-split one (a
    # dev controller accumulates e2e debris from prior runs; the sweep owns it).
    local m
    m=$(ls -1 "${XDG_STATE_HOME:-$HOME/.local/state}"/cloudify/deployments/_direct/direct/fixture-split-*/manifest.json 2>/dev/null | sort | tail -1)
    [ -n "$m" ] || { echo "no _direct manifest"; return 1; }
    [ "$(jq -r '.bindings | length' "$m")" -eq 2 ]
    jq -e --arg a "cloudai:$HOST_A" --arg b "cloudai:$HOST_B" \
        '.bindings[$a] and .bindings[$b]' "$m" >/dev/null

    # Both hosts' records under the SAME deployment name, one per instance tree.
    local n ra rb
    n=$(basename "$(dirname "$m")")
    ra="$(_ivps_path cloudai "$HOST_A")/deployments/_direct/direct/$n/packages/fixture-split/default/state.json"
    rb="$(_ivps_path cloudai "$HOST_B")/deployments/_direct/direct/$n/packages/fixture-split/default/state.json"
    [ -f "$ra" ] || { echo "missing: $ra"; return 1; }
    [ -f "$rb" ] || { echo "missing: $rb"; return 1; }
    [ "$(jq -r .deployment "$ra")" = "$n" ]
    [ "$(jq -r .deployment "$rb")" = "$n" ]
    # The word derives from the events: one install across both hosts.
    [ "$(jq -r .status "$m")" = "installed" ]
}

_ivps_path() { # <node> <instance> - the controller's inventory dir
    ivps node path "$1:$2"
}

@test "--name addresses a direct deployment across invocations (ADR-027 wired)" {
    rubric "named install, separate named verify - seeded against applied values, the word derives"
    run bash -c "PATH=\$PATH cloudify --on $HOST_A $HOST_B --name web install fixture-split"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Deployment: _direct/direct/web (status installed)"* ]]

    run bash -c "PATH=\$PATH cloudify --on $HOST_A $HOST_B --name web verify fixture-split"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Deployment: _direct/direct/web (status verified)"* ]]

    local m="${XDG_STATE_HOME:-$HOME/.local/state}/cloudify/deployments/_direct/direct/web/manifest.json"
    [ "$(jq -r '.bindings | length' "$m")" -eq 2 ]
    [ "$(jq -r .status "$m")" = "verified" ]
    local h
    for h in "$HOST_A" "$HOST_B"; do
        [ -f "$(_ivps_path cloudai "$h")/deployments/_direct/direct/web/packages/fixture-split/default/state.json" ]
    done
}
