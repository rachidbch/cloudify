#!/usr/bin/env bash
pkg_verify() {
    grep -q "INSTALL_RAN" /tmp/fixture-split-log &&
        grep -q "CONFIGURE_RAN" /tmp/fixture-split-log
}
