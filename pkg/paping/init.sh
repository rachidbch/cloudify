# Ping for any port
# Use it with:
# $ paping google.com -p 80 -c 4

[ -d ~/tmp ] || mkdir ~/tmp 
(cd ~/tmp
 wget https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/paping/paping_1.5.5_x86-64_linux.tar.gz -O paping.tar.gz && tar -xzf paping.tar.gz
 sudo mv paping /usr/local/bin/
)
