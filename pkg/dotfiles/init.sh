# Dotfiles Install 

# To simplify for now we don't use XDG_CONGIG dir. Use it? 
#[ -d ~/.config/dotfiles ] || git clone https://gitlab.com/mobilefirstcentury/dotfiles.git ${XDG_CONFIG_HOME:-~/.config}/dotfiles
echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaa
pkg_depends stow 

# Clone cloudfiles repo
if [ -d "$HOME"/.dotfiles ]; then
  PKG_DEBUG 'Updating dotfiles'
  ( cd "$HOME"/.dotfiles;   
      echo "just before git pull"
      #git pull --recurse-submodules 
      git pull 
      echo "just after git pull"
      git submodule update --recursive --remote  
  )
else
  PKG_DEBUG_LN "Downloading dotfiles"
  git clone --recurse-submodules https://gitlab.com/mobilefirstcentury/dotfiles.git  "$HOME"/.dotfiles
  ( cd "$HOME"/.dotfiles; git submodule update --recursive --remote )
fi

PKG_DEBUG "Installing stowit"
ln -sfn "$HOME"/.dotfiles/stow/stowit "$HOME"/.local/bin/stowit
ln -sfn "$HOME"/.dotfiles/stow/unstowit "$HOME"/.local/bin/unstowit

PKG_DEBUG "Setting up dotfiles with stow"
"$HOME"/.local/bin/stowit



