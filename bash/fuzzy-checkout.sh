# ./fuzzy-checkout.sh
# ./fuzzy-checkout.sh <location>

#!/usr/bin/env bash

WORKING_DIR=${1:-${PWD}}
FZF_H=20
GIT_PRETTY_FORMAT="%(color:white)%(committerdate:short) %(objectname:short=10)%(color:reset) %(color:bold red)%(align:width=50)%(refname:short)%(end)%(color:reset)%09%(color:white)%(align:65)%(contents:subject)%(end)%(color:reset)"

# Exit if it's not a git repository
[[ ! -d .git ]] && exit 1

# Fuzzy select from available branches
SELECTION=$(git -C ${WORKING_DIR} branch --list --all --no-column --sort=-committerdate --format="${GIT_PRETTY_FORMAT}" |
            rg --case-sensitive -v HEAD |
            fzf --reverse --no-multi --cycle --border --height ${FZF_H})

# Exit on void selection
[[ -z ${SELECTION} ]] && exit 1

# Extract branch name
BRANCH=$(echo ${SELECTION} | cut -d ' ' -f3)

# Switch to selected branch
STATUS=$(git -C ${WORKING_DIR} checkout ${BRANCH} 2>&1 >/dev/null)

# Output possible error
[[ ! "$?" -eq 0 ]] && echo "${STATUS}" | less
