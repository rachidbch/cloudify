#!/usr/bin/env bash
# Keepassxc 
# Crucially Keepassxc features a commmand line tool: keepassxc-cli

if ! grep -q "^deb .*phoerious/keepassxc" /etc/apt/sources.list.d/*; then
  sudo add-apt-repository ppa:phoerious/keepassxc -y
  sudo apt-get -q update 
fi
sudo apt-get -q install keepassxc  -y

# Install kip
(
  [ -d ~/tmp ] || mkdir ~/tmp
  [ -d ~/tmp/kip ] && rm -rf ~/tmp/kip
  cd ~/tmp || exit 1
  git clone "https://gitlab.com/rachidbch/kip.git"
  cd kip || exit 1
  sudo install -m755 ./kip /usr/local/bin/
)
