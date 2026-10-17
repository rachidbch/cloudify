#!/usr/bin/env bats
# A failed Docker probe must stop the real canary setup before any product call.

@test "canary refuses a Docker probe failure before mutation" {
    source tests/helpers/report.bash
    rubric "an unavailable daemon is not an empty test host"
    [ ! -e /root/guacamole ]
    export CANARY_FIXTURE="$BATS_TEST_TMPDIR/canary"
    export CANARY_MUTATED="$BATS_TEST_TMPDIR/product-called"
    mkdir -p "$CANARY_FIXTURE/tests/"{helpers,integration} "$CANARY_FIXTURE/bin"
    cp tests/helpers/report.bash "$CANARY_FIXTURE/tests/helpers/"
    cp tests/integration/package-guacamole.bats "$CANARY_FIXTURE/tests/integration/"
    cat > "$CANARY_FIXTURE/bin/docker" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "$DOCKER_FAIL_KIND" ]]; then
    echo 'fixture Docker unavailable' >&2
    exit 78
fi
SH
    cat > "$CANARY_FIXTURE/cloudify" <<'SH'
#!/usr/bin/env bash
printf 'unexpected product mutation\n' > "$CANARY_MUTATED"
SH
    chmod +x "$CANARY_FIXTURE/bin/docker" "$CANARY_FIXTURE/cloudify"
    export PATH="$CANARY_FIXTURE/bin:$PATH"
    for DOCKER_FAIL_KIND in container volume; do
        export DOCKER_FAIL_KIND
        # The child shell reads the exported fixture path.
        # shellcheck disable=SC2016
        run env -u BATS_RUN_TMPDIR -u BATS_FILE_TMPDIR -u BATS_TEST_TMPDIR -u BATS_TMPDIR \
            bash -c 'cd "$CANARY_FIXTURE" && exec bats --filter "^install provisions and configures the stack$" tests/integration/package-guacamole.bats'
        printf '%s\n' "$output"
        [ "$status" -ne 0 ]
        [[ "$output" == *'fixture Docker unavailable'* ]]
        [ ! -e "$CANARY_MUTATED" ]
    done
}
