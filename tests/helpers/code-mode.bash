#!/usr/bin/env bash
# tests/helpers/code-mode.bash - how a dispatch target obtains the cloudify
# code its payload runs. One switch, three modes:
#
#   CLOUDIFY_TEST_CODE_MODE=push (default)
#       Pin the payload's update marker, then push THIS working tree over the
#       target's checkout (tar over ssh). No GitHub round trip - the default
#       for tests: what runs on the target is exactly what is being tested.
#   CLOUDIFY_TEST_CODE_MODE=github
#       The target's checkout resets to its origin's default branch (GitHub is
#       the source of truth; the branch state there is what gets tested).
#   CLOUDIFY_TEST_CODE_MODE=branch:<name>
#       The target's checkout resets to origin/<name> - push the branch to
#       GitHub first.
#
# Sourced by the e2e suites; requires ssh root@<host> reachability and, when
# the target has no checkout yet, `cloudify` on PATH with remote credentials
# (the first dispatch bootstraps the repo through the normal payload).

tests_code_mode() { printf '%s' "${CLOUDIFY_TEST_CODE_MODE:-push}"; }

tests_code_ssh() { # <host> <command...>
    ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 "root@$1" "${@:2}"
}

# tests_code_prepare <host> - bring the target's cloudify checkout to the
# mode's state; returns non-zero (named) on any failure.
tests_code_prepare() {
    local host="$1" mode ref
    mode=$(tests_code_mode)

    # Bootstrap once through the normal payload when the target has no
    # checkout yet. The dispatch itself may fail (nothing is installed); the
    # cloned repo is what this step wants.
    if ! tests_code_ssh "$host" 'test -d /root/cloudify' 2>/dev/null; then
        cloudify --on "$host" verify fixture-split >/dev/null 2>&1 || true
        tests_code_ssh "$host" 'test -d /root/cloudify' 2>/dev/null \
            || { echo "tests_code_prepare: $host did not bootstrap a checkout" >&2; return 1; }
    fi

    case "$mode" in
        push)
            # Pin the freshness marker first: the payload's own update step
            # must not git-pull over the tree about to be pushed.
            tests_code_ssh "$host" 'touch /root/cloudify/.#last_update' || return 1
            tar czf - lib pkg schemas runbooks cloudify Taskfile.yml \
                | tests_code_ssh "$host" 'tar xzf - -C /root/cloudify' \
                || { echo "tests_code_prepare: cannot push the tree to $host" >&2; return 1; }
            # The symlink the bootstrap gist normally maintains.
            tests_code_ssh "$host" 'ln -sf /root/cloudify/cloudify /usr/local/bin/cloudify' || return 1
            tests_code_ssh "$host" \
                'grep -q _cloudify_vars_raw_encode /root/cloudify/lib/vars.sh' \
                || { echo "tests_code_prepare: $host is not running this checkout" >&2; return 1; }
            ;;
        github)
            tests_code_ssh "$host" \
                'cd /root/cloudify && git fetch -q origin && git remote set-head origin -a >/dev/null && git reset -q --hard origin/HEAD' \
                || { echo "tests_code_prepare: cannot reset $host to the default branch" >&2; return 1; }
            ;;
        branch:*)
            ref="${mode#branch:}"
            [[ -n "$ref" ]] || { echo "tests_code_prepare: branch: needs a name" >&2; return 1; }
            tests_code_ssh "$host" \
                "cd /root/cloudify && git fetch -q origin && git checkout -q -B '$ref' 'origin/$ref'" \
                || { echo "tests_code_prepare: cannot put $host on origin/$ref (pushed?)" >&2; return 1; }
            ;;
        *)
            echo "tests_code_prepare: unknown CLOUDIFY_TEST_CODE_MODE '$mode' (push | github | branch:<name>)" >&2
            return 1
            ;;
    esac
}
