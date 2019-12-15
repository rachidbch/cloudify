[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get update
sudo apt install vim -y


