#!/usr/bin/env bash
# Serial acceptance batch: unit -> gate -> canary by default, or the suites
# given as arguments (unit|gate|canary). Each suite runs through its Taskfile
# target (one ssh session via tests/remote-bats.sh; canary = Guacamole lifecycle).
#
# Receipts land in results/acceptance/<run-id>/ :
#   batch.current    LAST-STARTED suite - a progress marker, never a liveness proof
#   <suite>.exit     the suite's real task exit, written only when it finishes
#   <suite>.report   absolute pointer to that run's retained report.tap
#   batch.exit       the batch's own exit, written on completion or early stop
#
# Typical detached use (the caller owns detaching, the script owns receipts):
#   setsid bash tests/run-acceptance.sh </dev/null >/dev/null 2>&1 &
# Poll the receipt files; never infer state from PIDs or batch.current, and
# never kill a running suite without verifying it is stuck, not slow.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

suites=("$@")
if (( ${#suites[@]} == 0 )); then
    suites=(unit gate canary)
fi

run_id=$(date +%Y%m%d-%H%M%S)
out="results/acceptance/$run_id"
mkdir -p "$out" || exit 1
trap 'printf "%s\n" "$?" > "$out/batch.exit"' EXIT

for suite in "${suites[@]}"; do
    case "$suite" in
        unit) target=test-unit ;;
        gate) target=gate ;;
        canary) target=test-canary ;;
        *)
            printf 'unknown suite: %s (expected unit|gate|canary)\n' "$suite" >&2
            exit 64
            ;;
    esac
    printf '%s\n' "$suite" > "$out/batch.current"
    task "$target"
    rc=$?
    printf '%s\n' "$rc" > "$out/$suite.exit"
    readlink -f "results/$suite.tap" > "$out/$suite.report"
    if (( rc != 0 )); then
        exit "$rc"
    fi
done

# The milestone marker: only a complete green ladder (the default three suites)
# may move it. The selector compares changes against this commit.
if (( ${#suites[@]} == 3 )) && [[ "${suites[0]} ${suites[1]} ${suites[2]}" == "unit gate canary" ]]; then
    git rev-parse HEAD > results/acceptance/GREEN
    printf 'green marker: %s\n' "$(cat results/acceptance/GREEN)"
fi
