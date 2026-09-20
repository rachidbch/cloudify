#!/usr/bin/env bats
# Result-channel worker side (state-model-v2 4.3): the pass-through capture
# stage on the streamed log, line-by-line validation, and the executed-code
# check. Contract: plans/state-model-v2-phase4-design.md "Result lines on the
# streamed log" + "checkout v1:". The stage must never break the streamed log
# (docs/FRAGILE.md section 3): pass-through byte-exact, return 0 always.

source tests/helpers/common.bash

setup() {
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/vars.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/results.sh
    source lib/packages.sh
    source lib/remote.sh
    source lib/context.sh

    export CLOUDIFY_NO_VERIFY=true
    export CLOUDIFY_LOG_FILE="$CLOUDIFY_TMP/dispatch.log"
    : > "$CLOUDIFY_LOG_FILE"
}

teardown() {
    teardown_test_env
}

#-- The pass-through capture stage --

@test "tap: pass-through is byte-exact; collection keeps only keyed lines, host prefix stripped" {
    local file="$CLOUDIFY_TMP/collected"
    local input
    input=$'somehost: installing nginx\nresult v1: parent=- package=a instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=1.0.0\nsomehost: result v1: parent=- package=b instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=2.0.0\ncheckout v1: commit=abc111 dirty=false\nsomehost: checkout v1: commit=abc111 dirty=false\n12:34:56 not a result line\nplain tail\n'
    printf '%s' "$input" | cloudify_results_tap "$file" > "$CLOUDIFY_TMP/passthrough"

    # Pass-through: every byte the stream carried, onward unchanged.
    cmp -s <(printf '%s' "$input") "$CLOUDIFY_TMP/passthrough"

    # Collection: only the keyed lines; host prefix stripped; body verbatim.
    local want
    want=$'result v1: parent=- package=a instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=1.0.0\nresult v1: parent=- package=b instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=2.0.0\ncheckout v1: commit=abc111 dirty=false\ncheckout v1: commit=abc111 dirty=false\n'
    cat "$file"
    cmp -s <(printf '%s' "$want") "$file"
}

@test "tap: a final line without a trailing newline is passed through and collected" {
    local file="$CLOUDIFY_TMP/collected"
    printf 'plain' | cloudify_results_tap "$file" > "$CLOUDIFY_TMP/p1"
    [ "$(cat "$CLOUDIFY_TMP/p1")" = "plain" ]
    [ ! -s "$file" ]

    printf 'result v1: parent=- package=z instance=default phase=install action=install outcome=failed exit=3 verification=not-run version=none' \
        | cloudify_results_tap "$file" > "$CLOUDIFY_TMP/p2"
    [ "$(cat "$CLOUDIFY_TMP/p2")" = "result v1: parent=- package=z instance=default phase=install action=install outcome=failed exit=3 verification=not-run version=none" ]
    grep -q '^result v1: parent=- package=z ' "$file"
}

@test "tap: returns 0 on empty input and appends without truncating" {
    local file="$CLOUDIFY_TMP/collected"
    printf 'seed\n' > "$file"
    : | cloudify_results_tap "$file"
    [ "$?" -eq 0 ]
    grep -q '^seed$' "$file"
}

#-- Line validation --

# Emit one real line through the framework renderer.
valid_line() {
    cloudify_result_emit - nginx install install 0 ok "1.24.0"
}

@test "validate: the framework's own output passes" {
    valid_line > "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"
}

@test "validate: unknown appended fields are ignored" {
    valid_line | sed 's/$/ extrafield=passthrough/' > "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"
}

@test "validate: structural breaches fail - missing key, duplicate key, bad enums, bad exit" {
    local bad
    # Missing required key (no version).
    valid_line | sed 's/ version=1.24.0//' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    # Duplicate key.
    valid_line | sed 's/verification=ok/verification=ok verification=ok/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    # Unknown outcome value.
    valid_line | sed 's/outcome=succeeded/outcome=maybe/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    # Non-numeric and out-of-range exit.
    valid_line | sed 's/exit=0/exit=seven/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]
    valid_line | sed 's/exit=0/exit=300/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    # Bad phase / action / verification.
    valid_line | sed 's/phase=install/phase=party/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]
    valid_line | sed 's/action=install/action=celebrate/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]
    valid_line | sed 's/verification=ok/verification=sorta/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    # Space-bearing values (line-safety is absolute).
    valid_line | sed 's/package=nginx/package=two words/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]
}

@test "validate: forced-failure consistency - unknown version, non-zero exit or failed verification cannot claim succeeded" {
    valid_line | sed 's/version=1.24.0/version=unknown/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    valid_line | sed 's/exit=0/exit=9/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    valid_line | sed 's/verification=ok/verification=failed/' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    # And the failed forms themselves pass.
    valid_line | sed 's/version=1.24.0/version=unknown/;s/outcome=succeeded/outcome=failed/' > "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"
    valid_line | sed 's/exit=0/exit=9/;s/outcome=succeeded/outcome=failed/' > "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"
}

@test "validate: caps - line over 512 bytes fails; 64 result lines pass, 65 fail" {
    local big_version
    big_version=$(printf '1%.0s' $(seq 1 500))
    valid_line | sed "s/version=1.24.0/version=$big_version/" > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]

    valid_line > "$CLOUDIFY_TMP/lines"
    local i
    for i in $(seq 1 62); do valid_line >> "$CLOUDIFY_TMP/lines"; done
    printf 'checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false\n' >> "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"

    valid_line >> "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]
}

@test "validate: checkout line fields - 40-hex or unknown commit, true|false dirty" {
    printf 'checkout v1: commit=abc111 dirty=false\n' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ] # 6-hex is not a 40-hex commit

    printf 'checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false\n' > "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"

    printf 'checkout v1: commit=unknown dirty=false\n' > "$CLOUDIFY_TMP/lines"
    cloudify_results_validate "$CLOUDIFY_TMP/lines"

    printf 'checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=maybe\n' > "$CLOUDIFY_TMP/lines"
    run cloudify_results_validate "$CLOUDIFY_TMP/lines"
    [ "$status" -ne 0 ]
}

#-- Child-side checkout line --

@test "print_checkout: frozen shape, 40-hex commit and dirty=false in a clean repo" {
    git init -q "$CLOUDIFY_TMP/repo"
    git -C "$CLOUDIFY_TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
    local commit
    commit=$(git -C "$CLOUDIFY_TMP/repo" rev-parse HEAD)

    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/repo" run cloudify_results_print_checkout
    [ "$status" -eq 0 ]
    [[ "$output" == "checkout v1: commit=$commit dirty=false" ]]
}

@test "print_checkout: dirty=true when the tree carries uncommitted changes" {
    git init -q "$CLOUDIFY_TMP/repo"
    git -C "$CLOUDIFY_TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
    touch "$CLOUDIFY_TMP/repo/uncommitted"

    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/repo" run cloudify_results_print_checkout
    [[ "$output" == *"dirty=true" ]]
}

@test "print_checkout: outside a git repo reads commit=unknown dirty=false" {
    CLOUDIFY_SCRIPT_DIR="$CLOUDIFY_TMP/not-a-repo" run cloudify_results_print_checkout
    [ "$output" = "checkout v1: commit=unknown dirty=false" ]
}

@test "install prints exactly one checkout line before its package work" {
    mkdir -p "$CLOUDIFY_DIR/pkg/ck"
    printf '1.0.0\n' > "$CLOUDIFY_DIR/pkg/ck/.version"
    printf '#!/usr/bin/env bash\n' > "$CLOUDIFY_DIR/pkg/ck/install.sh"
    run cloudify_install_package ck
    [ "$status" -eq 0 ]
    [ "$(grep -c '^checkout v1: ' <<< "$output")" -eq 1 ]
    # Before the package's result line.
    [[ "$output" == *"checkout v1:"*"result v1: parent=- package=ck "* ]]
}

#-- Executed-code verdicts --

# A collection file with one checkout record.
make_collected() {
    printf '%s\n' "$1" > "$CLOUDIFY_TMP/collected"
}

@test "executed-code: commit match proceeds; mismatch and unknown degrade; missing line degrades" {
    make_collected 'checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false'
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" 0123456789abcdef0123456789abcdef01234567 false)" = "ok" ]

    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" fedcba98fedcba98fedcba98fedcba98fedcba98 false)" = "degraded-mismatch" ]

    make_collected 'checkout v1: commit=unknown dirty=false'
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" 0123456789abcdef0123456789abcdef01234567 false)" = "degraded-unknown" ]

    : > "$CLOUDIFY_TMP/collected"
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" 0123456789abcdef0123456789abcdef01234567 false)" = "degraded-missing" ]
}

@test "executed-code: a development-override run never degrades" {
    : > "$CLOUDIFY_TMP/collected"
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" 0123456789abcdef0123456789abcdef01234567 true)" = "ok-dev" ]

    make_collected 'checkout v1: commit=fedcba98fedcba98fedcba98fedcba98fedcba98 dirty=true'
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" 0123456789abcdef0123456789abcdef01234567 true)" = "ok-dev" ]
}

@test "executed-code: init and dispatch children must agree; first line wins" {
    local c1=0123456789abcdef0123456789abcdef01234567 c2=fedcba98fedcba98fedcba98fedcba98fedcba98
    { printf 'checkout v1: commit=%s dirty=false\n' "$c1"
      printf 'checkout v1: commit=%s dirty=true\n' "$c2"; } > "$CLOUDIFY_TMP/collected"
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" "$c1" false)" = "degraded-divergent" ]

    { printf 'checkout v1: commit=%s dirty=false\n' "$c1"
      printf 'checkout v1: commit=%s dirty=false\n' "$c1"; } > "$CLOUDIFY_TMP/collected"
    [ "$(cloudify_results_check_executed "$CLOUDIFY_TMP/collected" "$c1" false)" = "ok" ]
}

#-- Emission dual-write (the local collection path) --

@test "emission appends to CLOUDIFY_RESULTS_FILE when set; stdout is unchanged" {
    local file="$CLOUDIFY_TMP/local-collected"
    CLOUDIFY_RESULTS_FILE="$file" run cloudify_result_emit - nginx install install 0 ok "1.24.0"
    [[ "$output" == "result v1: parent=- package=nginx instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=1.24.0" ]]
    [ "$(cat "$file")" = "$output" ]

    rm -f "$file"
    run cloudify_result_emit - nginx install install 0 ok "1.24.0"
    [ ! -e "$file" ]
}

#-- Remote pipeline wiring --

@test "remote dispatch: the stream is captured whole - pass-through on the log, keyed lines in the collection file" {
    source lib/vars.sh
    source lib/deployments.sh
    source lib/targets.sh
    source lib/runbooks.sh

    ssh() {
        cat > /dev/null # the payload arrives on stdin; emit the canned stream
        printf '%s' "$canned"
        return 0
    }

    export CLOUDIFY_REMOTE_USER=testuser CLOUDIFY_REMOTE_PWD=dummy
    local canned
    canned=$'bootstrapping\nresult v1: parent=- package=wired instance=default phase=install action=install outcome=succeeded exit=0 verification=not-run version=3.2.1\ncheckout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false\ndone\n'
    CLOUDIFY_DEPLOYMENT="" cloudify_remote_sync cloudai install wired > "$CLOUDIFY_TMP/stream.out" 2>&1

    grep -q '^cloudai: bootstrapping$' "$CLOUDIFY_TMP/stream.out"
    grep -q '^cloudai: done$' "$CLOUDIFY_TMP/stream.out"

    local file="${CLOUDIFY_RESULTS_FILE:-}"
    [ -n "$file" ] && [ -f "$file" ]
    grep -q '^result v1: parent=- package=wired instance=default phase=install action=install outcome=succeeded exit=0 verification=not-run version=3.2.1$' "$file"
    grep -q '^checkout v1: commit=0123456789abcdef0123456789abcdef01234567 dirty=false$' "$file"
    [ "$(grep -c . "$file")" -eq 2 ]
    cloudify_results_validate "$file"
}
