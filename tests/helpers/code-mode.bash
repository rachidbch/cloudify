#!/usr/bin/env bash
# tests/helpers/code-mode.bash - how a dispatch target obtains the cloudify
# code its payload runs. One switch, three modes:
#
#   CLOUDIFY_TEST_CODE_MODE=push (default)
#       The local working tree goes to the target over ssh (tar), freshness
#       marker pinned so the payload's update step never pulls GitHub over
#       it. No GitHub round trip, no credentials: what runs on the target is
#       exactly what is being tested. Tests default here - same shape as the
#       unit runner (tar over one ssh) and the integration runner (ivps push).
#   CLOUDIFY_TEST_CODE_MODE=github
#       The target's checkout resets to its origin's default branch and every
#       dispatch pulls (CLOUDIFY_FORCE_UPDATE=true, no ref mandate): GitHub is
#       the source of truth; what is shipped is what is tested.
#   CLOUDIFY_TEST_CODE_MODE=branch:<name>
#       The target's checkout resets to origin/<name> (push the branch first)
#       and every dispatch holds it there (CLOUDIFY_FORCE_UPDATE=true and
#       CLOUDIFY_GIT_REF=<name> once the bootstrap gist honors the ref; the
#       reset alone holds it until then).
#
# Sourced by the e2e suites; requires ssh root@<host> reachability.

tests_code_mode() { printf '%s' "${CLOUDIFY_TEST_CODE_MODE:-push}"; }

tests_code_ssh() { # <host> <command...>
    ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 "root@$1" "${@:2}"
}

# tests_code_prepare <host> - bring the target's cloudify checkout to the
# mode's state and set the controller env the payload reads. Returns
# non-zero (named) on any failure. Call once per host before any dispatch.
tests_code_prepare() {
    local host="$1" mode ref
    mode=$(tests_code_mode)

    case "$mode" in
        push)
            # The pushed tree is the truth: no update step may pull over it.
            export CLOUDIFY_FORCE_UPDATE=false
            unset CLOUDIFY_GIT_REF
            tests_code_ssh "$host" 'mkdir -p /root/cloudify' || return 1
            # Pin the freshness marker first: the payload's update step must
            # not run its gist (pull/clone) over the tree about to be pushed.
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
            # Every dispatch pulls the origin's default branch; no ref mandate.
            export CLOUDIFY_FORCE_UPDATE=true
            export CLOUDIFY_GIT_REF=""
            if ! tests_code_ssh "$host" 'test -d /root/cloudify' 2>/dev/null; then
                cloudify --on "$host" verify fixture-split >/dev/null 2>&1 || true
                tests_code_ssh "$host" 'test -d /root/cloudify' 2>/dev/null \
                    || { echo "tests_code_prepare: $host did not bootstrap a checkout" >&2; return 1; }
            fi
            tests_code_ssh "$host" \
                'cd /root/cloudify && git fetch -q origin && git remote set-head origin -a >/dev/null && git reset -q --hard origin/HEAD' \
                || { echo "tests_code_prepare: cannot reset $host to the default branch" >&2; return 1; }
            ;;
        branch:*)
            ref="${mode#branch:}"
            [[ -n "$ref" ]] || { echo "tests_code_prepare: branch: needs a name" >&2; return 1; }
            # Every dispatch pulls and holds the mandated branch.
            export CLOUDIFY_FORCE_UPDATE=true
            export CLOUDIFY_GIT_REF="$ref"
            if ! tests_code_ssh "$host" 'test -d /root/cloudify' 2>/dev/null; then
                cloudify --on "$host" verify fixture-split >/dev/null 2>&1 || true
                tests_code_ssh "$host" 'test -d /root/cloudify' 2>/dev/null \
                    || { echo "tests_code_prepare: $host did not bootstrap a checkout" >&2; return 1; }
            fi
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
