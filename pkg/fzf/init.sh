sudo apt-get -q install fasd -y

[ -d ~/.fzf ] || git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --bin                # configuration files are already in dotfiles
# accept all options but refuse bash config file modification.
# [TODO] how to install unattented?
# ~/.fzf.bash file will be created in previous step: do not deplace it as it will be referenced by bash-it enable/disable machinery!
bash-it enable plugin fzf
# bash-it fzf plugin defines some bash function that we can disable (tab completion not set)
# enable custom fzf (and fasd that integrate with it) by creating a soft link in .bash.d/enabled pointing to .bash.d/available
