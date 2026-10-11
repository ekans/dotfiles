#!/bin/sh
# Locks the niri session with chauvenity-lock (shell.qml beside this file),
# and returns once niri has confirmed every output is covered: swayidle's
# before-sleep waits on this, so the laptop never goes to sleep with the
# desktop still on screen. What swayidle runs, from
# ~/.config/systemd/user/chauvenity-swayidle.service.d/50-chauvenity-lock.conf.
#
# The lock runs as chauvenity-lock.service, a transient unit:
#   - outside swayidle's cgroup, so restarting swayidle leaves the lock up;
#   - Restart=on-failure, so a lock that crashes while locked is followed by a
#     new one rather than niri's red screen for good.
# Run while already locked, it only waits for the lock that is up.
#
# swaylock is the fallback, for a lock screen that cannot start at all.

unit=chauvenity-lock.service

secure() {
    [ "$(qs -c chauvenity-lock ipc call lock secure 2>/dev/null)" = true ]
}

if ! systemctl --user is-active --quiet "$unit"; then
    systemctl --user reset-failed "$unit" 2>/dev/null
    systemd-run --user --quiet --collect --unit="$unit" \
        -p Description="Lock screen (niri session)" \
        -p BindsTo=niri.service -p After=niri.service \
        -p Restart=on-failure -p RestartSec=200ms \
        -p Slice=session.slice \
        /usr/bin/qs -c chauvenity-lock \
        || exec swaylock -f
else
    # Still up from an earlier lock: a no-op while it is locked.
    qs -c chauvenity-lock ipc call lock lock 2>/dev/null
fi

i=0
while [ "$i" -lt 50 ]; do
    secure && exit 0
    sleep 0.1
    i=$((i + 1))
done

echo "chauvenity-lock: niri has not confirmed the lock after 5 s; swaylock instead" >&2
systemctl --user stop "$unit"
exec swaylock -f
