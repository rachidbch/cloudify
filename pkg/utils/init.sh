# Utils pkg install
#
# Utils pkg gathers small in-house utility scripts

# ~/.local/bin/interactivepath allows you to edit your PATH in VIM
# =NOTE= As it must manipulate your shell environment, you must source it and not execute it.

[[ -e ~/.local/bin/interactivepath ]] && rm ~/.local/bin/interactivepath
cat -> "$HOME"/.local/bin/interactivepath <<- EOF
	PATHBACK=\$PATH
	PATHNEW=\$( echo \$PATH | tr ':' '\n' | EDITOR=vi vipe | sed '/^$/d' | tr '\n' ':')

	# Check everything is OK
	# echo \$PATHNEW | tr ':' '\n' 
	# Replace
	export PATH=\$PATHNEW && unset PATHNEW && unset PATHBACK 
EOF

# interactivepath must be sourced not executed, otherwise it will have no effect on your shell environment
chmod -x "$HOME"/.local/bin/interactivepath
