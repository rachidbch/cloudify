#!/usr/bin/env bash
# Fasd

pkg_apt_repository "aacebedo/fasd"
pkg_apt_install fasd


# Remove this
# if ! grep -q "^deb .*aacebedo/fasd" /etc/apt/sources.list.d/*; then
#   sudo add-apt-repository ppa:aacebedo/fasd -y
#   sudo apt-get -q update 
# fi


