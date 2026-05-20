#!/usr/bin/env zsh
DIR="${0:A:h}"
"$DIR/update-all.sh"
print -n "\nPress any key to close…"
read -k1 _
