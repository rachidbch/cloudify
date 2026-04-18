#!/usr/bin/env bash
# =warning= Mariadb is a drop-in replacement of MySQL and as such can't be installed alongside Mysql 
#           However you [it's still possible to have it installed alongside Mysql](https://mariadb.com/kb/en/installing-mariadb-alongside-mysql/)

# =note= Mysql and Mariadb can't be installed alongside
if [ -z "$(command -v "mysql" 2>&1)"  ]  && [ -z "$(command -v "mariadb" 2>&1)"  ] ; then
  [ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get -q update 

  # =todo= Prefer installation with curl (just like mysql) for maximum flexibility
  #        BUT I didn't find anywhere how to do it. Not sure it's possible ...
  #        What is feasible is to use an official script for the installation
  #        See [here](https://blog.dbi-services.com/how-to-install-a-specific-version-of-mariadb/) 
  #        More details [here](https://mariadb.com/kb/en/installing-mariadb-deb-files/)
           
  # =todo= Check if deb installation via curl poses dependency problems ... (See [here][https://askubuntu.com/questions/92019/how-to-install-specific-ubuntu-packages-with-exact-version)

  sudo apt-get -q install mariadb-server -y

  # =todo= Still need to secure the install by running mysql_secure_installation unnatended
  # Copy code from [here](https://hackviking.com/2015/02/03/auto-config-mysql/)
fi
