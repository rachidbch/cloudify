# Install latest release from Github 
#   =todo= Create a script inside ~/workify/scripts/that automate Install from Github releases
#   =todo= The script should have an argument to specify release to install (defaults to latest).
#          Use 'https://api.github.com/repos/USER/REPO/releases' to list all releases
#   =todo= Someday, when the script is created, decide if replacing it with 'https://github.com/archf/ghi/blob/master/ghi' is worthwhile

# Install Latest release from github
PKG_REPO_ID="github/hub"
PKG_CMD="hub"

WRKFY_DEBUG_MSG_NEWLINE "Retrieving $PKG_REPO_ID last release"
PKG_RELEASE_URL=$(curl -sSL "https://api.github.com/repos/${PKG_REPO_ID}/releases/latest" | jq -r ".assets[].browser_download_url" | grep -ie 'linux[-_]amd64' | grep -ie '\.tgz\|\.tar\.gz')
WRKFY_DEBUG_MSG_NEWLINE "Last release url: $PKG_RELEASE_URL"

if [[ ! -z "$PKG_CMD"  ]]; then 

  [[ -d /tmp/"$PKG_CMD" ]] && rm -rf /tmp/"$PKG_CMD"
  mkdir /tmp/"$PKG_CMD"

  WRKFY_DEBUG_MSG "Extracting $PKG_REPO_ID tgz archive. in /tmp/$PKG_CMD/"
  curl -sSL "$PKG_RELEASE_URL" | tar -C /tmp/"$PKG_CMD"  --strip-components=1  -xzf -
  WRKFY_DEBUG_MSG "Installing $PKG_REPO_ID in /usr/local/"

  # Some install archives have an install/setup script. 
  # If that's the case, let it do its thing
  (
    [[ -f /tmp/"$PKG_CMD"/install ]] && WRKFY_DEBUG_MSG "Running archive setup script" && sudo bash  /tmp/"$PKG_CMD"/install && exit 0
    [[ -f /tmp/"$PKG_CMD"/install.sh ]] && WRKFY_DEBUG_MSG "Running archive setup script" && sudo bash  /tmp/"$PKG_CMD"/install.sh && exit 0
    [[ -f /tmp/"$PKG_CMD"/setup ]] && WRKFY_DEBUG_MSG "Running archive setup script" && sudo bash  /tmp/"$PKG_CMD"/setup && exit 0
    [[ -f /tmp/"$PKG_CMD"/setup.sh ]] && WRKFY_DEBUG_MSG "Running archive setup script" && sudo bash  /tmp/"$PKG_CMD"/setup.sh && exit 0
     
    # The 'install' command doesn't have a recursive option. We use find as a workaround 
    # This will install each file in the archive at corresping path /usr/local
    # Note we excluding the first level, as this is the place of files, like LICENSE, that shouldn't be installed 
    (cd /tmp/"$PKG_CMD" && sudo find . -mindepth 2 -type f  -exec install -Dm 755 "{}" "/usr/local/{}" \;)
  )
  WRKFY_DEBUG_MSG "Discarding tmp/$PKG_CMD/"
  rm -rf "/tmp/${PKG_CMD}"
fi

# =INFO= When authenticating with gh, you'll be asked a username and a password.
#        For the password, use a PAT (Personnal Access Token) to create on Github.


## # Install latest release from Github (=snippet=)
## #   =todo= Create a script inside ~/cloudstation/scripts/that automate Install from Github releases
## #   =todo= The script should an argument to specify release to install (defaults to latest).
## #          Use 'https://api.github.com/repos/digitalocean/doctl/releases' to list all releases
## #   =todo= When script is created, someday decide if replacing it with 'https://github.com/archf/ghi/blob/master/ghi' is worthwhile
## 
## # Install Latest doctl from github
## PKG_REPO_ID="github/hub"
## PKG_CMD="hub"
## 
## PKG_RELEASE_URL=$(curl -sSL "https://api.github.com/repos/${PKG_REPO_ID}/releases/latest" | jq -r ".assets[].browser_download_url" | grep -ie 'linux[-_]amd64')
## 
## if [[ ! -z "$PKG_CMD"  ]]; then 
##   [[ -d /tmp/"$PKG_CMD" ]] && rm -rf /tmp/"$PKG_CMD"
##   mkdir /tmp/"$PKG_CMD"
##   curl -sSL "$PKG_RELEASE_URL" | tar -C /tmp/"$PKG_CMD"  --strip-components=1  -xzf -
##   sudo install -m755 "/tmp/${PKG_CMD}" "/usr/local/bin/${PKG_CMD}"
##   #rm "/tmp/${PKG_CMD}"
## fi
## 
## # =INFO= When authenticating with hub, you'll be asked a username and a password.
## #        For the password, use a PAT (Personnal Access Token) to create on Github.
