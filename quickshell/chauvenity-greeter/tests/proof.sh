#!/usr/bin/env bash
# Runs the greeter against a fake greetd inside niri-sandbox (nothing appears
# on the live session) and takes the screenshots of a login: idle, typing, a
# wrong password, GNOME picked, the power menu, a right password. Fails unless
# the fake greetd was asked to start GNOME.
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
key -k Tab
shot 04-gnome
key -M ctrl -M alt -k Delete -m alt -m ctrl
shot 05-power
key -k Escape
key hunter2
key -k Return
shot 06-success 0.9
sleep 4

echo "--- what greetd was asked"
cat "$out/greetd.log"
grep -q '"type":"start_session","cmd":\["/usr/bin/gnome-session"\]' "$out/greetd.log"
echo "ok: greetd was asked to start gnome-session"
