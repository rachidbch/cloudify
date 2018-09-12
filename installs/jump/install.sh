# notes: release links
#   - v0.21.0  Linux 64 : https://github.com/gsamokovarov/jump/releases/download/v0.21.0/jump_0.21.0_amd64.deb

# download bat deb in ~/workstation/install/deb
rm ./jump.deb
curl -LSs "https://github.com/gsamokovarov/jump/releases/download/v0.21.0/jump_0.21.0_amd64.deb" > jump.deb

# install fd
sudo apt update
sudo apt install ./jump.deb -y

