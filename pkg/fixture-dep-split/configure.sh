#!/usr/bin/env bash
# Run phase: must run after install.sh even though install.sh pulled a dep.
echo "DEP_SPLIT_CONFIGURE_RAN" >> /tmp/fixture-dep-split-log
