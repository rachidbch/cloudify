# this will install a list a list of alternatives to usual bash commands that will create 
# any needed parent directory before exectuting
# for instance "$ptouch ./newdir/newfile.md" will create a file named 'newfile.md' in a
# created 'newdir' directory


# [TODO] use $LOCAL_BIN instead of ~/.local/bin
# [TODO] if $LOCAL_BIN is null exit with an error message


(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  cp ./ptouch ~/.local/bin/ && chmod +x ~/.local/bin/ptouch
  cp ./pvim ~/.local/bin/ && chmod +x ~/.local/bin/pvim
)
