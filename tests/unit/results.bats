#!/usr/bin/env bash
# bats file_tags=results
# Result-line emission freeze (state-model-v2 4.3): one `result v1:` line per
# package attempt, printed by the child's framework code on the streamed log.
# Contract: plans/state-model-v2-phase4-design.md "Result lines on the
# streamed log", amended 2026-09-20: the version is the package's DECLARED
# `.version` file, not machine observation. The payload template and its
# goldens stay untouched; the lines are ordinary keyed lines in the stream.

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
    export CLOUDIFY_NO_VERIFY=true
}

teardown() {
    teardown_test_env
}

# A package fixture with a declared version (and an optional recipe body).
make_declared_pkg() {
    local name="${1:-declared}" version="${2:-1.2.3}" body="${3-:}"
    mkdir -p "$CLOUDIFY_DIR/pkg/$name"
    printf '%s\n' "$version" > "$CLOUDIFY_DIR/pkg/$name/.version"
    cat > "$CLOUDIFY_DIR/pkg/$name/install.sh" <<EOF
#!/usr/bin/env bash
$body
EOF
}

@test "emit: renders the frozen v1 line byte-exact" {
    run cloudify_result_emit - nginx install install 0 ok "1.24.0"
    [ "$status" -eq 0 ]
    [ "$output" = "result v1: parent=- package=nginx instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=1.24.0" ]
}

@test "emit: unknown version forces outcome=failed and never alters exit" {
    run cloudify_result_emit - nginx install install 0 ok unknown
    [ "$status" -eq 0 ]
    [[ "$output" == *"outcome=failed exit=0 verification=ok version=unknown"* ]]
}

@test "emit: verification=failed forces outcome=failed with truthful exit" {
    run cloudify_result_emit - nginx install install 0 failed "1.24.0"
    [[ "$output" == *"outcome=failed exit=0 verification=failed version=1.24.0"* ]]
}

@test "emit: verification=not-run with exit 0 and version=none is succeeded" {
    run cloudify_result_emit - nginx install install 0 not-run none
    [[ "$output" == *"outcome=succeeded exit=0 verification=not-run version=none"* ]]
}

@test "emit: non-zero exit forces outcome=failed" {
    run cloudify_result_emit - nginx install install 17 ok "1.24.0"
    [[ "$output" == *"outcome=failed exit=17 verification=ok version=1.24.0"* ]]
}

@test "emit: dependency parent lands verbatim" {
    run cloudify_result_emit nginx nginx-common install install 0 not-run none
    [[ "$output" == "result v1: parent=nginx package=nginx-common instance=default phase=install action=install outcome=succeeded exit=0 verification=not-run version=none" ]]
}

@test "version declaration: well-formed file reads verbatim" {
    make_declared_pkg good "1.2.3"
    [ "$(_cloudify_result_version_of good)" = "1.2.3" ]
}

@test "version declaration: missing, empty or off-charset reads unknown" {
    make_declared_pkg normal "9.9.9"
    mkdir -p "$CLOUDIFY_DIR/pkg/absent"                       # no .version file
    mkdir -p "$CLOUDIFY_DIR/pkg/empty" && : > "$CLOUDIFY_DIR/pkg/empty/.version"
    mkdir -p "$CLOUDIFY_DIR/pkg/spaced" && printf '1.0 beta\n' > "$CLOUDIFY_DIR/pkg/spaced/.version"

    [ "$(_cloudify_result_version_of normal)" = "9.9.9" ]
    [ "$(_cloudify_result_version_of absent)" = "unknown" ]
    [ "$(_cloudify_result_version_of empty)" = "unknown" ]
    [ "$(_cloudify_result_version_of spaced)" = "unknown" ]
    [ "$(_cloudify_result_version_of "")" = "unknown" ]
}

@test "instance: no .package-instance marker resolves default" {
    make_declared_pkg plain
    [ "$(_cloudify_result_instance_of plain)" = "default" ]
}

@test "instance: marker names a supplied variable; unsupplied or invalid resolves unknown, never a guess" {
    make_declared_pkg marked
    printf 'NODE_ROLE\n' > "$CLOUDIFY_DIR/pkg/marked/.package-instance"

    NODE_ROLE=worker run _cloudify_result_instance_of marked
    [ "$output" = "worker" ]

    run _cloudify_result_instance_of marked
    [ "$output" = "unknown" ]

    NODE_ROLE="has space" run _cloudify_result_instance_of marked
    [ "$output" = "unknown" ]

    printf '1BAD\n' > "$CLOUDIFY_DIR/pkg/marked/.package-instance"
    NODE_ROLE=worker run _cloudify_result_instance_of marked
    [ "$output" = "unknown" ]
}

@test "pkg_depends: one succeeded line per package attempt, parent=- at top level" {
    make_declared_pkg mypkg "9.9.9"
    run pkg_depends mypkg
    [ "$status" -eq 0 ]
    [ "$(grep -c '^result v1: ' <<< "$output")" -eq 1 ]
    grep -q '^result v1: parent=- package=mypkg instance=default phase=install action=install outcome=succeeded exit=0 verification=not-run version=9.9.9$' <<< "$output"
}

@test "pkg_depends: dependency pulls are attributed to the declaring package" {
    make_declared_pkg dep "0.1.0"
    make_declared_pkg caller "2.0.0" 'pkg_depends dep'
    run pkg_depends caller
    [ "$status" -eq 0 ]
    grep -q '^result v1: parent=caller package=dep ' <<< "$output"
    grep -q '^result v1: parent=- package=caller ' <<< "$output"
    [ "$(grep -c '^result v1: ' <<< "$output")" -eq 2 ]
}

@test "pkg_depends: framework work is attributed via CLOUDIFY_RESULT_PARENT" {
    make_declared_pkg fw "0.0.1"
    CLOUDIFY_RESULT_PARENT=@defaults run pkg_depends fw
    grep -q '^result v1: parent=@defaults package=fw ' <<< "$output"
}

@test "pkg_depends: native fallback reports version=none" {
    pkg_apt_install() { return 0; }
    run pkg_depends totally-unknown-thing
    [ "$status" -eq 0 ]
    grep -q '^result v1: parent=- package=totally-unknown-thing instance=default phase=install action=install outcome=succeeded exit=0 verification=not-run version=none$' <<< "$output"
}

@test "pkg_depends: failed recipe emits outcome=failed with the real exit code and the declared version" {
    make_declared_pkg broken "0.0.1" 'exit 42'
    run pkg_depends broken
    [ "$status" -ne 0 ]
    grep -q '^result v1: parent=- package=broken instance=default phase=install action=install outcome=failed exit=42 verification=not-run version=0.0.1$' <<< "$output"
}

@test "pkg_depends: failed native attempt emits outcome=failed version=none" {
    pkg_apt_install() { return 3; }
    run pkg_depends no-such-pkg-xyz
    [ "$status" -ne 0 ]
    grep -q '^result v1: parent=- package=no-such-pkg-xyz instance=default phase=install action=install outcome=failed exit=3 verification=not-run version=none$' <<< "$output"
}

@test "pkg_depends: undeclared version on a recipe package emits unknown and fails the attempt" {
    mkdir -p "$CLOUDIFY_DIR/pkg/no-declaration"
    printf '#!/usr/bin/env bash\n' > "$CLOUDIFY_DIR/pkg/no-declaration/install.sh"
    run pkg_depends no-declaration
    [ "$status" -eq 0 ] # recipe exited 0; the FRAMEWORK's verdict is what failed
    grep -q '^result v1: parent=- package=no-declaration instance=default phase=install action=install outcome=failed exit=0 verification=not-run version=unknown$' <<< "$output"
}

@test "pkg_depends: verify failure emits verification=failed with exit still truthful" {
    make_declared_pkg verifail "1.1.1"
    cat > "$CLOUDIFY_DIR/pkg/verifail/verify.sh" <<'EOF'
#!/usr/bin/env bash
function pkg_verify() {
    return 1
}
EOF
    CLOUDIFY_NO_VERIFY=false
    PKG_VERIFY_TIMEOUT=1
    run pkg_depends verifail
    [ "$status" -ne 0 ]
    grep -q '^result v1: parent=- package=verifail instance=default phase=install action=install outcome=failed exit=0 verification=failed version=1.1.1$' <<< "$output"
}

@test "pkg_depends: successful verify emits verification=ok" {
    make_declared_pkg veriok "1.1.2"
    cat > "$CLOUDIFY_DIR/pkg/veriok/verify.sh" <<'EOF'
#!/usr/bin/env bash
function pkg_verify() {
    return 0
}
EOF
    CLOUDIFY_NO_VERIFY=false
    PKG_VERIFY_TIMEOUT=1
    run pkg_depends veriok
    [ "$status" -eq 0 ]
    grep -q '^result v1: parent=- package=veriok instance=default phase=install action=install outcome=succeeded exit=0 verification=ok version=1.1.2$' <<< "$output"
}

@test "declaration gate: every resolvable recipe in pkg/ declares a well-formed .version" {
    # Mirrors the resolver's generic preference (install.sh, else init.sh);
    # no os-specific-only recipes exist. Native-fallback subjects (no recipe)
    # need no declaration. The gate walks THE TREE UNDER TEST
    # ($BATS_TEST_DIRNAME/../..), never CLOUDIFY_SCRIPT_DIR of a mirror - and
    # fails loudly when that root lacks pkg/, so it can never pass vacuous.
    local root="$BATS_TEST_DIRNAME/../.." dir recipe token missing_recipes=""
    [ -d "$root/pkg" ] || { echo "declaration gate: no pkg/ under $root - wrong test root"; return 1; }
    while IFS= read -r dir; do
        recipe="$dir/install.sh"
        [[ -f "$recipe" ]] || recipe="$dir/init.sh"
        if [[ ! -f "$recipe" ]]; then
            continue # no resolvable recipe: native-fallback subject, not a recipe
        fi
        token=$(head -n 1 "$dir/.version" 2>/dev/null | tr -d '[:space:]') || true
        if [[ -z "$token" || ! "$token" =~ ^[A-Za-z0-9._+~:-]+$ ]]; then
            missing_recipes="$missing_recipes $(basename "$dir")"
        fi
    done < <(find "$root/pkg" -mindepth 1 -maxdepth 1 -type d | sort)
    [ -z "$missing_recipes" ] || {
        echo "packages missing a well-formed .version declaration:$missing_recipes"
        return 1
    }
}
