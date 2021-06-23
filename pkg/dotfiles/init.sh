# Dotfiles Install 

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles

pkg_depends stow 

# Clone cloudfiles repo
if [ -d "$HOME"/.dotfiles ]; then
  PKG_DEBUG_LN "Updating dotfiles"
  ( cd "$HOME"/.dotfiles; git pull --recurse-submodules )
  ( cd "$HOME"/.dotfiles; git submodule update --recursive --remote )
else
  PKG_DEBUG_LN "Downloading dotfiles"
  git clone --recurse-submodules https://gitlab.com/mobilefirstcentury/dotfiles.git  "$HOME"/.dotfiles
  ( cd "$HOME"/.dotfiles; git submodule update --recursive --remote )
fi

PKG_DEBUG "Backuping .bashrc"
[[ -d "$HOME"/.backup ]] || mkdir "$HOME"/.backup 
mv "$HOME"/.backup/.bashrc.bak.4 "$HOME"/.backup/.bashrc.bak.5 2>/dev/null 
mv "$HOME"/.backup/.bashrc.bak.3 "$HOME"/.backup/.bashrc.bak.4 2>/dev/null
mv "$HOME"/.backup/.bashrc.bak.2 "$HOME"/.backup/.bashrc.bak.3 2>/dev/null
mv "$HOME"/.backup/.bashrc.bak  "$HOME"/.backup/.bashrc.bak.2 2>/dev/null
mv "$HOME"/.bashrc "$HOME"/.backup/.bashrc.bak

PKG_DEBUG "Installing stowit"
ln -nsf "$HOME"/.dotfiles/stow/stowit "$HOME"/.local/bin/stowit
ln -nsf "$HOME"/.dotfiles/stow/unstowit "$HOME"/.local/bin/unstowit

PKG_DEBUG "Setting up dotfiles with stow"
"$HOME"/.local/bin/stowit



