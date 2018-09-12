Megadown
========
# utility to download from mega.nz

# first install dependencies
if [ -z "$(command -v "python" 2>&1)"  ]; then sudo apt install python; fi    # Ubuntu 18.10 comes with only Python3, megadown needs python2
sudo apt install pv

# install megadown
[ -d ./git ] && rm -rf ./git
git clone "https://github.com/tonikelope/megadown" git
chmod +x git/megadown                                                         # prevents a bug when sourcing instead of executing the file
cp -f git/megadown "$LOCAL_BIN"/                                              # [TODO] test if we can use a symlink here

