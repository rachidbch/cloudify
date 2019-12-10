wget -O ""${LOCAL_BIN}/grv https://github.com/rgburke/grv/releases/download/v0.1.3/grv_v0.1.3_linux64""
chmod +x ${LOCAL_BIN}/grv
if [ ! -e "${LOCAL_BIN}/grv" ]; then 
  ln -s "$WORKSTATION_DIR/installs/grv/bin/grv" "${LOCAL_BIN}/grv"
else 
  echo "Warning: ${LOCAL_BIN}/grv already exist. Skip creating grv symlink" 
fi
