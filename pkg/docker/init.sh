sudo apt-get -q update -y
sudo apt-get -q install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common -y

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

sudo apt-get -q update -y

sudo apt-get -q install docker-ce docker-ce-cli containerd.io -y

sudo curl -L "https://github.com/docker/compose/releases/download/1.25.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

msg "Docker version installed"
docker -v

msg "Adding $USER to \'docker\' group"
sudo usermod -aG docker "$USER"

msg "Warning: Ensure $USER is in \'docker\' group"
msg "\$ newgrp docker"
msg "\$ newgrp $USER"
msg "Then test docker installation"
msg "\$ docker run hello-world"
