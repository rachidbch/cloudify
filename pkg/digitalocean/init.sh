
# Install latest release from Github (=snippet=)
#   =todo= Create a script inside ~/cloudstation/scripts/that automate Install from Github releases
#   =todo= The script should an argument to specify release to install (defaults to latest).
#          Use 'https://api.github.com/repos/digitalocean/doctl/releases' to list all releases
#   =todo= When script is created, someday decide if replacing it with 'https://github.com/archf/ghi/blob/master/ghi' is worthwhile



# Install Latest doctl from github
PKG_REPO_ID="digitalocean/doctl"
PKG_CMD="doctl"

PKG_RELEASE_URL=$(curl -sSL "https://api.github.com/repos/${PKG_REPO_ID}/releases/latest" | jq -r ".assets[].browser_download_url" | grep -ie 'linux[-_]amd64')

curl -sSL "$PKG_RELEASE_URL" | tar -C /tmp/ -xzvf -
sudo install -m755 "/tmp/${PKG_CMD}" "/usr/local/bin/${PKG_CMD}"
rm "/tmp/${PKG_CMD}"


