export TODO_DIR=~/.todo
(
TODOTXT_VER=2.11.0
cd /tmp/
wget -O todo.txt_cli.tar.gz "https://github.com/todotxt/todo.txt-cli/releases/download/v${TODOTXT_VER}/todo.txt_cli-${TODOTXT_VER}.tar.gz"
if [ ! -d "/tmp/todo.txt_cli" ]; then mkdir /tmp/todo.txt_cli; fi
tar xzvf todo.txt_cli.tar.gz -C /tmp/todo.txt_cli --strip-components 1
chmod +x /tmp/todo.txt_cli/todo.sh
sudo mv /tmp/todo.txt_cli/todo.sh /usr/local/bin/

if [ ! -e ~/.todo ]; then mkdir ~/.todo; fi
mv /tmp/todo.txt_cli/todo.cfg ~/.todo/config
# Comment out TODO_DIR as it has already been exported 
sed -i '/^export TODO_DIR/ s/^/#/' ~/.todo/config
sudo mv /tmp/todo.txt_cli/todo_completion  /etc/bash_completion.d/todo
)
