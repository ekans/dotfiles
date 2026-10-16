# The helper's socket: the one way into the walkpad, for the bar
# (WalkpadService.qml) and for a person debugging it:
#
#     socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/walkpad.sock     then type `watch`
#
# Everything the wire is lives here and in walkpad.mjs, its reader;
# tests/fixtures/wire.jsonl is the contract both test against.
#
# A Unix stream socket at WALKPAD_SOCKET, by default
# $XDG_RUNTIME_DIR/walkpad.sock. Text lines, UTF-8, one per message.
#
# Client -> helper, one command per line:
#
#     watch                 the full state now, then every change (the bar)
#     finish                finish the open walk (no-op without one)
#     delete 12             delete walk 12, open or not
#     connect on|off|toggle "Connect to the pad"; `on` while on tries now
#     forget                forget the remembered pad and look again
#     samples 12            walk 12's speed trace, to this client only
#
# `samples` is answered with its samples line. Every other command but
# `watch` is answered, to its sender only, with
#
#     {"type":"done","cmd":"delete 12","error":""}
#
# Helper -> watching clients, JSON objects, one per line (times in ms since
# the epoch, as calendar-events.py):
#
#     {"type":"status","protocol":1,"link":{"state":"connected","pad":"MAXFREE03650"},
#      "connect":true,"pad":"MAXFREE03650","speedKmh":3.2,
#      "open":{"id":17,"startedAt":1792141200000,"endedAt":1792141954000,
#              "elapsedS":754,"distanceKm":0.62,"calories":31,"maxSpeedKmh":3.5},
#      "problems":[]}
#     {"type":"walks","walks":[{"id":17,"startedAt":…,"endedAt":…,"elapsedS":754,
#      "distanceKm":0.62,"calories":31,"maxSpeedKmh":3.5,"open":true}, …]}
#     {"type":"trace","walk":17,"points":[[1792141200000,3.0],[1792141201000,3.0]]}
#     {"type":"point","walk":17,"point":[1792141955000,3.2]}
#     {"type":"samples","walk":12,"points":[[…,2.8],…]}
#
# link is one of {"state":"off"}, {"state":"unavailable","reason":"Bluetooth is off"},
# {"state":"searching"}, {"state":"waiting","pad":"…","retryAt":ms|null,"error":"…"},
# {"state":"connected","pad":"…"}.
#
# What a watching client is sent is derived, never queued: each client has a
# Cursor saying what it has seen, and `publish` sends the difference between
# the View and the Cursor. A new client's Cursor is empty, so the snapshot on
# `watch` and every later change take the same code path.

from __future__ import annotations

import asyncio
import json
import os
import signal
import socket
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Literal

from controller import View, WalkController
from link import Connected, LinkState, Off, Searching, Unavailable, Waiting
from recorder import SpeedPoint
from store import Walk

#: Bumped when a line's meaning changes; walkpad.mjs has the same number and
#: says so when they differ (a service older than the bar, until restarted).
PROTOCOL = 1

#: How often the idle rule runs with no event to run it.
TICK_S = 30.0

#: A client whose unread lines pass this is dropped; the bar reconnects.
MAX_BUFFER = 1 << 20


# --- commands -------------------------------------------------------------------

@dataclass(frozen=True)
class Command:
    name: Literal["watch", "finish", "delete", "connect", "forget", "samples"]
    #: Walk id for delete/samples; "on" / "off" / "toggle" for connect.
    arg: int | str | None = None


def parse_command(line: str) -> Command | str:
    """A Command, or the error to answer with. Validates the argument's shape
    (an int id; on/off/toggle) so the controller gets domain values only."""
    words = line.split()
    if not words:
        return "empty command"
    name, args = words[0], words[1:]
    if name in ("watch", "finish", "forget"):
        return Command(name) if not args else f"{name} takes no argument"
    if name in ("delete", "samples"):
        if len(args) != 1 or not args[0].isascii() or not args[0].isdigit():
            return f"{name} takes a walk id"
        return Command(name, int(args[0]))
    if name == "connect":
        if len(args) != 1 or args[0] not in ("on", "off", "toggle"):
            return "connect takes on, off or toggle"
        return Command(name, args[0])
    return f'unknown command "{name}"'


def run_command(controller: WalkController, command: Command) -> tuple[str, list[str]]:
    """Applies a command; returns (error, lines for this client only)."""
    if command.name == "finish":
        controller.finish()
    elif command.name == "delete":
        if not controller.delete(command.arg):
            return f"no walk {command.arg}", []
    elif command.name == "connect":
        if command.arg == "toggle":
            controller.toggle_connect()
        else:
            controller.set_connect(command.arg == "on")
    elif command.name == "forget":
        controller.forget()
    elif command.name == "samples":
        points = controller.samples(command.arg)
        if points is None:
            return f"no walk {command.arg}", []
        return "", [_line({"type": "samples", "walk": command.arg, "points": [encode_point(p) for p in points]})]
    return "", []


def done_line(cmd: str, error: str) -> str:
    return _line({"type": "done", "cmd": cmd, "error": error})


# --- view -> lines ------------------------------------------------------------

@dataclass
class Cursor:
    """What one watching client has been sent."""
    status: str | None = None
    walks_revision: int = -1
    trace_walk: int | None | Literal["unsent"] = "unsent"
    trace_len: int = 0


def _line(message: dict) -> str:
    # Compact, so an unchanged state encodes to an identical string.
    return json.dumps(message, separators=(",", ":"), ensure_ascii=False)


def _ms(t: float) -> int:
    return round(t * 1000)


def encode_link(link: LinkState) -> dict:
    if isinstance(link, Off):
        return {"state": "off"}
    if isinstance(link, Unavailable):
        return {"state": "unavailable", "reason": link.reason}
    if isinstance(link, Searching):
        return {"state": "searching"}
    if isinstance(link, Waiting):
        return {"state": "waiting", "pad": link.pad,
                "retryAt": _ms(link.retry_at) if link.retry_at is not None else None, "error": link.error}
    if isinstance(link, Connected):
        return {"state": "connected", "pad": link.pad}
    raise TypeError(f"not a link state: {link!r}")


def _walk_fields(walk: Walk) -> dict:
    totals = walk.totals
    return {"id": walk.id, "startedAt": _ms(totals.started_at), "endedAt": _ms(totals.ended_at),
            "elapsedS": totals.counters.elapsed_s, "distanceKm": totals.counters.distance_km,
            "calories": totals.counters.calories, "maxSpeedKmh": totals.max_speed_kmh}


def encode_walk(walk: Walk) -> dict:
    return dict(_walk_fields(walk), open=not walk.finished)


def encode_point(point: SpeedPoint) -> list:
    return [_ms(point.t), point.speed_kmh]


def encode_status(view: View) -> str:
    return _line({
        "type": "status", "protocol": PROTOCOL, "link": encode_link(view.link),
        "connect": view.settings.connect, "pad": view.settings.pad.name if view.settings.pad else None,
        "speedKmh": view.speed_kmh, "open": _walk_fields(view.open) if view.open else None,
        "problems": list(view.problems),
    })


def publish(view: View, cursor: Cursor, load_walks: Callable[[], list[Walk]]) -> list[str]:
    """Lines that bring `cursor` up to `view`, advancing it. Pure but for
    `load_walks`, called only when the walk list changed."""
    lines = []
    if (status := encode_status(view)) != cursor.status:
        lines.append(status)
        cursor.status = status
    if view.walks_revision != cursor.walks_revision:
        lines.append(_line({"type": "walks", "walks": [encode_walk(w) for w in load_walks()]}))
        cursor.walks_revision = view.walks_revision
    open_id = view.open.id if view.open else None
    if cursor.trace_walk != open_id or len(view.trace) < cursor.trace_len:
        # A new walk, or a client that has nothing yet: the whole trace.
        lines.append(_line({"type": "trace", "walk": open_id, "points": [encode_point(p) for p in view.trace]}))
    else:
        lines += [_line({"type": "point", "walk": open_id, "point": encode_point(p)})
                  for p in view.trace[cursor.trace_len:]]
    cursor.trace_walk, cursor.trace_len = open_id, len(view.trace)
    return lines


# --- the socket ---------------------------------------------------------------

class Server:
    """Owns the listening socket and the clients. After every event and every
    command it calls `publish` for each watching client."""

    def __init__(self, socket_path: Path, log: Callable[[str], None]) -> None:
        self.socket_path = socket_path
        self.log = log
        self.controller: WalkController | None = None
        self._server: asyncio.Server | None = None
        self._watching: dict[asyncio.StreamWriter, Cursor] = {}
        self._clients: set[asyncio.StreamWriter] = set()
        self._stop = asyncio.Event()
        self._reason = "stop"

    async def listen(self) -> str:
        """Binds the socket without serving yet; why it could not, or ""."""
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(self.socket_path))
            return f"another walkpad serves {self.socket_path}"
        except (FileNotFoundError, ConnectionRefusedError):
            pass
        finally:
            probe.close()
        self.socket_path.unlink(missing_ok=True)
        self.socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._server = await asyncio.start_unix_server(self._client, self.socket_path, start_serving=False)
        os.chmod(self.socket_path, 0o600)
        return ""

    def stop(self, reason: Literal["stop", "reload"]) -> None:
        self._reason = reason
        self._stop.set()

    async def run(self, controller: WalkController) -> str:
        """Serves `controller` until stopped: by SIGTERM or SIGINT ("stop")
        or by stop("reload"). Returns which."""
        self.controller = controller
        controller.changed = self.publish_all
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(signum, self.stop, "stop")
        tick = loop.create_task(self._tick())
        await self._server.start_serving()
        self.log(f"serving {self.socket_path}")
        try:
            await self._stop.wait()
        finally:
            tick.cancel()
            controller.changed = lambda: None
        return self._reason

    async def close(self) -> None:
        if self._server:
            self._server.close()
            self.socket_path.unlink(missing_ok=True)
        for writer in list(self._clients):
            writer.close()

    async def _tick(self) -> None:
        while True:
            await asyncio.sleep(TICK_S)
            self.controller.check_idle(self.controller.source.now())
            self.publish_all()

    async def _client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Reads commands line by line until EOF."""
        self._clients.add(writer)
        try:
            while line := await reader.readline():
                text = line.decode("utf-8", "replace").strip()
                command = parse_command(text)
                if isinstance(command, str):
                    self._send(writer, [done_line(text, command)])
                elif command.name == "watch":
                    self._watching.setdefault(writer, Cursor())
                    self.publish_all()
                else:
                    error, lines = run_command(self.controller, command)
                    self._send(writer, lines if lines else [done_line(text, error)])
                    self.publish_all()
        except (ConnectionError, ValueError):
            # A reset connection, or a line past the reader's limit.
            pass
        finally:
            self._drop(writer)

    def _send(self, writer: asyncio.StreamWriter, lines: list[str]) -> None:
        if writer.is_closing():
            return
        writer.write("".join(f"{line}\n" for line in lines).encode())
        if writer.transport.get_write_buffer_size() > MAX_BUFFER:
            self.log("dropping a client that does not read")
            self._drop(writer)

    def _drop(self, writer: asyncio.StreamWriter) -> None:
        self._watching.pop(writer, None)
        self._clients.discard(writer)
        writer.close()

    def publish_all(self) -> None:
        if not self._watching or not self.controller:
            return
        view = self.controller.view()
        walks = None

        def load_walks() -> list[Walk]:
            nonlocal walks
            if walks is None:
                walks = self.controller.walks()
            return walks

        for writer, cursor in list(self._watching.items()):
            if lines := publish(view, cursor, load_walks):
                self._send(writer, lines)
