#!/usr/bin/env bash
# wezterm — GPU-accelerated terminal emulator
# https://wezfurlong.org/wezterm/
#
# Installs from GitHub releases .deb (Ubuntu 22.04 build, compatible with 24.04).
# The apt.fury.io repo is unreliable — direct .deb is more dependable.

WEZTERM_VERSION="20240203-110809-5046fc22"
WEZTERM_DEB="wezterm-${WEZTERM_VERSION}.Ubuntu22.04.deb"
WEZTERM_URL="https://github.com/wezterm/wezterm/releases/download/${WEZTERM_VERSION}/${WEZTERM_DEB}"

# Skip if already installed
command -v wezterm >/dev/null 2>&1 && exit 0

curl -LO "${WEZTERM_URL}"
pkg_apt_install "./${WEZTERM_DEB}"
rm -f "${WEZTERM_DEB}"
