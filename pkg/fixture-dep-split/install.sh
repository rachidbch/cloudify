#!/usr/bin/env bash
# Test fixture: split pkg whose install.sh pulls a dependency.
# Regression guard for the pkg_depends local-var leak (pkg not declared
# local) that silently skipped configure.sh when a dep ran first.

pkg_depends fixture-legacy

echo "DEP_SPLIT_INSTALL_RAN" >> /tmp/fixture-dep-split-log
