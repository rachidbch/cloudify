# notes: release links
#   - v0.8.10  Linux 64 : https://dev.mysql.com/get/mysql-apt-config_0.8.10-1_all.deb

# download bat deb in ~/workstation/install/deb
curl -LSs "https://dev.mysql.com/get/mysql-apt-config_0.8.10-1_all.deb" > mysql.deb

# install mysql deb
sudo apt-get -q update
sudo apt-get -q install ./mysql.deb -y
