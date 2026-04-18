#!/usr/bin/env bash
# Install mise (polyglot runtime manager: node, python, go, etc.)
# https://mise.jdx.dev

pkg_apt_install curl

curl -sSL https://mise.run | sh

# shellcheck disable=SC2016 # single quotes are intentional: pkg_in_startuprc writes literal strings to .bashrc
pkg_in_startuprc \
    '## MISE ENV SETUP'\
    'eval "$(~/.local/bin/mise activate bash)"'
