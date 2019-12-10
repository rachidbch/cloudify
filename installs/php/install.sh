# PHP
# ====

set -e

echo "installing php ..."
# PHP doesn\'t necessitate rbm version management system as it is build to be backward compatible.
# dependencies management is done per project directory using composer

sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update
sudo apt-get install php -y
# [TODO] should install php 7.2 instead but no available repo for Ubuntu 17.10 (As it's not a LTS Ubuntu version)
#sudo apt-get install php7.2-cli -y
echo "php installation done!"

echo "installing phpbrew ..."
# However for learning purpose, we install phpbrew  (note that phpenv is a pyenv like alternative to phpbrew)
# phpbrew let us build any php version with any extension and switch between them
# however there's no automatic way to activate a per-project php version
# for each project, we have to:
#    1. $ cd <project dir>
#    2. $ phpbrew use <php-version>
#    3. $ work on the project
#    4. $ phpbrew off
# [TODO] write/steal a script activate/deactivate that activate the php version declared by composer.json
# see a [[https://www.gocit.vn/bai-viet/phpbrew-builds-and-installs-multiple-version-phps-in-your-home-directory/][phpbrew tuto here]]

[[ -d ~/temp ]] || mkdir ~/temp
cd ~/temp
curl -L -O https://github.com/phpbrew/phpbrew/raw/master/phpbrew
chmod +x phpbrew
# Move phpbrew to somewhere can be found by your $PATH
sudo mv phpbrew /usr/local/bin/phpbrew
cd -
phpbrew init

echo "phpbrew installation done!"
echo "installing composer ..."
# next we install composer using a script taken [[here][https://getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md]]
# we only modified the install dir and executable file name in the second last line

EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('SHA384', 'composer-setup.php');")"

if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE"  ]
then
    >&2 echo 'ERROR: Invalid installer signature'
    rm composer-setup.php
    exit 1
fi
LOCAL_BIN="/usr/local/bin"
sudo php composer-setup.php  --install-dir="$LOCAL_BIN" --filename=composer
RESULT=$?
rm composer-setup.php
echo "composer installation done!"
echo "installing psysh ..."
sudo chown -R $USER ~/.composer/                                # For some reason I had a permission denied because files from this fodler where owned by root  
composer g require psy/psysh:@stable
# this should install psysh in ~/.config/composer/vendor/bin. 
#That dir should be in the path
PATH="${PATH}:/home/${USER}/.config/composer/vendor/bin"
# install sqlite php driver needed to read manual doc from within psysh
sudo apt install php-sqlite3
# install php manual doc
wget -P ~/.local/share/psysh/ "http://psysh.org/manual/en/php_manual.sqlite"

echo "psysh installation done!"
exit $RESULT
