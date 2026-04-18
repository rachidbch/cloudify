#!/usr/bin/env bash
# Utils pkg install
#
# Utils pkg gathers small in-house utility scripts


# Moreutils apt package contains the vipe utility that is used by ipath
pkg_depends moreutils


# 'IPATH' FUNCTION ALLOWS YOU TO *INTERACTIVELY* EDIT YOUR PATH IN VIM
# Here's the function in a readable format
# function ipath() {
#     PATHBACK=\$PATH
#     PATHNEW=\$( echo \$PATH | tr ':' '\n' | EDITOR=vi vipe | sed '/^$/d' | tr '\n' ':')
#     PATHNEW=\$(sed -r 's/:\$//' <<<"\$PATHNEW")
#     export PATH=\$PATHNEW && unset PATHNEW && unset PATHBACK 
# }
# =NOTE= Newline characters '\n' are escaped: '\\n'
# shellcheck disable=SC2016 # single quotes are intentional: pkg_in_startuprc writes literal strings to .bashrc
pkg_in_startuprc \
  '# Function ipath Setup' \
  'function ipath() { PATHBACK=$PATH; PATHNEW=$( echo $PATH | tr '\'':'\'' '\''\\n'\'' | EDITOR=vi vipe | sed '\''/^$/d'\'' | tr '\''\\n'\'' '\'':'\''); PATHNEW=$(sed -r '\''s/:$//'\'' <<<"\$PATHNEW"); export PATH=$PATHNEW && unset PATHNEW && unset PATHBACK; }'

# Make it a little bit easier to reload bashrc
# Here's the alias is a readable format:
# alias rcreload='source ~/.bashrc'
pkg_in_startuprc '# Alias rcreload Setup' 'alias rcreload="source ~/.bashrc"'

# Make it a little bit to edit .bashrc 
# Here's the alias is a readable format:
# alias rcedit='vim ~/.bashrc'
# shellcheck disable=SC2016 # single quotes are intentional: pkg_in_startuprc writes literal strings to .bashrc
pkg_in_startuprc '# Alias rcedit Setup' 'alias rcedit="${EDITOR:-vi} ~/.bashrc"'
