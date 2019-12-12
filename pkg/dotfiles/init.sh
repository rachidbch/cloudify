#!/bin/bash

# clone dotfiles repo
# =todo= authorization needed as long as we have ssh package in dotfiles!
# =todo= remove ssh package from dotfiles!
[ -d ~/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ~/dotfiles

# Stow!
sudo apt-get -q install stow
( cd ~/dotfiles; bash ./stow/stowit )

# To simplify for now we don't use XDG_CONGIG dir. =todo= Use it?
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles

# This boilerplate below seems to be outdated has our dotfiles repo doesn't have an install.sh script anymore
# =todo= Remove?
# generate symlinks for softwares not respecting XDG Base Directory Spec.
# the script would not work if sourced, so we have to execute it
#chmod +x ${XDG_CONFIG_HOME:-~/.config}/dotfiles/install.sh
#source ${XDG_CONFIG_HOME:-~/.config}/dotfiles/install.sh
