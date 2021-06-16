# Some stations come without proper locales
# On RackNerd VPS, I had a lot of " perl: warning: Setting locale failed." errors
# Some advise to be selective and install only needed locales. How?
sudo apt-get -q install language-pack-en -y 

# Without software-propreties-common this no add-apt-repository ...
# Add a mini comment to explain other installs
sudo apt-get -q install apt-transport-https ca-certificates curl gnupg-agent -y
software-properties-common bc -y

# trash-cli is used by workify to safely delete files and directories 
sudo apt-get -q install trash-cli -y

# Nice to have tooling 
sudo apt-get -q install tree psproc -y
sudo apt-get -q install jq -y
sudo apt-get -q install rename -y

