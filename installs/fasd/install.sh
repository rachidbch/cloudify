# Fasd

if ! grep -q "^deb .*aacebedo/fasd" /etc/apt/sources.list.d/*; then
  sudo add-apt-repository ppa:aacebedo/fasd -y
  sudo apt-get update 
fi
sudo apt-get install fasd  -y


