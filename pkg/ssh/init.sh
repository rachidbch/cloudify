[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get -q update
sudo apt install autossh
