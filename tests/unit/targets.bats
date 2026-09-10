#!/usr/bin/env bats
# Tests for lib/targets.sh — the `--on` target grammar resolver.
# The resolver is validation-only: it never provisions, it dies (fail closed) on
# an unknown or ambiguous target.

setup() {
    source tests/helpers/common.bash
    setup_test_env

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/targets.sh

    # The ivps config (IVPS_DEFAULT_NODE) lives in a temp dir: no file by default
    export IVPS_CONFIG_DIR="$CLOUDIFY_TMP/ivps"
    mkdir -p "$IVPS_CONFIG_DIR"
    unset CLOUDIFY_NODE IVPS_DEFAULT_NODE

    IVPS_NODES=()
    IVPS_ROWS=()
    IVPS_LIST_RC=0
}

teardown() {
    teardown_test_env
}

# ivps stub as a shell function (shadows any real ivps in PATH).
#   IVPS_NODES  — node names `ivps node path` accepts
#   IVPS_ROWS   — "<node>:<name>" rows `ivps list` prints
#   IVPS_LIST_RC — exit code of `ivps list`
ivps() {
    local sub="${1:-}" e r
    case "$sub" in
        node)
            # ivps node path <node>
            for e in ${IVPS_NODES[@]+"${IVPS_NODES[@]}"}; do
                [[ "$e" == "${3:-}" ]] && { echo "/ivps/nodes/${3:-}"; return 0; }
            done
            return 1
            ;;
        list)
            [[ "$IVPS_LIST_RC" -eq 0 ]] || return "$IVPS_LIST_RC"
            echo "  REMOTE:NAME      STATUS"
            for r in ${IVPS_ROWS[@]+"${IVPS_ROWS[@]}"}; do
                printf '  %-30s Running\n' "$r"
            done
            return 0
            ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------
# Bare token: kind discovery
# ---------------------------------------------------------------

@test "bare name that is an ivps node resolves to a node target" {
    rubric "X is a node -> node target, ssh host is the node"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)

    run _cloudify_target_resolve cloudai
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudai\t\tcloudai')" ]
}

@test "bare name that is only an ivps instance resolves to that instance" {
    rubric "X is an instance -> instance target, its node is discovered"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify cloudai:hermes)

    run _cloudify_target_resolve hermes
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudai\thermes\thermes')" ]
}

@test "bare name that is both a node and an instance dies as ambiguous" {
    rubric "X node + instance -> ambiguity error"
    IVPS_NODES=(cloudai cloudstation)
    IVPS_ROWS=(cloudstation:cloudai)

    run _cloudify_target_resolve cloudai
    [ "$status" -ne 0 ]
    [[ "$output" == *"ambiguous"* ]]
}

@test "bare name on several nodes dies as ambiguous" {
    rubric "instance on 2 nodes -> ambiguity error, no silent pick"
    IVPS_NODES=(cloudai cloudstation)
    IVPS_ROWS=(cloudai:web cloudstation:web)

    run _cloudify_target_resolve web
    [ "$status" -ne 0 ]
    [[ "$output" == *"ambiguous"* ]]
}

@test "bare name unknown to ivps falls back to a plain host" {
    rubric "X not in the inventory -> plain host (back-compat, ssh validates)"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)

    run _cloudify_target_resolve myserver
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '\t\tmyserver')" ]
}

@test "a multi-colon token stays a plain host (IPv6 back-compat)" {
    rubric "fd42::1 -> plain host, not parsed as a target triple"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)

    run _cloudify_target_resolve 'fd42::1'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '\t\tfd42::1')" ]
}

# ---------------------------------------------------------------
# X: — node asserted by syntax
# ---------------------------------------------------------------

@test "X: resolves to a node target" {
    rubric "X: -> node target"
    IVPS_NODES=(cloudai)

    run _cloudify_target_resolve 'cloudai:'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudai\t\tcloudai')" ]
}

@test "X: where X is not a node dies with a clear message" {
    rubric "X: non-node -> error (explicit kind assertion fails closed)"
    IVPS_NODES=(cloudstation)
    IVPS_ROWS=(cloudai:cloudify)

    run _cloudify_target_resolve 'cloudify:'
    [ "$status" -ne 0 ]
    [[ "$output" == *"node 'cloudify' not found"* ]]
}

# ---------------------------------------------------------------
# X:Y — instance on an explicit node
# ---------------------------------------------------------------

@test "X:Y resolves to the instance target" {
    rubric "X:Y -> instance target, ssh host is the instance name"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify cloudstation:other)

    run _cloudify_target_resolve 'cloudai:cloudify'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudai\tcloudify\tcloudify')" ]
}

@test "X:Y where Y is not on X dies" {
    rubric "X:Y with Y on another node -> error, no cross-node guess"
    IVPS_NODES=(cloudai cloudstation)
    IVPS_ROWS=(cloudstation:cloudify)

    run _cloudify_target_resolve 'cloudai:cloudify'
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not on node 'cloudai'"* ]]
}

@test "X:Y where X is not a node dies" {
    rubric "X:Y with an unknown node -> error"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)

    run _cloudify_target_resolve 'nosuchnode:cloudify'
    [ "$status" -ne 0 ]
    [[ "$output" == *"node 'nosuchnode' not found"* ]]
}

# ---------------------------------------------------------------
# :Y — instance on the active / default node
# ---------------------------------------------------------------

@test ":Y uses CLOUDIFY_NODE as the active node" {
    rubric ":Y -> instance on CLOUDIFY_NODE"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)
    export CLOUDIFY_NODE=cloudai

    run _cloudify_target_resolve ':cloudify'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudai\tcloudify\tcloudify')" ]
}

@test ":Y falls back to IVPS_DEFAULT_NODE from the ivps config" {
    rubric ":Y with no active node -> instance on the ivps default node"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)
    echo 'IVPS_DEFAULT_NODE="cloudai"' > "$IVPS_CONFIG_DIR/config.env"

    run _cloudify_target_resolve ':cloudify'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudai\tcloudify\tcloudify')" ]
}

@test "CLOUDIFY_NODE wins over IVPS_DEFAULT_NODE" {
    rubric "active node beats the ivps default"
    IVPS_NODES=(cloudai cloudstation)
    IVPS_ROWS=(cloudstation:guac-gui)
    echo 'IVPS_DEFAULT_NODE=cloudai' > "$IVPS_CONFIG_DIR/config.env"
    export CLOUDIFY_NODE=cloudstation

    run _cloudify_target_resolve ':guac-gui'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'cloudstation\tguac-gui\tguac-gui')" ]
}

@test ":Y with neither active nor default node dies with a hint" {
    rubric ":Y with no node at all -> error + how to set one"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudai:cloudify)

    run _cloudify_target_resolve ':cloudify'
    [ "$status" -ne 0 ]
    [[ "$output" == *"no active node"* ]]
    [[ "$output" == *"cloudify node use"* ]]
}

@test ":Y where Y is not on the active node dies" {
    rubric ":Y on a node that does not host it -> error"
    IVPS_NODES=(cloudai)
    IVPS_ROWS=(cloudstation:guac-gui)
    export CLOUDIFY_NODE=cloudai

    run _cloudify_target_resolve ':guac-gui'
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not on node 'cloudai'"* ]]
}

@test ": with no node and no instance dies" {
    rubric "':' alone -> usage error, never a host name"
    IVPS_NODES=(cloudai)

    run _cloudify_target_resolve ':'
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing node and instance"* ]]
}

# ---------------------------------------------------------------
# localhost / local — a node like any other, no fallback
# ---------------------------------------------------------------

@test "localhost resolves to node local with ssh host localhost" {
    rubric "localhost -> node local (no ivps lookup, no fallback)"
    IVPS_NODES=()

    run _cloudify_target_resolve localhost
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'local\t\tlocalhost')" ]
}

@test "bare local resolves to node local with ssh host localhost" {
    rubric "local is a real ivps node -> node target, ssh host localhost"
    IVPS_NODES=(local)

    run _cloudify_target_resolve local
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'local\t\tlocalhost')" ]
}

@test "localhost: resolves to node local" {
    rubric "localhost: -> node local, same as the bare form"
    IVPS_NODES=(local)

    run _cloudify_target_resolve 'localhost:'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'local\t\tlocalhost')" ]
}

@test "localhost:Y resolves to an instance on node local" {
    rubric "localhost:Y -> instance on node local"
    IVPS_NODES=(local)
    IVPS_ROWS=(local:mybox)

    run _cloudify_target_resolve 'localhost:mybox'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'local\tmybox\tmybox')" ]
}

# ---------------------------------------------------------------
# ivps missing / failing
# ---------------------------------------------------------------

@test "ivps absent: a bare name is still a plain host" {
    rubric "no ivps -> bare name stays a plain host"
    unset -f ivps

    run _cloudify_target_resolve myserver
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '\t\tmyserver')" ]
}

@test "ivps absent: an explicit form dies with a clear message" {
    rubric "no ivps -> X: / X:Y / :Y die (kind cannot be asserted)"
    unset -f ivps

    run _cloudify_target_resolve 'cloudai:cloudify'
    [ "$status" -ne 0 ]
    [[ "$output" == *"ivps is required"* ]]
}

@test "ivps list failing: a bare name is still a plain host" {
    rubric "ivps present but inventory read fails -> plain host, no abort"
    IVPS_NODES=(cloudai)
    IVPS_LIST_RC=1

    run _cloudify_target_resolve cloudify
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '\t\tcloudify')" ]
}

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

@test "_cloudify_target_active_node prints CLOUDIFY_NODE" {
    rubric "active node reader"
    export CLOUDIFY_NODE=cloudai
    run _cloudify_target_active_node
    [ "$output" = "cloudai" ]
}

@test "_cloudify_target_default_node reads IVPS_DEFAULT_NODE from the ivps config" {
    rubric "ivps default node reader"
    echo 'IVPS_DEFAULT_NODE=cloudstation' > "$IVPS_CONFIG_DIR/config.env"
    run _cloudify_target_default_node
    [ "$output" = "cloudstation" ]
}

@test "_cloudify_target_default_node is empty without a config or env value" {
    rubric "no default node -> empty, no failure"
    run _cloudify_target_default_node
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------
# cloudify node use
# ---------------------------------------------------------------

@test "cloudify node use prints the export for an existing node" {
    rubric "node use -> export + eval hint, mirroring deployment use"
    IVPS_NODES=(cloudai)

    run cloudify_node_use cloudai
    [ "$status" -eq 0 ]
    [[ "$output" == *"export CLOUDIFY_NODE=cloudai"* ]]
    [[ "$output" == *"eval \"\$(cloudify node use cloudai)\""* ]]
}

@test "cloudify node use localhost names node local" {
    rubric "node use localhost -> node local"
    IVPS_NODES=(local)

    run cloudify_node_use localhost
    [ "$status" -eq 0 ]
    [[ "$output" == *"export CLOUDIFY_NODE=local"* ]]
}

@test "cloudify node use dies for an unknown node" {
    rubric "node use validates existence"
    IVPS_NODES=(cloudai)

    run cloudify_node_use nosuchnode
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "cloudify node use dies when ivps is absent" {
    rubric "node use needs the inventory"
    unset -f ivps

    run cloudify_node_use cloudai
    [ "$status" -ne 0 ]
    [[ "$output" == *"ivps is not installed"* ]]
}

# ---------------------------------------------------------------
# Module guard
# ---------------------------------------------------------------

@test "module guard prevents double-sourcing" {
    rubric "lib/targets.sh is guarded"
    source lib/targets.sh
    source lib/targets.sh
    [ "$(type -t _cloudify_target_resolve)" = "function" ]
}
