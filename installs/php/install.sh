PHP
====

# PHP doesn\'t necessitate rbm version management system as it is build to be backward compatible.
# dependencies management is done per project directory using composer

sudo apt install php
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

php composer-setup.php --quiet
RESULT=$?
rm composer-setup.php --install-dir="$LOCAL_BIN" --filename=composer
exit $RESULT
