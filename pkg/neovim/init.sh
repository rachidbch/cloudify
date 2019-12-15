UBUNTU_VER="$(lsb_release -r | cut -f2)"

if (( $(echo "$UBUNTU_VER >= 18.04" | bc -l ))); then
  [ -z "$(find /var/cache/apt/pkgcache.bin -mmin -60)" ] &&  sudo apt-get update
  sudo apt-get install neovim -y
  sudo apt-get install python-neovim -y
  sudo apt-get install python3-neovim  -y
else
  sudo add-apt-repository ppa:neovim-ppa/stable -y
  sudo apt-get update
  sudo apt-get install neovim -y
  sudo apt-get install python-dev python-pip python3-dev python3-pip -y
fi

python3 -m pip install --user --upgrade pynvim
python2 -m pip install --user --upgrade pynvim

# Install Minpac Neo(Vim) package manager
# Compatible with NeoVim and Vim8+
echo "Warning: At first nvim launch, type :checkhealth to verify your setup is optimal"
echo "         Learn to configure and use neovim with: http://pdf1024.com/files/20190617/Modern.Vim.2018.5.pdf"
echo "         Learn Minpac from https://thoughtbot.com/upcase/videos/neovim-minpac"
