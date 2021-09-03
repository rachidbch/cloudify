
# Restic Installation 

pkg_depends rclone
pkg_install_release restic "restic/restic"

# Copy Restic scripts
# =NOTE= These are custom scripts that aim to ease restic use (in manual and cron mode) 

PKG_DEBUG "Creating /usr/local/bin/resticfy file"
#  Ensure it's owned by root:root and it can be executed by everybody but not modified or read
sudo cp $HOME/cloudify/restic/resticfy /usr/local/bin/resticfy
sudo chown root:root /usr/local/bin/resticfy
sudo chmod 711 /usr/local/bin/resticfy
PKG_DEBUG "Created /usr/local/bin/resticfy file"

PKG_DEBUG "Creating 'Default' restic backup Operation"
mkdir -p $HOME/.config/restic/Operations/Default/
touch $HOME/.config/restic/Operations/Default/whitelist
touch $HOME/.config/restic/Operations/Default/blacklist
[[ -f $HOME/.config/restic/Operations/Default/.repo ]] || echo "rclone:${CLOUDIFY_RCLONE_REMOTE:-default}:cloudify/$(hostname)" > $HOME/.config/restic/Operations/Default/.repo 
PKG_DEBUG "Created 'Default' restic backup Operation"

PKG_DEBUG "Creating Default Backup cron job"
sudo tee /etc/cron.daily/cloudify.backup <<EOF
logger 'BEGIN RESTIC'
export RESTIC_PASSWORD=${RESTIC_PASSWORD}
export RCLONE_TIMEOUT=50
/usr/local/bin/resticfy All rbc >> /var/log/cloudify.backup.log  2>&1
unset RESTIC_PASSWORD
logger 'END RESTIC'
EOF
#sudo chown root:root /etc/cron.d/backup.restic.sh
sudo chmod 700 /etc/cron.d/backup.restic.sh 
PKG_DEBUG "Created Default Backup cron job."

