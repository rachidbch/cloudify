#!/bin/bash

# clone dotfiles repo
[ -d ~/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ~/dotfiles

# Stow!
sudo apt-get -q install stow
( cd ~/dotfiles; bash ./stow/stowit )

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles

