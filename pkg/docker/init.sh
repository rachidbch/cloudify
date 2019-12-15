sudo apt-get -q update
sudo apt-get -q install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

sudo apt-get -q update

sudo apt-get -q install docker-ce docker-ce-cli containerd.io -y

echo "Docker version installed"
docker -v

echo "Warning: Don't forget to add $USER to docker group"
echo "> sudo usermod -aG docker $USER"
echo "> newgrp docker"
echo "> newgrp $USER"
echo "> docker run hello-world"
