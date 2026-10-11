#!/bin/sh
# The snippet overlay's dealings with the rest of the session: the clipboard,
# the keyboard, files, editors. shell.qml runs it as `sh actions.sh <command>`.
#
#   probe <limit>               niri's focused output and window, then the
#                               primary selection and the clipboard as text
#                               (at most <limit> bytes each), split by RS lines
#   list <dir>                  every *.md and *.txt under <dir>, hidden ones
#                               aside: RS, its path, a newline, its contents
#   paste <text> [terminal] [lefts]
#                               Ctrl+V <text> into the window that had focus,
#                               Ctrl+Shift+V if it is a terminal, press Left
#                               <lefts> times, then put the clipboard back
#   type <text> [lefts]         type <text> with wtype instead
#   copy <text> [sensitive]     leave <text> on the clipboard
#   edit <file>                 open <file> in the editor; once it is closed,
#                               tell the overlay, which renames the file if it
#                               was named after its keyword and that changed
#   draft <dir> <stem> <text>   open <text> as a draft, <stem>.md in a folder of
#                               its own under $XDG_RUNTIME_DIR. Saved when the
#                               editor closes, the overlay files it in <dir>
#                               under its keyword; else it is dropped
#   save <dir> <stem> <text>    write <text> to <dir>/<stem>.md, or -2, -3… if
#                               taken, and print where it went
#   pair <copy> <file>          <copy>, an RS line, then `present` and <file>,
#                               or `missing`; <copy> is removed
#   move <file> <dir> <stem>    move <file> to <dir>/<stem>, keeping its
#                               extension, or <stem>-2, -3… if taken, print
#                               where it went, and drop the draft folder it
#                               came from

set -u

# Long enough for niri to give the keyboard back to the window.
wait_for_focus() {
    sleep 0.15
}

press_left() {
    n=${1:-0}
    case $n in '' | *[!0-9]*) return 0 ;; esac
    [ "$n" -gt 0 ] || return 0
    # After what was pasted has landed.
    sleep 0.1
    set --
    while [ "$n" -gt 0 ]; do
        set -- "$@" -k Left
        n=$((n - 1))
    done
    wtype "$@"
}

# $SNIPPETS_EDITOR inside $SNIPPETS_TERMINAL, as snippets.service sets them;
# else $VISUAL or $EDITOR inside the default terminal. Returns once the window
# is closed: Ghostty with gtk-single-instance = false runs one process per
# window.
open_editor() {
    editor=${SNIPPETS_EDITOR:-${VISUAL:-${EDITOR:-nano}}}
    if [ -n "${SNIPPETS_TERMINAL:-}" ]; then
        "$SNIPPETS_TERMINAL" -e "$editor" "$1"
    else
        xdg-terminal-exec "$editor" "$1"
    fi
}

# Moves $1 to $2/$3 plus its extension, or $3-2, $3-3… if taken, and prints
# where it went.
move_to() {
    name=${1##*/}
    ext=
    case $name in *.*) ext=.${name##*.} ;; esac
    mkdir -p -- "$2" || return 1
    target="$2/$3$ext"
    n=2
    while [ -e "$target" ]; do
        target="$2/$3-$n$ext"
        n=$((n + 1))
    done
    mv -n -- "$1" "$target" && printf '%s\n' "$target"
}

case ${1:-} in
probe)
    limit=$2
    niri msg --json focused-output 2>/dev/null
    printf '\036\n'
    niri msg --json focused-window 2>/dev/null
    printf '\036\n'
    wl-paste --primary --no-newline --type text 2>/dev/null | head -c "$limit"
    printf '\036\n'
    wl-paste --no-newline --type text 2>/dev/null | head -c "$limit"
    ;;

list)
    cd "$2" 2>/dev/null || exit 0
    find -L . -name '.*' ! -name . -prune -o -type f \( -name '*.md' -o -name '*.txt' \) -print | LC_ALL=C sort |
        while IFS= read -r f; do
            printf '\036%s\n' "${f#./}"
            cat -- "$f"
        done
    ;;

paste)
    text=$2
    terminal=${3:-}
    lefts=${4:-0}
    dir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/snippets.XXXXXX") || exit 1
    trap 'rm -rf "$dir"' EXIT

    # What is on the clipboard now, to put back once the paste is done: its
    # text if it has some, else a PNG, else whatever it offers first.
    types=$(wl-paste --list-types 2>/dev/null)
    kept=
    for t in 'text/plain;charset=utf-8' text/plain image/png; do
        if printf '%s\n' "$types" | grep -qxF "$t"; then
            kept=$t
            break
        fi
    done
    [ -n "$kept" ] || kept=$(printf '%s\n' "$types" | head -n 1)
    # A password manager's copy goes back marked the same way, so cliphist
    # still leaves it out.
    hint=
    if printf '%s\n' "$types" | grep -qxF x-kde-passwordManagerHint; then
        hint=--sensitive
    fi
    if [ -n "$kept" ]; then
        wl-paste --no-newline --type "$kept" > "$dir/kept" 2>/dev/null || kept=
    fi

    # Marked sensitive, so cliphist does not record every expansion.
    printf '%s' "$text" | wl-copy --sensitive --type 'text/plain;charset=utf-8' || exit 1
    wait_for_focus
    if [ -n "$terminal" ]; then
        wtype -M ctrl -M shift v -m shift -m ctrl
    else
        wtype -M ctrl v -m ctrl
    fi
    press_left "$lefts"

    # Long enough for the window to have read the clipboard.
    sleep 0.5
    if [ -n "$kept" ]; then
        wl-copy $hint --type "$kept" < "$dir/kept"
    else
        wl-copy --clear
    fi
    ;;

type)
    wait_for_focus
    printf '%s' "$2" | wtype -
    press_left "${3:-0}"
    ;;

copy)
    if [ -n "${3:-}" ]; then
        printf '%s' "$2" | wl-copy --sensitive --type 'text/plain;charset=utf-8'
    else
        printf '%s' "$2" | wl-copy --type 'text/plain;charset=utf-8'
    fi
    ;;

edit)
    before=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/snippets-before.XXXXXX") || exit 1
    cp -- "$2" "$before" || exit 1
    open_editor "$2"
    qs -c snippets ipc call snippets edited "$2" "$before" > /dev/null 2>&1 || rm -f -- "$before"
    ;;

draft)
    drafts=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/snippet-draft.XXXXXX") || exit 1
    file="$drafts/$3.md"
    printf '%s' "$4" > "$file" || exit 1
    written=$(stat -c %y -- "$file")
    open_editor "$file"
    # Not written since, as after :q!: nothing to keep. A :wq without a change
    # still counts as saved.
    if [ ! -f "$file" ] || [ "$(stat -c %y -- "$file")" = "$written" ]; then
        rm -rf -- "$drafts"
    elif ! qs -c snippets ipc call snippets drafted "$file" "$2" > /dev/null 2>&1; then
        # The overlay is not running: kept under the name it was opened with.
        move_to "$file" "$2" "$3" > /dev/null && rmdir -- "$drafts"
    fi
    ;;

save)
    file="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/snippet-draft.XXXXXX")/$3.md" || exit 1
    printf '%s' "$4" > "$file" || exit 1
    move_to "$file" "$2" "$3" && rmdir -- "${file%/*}"
    ;;

pair)
    cat -- "$2" 2>/dev/null
    rm -f -- "$2"
    printf '\036\n'
    if [ -f "$3" ]; then
        echo present
        cat -- "$3"
    else
        echo missing
    fi
    ;;

move)
    move_to "$2" "$3" "$4" || exit 1
    case ${2%/*} in
    */snippet-draft.*) rmdir -- "${2%/*}" 2>/dev/null ;;
    esac
    ;;

*)
    echo "actions.sh: unknown command '${1:-}'" >&2
    exit 2
    ;;
esac
