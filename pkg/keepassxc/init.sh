#!/usr/bin/env bash
# Keepassxc
# Crucially Keepassxc features a commmand line tool: keepassxc-cli

add-apt-repository ppa:phoerious/keepassxc -y
apt-get install -y keepassxc

# Install kip
(
  [ -d ~/tmp ] || mkdir ~/tmp
  [ -d ~/tmp/kip ] && rm -rf ~/tmp/kip
  cd ~/tmp || exit 1
  git clone "https://gitlab.com/rachidbch/kip.git"
  cd kip || exit 1
  sudo install -m755 ./kip /usr/local/bin/
)
