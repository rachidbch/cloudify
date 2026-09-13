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
# MUTATES the fleet: it launches two throwaway containers on $REMOTE and deletes
# them in teardown_file. Nothing else on the fleet is touched.
#
# Requirements: `cloudify` on PATH (the local branch), ivps, and SSH reach to the
# remote. The branch must be PUSHED: each host bootstraps cloudify from GitHub.
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

setup_file() {
    export PATH="$HOME/.local/bin:$PATH"
    mkdir -p "$WD" "$CFG_DIR"

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
deployment: two-host-e2e
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

    # The bootstrap gist clones the repo's DEFAULT branch, so a live run would
    # exercise master and could pass without testing this checkout. Bootstrap the
    # repo once, pin the freshness marker so the payload skips its git pull, then
    # push the working tree over it - the same idea as `task sync` for the unit
    # container, and the reason the branch must be pushed is now only the gist.
    echo "── bootstrapping and pinning the working tree on both hosts ──"
    for h in "$HOST_A" "$HOST_B"; do
        # The first dispatch is what bootstraps the repo on a host, and it does so
        # through the normal payload with the operator's git credentials. It may
        # fail (nothing is installed yet); the repo is what this step wants.
        cloudify --on "$h" verify fixture-split >/dev/null 2>&1 || true
        _ssh "$h" 'test -d /root/cloudify' 2>/dev/null \
            || { echo "FAIL: $h did not bootstrap"; return 1; }
        # Pin the freshness marker so the payload skips its own git pull, then put
        # this checkout over the default branch's clone.
        _ssh "$h" 'touch /root/cloudify/.#last_update' || return 1
        for d in lib pkg schemas runbooks; do
            ivps push "$REMOTE:$h" "$PWD/$d" /root/cloudify/ -- --delete >/dev/null 2>&1 \
                || { echo "FAIL: cannot push $d to $h"; return 1; }
        done
        ivps push "$REMOTE:$h" "$PWD/cloudify" /root/cloudify/ >/dev/null 2>&1 \
            || { echo "FAIL: cannot push the CLI to $h"; return 1; }
        _ssh "$h" 'grep -q _cloudify_vars_raw_encode /root/cloudify/lib/vars.sh' \
            || { echo "FAIL: $h is not running this checkout"; return 1; }
        echo "  $h has this checkout"
    done

    export E2E_TARGETS=(--target "alpha=$HOST_A" --target "beta=$HOST_B")
}

setup() {
    # bats runs @test in subshells, so re-derive what setup_file exported.
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
    export K3S_TOKEN="e2e-$(date +%s)"
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
        local m
        m=$(find "$XDG_STATE_HOME/cloudify/deployments" -name manifest.json 2>/dev/null | head -1)
        [[ -n "$m" ]] || { printf 'missing'; return 0; }
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
    [[ "$output" == "active" ]] || { echo "manifest status: $output"; return 1; }
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

    run bash -c "find '$CLOUDIFY_TMP' -name 'cloudify-*context*' | wc -l"
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
