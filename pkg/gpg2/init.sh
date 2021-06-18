UBUNTU_VER="$(lsb_release -r | cut -f2)"
# =todo= From Ubuntu 18.04 and up, gnupg package *is* GnuPG 2 
if (( $(echo "$UBUNTU_VER < 18.04" | bc -l ))); then
    [ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get -q update
    sudo apt-get install gnupg2
    sudo mv /usr/bin/gpg /usr/bin/gpg1  
    sudo ln -ns /usr/bin/gpg2 /usr/bin/gpg
fi
