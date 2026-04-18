#!/usr/bin/env bash
# Install latest Scaleway CLI release from GitHub
pkg_depends jq
pkg_install_release scw "scaleway/scaleway-cli"
