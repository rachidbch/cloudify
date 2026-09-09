#!/usr/bin/env bash
# Human-readable test report. Writes to fd 9 when the runner opened it, so lines
# stream live while bats runs; otherwise stdout (bats-captured, shown on failure
# or with --show-output-of-passing-tests).

_rpt() {
    if [[ -e /dev/fd/9 ]]; then
        printf '%s\n' "$*" >&9
    else
        printf '%s\n' "$*"
    fi
}

rubric() { _rpt "[$(date +%H:%M:%S)] ==== $* ===="; }
subrubric() { _rpt "[$(date +%H:%M:%S)]   -- $*"; }
step() { _rpt "[$(date +%H:%M:%S)]      $*"; }
