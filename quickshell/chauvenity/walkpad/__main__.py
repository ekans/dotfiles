#!/usr/bin/python3
# The walkpad: records a CITYSPORTS walking pad's walks and serves them to the
# chauvenity bar. Runs as the systemd user service walkpad.service, so a walk
# outlives the bar reloading, crashing or being edited:
#
#     /usr/bin/python3 -B ~/.config/quickshell/chauvenity/walkpad serve
#
# config.py says what the environment chooses, and server.py what the socket
# carries. To watch the wire by hand:
#
#     socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/walkpad.sock     then type `watch`
#
# The helper exits once one of its own .py files changes, and systemd starts
# the new code a second later, the way the bar reloads on a .qml save. That
# exit leaves the pad connected, so the next helper picks the walk up at
# once. Stopping it (SIGTERM) hands the pad back.
#
# /usr/bin/python3 because it has the GObject bindings; the python3 on PATH
# may well not. -B because this directory is the user's live bar config and
# must not fill with __pycache__. The modules import each other by bare name:
# running the directory puts it first on sys.path.
#
# Logs go to stderr, so to `journalctl --user -u walkpad`.

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from gi.events import GLibEventLoopPolicy
from gi.repository import Gio

from bluez import BluezSource
from config import Bluez, Config, resolve
from controller import WalkController
from replay import ReplaySource
from server import Server
from store import Store, StoreLocked, StoreTooNew

#: Exit status for a configuration the helper refuses; the unit does not
#: restart on it.
REFUSED = 2

#: A `git pull` touches several files: the helper exits once they are quiet.
SETTLE_S = 1.0


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def watch_code(directory: Path, changed) -> object:
    """Calls `changed` once the directory's *.py files have been quiet for
    SETTLE_S after a change. Returns the monitor, which must be kept."""
    loop = asyncio.get_running_loop()
    pending = None

    def on_event(_monitor, file, other, _event) -> None:
        nonlocal pending
        if not any(f is not None and f.get_basename().endswith(".py") for f in (file, other)):
            return
        if pending:
            pending.cancel()
        pending = loop.call_later(SETTLE_S, changed)

    monitor = Gio.File.new_for_path(str(directory)).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
    monitor.connect("changed", on_event)
    return monitor


async def serve(config: Config) -> int:
    server = Server(config.socket, log)
    if error := await server.listen():
        log(f"walkpad: {error}")
        return 1
    try:
        try:
            store, problems = Store.open(config.db, config.import_from, log)
        except (StoreLocked, StoreTooNew) as error:
            log(f"walkpad: {error}")
            return 1
        try:
            try:
                source = BluezSource(log) if isinstance(config.pad, Bluez) else ReplaySource(config.pad.script, log)
            except ValueError as error:
                log(f"walkpad: {error}")
                return REFUSED
            controller = WalkController(store, source, problems, log)
            monitor = watch_code(Path(__file__).resolve().parent, lambda: server.stop("reload"))
            reason = await server.run(controller)
            monitor.cancel()
            if reason == "reload":
                log("walkpad: its code changed; exiting so that the new code starts")
            await source.close(release=reason == "stop")
        finally:
            store.close()
    finally:
        await server.close()
    return 0


def main(argv: list[str]) -> int:
    if argv != ["serve"]:
        log("usage: walkpad serve")
        return REFUSED
    config = resolve(os.environ)
    if isinstance(config, str):
        log(f"walkpad: {config}")
        return REFUSED

    # The GLib loop, so that Gio's D-Bus calls and file monitors can be
    # awaited next to the socket.
    loop = GLibEventLoopPolicy().new_event_loop()
    try:
        return loop.run_until_complete(serve(config))
    finally:
        loop.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
