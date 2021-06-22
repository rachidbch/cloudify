# Install gitless (using pipx)

PKG_DEBUG "Installing gitless"

# For some reasons, pipx compiles gitless with gcc (!)
# That's the reason why build-essential (containing gcc compiler), python-dev and python3-dev (containing python C headers) and libgit2 (git
# library?) are listed as dependencies
# Without these, pipx keeps failing with gcc compiler errors about missing headers and libraries
pkg_depends build-essential git pip pipx python-dev python3-dev libgit2-dev
pipx install gitless
