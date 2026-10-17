#!/usr/bin/env bash
# One plain ssh session to the test target: stream the tree in, run bats
# there (non-tty => live TAP), stream it back, tear the run dir down; the
# SSH failures keep their exit status; local staging/report failures also fail.
# CLOUDIFY_TEST_TARGET defaults to cloudify.
# Usage: tests/remote-bats.sh <name> <bats args...>
set -euo pipefail
cd "$(dirname "$0")/.." || exit
name=${1:?usage: tests/remote-bats.sh <name> <bats args...>}; shift
target=${CLOUDIFY_TEST_TARGET:-cloudify}
printf -v bats_args ' %q' "$@"
mkdir -p results
report_dir=$(mktemp -d "results/$name.XXXXXXXX")
ln -sfn "${report_dir#results/}/report.tap" "results/$name.tap"
archive="$report_dir/tree.tar"
trap 'trash-put -- "$archive"' EXIT
tar -C . -cf "$archive" lib tests pkg schemas runbooks cloudify VERSION
set +e
# Arguments are deliberately expanded here after shell quoting, not on the target.
# shellcheck disable=SC2029
ssh "root@$target" "
      set -eu
      command -v trash-put
      d=\$(mktemp -d /root/cloudify-run-XXXXXX)
      trap 'trash-put -- \"\$d\"' EXIT
      tar -xf - -C \"\$d\"
      cd \"\$d\"
      if bats${bats_args} 9>&1; then rc=0; else rc=\$?; fi
      exit \$rc
    " < "$archive" 2>&1 | tee "$report_dir/report.tap"
pipeline_status=("${PIPESTATUS[@]}")
rc=${pipeline_status[0]}
if (( rc == 0 )); then rc=${pipeline_status[1]}; fi
exit "$rc"
