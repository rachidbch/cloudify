#!/bin/bash

# clone dotfiles repo

[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles
# generate symlinks for softwares not respecting XDG Base Directory Spec.
# the script would not work if sourced, so we have to execute it
chmod +x ${XDG_CONFIG_HOME:-~/.config}/dotfiles/install.sh
source ${XDG_CONFIG_HOME:-~/.config}/dotfiles/install.sh
