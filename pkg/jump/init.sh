# Install latest jump release from GitHub
pkg_depends jq
pkg_install_release jump "gsamokovarov/jump"

pkg_in_startuprc \
    '## JUMP ENV SETUP'\
    'eval "$(jump shell bash)"'
