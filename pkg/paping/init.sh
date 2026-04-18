#!/usr/bin/env bash
# Ping for any port (replaces legacy paping with tcping-rs)
# Usage: tcping google.com 80
pkg_depends jq
pkg_install_release tcping "lvillis/tcping-rs"
