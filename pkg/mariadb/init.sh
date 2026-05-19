#!/usr/bin/env bash
# =warning= Mariadb is a drop-in replacement of MySQL and as such can't be installed alongside Mysql
#           However you [it's still possible to have it installed alongside Mysql](https://mariadb.com/kb/en/installing-mariadb-alongside-mysql/)

# =note= Mysql and Mariadb can't be installed alongside

# --- Install guard ---
if command -v mariadb >/dev/null 2>&1 && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "mariadb already installed. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested ---
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_info "Clearing mariadb data..."
    sudo rm -rf /var/lib/mysql
fi

if [ -z "$(command -v "mysql" 2>&1)"  ]  && [ -z "$(command -v "mariadb" 2>&1)"  ] ; then
  apt-get install -y mariadb-server

  # =todo= Still need to secure the install by running mysql_secure_installation unnatended
  # Copy code from [here](https://hackviking.com/2015/02/03/auto-config-mysql/)
fi
