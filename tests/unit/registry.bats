#!/usr/bin/env bats
# Tests for lib/registry.sh — registry storage primitives.
# The registry is observation-only storage: one config.yaml per
# (deployment, target, package). The bucket is the ivps node dir when
# resolvable, else a plain-host bucket under
# ${CLOUDIFY_CREDENTIALS_DIR:-$HOME/.config/cloudify}/registry/hosts/<ssh_host>.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/registry.sh

    # Node dirs and the fallback bucket live under temp dirs only
    export HOME="$CLOUDIFY_TMP/home"
    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/creds"
    mkdir -p "$HOME" "$CLOUDIFY_CREDENTIALS_DIR"

    IVPS_NODE_ROOT="$CLOUDIFY_TMP/ivps/nodes"
    IVPS_NODES=()
    IVPS_NODE_PATH_RC=0

    DEP="xfce-gui"
    NODE="cloudai"
    INSTANCE=""
    HOST="cloudify"
    PKG="vim"
    RECORD='status: installed
version: 9.1'
}

teardown() {
    teardown_test_env
}

# ivps stub as a shell function (shadows any real ivps in PATH).
#   IVPS_NODES        — node names `ivps node path` accepts
#   IVPS_NODE_PATH_RC — exit code of `ivps node path` when the node is listed
ivps() {
    local sub="${1:-}" e
    case "$sub" in
        node)
            [[ "${2:-}" == "path" ]] || return 1
            [[ "${IVPS_NODE_PATH_RC:-0}" -eq 0 ]] || return "$IVPS_NODE_PATH_RC"
            for e in ${IVPS_NODES[@]+"${IVPS_NODES[@]}"}; do
                [[ "$e" == "${3:-}" ]] && { echo "$IVPS_NODE_ROOT/${3:-}"; return 0; }
            done
            return 1
            ;;
        *) return 1 ;;
    esac
}

# Put with the record on stdin (bats' `run` cannot redirect stdin itself)
_reg_put() {
    cloudify_registry_put "$1" "$2" "${3:-}" "${4:-}" "$5" <<< "$6"
}

# ---------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------

@test "node target: the record path is under the ivps node dir" {
    rubric "node target -> \$(ivps node path <node>)/deployments/<id>/pkgs/<pkg>/config.yaml"
    IVPS_NODES=(cloudai)

    run cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "instance target: the record path adds the instance segment" {
    rubric "instance target -> <node dir>/<instance>/deployments/<id>/pkgs/<pkg>/config.yaml"
    IVPS_NODES=(cloudai)

    run cloudify_registry_file "$DEP" "$NODE" "$HOST" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$IVPS_NODE_ROOT/cloudai/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "an unresolvable node falls back to the plain-host bucket" {
    rubric "ivps node path fails -> \${cred dir}/registry/hosts/<ssh host>/..."
    IVPS_NODES=()

    run cloudify_registry_file "$DEP" local "" localhost "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_CREDENTIALS_DIR/registry/hosts/localhost/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "a failing ivps node path (rc != 0) falls back, never aborts" {
    rubric "ivps present but node path errors -> fallback bucket, rc 0"
    IVPS_NODES=(cloudai)
    IVPS_NODE_PATH_RC=3

    run cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_CREDENTIALS_DIR/registry/hosts/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "an empty node falls back to the plain-host bucket" {
    rubric "no node (plain host) -> fallback bucket keyed by the ssh host"
    IVPS_NODES=(cloudai)

    run cloudify_registry_file "$DEP" "" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_CREDENTIALS_DIR/registry/hosts/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "an absent ivps falls back to the plain-host bucket" {
    rubric "no ivps at all -> fallback bucket, no abort"
    unset -f ivps
    # Hermetic: hide any real ivps binary from the `command -v` probe
    command() { [[ "${1:-} ${2:-}" == "-v ivps" ]] && return 1; builtin command "$@"; }

    run cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_CREDENTIALS_DIR/registry/hosts/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]
    unset -f command
}

@test "an instance on an unresolvable node keeps its own fallback bucket" {
    rubric "instance target without a node dir -> hosts/<host>/<instance>/..."
    IVPS_NODES=()

    run cloudify_registry_file "$DEP" "" "$HOST" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$CLOUDIFY_CREDENTIALS_DIR/registry/hosts/$HOST/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "the fallback bucket honours CLOUDIFY_CREDENTIALS_DIR, else HOME" {
    rubric "fallback root = \${CLOUDIFY_CREDENTIALS_DIR:-\$HOME/.config/cloudify}/registry/hosts"
    IVPS_NODES=()

    run cloudify_registry_file "$DEP" "" "" "$HOST" "$PKG"
    [ "$output" = "$CLOUDIFY_CREDENTIALS_DIR/registry/hosts/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]

    unset CLOUDIFY_CREDENTIALS_DIR
    run cloudify_registry_file "$DEP" "" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.config/cloudify/registry/hosts/$HOST/deployments/$DEP/pkgs/$PKG/config.yaml" ]
}

@test "with no node dir and no ssh host the bucket is unaddressable (fail closed)" {
    rubric "no bucket key at all -> error, never a collapsing path"
    IVPS_NODES=()

    run cloudify_registry_file "$DEP" "" "" "" "$PKG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no storage bucket"* ]]
}

@test "file is pure: resolving a path creates nothing" {
    rubric "cloudify_registry_file has no side effects"
    IVPS_NODES=(cloudai)

    run cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ ! -e "$IVPS_NODE_ROOT/cloudai" ]
    [ ! -e "$CLOUDIFY_CREDENTIALS_DIR/registry" ]
}

# ---------------------------------------------------------------
# Unsafe components
# ---------------------------------------------------------------

@test "path separators and dot components are rejected everywhere" {
    rubric "no '/' and no '.'/'..' in any component (fail closed)"
    IVPS_NODES=(cloudai)

    run cloudify_registry_file 'a/b' "$NODE" "" "$HOST" "$PKG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid deployment"* ]]

    run cloudify_registry_file '..' "$NODE" "" "$HOST" "$PKG"
    [ "$status" -ne 0 ]

    run cloudify_registry_file "$DEP" '../node' "" "$HOST" "$PKG"
    [ "$status" -ne 0 ]

    run cloudify_registry_file "$DEP" "$NODE" '..' "$HOST" "$PKG"
    [ "$status" -ne 0 ]

    run cloudify_registry_file "$DEP" "$NODE" "" '../host' "$PKG"
    [ "$status" -ne 0 ]

    run cloudify_registry_file "$DEP" "$NODE" "" "$HOST" '../passwd'
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid pkg"* ]]
}

@test "empty deployment or package is rejected" {
    rubric "deployment and pkg are required"
    IVPS_NODES=(cloudai)

    run cloudify_registry_file "" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"deployment is required"* ]]

    run cloudify_registry_file "$DEP" "$NODE" "" "$HOST" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"pkg is required"* ]]
}

@test "put with an unsafe component writes nothing" {
    rubric "validation happens before any mkdir/mktemp"
    IVPS_NODES=(cloudai)

    run _reg_put "$DEP" "$NODE" "" "$HOST" '../evil' "$RECORD"
    [ "$status" -ne 0 ]
    [ ! -e "$IVPS_NODE_ROOT/cloudai" ]
}

# ---------------------------------------------------------------
# put / get
# ---------------------------------------------------------------

@test "put then get round-trips the record verbatim" {
    rubric "put (stdin) -> get prints the same text"
    IVPS_NODES=(cloudai)

    run _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    [ "$status" -eq 0 ]

    run cloudify_registry_get "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$RECORD" ]
}

@test "put creates the parent chain under the node dir" {
    rubric "mkdir -p the record's parent, no other side effects"
    IVPS_NODES=(cloudai)

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    [ -f "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/$PKG/config.yaml" ]
    [ ! -e "$CLOUDIFY_CREDENTIALS_DIR/registry" ]
}

@test "put on the fallback bucket round-trips" {
    rubric "plain host -> record under the local fallback bucket"
    IVPS_NODES=()

    _reg_put "$DEP" "" "" "$HOST" "$PKG" "$RECORD"
    run cloudify_registry_get "$DEP" "" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ "$output" = "$RECORD" ]
}

@test "the record file is 600 and its parent dir 700, whatever the base perms" {
    rubric "0700 dir / 0600 file enforced despite a 0755 base"
    IVPS_NODES=(cloudai)
    mkdir -p "$IVPS_NODE_ROOT/cloudai"
    chmod 755 "$IVPS_NODE_ROOT/cloudai"

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    local file="$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/$PKG/config.yaml"
    [ "$(stat -c '%a' "${file%/*}")" = "700" ]
    [ "$(stat -c '%a' "$file")" = "600" ]
    [ "$(stat -c '%a' "$IVPS_NODE_ROOT/cloudai")" = "755" ]
}

@test "put replaces atomically: new inode, no temp litter, perms kept" {
    rubric "mktemp in the same dir + mv = atomic replace (I7-6)"
    IVPS_NODES=(cloudai)

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    local file ino1 ino2
    file=$(cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG")
    ino1=$(stat -c '%i' "$file")

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" 'status: removed'
    ino2=$(stat -c '%i' "$file")

    [ "$(cat "$file")" = "status: removed" ]
    [ "$ino1" != "$ino2" ]
    [ "$(ls -A "${file%/*}")" = "config.yaml" ]
    [ "$(stat -c '%a' "$file")" = "600" ]
}

@test "put is idempotent for the same text" {
    rubric "put twice with the same record -> one file, same content"
    IVPS_NODES=(cloudai)

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    run cloudify_registry_get "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$output" = "$RECORD" ]
    [ "$(ls -A "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/$PKG")" = "config.yaml" ]
}

@test "get on an absent record prints nothing and fails" {
    rubric "absent record -> empty output, rc 1"
    IVPS_NODES=(cloudai)

    run cloudify_registry_get "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------
# delete / list
# ---------------------------------------------------------------

@test "delete removes the record and prunes the empty parents" {
    rubric "delete -> file + <pkg>/ + pkgs/ gone, deployments/<id> spared"
    IVPS_NODES=(cloudai)

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    local file pkg_dir
    file=$(cloudify_registry_file "$DEP" "$NODE" "" "$HOST" "$PKG")
    pkg_dir="${file%/*}"

    run cloudify_registry_delete "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ ! -e "$file" ]
    [ ! -d "$pkg_dir" ]
    [ ! -d "${pkg_dir%/*}" ]
    [ -d "$IVPS_NODE_ROOT/cloudai/deployments/$DEP" ]
    [ -d "$IVPS_NODE_ROOT/cloudai" ]
}

@test "delete keeps the pkgs dir while another package keeps a record" {
    rubric "no over-pruning: a sibling record pins the shared parents"
    IVPS_NODES=(cloudai)

    _reg_put "$DEP" "$NODE" "" "$HOST" "$PKG" "$RECORD"
    _reg_put "$DEP" "$NODE" "" "$HOST" git 'status: installed'

    run cloudify_registry_delete "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ -d "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs" ]
    [ -f "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/git/config.yaml" ]
}

@test "delete on an absent record is a no-op with rc 0" {
    rubric "idempotent delete"
    IVPS_NODES=(cloudai)

    run cloudify_registry_delete "$DEP" "$NODE" "" "$HOST" "$PKG"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "list prints the packages that hold a record" {
    rubric "list -> one line per record dir, empty when none"
    IVPS_NODES=(cloudai)

    run cloudify_registry_list "$DEP" "$NODE" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    _reg_put "$DEP" "$NODE" "" "$HOST" vim "$RECORD"
    _reg_put "$DEP" "$NODE" "" "$HOST" git 'status: installed'
    mkdir -p "$IVPS_NODE_ROOT/cloudai/deployments/$DEP/pkgs/empty"

    run cloudify_registry_list "$DEP" "$NODE" ""
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'git\nvim')" ]
}

@test "list sees only its own deployment and bucket" {
    rubric "bucketing: other deployments/targets never leak in"
    IVPS_NODES=(cloudai)

    _reg_put "$DEP" "$NODE" "" "$HOST" vim "$RECORD"
    _reg_put "other-app" "$NODE" "" "$HOST" git 'status: installed'
    _reg_put "$DEP" "$NODE" "$HOST" "$HOST" curl 'status: installed'

    run cloudify_registry_list "$DEP" "$NODE" ""
    [ "$output" = "vim" ]

    run cloudify_registry_list "other-app" "$NODE" ""
    [ "$output" = "git" ]

    run cloudify_registry_list "$DEP" "$NODE" "$HOST"
    [ "$output" = "curl" ]
}

@test "list works on the plain-host fallback bucket" {
    rubric "fallback bucket listing needs the ssh host"
    IVPS_NODES=()

    _reg_put "$DEP" "" "" "$HOST" vim "$RECORD"
    run cloudify_registry_list "$DEP" "" "" "$HOST"
    [ "$status" -eq 0 ]
    [ "$output" = "vim" ]

    run cloudify_registry_list "$DEP" "" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------
# Module guard
# ---------------------------------------------------------------

@test "module guard prevents double-sourcing" {
    rubric "lib/registry.sh is guarded"
    source lib/registry.sh
    source lib/registry.sh
    [ "$(type -t cloudify_registry_file)" = "function" ]
    [ "$(type -t cloudify_registry_put)" = "function" ]
    [ "$(type -t cloudify_registry_get)" = "function" ]
    [ "$(type -t cloudify_registry_delete)" = "function" ]
    [ "$(type -t cloudify_registry_list)" = "function" ]
}
