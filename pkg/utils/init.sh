# Utils pkg install
#
# Utils pkg gathers small in-house utility scripts

# ~/.local/bin/ipath allows you to *interactively* edit your PATH in VIM
# =NOTE= As it must manipulate your shell environment, you must source it and not execute it.
# =TODO= ipath should be an alias instead. That way you wouldn't need to source it.

[[ -e ~/.local/bin/ipath ]] && rm ~/.local/bin/ipath
cat -> "$HOME"/.local/bin/ipath <<- EOF
	PATHBACK=\$PATH
	PATHNEW=\$( echo \$PATH | tr ':' '\n' | EDITOR=vi vipe | sed '/^$/d' | tr '\n' ':')
	# Remove last ':'
	PATHNEW=\$(sed -r 's/:\$//' <<<"\$PATHNEW")
	# echo Check everything is OK
	# echo \$PATHNEW | tr ':' '\n' 
	# Replace
	export PATH=\$PATHNEW && unset PATHNEW && unset PATHBACK 
EOF

# ipath must be sourced not executed, otherwise it will have no effect on your shell environment
chmod -x "$HOME"/.local/bin/ipath
