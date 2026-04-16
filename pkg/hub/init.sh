# Install latest hub release from GitHub

pkg_depends git
pkg_install_release hub "github/hub"

# =INFO= When authenticating with hub, you'll be asked a username and a password.
#        For the password, use a PAT (Personal Access Token) created on GitHub.
