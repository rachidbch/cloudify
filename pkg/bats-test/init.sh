#!/usr/bin/env bash
# Bats testing framework with assertion libraries
# Used by cloudify's own test suite
#
# bats-core is pinned to 1.13.0 (the version the dev machines run) and
# installed from the release tarball: apt's 1.10.0 predates parser fixes
# (herestrings inside @test bodies, multi-word --filter), and the version
# skew silently changed which test files parse where - tests must mean the
# same thing on every machine that runs them.

pkg_apt_install bats-assert bats-support bats-file

set -e
curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v1.13.0.tar.gz -o /tmp/bats-core.tgz
tar -xzf /tmp/bats-core.tgz -C /tmp
/tmp/bats-core-1.13.0/install.sh /usr/local
rm -rf /tmp/bats-core.tgz /tmp/bats-core-1.13.0
