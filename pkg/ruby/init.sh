if ! grep -q "^deb .*rael-gc/rvm" /etc/apt/sources.list.d/*; then
  sudo apt-add-repository -y ppa:rael-gc/rvm
  sudo apt-get -q update
fi
sudo apt-get -q install rvm -y
