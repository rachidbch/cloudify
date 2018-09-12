# notes: release links
#   - v1.43.1  Linux 64 : https://github.com/sharkdp/bat/releases/download/v0.6.1/bat_0.6.1_amd64.deb

# download bat deb in ~/workstation/install/deb
curl -LSs "https://github.com/sharkdp/bat/releases/download/v0.6.1/bat_0.6.1_amd64.deb" > bat.deb

# install bat
sudo apt update
sudo apt install ./bat.deb -y
