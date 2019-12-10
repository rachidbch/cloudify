#SPACEMACS

# spacemacs install

if [[ -d ~/dotfiles/spacemacs/.spacemacs.d ]]; then
  if ! grep -q "^deb .*kelleyk/emacs" /etc/apt/sources.list.d/*; then
    sudo add-apt-repository ppa:kelleyk/emacs
    sudo apt update
  fi
  sudo apt install emacs26-nox -y #non-X version

  # spacemacs install
  [ -d ~/.spacemacs.emacs.d ] || git clone https://github.com/syl20bnr/spacemacs ~/.spacemacs.emacs.d
  rm -rf ~/.spacemacs.emacs.d/private
  ln -s ~/.spacemacs.d/private ~/.spacemacs.emacs.d/private

  # install some private layers
  git clone https://github.com/venmos/w3m-layer.git ~/.spacemacs.d/private/w3m

  # spacemacs bugs workarounds

  # 1. missing layers dir
  [ -d ~/.spacemacs.d/layers ] || mkdir ~/.spacemacs.d/layers

  # 2. ac-ispell package bug: see https://github.com/syl20bnr/spacemacs/issues/11095 
  git clone  https://github.com/syohex/emacs-ac-ispell.git ~/.spacemacs.d/private/emacs-ac-ispell
  # install package manually in spacemacs: SPC SPC package-install-file ~/.spacemacs.d/private/emacs-ac-ispell          ;; [TODO] automate

  # 3. yas snippets dirs warning: see https://github.com/syl20bnr/spacemacs/issues/10316
  # simply create an empty `snippets` directory in path indicated by warning message
  [ -d ~/.spacemacs.d/snippets ] || mkdir ~/.spacemacs.d/snippets

  if [[ -d ~/.emacs.d && ! -L ~/.emacs.d ]]; then
    echo "Warning: ~/.emacs.d directory found. Backing it up before symlinking to dotfiles"
    mv ~/.emacs.d ~/.emacs.d.bak
  fi
  ln -nsf ~/.spacemacs.emacs.d ~/.emacs.d
else
  echo "Warning: Bash no dotfiles found"
fi
