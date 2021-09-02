# Rclone Installation 

pkg_depends jq
pkg_install_release rclone "rclone/rclone"

# Create a S3 Rclone remote in ~/.config/rclone/rclone.conf
PKG_DEBUG "${RED}Creating ${HOME}/.config/rclone/rclone.conf file"
cat $HOME/cloudify/pkg/rclone/rclone.conf | envsubst | tee ${HOME}/.config/rclone/rclone.conf &> /dev/null 
PKG_DEBUG "${RED}Created ${HOME}/.config/rclone/rclone.conf file"

## notes: release links
##    v1.43.1  Linux 64 : https://downloads.rclone.org/v1.43.1/rclone-v1.43.1-linux-amd64.deb
#
## download rclone deb in ~/workstation/install/deb
#curl -LSs "https://downloads.rclone.org/v1.43.1/rclone-v1.43.1-linux-amd64.deb" > rclone.deb
#
## install rclone
#sudo apt-get -q update
#sudo apt-get -q install ./rclone.deb
#
## install megadown
#source "$WORKSTATION_DIR"/installs/megadown/install.sh
#
## to bootstrap the installation you need rclone passwords saved in  mega:BOOTSTRAP/rclone.conf
## fortunately mega can generate direct file urls but we need megadown script to downaload in a script (or on command line)
## download rclone.conf
#if [ ! -d "~/.config/rclone"  ]; then mkdir -p ~/.config/rclone; fi
#megadown 'https://mega.nz/#!5FwRwA6a!V2Z4JUDPuQ_C0INzyLO4hzdfrvFIx-51mo7AzepPGng' -o ~/.config/rclone/rclone.conf
#
## sets up autompletion for bash shell
#sudo rclone genautocomplete bash
