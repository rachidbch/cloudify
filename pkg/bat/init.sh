# bat utility 
# bat is better cat 

pkg_install_release bat "sharkdp/bat"

# # notes: release links
# BAT_TAG=0.12.1
# 
# [ -d ~/tmp ] || mkdir ~/tmp
# 
# # download bat deb in ~/workstation/install/deb
# # =todo= could be smarter by checking latest tag and comparing it with BAT_TAG (Another install script has the git vodoo to check the latest tag)
# curl -LSs "https://github.com/sharkdp/bat/releases/download/v${BAT_TAG}/bat_${BAT_TAG}_amd64.deb" > ~/tmp/bat.deb
# 
# # install bat
# sudo apt-get -q install ~/tmp/bat.deb -y
