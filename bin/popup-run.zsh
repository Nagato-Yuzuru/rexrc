#!/bin/zsh
# The popup's command, run in a detached block by popup_run under an interactive
# login zsh so aliases and PATH match a normal pane.
# $1 command, $2 seconds before showing, $3 the bar's block, $4 the bar's fifo.
#
# Reports to the bar through the fifo: "shown" once the popup is visible,
# "done" for a clean exit before that, or the last lines of output for an early
# failure, which the bar shows in place. A failure after showing goes through
# popup_failed, which reopens the bar with the error.

setopt extendedglob
cmd=$1 delay=$2 bar=$3 fifo=$4 flag=$4.shown
show() { rex do popup_show "block=$REX_BLOCK" "bar=$bar" >/dev/null 2>&1; }
report() { [[ -p $fifo ]] && print -rn -- "$1"$'\0' >$fifo; }

if [[ -z $cmd ]]; then
    show
    report shown
    exec "$SHELL" -l
fi

dir=$PWD
print -n '\e[H\e[2J\e[3J' # keep .zshrc banners out of the error excerpt
{
    sleep $delay
    : >$flag
    show
    report shown
} &|
shower=$!
(eval "$cmd") # subshell: an exit in the command doesn't skip the cleanup below
rc=$?
kill $shower 2>/dev/null

if [[ ! -e $flag ]]; then # never shown
    ((rc == 0 || rc == 130)) && {
        report done
        exit 0
    }
    lines=(${(f)"$(rex capture -b $REX_BLOCK 2>/dev/null)"})
    lines=(${lines:#[[:space:]]#})
    # Last 3 lines; with fewer, [-3,-1] would be empty.
    msg=${(F)lines[$((${#lines} > 3 ? ${#lines} - 2 : 1)),-1]}
    rex do popup_bar_error "bar=$bar" >/dev/null 2>&1
    report "${msg:-[exit $rc]}"
    exit 0
fi

rm -f $flag
((rc == 0 || rc == 130)) && exit 0
rex do popup_failed "command=$cmd" "cwd=$dir" "rc=$rc" "block=$REX_BLOCK" >/dev/null 2>&1 && exit 0
print -P "\n%F{red}[exit $rc]%f press any key to close"
read -sk1
