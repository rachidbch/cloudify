# Install pcmd utilities: ptouch and pvim
# These create parent directories before executing (e.g. ptouch ./newdir/newfile.md)

(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  cp ./ptouch "$CLOUDIFY_LOCAL_BIN/ptouch" && chmod +x "$CLOUDIFY_LOCAL_BIN/ptouch"
  cp ./pvim "$CLOUDIFY_LOCAL_BIN/pvim" && chmod +x "$CLOUDIFY_LOCAL_BIN/pvim"
)
