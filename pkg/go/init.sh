[ -z $(which gvm) ] && [ -d ~/.gvm ] && rm -rf ~/.gvm

if [ -z $(which gvm) ]; then 
 export GVM_NO_UPDATE_PROFILE=true                # Our ~/.bashrc is in our dotfiles 
 bash < <(curl -s -S -L https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer)
 source ~/.gvm/scripts/gvm
fi

# to install go1.5+ first install go1.4 binary (installing go1.5+ necessitates a working go install ..)
if [ -z $(which go.1.4) ]; then
 gvm install go1.4 -B
 gvm use go1.4
elif  [ -z $(which go.1.13) ]; then
 export GOROOT_BOOTSTRAP=$GOROOT
 gvm install go1.13
fi
