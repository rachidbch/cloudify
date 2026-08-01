#!/usr/bin/env bats
# LIVE e2e — k3s multi-cluster UX validation (Phase 3, plan k3s-multi-cluster).
# Two mutually-isolated k3s clusters (prod ∥ dev) on throwaway tailnet-tagged
# nodes, using the branch-stacked ivps (F1 tag + F2 launch --tag) and cloudify
# (C1 .remote-vars + C2 install/run split + these k3s recipes).
#
# MUTATES the live tailnet ACL — throwaway tags only (k3s-prod, k3s-dev),
# snapshot taken in setup_file, teardown_file deletes nodes + tags and diffs
# the ACL back to the snapshot.
#
# Requirements (documented, not auto-checked beyond creds):
#   IVPS_BIN  — path to the stacked ivps branch binary (F1+F2+F3). Default ~/tmp/k3s-e2e/ivps-stack
#   cloudify  — the local branch CLI (run from the repo dir, PATH must include it)
#   TS_SERVICE_API_KEY + TS_DOMAIN in ~/.config/ivps/config.env (ACL-write scope)
#
# Run: PATH="$PWD:$HOME/tmp/k3s-e2e:$PATH" IVPS_BIN=$HOME/tmp/k3s-e2e/ivps-stack bats tests/e2e/k3s-multi-cluster.bats

IVPS_BIN="${IVPS_BIN:-$HOME/tmp/k3s-e2e/ivps-stack}"
REMOTE="cloudai"
PROD_SERVER="k3s-prod-1"; PROD_AGENT="k3s-prod-2"
DEV_SERVER="k3s-dev-1";  DEV_AGENT="k3s-dev-2"
TAG_PROD="k3s-prod"; TAG_DEV="k3s-dev"
TOKEN_PROD="k3s-token-prod-$(date +%s)"
TOKEN_DEV="k3s-token-dev-$(date +%s)"
TOKEN_PROD_NEW="k3s-token-prod-rotated-$(date +%s)"
TEST_SSH="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
WD="$HOME/tmp/k3s-e2e"
CLOUDIFY_CMD="cloudify --no-defaults"
VERIFY_TIMEOUT="PKG_VERIFY_TIMEOUT=300"
NODES="$PROD_SERVER $PROD_AGENT $DEV_SERVER $DEV_AGENT"

setup_file() {
    export PATH="$HOME/.local/bin:$PATH"
    local cfg="$HOME/.config/ivps/config.env"
    TS_KEY=$(awk -F= '/^TS_SERVICE_API_KEY=/{sub(/^TS_SERVICE_API_KEY=/,""); gsub(/"/,""); print}' "$cfg" 2>/dev/null)
    TS_DOMAIN=$(awk -F= '/^TS_DOMAIN=/{sub(/^TS_DOMAIN=/,""); gsub(/"/,""); print}' "$cfg" 2>/dev/null)
    [ -n "$TS_KEY" ] && [ -n "$TS_DOMAIN" ] || { echo "FAIL: TS creds missing in $cfg"; return 1; }
    export TS_KEY TS_DOMAIN
    [ -x "$IVPS_BIN" ] || { echo "FAIL: IVPS_BIN not found: $IVPS_BIN"; return 1; }
    # Snapshot the pristine ACL (restore reference)
    curl -sS -H "Authorization: Bearer $TS_KEY" -H "Accept: application/json" \
        "https://api.tailscale.com/api/v2/tailnet/${TS_DOMAIN}/acl" > "$WD/acl-pre.json"
    jq -e . "$WD/acl-pre.json" >/dev/null
}

teardown_file() {
    echo "── teardown: nodes, tags, ACL diff ──"
    for n in $NODES; do "$IVPS_BIN" delete "$REMOTE:$n" >/dev/null 2>&1 || echo "  ($n already gone)"; done
    "$IVPS_BIN" tag delete "$TAG_PROD" >/dev/null 2>&1 || true
    "$IVPS_BIN" tag delete "$TAG_DEV" >/dev/null 2>&1 || true
    curl -sS -H "Authorization: Bearer $TS_KEY" -H "Accept: application/json" \
        "https://api.tailscale.com/api/v2/tailnet/${TS_DOMAIN}/acl" > "$WD/acl-post.json"
    if diff <(jq -S . "$WD/acl-pre.json") <(jq -S . "$WD/acl-post.json") >/dev/null 2>&1; then
        echo "  ACL CLEAN — identical to pre-test snapshot"
    else
        echo "  WARNING: ACL differs from pre-test snapshot — inspect $WD/acl-pre.json vs acl-post.json"
    fi
}

@test "F1+F2: tag create + launch 4 tagged nodes" {
    run "$IVPS_BIN" tag create "$TAG_PROD"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$IVPS_BIN" tag create "$TAG_DEV"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for n in $NODES; do
        case "$n" in
            k3s-prod-*) launch_tag="$TAG_PROD" ;;
            k3s-dev-*)  launch_tag="$TAG_DEV" ;;
        esac
        "$IVPS_BIN" launch "$REMOTE:$n" --tag "$launch_tag" >/dev/null 2>&1 &
    done
    wait
    for n in $NODES; do
        run "$IVPS_BIN" list
        echo "$output" | grep -q "$n" || { echo "  $n not listed"; return 1; }
    done
}

@test "push branch code (cloudify + k3s recipes) into each node" {
    for n in $NODES; do
        echo "── pushing branch code to $n"
        $TEST_SSH "root@$n" "mkdir -p /root/cloudify" || return 1
        tar czf - lib pkg cloudify Taskfile.yml \
            | $TEST_SSH "root@$n" "tar xzf - -C /root/cloudify" || return 1
        $TEST_SSH "root@$n" "touch /root/cloudify/.#last_update" || return 1
    done
}

@test "prod cluster: k3s-server installs and is Ready at its tailscale IP" {
    run env K3S_TOKEN="$TOKEN_PROD" $VERIFY_TIMEOUT $CLOUDIFY_CMD --on "$PROD_SERVER" install k3s-server
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run $TEST_SSH "root@$PROD_SERVER" \
        '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes -o wide'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    echo "$output" | grep -q " Ready " || { echo "$output"; return 1; }
    echo "$output" | grep -q "100\." || { echo "$output"; return 1; }
}

@test "prod cluster: k3s-agent joins the server across the tag mesh" {
    local dns
    dns=$($TEST_SSH "root@$PROD_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_TOKEN="$TOKEN_PROD" K3S_URL="https://$dns:6443" $VERIFY_TIMEOUT \
        $CLOUDIFY_CMD --on "$PROD_AGENT" install k3s-agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run $TEST_SSH "root@$PROD_SERVER" \
        '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers'
    [ "$(echo "$output" | grep -c " Ready ")" -eq 2 ] || { echo "$output"; return 1; }
}

@test "dev cluster: k3s-server + agent form an isolated cluster" {
    run env K3S_TOKEN="$TOKEN_DEV" $VERIFY_TIMEOUT $CLOUDIFY_CMD --on "$DEV_SERVER" install k3s-server
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local dns
    dns=$($TEST_SSH "root@$DEV_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_TOKEN="$TOKEN_DEV" K3S_URL="https://$dns:6443" $VERIFY_TIMEOUT \
        $CLOUDIFY_CMD --on "$DEV_AGENT" install k3s-agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run $TEST_SSH "root@$DEV_SERVER" \
        '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers'
    [ "$(echo "$output" | grep -c " Ready ")" -eq 2 ] || { echo "$output"; return 1; }
}

@test "k3s-cli: both contexts merged, kubectl --context works" {
    local dns_prod dns_dev
    dns_prod=$($TEST_SSH "root@$PROD_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    dns_dev=$($TEST_SSH "root@$DEV_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_SERVER="$dns_prod" K3S_CONTEXT="k3s-prod" $CLOUDIFY_CMD install k3s-cli
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run env K3S_SERVER="$dns_dev" K3S_CONTEXT="k3s-dev" $CLOUDIFY_CMD install k3s-cli
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run kubectl --context k3s-prod get nodes --no-headers
    [ "$(echo "$output" | grep -c " Ready ")" -eq 2 ] || { echo "$output"; return 1; }
    run kubectl --context k3s-dev get nodes --no-headers
    [ "$(echo "$output" | grep -c " Ready ")" -eq 2 ] || { echo "$output"; return 1; }
}

@test "isolation: prod nodes cannot reach dev nodes on 6443 (and vice versa)" {
    local dev_ip prod_ip
    dev_ip=$($TEST_SSH "root@$DEV_SERVER" 'tailscale ip -4')
    prod_ip=$($TEST_SSH "root@$PROD_SERVER" 'tailscale ip -4')
    run $TEST_SSH "root@$PROD_SERVER" "timeout 4 bash -c 'echo > /dev/tcp/$dev_ip/6443' 2>/dev/null"
    [ "$status" -ne 0 ] || { echo "prod→dev 6443 reachable — isolation BROKEN"; return 1; }
    run $TEST_SSH "root@$DEV_SERVER" "timeout 4 bash -c 'echo > /dev/tcp/$prod_ip/6443' 2>/dev/null"
    [ "$status" -ne 0 ] || { echo "dev→prod 6443 reachable — isolation BROKEN"; return 1; }
}

@test "rotation: configure prod server + agent with a new token, cluster stays Ready" {
    run env K3S_TOKEN="$TOKEN_PROD_NEW" $VERIFY_TIMEOUT $CLOUDIFY_CMD --on "$PROD_SERVER" configure k3s-server
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local dns
    dns=$($TEST_SSH "root@$PROD_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_TOKEN="$TOKEN_PROD_NEW" K3S_URL="https://$dns:6443" $VERIFY_TIMEOUT \
        $CLOUDIFY_CMD --on "$PROD_AGENT" configure k3s-agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run $TEST_SSH "root@$PROD_SERVER" \
        '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers'
    [ "$(echo "$output" | grep -c " Ready ")" -eq 2 ] || { echo "$output"; return 1; }
}
