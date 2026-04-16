#!/usr/bin/env bash
# tests/run-integration.sh — SSH-based integration test orchestrator
# Runs each package integration test in a fresh snapshot via the real
# production path: cloudify install <pkg> --on <host> (SSH + bootstrap gist).
set -euo pipefail

CONTAINER="cloudai:cloudify"
SNAPSHOT="itest-base"
TEST_HOST="cloudify"
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

echo "=== SSH-Based Integration Test Runner ==="
echo "Tests to run: ${#TEST_FILES[@]}"
echo ""

# Ensure the base snapshot exists
ensure_snapshot() {
    if incus snapshot list "$CONTAINER" --format csv 2>/dev/null | grep -q "$SNAPSHOT"; then
        echo "Snapshot '$SNAPSHOT' found."
    else
        echo "Snapshot '$SNAPSHOT' not found. Creating..."
        ssh "root@$TEST_HOST" 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq bats bats-assert bats-support bats-file'
        incus snapshot create "$CONTAINER" "$SNAPSHOT" --no-expiry
        echo "Snapshot '$SNAPSHOT' created."
    fi
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

    # 1. Restore clean snapshot (incus — host-side only)
    echo "  Restoring snapshot '$SNAPSHOT'..."
    incus snapshot restore "$CONTAINER" "$SNAPSHOT" > /dev/null 2>&1

    # 2. Clear stale SSH host key (snapshot restore changes host identity)
    echo "  Clearing stale SSH host key..."
    ssh-keygen -R "$TEST_HOST" > /dev/null 2>&1 || true

    # 3. Ensure cloudify is on PATH (project dir contains the CLI router)
    export PATH="$PROJECT_DIR:$PATH"

    # 4. Set env vars for cloudify remote execution
    export CLOUDIFY_DIR="$PROJECT_DIR"
    export CLOUDIFY_REMOTE_USER=root
    export CLOUDIFY_REMOTE_PWD=dummy
    export CLOUDIFY_SKIPCREDENTIALS=true
    export CLOUDIFY_GITHUBUSER="${CLOUDIFY_GITHUBUSER:-dummy}"
    export CLOUDIFY_GITHUBPWD="${CLOUDIFY_GITHUBPWD:-dummy}"
    export CLOUDIFY_GITLABUSER="${CLOUDIFY_GITLABUSER:-dummy}"
    export CLOUDIFY_GITLABPWD="${CLOUDIFY_GITLABPWD:-dummy}"
    export CLOUDIFY_RCLONE_REMOTE="${CLOUDIFY_RCLONE_REMOTE:-dummy}"
    export CLOUDIFY_RCLONE_REMOTE_REGION="${CLOUDIFY_RCLONE_REMOTE_REGION:-dummy}"
    export CLOUDIFY_RCLONE_REMOTE_ENDPOINT="${CLOUDIFY_RCLONE_REMOTE_ENDPOINT:-dummy}"
    export CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID="${CLOUDIFY_RCLONE_REMOTE_ACCESSKEYID:-dummy}"
    export CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY="${CLOUDIFY_RCLONE_REMOTE_SECRETACCESSKEY:-dummy}"
    export RESTIC_PASSWORD="${RESTIC_PASSWORD:-dummy}"

    # 5. Run bats on localhost (tests SSH into container via cloudify --on)
    echo "  Running bats..."
    if bats "$test_file" > "$tap_file" 2>&1; then
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
