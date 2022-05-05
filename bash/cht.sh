#!/usr/bin/env bash

DEFAULT_STYLE="emacs"
STYLE=${1:-$DEFAULT_STYLE}

URL=https://cheat.sh # Also: cht.sh

SELECTION=$(bat -p ${PWD}/*.list ${PWD}/special | fzf --print-query --algo=v1 --no-sort --no-multi --cycle --color --border --height 20 | tail -1)

[[ -z ${SELECTION} ]] && exit 0 # Exit on void selection

echo "# Language-only : 'hello', ':learn', ':list', ':random'"
echo "# "
echo "# Default       :  Shows cheatsheet"

read -p "[${SELECTION}] %> " KEYWORDS # Retrieve input
KEYWORDS=$(echo ${KEYWORDS} | tr ' ' '+')



if rg --quiet ${SELECTION} ${PWD}/languages.list; then
    if [[ -z "${KEYWORDS}" ]]; then
        URL="${URL}/${SELECTION}"
    else
        URL="${URL}/${SELECTION}/${KEYWORDS}"
    fi
else
        URL="${URL}/${SELECTION}~${KEYWORDS}"
fi

echo $URL
tmux neww bash -c "curl -s ${URL}?style=${STYLE} | bat -p --paging=always"
