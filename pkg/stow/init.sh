
dpkg -l stow |& grep -q "^ii  stow" || WRKFY_DEBUG_MSG_NEWLINE "Installing stow" && sudo apt-get -q install stow  -y
