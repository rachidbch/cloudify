# Neovim installation

pkg_apt_install neovim
pkg_apt_install python3-neovim

python3 -m pip install --user --upgrade pynvim

echo "Warning: At first nvim launch, type :checkhealth to verify if your setup is optimal"
