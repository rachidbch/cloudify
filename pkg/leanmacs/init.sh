# Emacs 

# Declare dependency packages
WRKFY_PKG_DEPS fzf sqlite3

# emacs install
if ! grep -q "^deb .*kelleyk/emacs" /etc/apt/sources.list.d/*; then
  sudo add-apt-repository ppa:kelleyk/emacs -y
  sudo apt-get -q update
fi

sudo apt-get -q install emacs26-nox -y  #non-X version

if [[ -d ~/dotfiles/emacs/.lean.emacs.d ]]; then
 if [[ -d ~/.emacs.d && ! -L ~/.emacs.d ]]; then
  echo "Warning: ~/.emacs.d directory found. Backing it up before symlinking to dotfiles"
  mv ~/.emacs.d ~/.emacs.d.bak 
 fi
 ln -nsf ~/.lean.emacs.d ~/.emacs.d
else
  echo "Warning: Bash no dotfiles found"
fi

