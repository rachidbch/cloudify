#!/usr/bin/env bats
# Structural regression tests for the k3s recipes (Phase 3).
# The two ADR-010 REQUIRED flags (flannel-iface=tailscale0, KubeletInUserNamespace)
# are load-bearing — if a refactor drops them, cross-node pod traffic dies.
# The recipes themselves are validated live by tests/e2e/k3s-multi-cluster.bats.

setup() {
    source tests/helpers/common.bash
    setup_test_env
    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/packages.sh
    source lib/remote.sh
    export CLOUDIFY_RECIPE_FILENAME=init.sh
    # Resolver walks CLOUDIFY_DIR — symlink the REAL recipes into the temp tree
    for p in k3s-server k3s-agent k3s-cli; do
        ln -s "$CLOUDIFY_SCRIPT_DIR/pkg/$p" "$CLOUDIFY_DIR/pkg/$p"
    done
    export REAL_PKG="$CLOUDIFY_DIR/pkg"
}

teardown() {
    teardown_test_env
}

@test "k3s-server is a split pkg (install.sh + configure.sh + verify.sh)" {
    [ -f "$REAL_PKG/k3s-server/install.sh" ]
    [ -f "$REAL_PKG/k3s-server/configure.sh" ]
    [ -f "$REAL_PKG/k3s-server/verify.sh" ]
    run cloudify_package_recipe_path k3s-server
    [ "$status" -eq 0 ]
    [[ "$output" == *"/k3s-server/install.sh" ]]
    run cloudify_package_recipe_path k3s-server configure.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"/k3s-server/configure.sh" ]]
}

@test "k3s-agent is a split pkg (install.sh + configure.sh + verify.sh)" {
    [ -f "$REAL_PKG/k3s-agent/install.sh" ]
    [ -f "$REAL_PKG/k3s-agent/configure.sh" ]
    [ -f "$REAL_PKG/k3s-agent/verify.sh" ]
}

@test "k3s-cli is a legacy init.sh pkg" {
    [ -f "$REAL_PKG/k3s-cli/init.sh" ]
    run cloudify_package_recipe_path k3s-cli
    [ "$status" -eq 0 ]
    [[ "$output" == *"/k3s-cli/init.sh" ]]
}

@test "server + agent configure.sh carry the two REQUIRED flags (ADR-010)" {
    for f in k3s-server k3s-agent; do
        grep -q "flannel-iface: tailscale0" "$REAL_PKG/$f/configure.sh"
        grep -q "KubeletInUserNamespace=true" "$REAL_PKG/$f/configure.sh"
    done
}

@test "server configure.sh pins node-ip/node-external-ip + tls-san" {
    grep -q "node-ip:" "$REAL_PKG/k3s-server/configure.sh"
    grep -q "node-external-ip:" "$REAL_PKG/k3s-server/configure.sh"
    grep -q "tls-san:" "$REAL_PKG/k3s-server/configure.sh"
}

@test ".remote-vars declarations match the cluster secrets" {
    grep -qx "K3S_TOKEN" "$REAL_PKG/k3s-server/.remote-vars"
    grep -qx "K3S_TOKEN" "$REAL_PKG/k3s-agent/.remote-vars"
    grep -qx "K3S_URL" "$REAL_PKG/k3s-agent/.remote-vars"
    grep -qx "K3S_SERVER" "$REAL_PKG/k3s-cli/.remote-vars"
    grep -qx "K3S_CONTEXT" "$REAL_PKG/k3s-cli/.remote-vars"
}
