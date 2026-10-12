#!/usr/bin/env bash
# Runs the greeter against a fake greetd inside niri-sandbox (nothing appears
# on the live session) and takes the screenshots of a login: idle, typing, a
# greetd that never answers and Escape, a wrong password, GNOME picked, Enter
# with the power menu open (which must not log in), a right password. Fails
# unless the fake greetd was asked to start GNOME after exactly three attempts.
#
#   tests/proof.sh [OUTPUT_DIR]      screenshots and greetd.log land there
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=${here%/tests}
out=${1:-$(mktemp -d)}
mkdir -p "$out"
export NIRI_SANDBOX=${NIRI_SANDBOX:-${BB_THREAD_ID:-greeter-proof}}
sandbox=${NIRI_SANDBOX_BIN:-niri-sandbox}
niri_config=$(realpath "$config/../../niri/config.kdl")

node "$here/fake-greetd.mjs" --socket "$out/greetd.sock" --password hunter2 \
    --log "$out/greetd.log" --launch-delay 3000 > "$out/fake-greetd.out" &
fake=$!
trap 'kill $fake 2>/dev/null; "$sandbox" down >/dev/null' EXIT
while ! [ -S "$out/greetd.sock" ]; do sleep 0.1; done

"$sandbox" up -c "$niri_config" >/dev/null
"$sandbox" spawn env GREETD_SOCK="$out/greetd.sock" qs -p "$config"
sleep 3

key() { "$sandbox" run wtype "$@"; }
shot() { sleep "${2:-0.6}"; "$sandbox" shot "$out/$1.png" >/dev/null; echo "$out/$1.png"; }

shot 01-idle
key wrong7
shot 02-typing
key -k Return
shot 03-wrong 0.25
sleep 1.5
key stall
key -k Return
shot 04-checking
key -k Escape
shot 05-escaped
key -k Tab
shot 06-gnome
key zz
key -M ctrl -M alt -k Delete -m alt -m ctrl
key -k Return
shot 07-power
key -k Escape
key -k Escape
key hunter2
key -k Return
shot 08-success 0.9
sleep 4

echo "--- what greetd was asked"
cat "$out/greetd.log"
grep -q '"type":"start_session","cmd":\["/usr/bin/gnome-session"\]' "$out/greetd.log"
echo "ok: greetd was asked to start gnome-session"
[ "$(grep -c '"type":"create_session"' "$out/greetd.log")" = 3 ]
echo "ok: three attempts, none from Enter with the power menu open"
grep -q '"stalled":true}' "$out/greetd.log" && grep -q '"type":"cancel_session"' "$out/greetd.log"
echo "ok: Escape cancelled the attempt greetd never answered"
