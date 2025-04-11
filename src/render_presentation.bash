#!/usr/bin/env bash

set -eu
#
#
# Check if the file is sourced or executed
#
# it examines FUNCNAME to determine if the current file is sourced. It contains
# the stack's function names, obviously currently executing being the first.
#
# Usage: __is_sourced
#
__is_sourced() {
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '__is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

#
#
# Prints a help message
#
# Usage: print_help
#
print_help() {
	echo "$0 is a utility to generate standalone html pages from md using pandoc"
	echo
	echo "Usage: $0 source destination"
	echo
	echo "Options:"
	echo "    source        Path that contains the sources, expects css, js,"
	echo "                     templates, and chapters to be present"
	echo "    destination   Path to build the standalone html to"
	echo "                     Note that the destination path gets deleted if exists"
}

main() {
	if [ $# -lt 2 ]; then
		echo "Error: No arguments provided."
		print_help
		exit 1
	fi

    local source="$1"
    local dest="$2"

	if ! command -v pandoc --version 2>&1 >/dev/null
	then
    	echo "pandoc is not installed, or not in PATH"
    	exit 1
	fi

	if [ -d "$dest" ]
	then
		rm -rf "$dest"
	fi
	mkdir "$dest"

	cp -R "$source"/js  "$dest"
	cp -R "$source"/css "$dest"
	cp -R "$source"/img "$dest"
	
	for file in "$source"/chapters/*.md
	do
		[ -e "$file" ] || continue
		echo "Generating $(basename ${file%.*}).html"
		if ! pandoc -s --template presentation/templates/base.tmpl \
				"$file" -o dest/"$(basename ${file%.*})".html
		then
			echo "Failed to process $file"
			exit 1
		fi
	done
}

if ! __is_sourced; then
	main "$@"
fi
