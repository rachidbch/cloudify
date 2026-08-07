#!/usr/bin/env bats
# LIVE e2e — k3s multi-cluster UX validation (Phase 3, plan k3s-multi-cluster).
# Two mutually-isolated k3s clusters (prod ∥ dev) on throwaway tailnet-tagged
# nodes. ivps (tag create + acl grant + launch --tag) manages identity/policy;
# cloudify (C1 .remote-vars + C2 install/run split + these k3s recipes)
# installs and configures k3s.
#
# MUTATES the live tailnet ACL — throwaway tags only (k3s-prod, k3s-dev),
# snapshot taken in setup_file, teardown_file deletes nodes -> revokes grants
# -> deletes tags and diffs the ACL back to the snapshot.
#
# Requirements (documented, not auto-checked beyond creds):
#   IVPS_BIN  — path to the ivps binary (main, with tag + acl support). Default ~/tmp/k3s-e2e/ivps-stack
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
CLOUDIFY_CMD="cloudify --no-defaults --no-verify"
# k3s node-ready poll (max 900s = 15min per node, 30s interval)
_k3s_poll_ready() {
    local host="$1" expected="${2:-1}"
    local n=0 max=30
    while [ $n -lt $max ]; do
        local out
        out=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@$host" \
            '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null') || { n=$((n+1)); sleep 30; continue; }
        local ready_count
        ready_count=$(echo "$out" | grep -c " Ready ")
        [ "$ready_count" -ge "$expected" ] && return 0
        n=$((n+1))
        sleep 30
    done
    echo "TIMEOUT: $host expected $expected Ready nodes after ${max}x30s, got:" >&2
    ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "root@$host" \
        '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null || echo kubectl-failed' >&2
    return 1
}
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
    echo "── teardown: nodes, grants, tags, ACL diff ──"
    for n in $NODES; do "$IVPS_BIN" delete "$REMOTE:$n" >/dev/null 2>&1 || echo "  ($n already gone)"; done
    "$IVPS_BIN" acl revoke "tag:$TAG_PROD" >/dev/null 2>&1 || true
    "$IVPS_BIN" acl revoke "tag:$TAG_DEV" >/dev/null 2>&1 || true
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

@test "tag + acl: create tags, grant mesh + operator, launch 4 nodes" {
    # Identity: create tags (tagOwners + authkey; no grants)
    run "$IVPS_BIN" tag create "$TAG_PROD"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$IVPS_BIN" tag create "$TAG_DEV"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Policy: mesh grant (nodes can talk to each other on k3s ports)
    run "$IVPS_BIN" acl grant "tag:$TAG_PROD" --src "tag:$TAG_PROD" --port 6443,8472
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$IVPS_BIN" acl grant "tag:$TAG_DEV" --src "tag:$TAG_DEV" --port 6443,8472
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Policy: operator grant + ssh.dst (workstation + mobile can reach nodes)
    run "$IVPS_BIN" acl grant "tag:$TAG_PROD" --src "tag:workstation,tag:mobile" --ssh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$IVPS_BIN" acl grant "tag:$TAG_DEV" --src "tag:workstation,tag:mobile" --ssh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Launch nodes into their tags
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
        echo "── waiting for MagicDNS: $n"
        local ok=false
        for _ in $(seq 1 18); do
            if getent hosts "$n" >/dev/null 2>&1; then ok=true; break; fi
            sleep 5
        done
        $ok || { echo "  $n never resolved via MagicDNS"; return 1; }
        echo "── pushing branch code to $n ($(getent hosts "$n" | awk '{print $1}'))"
        $TEST_SSH "root@$n" "mkdir -p /root/cloudify" || return 1
        tar czf - lib pkg cloudify Taskfile.yml \
            | $TEST_SSH "root@$n" "tar xzf - -C /root/cloudify" || return 1
        # Symlink cloudify into PATH (normally done by the bootstrap gist)
        $TEST_SSH "root@$n" "ln -sf /root/cloudify/cloudify /usr/local/bin/cloudify" || return 1
        # Install jq (needed by k3s-agent test for tailscale status parsing)
        $TEST_SSH "root@$n" "apt-get update -qq && apt-get install -y -qq jq" || return 1
        $TEST_SSH "root@$n" "touch /root/cloudify/.#last_update" || return 1
    done
}

@test "prod cluster: k3s-server installs and is Ready at its tailscale IP" {
    run env K3S_TOKEN="$TOKEN_PROD" $CLOUDIFY_CMD --on "$PROD_SERVER" install k3s-server
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _k3s_poll_ready "$PROD_SERVER" 1 || return 1
    run $TEST_SSH "root@$PROD_SERVER" \
        '/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes -o wide'
    echo "$output" | grep -q "100\." || { echo "$output"; return 1; }
}

@test "prod cluster: k3s-agent joins the server across the tag mesh" {
    local dns
    dns=$($TEST_SSH "root@$PROD_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_TOKEN="$TOKEN_PROD" K3S_URL="https://$dns:6443" \
        $CLOUDIFY_CMD --on "$PROD_AGENT" install k3s-agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _k3s_poll_ready "$PROD_SERVER" 2 || return 1
}

@test "dev cluster: k3s-server + agent form an isolated cluster" {
    run env K3S_TOKEN="$TOKEN_DEV" $CLOUDIFY_CMD --on "$DEV_SERVER" install k3s-server
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _k3s_poll_ready "$DEV_SERVER" 1 || return 1
    local dns
    dns=$($TEST_SSH "root@$DEV_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_TOKEN="$TOKEN_DEV" K3S_URL="https://$dns:6443" \
        $CLOUDIFY_CMD --on "$DEV_AGENT" install k3s-agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _k3s_poll_ready "$DEV_SERVER" 2 || return 1
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
    run env K3S_TOKEN="$TOKEN_PROD_NEW" $CLOUDIFY_CMD --on "$PROD_SERVER" configure k3s-server
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local dns
    dns=$($TEST_SSH "root@$PROD_SERVER" 'tailscale status --json | jq -r .Self.DNSName' | sed 's/\.$//')
    run env K3S_TOKEN="$TOKEN_PROD_NEW" K3S_URL="https://$dns:6443" \
        $CLOUDIFY_CMD --on "$PROD_AGENT" configure k3s-agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _k3s_poll_ready "$PROD_SERVER" 2 || return 1
}
