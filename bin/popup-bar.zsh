#!/bin/zsh -f
# The popup command bar, run in a short floating terminal by features/popup.lua.
# $1 prefilled command, $2 error to show (may be empty). After Enter it starts the
# command through popup_run and blocks on a fifo until the command reports back.

fifo=${TMPDIR:-/tmp}/rex-popup.$$
trap 'rm -f $fifo $fifo.shown' EXIT
trap 'exit 0' INT
mkfifo $fifo && exec {fd}<>$fifo || {
    print -r -- "popup: cannot create fifo $fifo"
    read -sk1
    exit 1
}

# Esc submits a sentinel instead of send-break: send-break aborts the whole
# script, the EXIT trap never runs, and the fifo leaks.
cancel() {
    BUFFER=$'\x18'
    zle accept-line
}
zle -N cancel
bindkey '^[' cancel

REPLY=$1 err=$2
while :; do
    print -n '\e[H\e[2J' # also clears login(1)'s "Last login" banner
    [[ -n $err ]] && print -r -- $'\e[31m'"$err"$'\e[0m'
    vared -p '%F{blue}popup>%f ' REPLY || exit 0
    [[ $REPLY == $'\x18' ]] && exit 0
    if ! out=$(rex do popup_run "command=$REPLY" "cwd=$PWD" "bar=$REX_BLOCK" "fifo=$fifo" 2>&1 >/dev/null); then
        err="popup failed to start: $out"
        continue
    fi
    if ! IFS= read -r -d '' -t 60 -u $fd res; then
        err="popup: no result from the command within 60 s"
        continue
    fi
    [[ $res == shown || $res == done ]] && exit 0
    err=$res
done
