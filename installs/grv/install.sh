if [ ! -d ./bin ]; then mkdir ./bin ; fi
wget -O ./bin/grv https://github.com/rgburke/grv/releases/download/v0.1.3/grv_v0.1.3_linux64
chmod +x ./bin/grv
ln -s "$WORKSTATION_DIR"/installs/grv/bin/grv ~/.local/bin/grv
