#!/usr/bin/env bash
# Core prerequisites that cloudify and other pkg recipes depend on

# Some stations come without proper locales
pkg_depends language-pack-en-base

# Required by cloudify package recipes (add-apt-repository, curl, etc.)
pkg_depends apt-transport-https ca-certificates curl gnupg-agent software-properties-common bc build-essential

# trash-cli is used by cloudify to safely delete files and directories
pkg_depends trash-cli
