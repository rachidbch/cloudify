#!/usr/bin/env bash
# Emacs 

# Declare dependency packages
pkg_depends fzf sqlite3 emacs26-nox

if [[ -d "$HOME"/.dotfiles/leanmacs/.leanmacs.d ]]; then
 if [[ -d ~/.emacs.d && ! -L ~/.emacs.d ]]; then
  echo "Warning: ~/.emacs.d directory found. Backing it up before symlinking to dotfiles"
  mv ~/.emacs.d ~/.emacs.d.bak 
 fi
 ln -sfn ~/.leanmacs.d ~/.emacs.d
else
  echo "Warning: No dotfiles found for leanmacs"
fi

# HACK!
# Emacs complains if org/roam folder doesn't exist.
# We may remove org-roam from leanmacs in the future. For the moment we force the creation of this folder
[[ -d "$HOME"/org/roam ]] || mkdir -p "$HOME"/org/roam
