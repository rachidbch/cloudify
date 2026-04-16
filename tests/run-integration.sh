#!/usr/bin/env bash
# tests/run-integration.sh — Hermetic integration test orchestrator
# Runs each package integration test in a fresh snapshot to guarantee isolation.
set -euo pipefail

CONTAINER="cloudai:cloudify"
REPO_DIR="/root/cloudify"
SNAPSHOT="itest-base"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$PROJECT_DIR/results"

# Default glob: all package integration tests (NOT recipe-discovery.bats)
DEFAULT_PATTERN="tests/integration/package-*.bats"

# Allow running a single test: ./tests/run-integration.sh tests/integration/package-bat.bats
TEST_FILES=()
if [[ $# -gt 0 ]]; then
    TEST_FILES=("$@")
else
    # Collect matching test files, sorted for determinism
    while IFS= read -r -d '' f; do
        TEST_FILES+=("$f")
    done < <(cd "$PROJECT_DIR" && find . -path "./$DEFAULT_PATTERN" -print0 | sort -z)
fi

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "No integration test files found matching pattern: $DEFAULT_PATTERN"
    exit 1
fi

echo "=== Hermetic Integration Test Runner ==="
echo "Tests to run: ${#TEST_FILES[@]}"
echo ""

# Ensure the base snapshot exists
ensure_snapshot() {
    if incus snapshot list "$CONTAINER" --format csv 2>/dev/null | grep -q "$SNAPSHOT"; then
        echo "Snapshot '$SNAPSHOT' found."
    else
        echo "Snapshot '$SNAPSHOT' not found. Creating..."
        ivps exec "$CONTAINER" -- bash -c 'apt-get update -qq && apt-get install -y -qq bats bats-assert bats-support bats-file'
        incus snapshot create "$CONTAINER" "$SNAPSHOT" --no-expiry
        echo "Snapshot '$SNAPSHOT' created."
    fi
}

# Sync local files into the container
sync_to_container() {
    echo "Syncing files to container..."
    incus file push -r "$PROJECT_DIR/lib"       "$CONTAINER/root/cloudify/" --create-dirs > /dev/null
    incus file push -r "$PROJECT_DIR/tests"     "$CONTAINER/root/cloudify/" --create-dirs > /dev/null
    incus file push -r "$PROJECT_DIR/pkg"       "$CONTAINER/root/cloudify/" --create-dirs > /dev/null
    incus file push "$PROJECT_DIR/cloudify"     "$CONTAINER/root/cloudify/cloudify" > /dev/null
    incus file push "$PROJECT_DIR/Makefile"     "$CONTAINER/root/cloudify/Makefile" > /dev/null
}

ensure_snapshot

# Prepare results directory
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# Run each test hermetically
passed=0
failed=0
failures=()

for test_file in "${TEST_FILES[@]}"; do
    test_name="$(basename "$test_file" .bats)"
    tap_file="$RESULTS_DIR/${test_name}.tap"

    echo "--- Running: $test_name ---"

    # 1. Restore clean snapshot
    echo "  Restoring snapshot '$SNAPSHOT'..."
    incus snapshot restore "$CONTAINER" "$SNAPSHOT" > /dev/null 2>&1

    # 2. Sync current code into the container
    sync_to_container

    # 3. Run bats inside the container
    echo "  Running bats..."
    if ivps exec "$CONTAINER" -- bash -c "cd $REPO_DIR && bats --output /tmp/tap --formatter tap '$test_file'" > "$tap_file" 2>&1; then
        echo "  PASSED"
        ((passed++)) || true
    else
        echo "  FAILED"
        ((failed++)) || true
        failures+=("$test_name")
    fi

    echo ""
done

# Summary
echo "=== Results ==="
echo "Total:  $((passed + failed))"
echo "Passed: $passed"
echo "Failed: $failed"

if [[ ${#failures[@]} -gt 0 ]]; then
    echo ""
    echo "Failed tests:"
    for f in "${failures[@]}"; do
        echo "  - $f"
        echo "    TAP output: results/${f}.tap"
    done
    echo ""
    echo "Container left in last-failed state for debugging."
    echo "Run 'make itest-reset' to restore clean state when done."
    exit 1
else
    # All passed: restore clean snapshot
    echo ""
    incus snapshot restore "$CONTAINER" "$SNAPSHOT" > /dev/null 2>&1
    echo "All tests passed. Container restored to clean state."
    exit 0
fi
