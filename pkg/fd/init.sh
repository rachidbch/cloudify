# notes: release links
#   - v1.43.1  Linux 64 : https://github.com/sharkdp/fd/releases/download/v7.1.0/fd_7.1.0_amd64.deb

# download bat deb in ~/workstation/install/deb
curl -LSs "https://github.com/sharkdp/fd/releases/download/v7.1.0/fd_7.1.0_amd64.deb" > fd.deb

# install fd
sudo apt-get -q update
sudo apt-get -q install ./fd.deb -y

