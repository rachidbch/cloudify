# Fasd

if ! grep -q "^deb .*aacebedo/fasd" /etc/apt/sources.list.d/*; then
  sudo add-apt-repository ppa:aacebedo/fasd -y
  sudo apt-get -q update 
fi
sudo apt-get -q install fasd  -y


