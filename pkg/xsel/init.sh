[ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get -q update                          
sudo apt install xsel
sudo apt xauth                           # needed to SSH forward X11 clipboard
without  

