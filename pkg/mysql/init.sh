#!/usr/bin/env bash
# notes: release links
#   - v0.8.10  Linux 64 : https://dev.mysql.com/get/mysql-apt-config_0.8.10-1_all.deb

# =todo= Complete this installation from this [doc](https://www.digitalocean.com/community/tutorials/how-to-install-mariadb-on-ubuntu-20-04-fr)

# =note= Mysql and Mariadb can't be installed alongside

# --- Install guard ---
if command -v mysql >/dev/null 2>&1 && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "mysql already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing mysql data..."
    sudo rm -rf /var/lib/mysql
fi

if [ -z "$(command -v "mysql" 2>&1)"  ]  && [ -z "$(command -v "mariadb" 2>&1)"  ] ; then

  # download bat deb in ~/workstation/install/deb
  curl -LSs "https://dev.mysql.com/get/mysql-apt-config_0.8.10-1_all.deb" > mysql.deb

  # install mysql deb
  apt-get install -y ./mysql.deb

  # =todo= Still need to secure the install by running mysql_secure_installation unnatended
  # Copy code from [here](https://hackviking.com/2015/02/03/auto-config-mysql/)
fi




