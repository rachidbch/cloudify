
# Install latest release from Github (=snippet=)
#   =todo= Create a script inside ~/cloudstation/scripts/that automate Install from Github releases
#   =todo= The script should an argument to specify release to install (defaults to latest).
#          Use 'https://api.github.com/repos/digitalocean/doctl/releases' to list all releases
#   =todo= When script is created, someday decide if replacing it with 'https://github.com/archf/ghi/blob/master/ghi' is worthwhile

# Install Latest doctl from github
PKG_REPO_ID="github/hub"
PKG_CMD="hub"

PKG_RELEASE_URL=$(curl -sSL "https://api.github.com/repos/${PKG_REPO_ID}/releases/latest" | jq -r ".assets[].browser_download_url" | grep -ie 'linux[-_]amd64')

if [[ ! -z "$PKG_CMD"  ]]; then 
  [[ -d /tmp/"$PKG_CMD" ]] && rm -rf /tmp/"$PKG_CMD"
  mkdir /tmp/"$PKG_CMD"
  curl -sSL "$PKG_RELEASE_URL" | tar -C /tmp/"$PKG_CMD"  --strip-components=1  -xzf -
  sudo install -m755 "/tmp/${PKG_CMD}" "/usr/local/bin/${PKG_CMD}"
  #rm "/tmp/${PKG_CMD}"
fi

# =INFO= When authenticating with hub, you'll be asked a username and a password.
#        For the password, use a PAT (Personnal Access Token) to create on Github.
