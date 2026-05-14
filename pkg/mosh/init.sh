#!/usr/bin/env bash
# Mosh server

# Install mosh
pkg_apt_install mosh

# Disable verbose login (the login message messes w/ mosh protocol)
touch ~/.hushlogin

# Configure and generate UTF-8 locale if not already present
if ! locale -a 2>/dev/null | grep -qi 'en_US.utf'; then
    sudo locale-gen en_US.UTF-8
fi
