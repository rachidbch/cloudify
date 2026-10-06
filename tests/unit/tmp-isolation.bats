#!/usr/bin/env bats
# Per-process scratch isolation (CLOUDIFY_TMP): the router assigns each process
# its own scratch dir; no exit may delete another party's files, the log home
# stays fixed, and orphans are bounded by the startup stale sweep.
# Description + non-breakage: tmp/tmp-isolation-description.md (consent
# 2026-09-27, LOGS.md).

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SHARED=/tmp/cloudify
RUN_HOME=""

# Run the real router with a harmless verb (no dispatch, no ssh), following
# the vars-cli.bats run_router pattern.
_run_router() {
    HOME="$RUN_HOME" CLOUDIFY_DIR="$REPO" CLOUDIFY_SKIPCREDENTIALS=true \
    CLOUDIFY_DISABLE_COLORS=true DEBUG=false bash "$REPO/cloudify" vars declared affine
}

setup() {
    source tests/helpers/report.bash
    RUN_HOME=$(mktemp -d)
    mkdir -p "$SHARED"
}

teardown() {
    rm -rf "$RUN_HOME" 2>/dev/null || true
    rm -f "$SHARED"/tmp-iso-survivor-* 2>/dev/null || true
    rm -rf "$SHARED"/tmp-iso-sentinel-* "$SHARED"/tmp-iso-stale-* "$SHARED"/tmp-iso-fresh-* 2>/dev/null || true
}

@test "an unrelated party's file in the shared root survives a full router run" {
    rubric "the pre-fix exit sweep deleted every non-logs child of /tmp/cloudify"
    local survivor="$SHARED/tmp-iso-survivor-$$"
    echo keep > "$survivor"
    _run_router
    [[ -f "$survivor" ]]
}

@test "an inherited CLOUDIFY_TMP is never used or swept by the child process" {
    rubric "pins the unconditional per-process assignment; a :- regression would share and sweep the parent's dir"
    local sentinel="$SHARED/tmp-iso-sentinel-$$"
    mkdir -p "$sentinel"
    echo keep > "$sentinel/marker"
    CLOUDIFY_TMP="$sentinel" _run_router
    [[ -f "$sentinel/marker" ]]
}

@test "startup sweeps tmp-* scratch dirs older than a day, never fresh ones" {
    rubric "orphan control for processes killed before their own cleanup"
    local stale="$SHARED/tmp-iso-stale-$$" fresh="$SHARED/tmp-iso-fresh-$$"
    mkdir -p "$stale" "$fresh"
    touch -d '2 days ago' "$stale"
    _run_router
    [[ ! -d "$stale" ]]
    [[ -d "$fresh" ]]
}

@test "each run writes its log under the fixed home /tmp/cloudify/logs" {
    rubric "the documented live-log home never moves with the scratch dir"
    _run_router
    local newest log
    newest=$(ls -t "$SHARED"/logs/*.log 2>/dev/null | head -1)
    [[ -n "$newest" ]]
    log=$(grep -l "vars declared affine" "$newest" 2>/dev/null)
    [[ -n "$log" ]]
}
