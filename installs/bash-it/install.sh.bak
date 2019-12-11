# Bash-it  

# Bash-it install complains if no ~/bin/ is found 
# =todo= Report Issue

if [[ ! -e ~/bin ]]; then
  mkdir ~/bin	 
elif [[ ! -d ~/bin ]]; then
  echo "FATAL: ~/bin already exists and isn\'nt a directory"
fi

# Bash-it complains if Bash-Completion is absent
sudo apt install bash-completion -y


if [[ ! -e ~/.bash_it ]]; then
  git clone --depth=1 https://github.com/Bash-it/bash-it.git ~/.bash_it  
elif [[ ! -d ~/.bash_it ]]; then
  echo "FATAL: ~/.bash_it already exists and isn\'nt a directory"
fi

 ~/.bash_it/install.sh -n                       # with '-n' option bash-it shouldn't overwrite ~/.bashrc (it shoudl be stowed from our dotfiles)

# Source ~/.bashrc to activate .bashrc
#source ~/.bashrc

