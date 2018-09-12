export NVM_DIR="$HOME/.nvm" && (
    if [ ! -d "$NMV_DIR"  ]; then
        git clone https://github.com/creationix/nvm.git "$NVM_DIR"
        cd "$NVM_DIR"
    else
        cd "$NVM_DIR"
        git pull
    fi
    git checkout `git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)`
) && \. "$NVM_DIR/nvm.sh"

# install latest LTS node
nvm install --lts --latest-npm
