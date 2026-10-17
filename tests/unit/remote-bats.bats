#!/usr/bin/env bats
# Exercise the real transport script with a local SSH double, inside the test target.
# Bats deliberately isolates each test's exported failure fixtures.
# shellcheck disable=SC2030,SC2031

setup() {
    source tests/helpers/report.bash
    export CASE_DIR="$BATS_TEST_TMPDIR/transport"
    local repo="$CASE_DIR/repo"
    mkdir -p "$repo"/{lib,tests,pkg,schemas,runbooks} "$CASE_DIR/bin"
    cp tests/remote-bats.sh "$repo/tests/remote-bats.sh"
    printf '9.8.7\n' > "$repo/VERSION"
    printf '#!/bin/bash\n' > "$repo/cloudify"
    export RUNNER="$repo/tests/remote-bats.sh"
    export CLOUDIFY_TEST_TARGET=fixture-target
    REAL_TAR=$(command -v tar)
    REAL_TEE=$(command -v tee)
    export REAL_TAR REAL_TEE
    export PATH="$CASE_DIR/bin:$PATH"
    cat > "$CASE_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$CASE_DIR/ssh-args"
[[ -z "${SSH_EXIT:-}" ]] || exit "$SSH_EXIT"
[[ $# == 2 && $1 == root@fixture-target ]] || exit 90
mktemp() {
    mkdir -p "$CASE_DIR/remote"
    printf '%s\n' "$CASE_DIR/remote"
}
export -f mktemp
if [[ -n "${STAGING_FAIL:-}" ]]; then
    tar() { echo 'fixture extraction failed' >&2; return 42; }
    export -f tar
fi
bash -c "$2"
SH
    cat > "$CASE_DIR/bin/bats" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$CASE_DIR/bats-args"
[[ -f VERSION && $(< VERSION) == 9.8.7 ]] || { echo 'VERSION missing from streamed tree' >&2; exit 91; }
printf '1..1\nok 1 transported\n'
printf 'raw stderr retained\n' >&2
exit "${BATS_EXIT:-0}"
SH
    cat > "$CASE_DIR/bin/tar" <<'SH'
#!/usr/bin/env bash
"$REAL_TAR" "$@" || exit "$?"
if [[ -n "${LOCAL_TAR_FAIL:-}" && " $* " == *' -cf '* ]]; then exit 41; fi
SH
    cat > "$CASE_DIR/bin/tee" <<'SH'
#!/usr/bin/env bash
"$REAL_TEE" "$@" || exit "$?"
exit "${TEE_EXIT:-0}"
SH
    chmod +x "$CASE_DIR/bin/ssh" "$CASE_DIR/bin/bats" "$CASE_DIR/bin/tar" "$CASE_DIR/bin/tee"
}

@test "transport streams VERSION and preserves a spaced Bats argument through one plain SSH" {
    rubric "the streamed tree and arguments reach remote Bats unchanged"
    run bash "$RUNNER" fixture 'tests/a spaced file.bats'
    [ "$status" -eq 0 ]
    local -a args
    mapfile -d '' -t args < "$CASE_DIR/ssh-args"
    [ "${#args[@]}" -eq 2 ]
    [ "${args[0]}" = root@fixture-target ]
    mapfile -d '' -t args < "$CASE_DIR/bats-args"
    [ "${#args[@]}" -eq 1 ]
    [ "${args[0]}" = 'tests/a spaced file.bats' ]
    [[ "$output" == *'ok 1 transported'* ]]
    [[ "$output" == *'raw stderr retained'* ]]
    [ -f "$CASE_DIR/repo/results/fixture.tap" ]
}

@test "transport preserves Bats and SSH failure exits through tee" {
    rubric "a successful local tee cannot hide a failing remote command"
    export BATS_EXIT=7
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 7 ]
    [[ "$output" == *'raw stderr retained'* ]]
    unset BATS_EXIT
    export SSH_EXIT=255
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 255 ]
}

@test "transport stops on extraction failure before invoking Bats" {
    rubric "a broken transfer never tests an incomplete tree"
    export STAGING_FAIL=1
    run bash "$RUNNER" fixture tests/example.bats
    printf '%s\n' "$output"
    [ "$status" -eq 42 ]
    [ ! -e "$CASE_DIR/bats-args" ]
}

@test "transport retains both reports when a suite name is reused" {
    rubric "rerunning a suite keeps its earlier native evidence"
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 0 ]
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 0 ]
    local -a reports=("$CASE_DIR/repo"/results/fixture.*/report.tap)
    [ "${#reports[@]}" -eq 2 ]
    [ -f "${reports[0]}" ]
    [ -f "${reports[1]}" ]
    [ -L "$CASE_DIR/repo/results/fixture.tap" ]
}

@test "transport rejects a producer failure before opening SSH" {
    rubric "an extractable partial archive is not a successful transfer"
    export LOCAL_TAR_FAIL=1
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 41 ]
    [ ! -e "$CASE_DIR/ssh-args" ]
    [ ! -e "$CASE_DIR/bats-args" ]
}

@test "transport fails on a report write error without masking SSH failure" {
    rubric "lost local evidence cannot count as success"
    export TEE_EXIT=23
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 23 ]
    export SSH_EXIT=255
    run bash "$RUNNER" fixture tests/example.bats
    [ "$status" -eq 255 ]
}
