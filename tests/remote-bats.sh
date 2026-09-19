#!/usr/bin/env bash
# One plain ssh session to the test target: stream the tree in, run bats
# there (non-tty => live TAP), stream it back, tear the run dir down; the
# ssh exit is the run's exit. CLOUDIFY_TEST_TARGET defaults to cloudify.
# Usage: tests/remote-bats.sh <name> <bats args...>
set -u
cd "$(dirname "$0")/.."
name=${1:?usage: tests/remote-bats.sh <name> <bats args...>}; shift
target=${CLOUDIFY_TEST_TARGET:-cloudify}
mkdir -p "results/$name"
set +e
tar -C . -cf - lib tests pkg schemas runbooks cloudify 2>/dev/null \
  | ssh "$target" "
      set -u
      d=\$HOME/cloudify-run
      rm -rf \"\$d\" && mkdir -p \"\$d\"
      tar -xf - -C \"\$d\"
      cd \"\$d\"
      sudo -n env HOME=/root bats $*
      rc=\$?
      sudo -n rm -rf \"\$d\"
      exit \$rc
    " 2>&1 | tee "results/$name.tap"
rc=${PIPESTATUS[1]}
exit "$rc"
