#!/usr/bin/python3
# Lends the clothesline's files to sandboxed apps for a drag.
#
# A Flatpak cannot read a path in $XDG_RUNTIME_DIR, so a drag offers, beside
# the path, a key from the document portal's FileTransfer interface. The app
# that takes the drop hands the key back to the portal and gets the file.
# Qt does not do this itself.
#
# Reads one path a line on stdin and prints `<path>\t<key>`, or `<path>\t` if
# the portal refused. A key is only good while this process runs: the portal
# drops a transfer when its sender leaves the bus. Each one stops after its
# first retrieval, and a new path stops the last one if nobody took it.

import os
import sys

from gi.repository import Gio, GLib

BUS_NAME = "org.freedesktop.portal.Documents"
PATH = "/org/freedesktop/portal/documents"
INTERFACE = "org.freedesktop.portal.FileTransfer"

bus = Gio.bus_get_sync(Gio.BusType.SESSION)


def call(method, args, reply="()", fds=None):
    result, _ = bus.call_with_unix_fd_list_sync(
        BUS_NAME, PATH, INTERFACE, method, args, GLib.VariantType(reply),
        Gio.DBusCallFlags.NONE, -1, fds, None)
    return result.unpack()


def lend(path):
    (key,) = call("StartTransfer", GLib.Variant("(a{sv})", ({
        "writable": GLib.Variant("b", False),
        "autostop": GLib.Variant("b", True),
    },)), "(s)")
    fds = Gio.UnixFDList()
    fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    try:
        fds.append(fd)
    finally:
        os.close(fd)
    call("AddFiles", GLib.Variant("(saha{sv})", (key, [0], {})), fds=fds)
    return key


last = None
for line in sys.stdin:
    path = line.rstrip("\n")
    if last:
        try:
            call("StopTransfer", GLib.Variant("(s)", (last,)))
        except GLib.Error:
            pass
    try:
        last = lend(path)
    except (GLib.Error, OSError) as error:
        print(f"portal-transfer: {path}: {error}", file=sys.stderr, flush=True)
        last = None
    print(f"{path}\t{last or ''}", flush=True)
