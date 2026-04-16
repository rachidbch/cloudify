# Ping for any port
# Use it with:
# $ paping google.com -p 80 -c 4

pkg_depends curl
curl -sSL "https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/paping/paping_1.5.5_x86-64_linux.tar.gz" | tar -C /tmp/ -xzf -
sudo install -m755 /tmp/paping /usr/local/bin/paping
