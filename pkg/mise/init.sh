# Install mise (polyglot runtime manager: node, python, go, etc.)
# https://mise.jdx.dev

pkg_apt_install curl

curl -sSL https://mise.run | sh

pkg_in_startuprc \
    '## MISE ENV SETUP'\
    'eval "$(~/.local/bin/mise activate bash)"'
