# Emacs 26 (non-X version)

if ! grep -q "^deb .*kelleyk/emacs" /etc/apt/sources.list.d/*; then
  sudo add-apt-repository ppa:kelleyk/emacs -y
  sudo apt-get -q update
fi
pkg_apt-install emacs26-nox                 

