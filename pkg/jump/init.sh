#!/usr/bin/env bash
# Install latest jump release from GitHub
pkg_depends jq
pkg_install_release jump "gsamokovarov/jump"

# shellcheck disable=SC2016 # single quotes are intentional: pkg_in_startuprc writes literal strings to .bashrc
pkg_in_startuprc \
    '## JUMP ENV SETUP'\
    'eval "$(jump shell bash)"'
