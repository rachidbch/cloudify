#!/usr/bin/env bash
# Pipx Install

pkg_depends python 

# HACK!
# At least on Ubuntu 20.04, after install, pipx complain about ensurepip not beeing available
# Pipx error message recommends running "apt install python3_venv"
pkg_apt_install python3-venv 

# Install pipx

PKG_DEBUG_LN "Installing pipx "
python3 -m pip install --user pipx
python3 -m pipx ensurepath

