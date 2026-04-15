# =todo Update this Install with instructions from [How To Install Go Using GVM (Golang Version Manager) Youtube video](https://www.youtube.com/watch?v=7hFfkOs8gRg)

[ -z $(which gvm) ] && [ -d ~/.gvm ] && rm -rf ~/.gvm

if [ -z $(which gvm) ]; then 
 export GVM_NO_UPDATE_PROFILE=true                # Our ~/.bashrc is in our dotfiles 
 bash < <(curl -s -S -L https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer)
 # This should set GOROOT env PATH 
 # =todo= And this probably should be sourced in bashrc/zshrc !!
 [[ -s "$HOME/.gvm/scripts/gvm" ]] && source "$HOME/.gvm/scripts/gvm"         
fi

# to install go1.5+ first install go1.4 binary (installing go1.5+ necessitates a working go install ..)
if [ -z $(which go.1.4) ]; then
 gvm install go1.4 -B
 gvm use go1.4
fi
if [ -z $(which go.1.18) ]; then
 export GOROOT_BOOTSTRAP=$GOROOT
 gvm install go1.18
 gvm use go1.18
fi
