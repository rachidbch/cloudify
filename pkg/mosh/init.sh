# Mosh server

# Install mosh
pkg_apt_install mosh

# Disable verbose login
# The login message messes w/ mosh protocole
touch ~/.hushlogin

# Steps are to be done only if mosh complaints about locales
# =todo= Find out if some of these steps can be left out.

# Edit default locale
mkdir -p ~/trash/etc/default
sudo tee /etc/default/locale &> /dev/null <<-'EOF'
	LANGUAGE=en_US.UTF-8
	LANG=en_US.UTF-8
	LC_ALL=en_US.UTF-8
EOF

# Generate locales
sudo locale-gen en_US.UTF-8
#sudo dpkg-reconfigure locales   # Then type `ENTER` twice

# sudo ufw allow mosh
# Enable mosh in UFW

