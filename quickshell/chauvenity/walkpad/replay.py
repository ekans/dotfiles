# A fake pad: link.PadSource played from a script, for the tests and for
# niri-sandbox. It reaches nothing (no D-Bus, no Bluetooth) and feeds the
# controller real frame bytes, so the decoder, the recorder, the walk rules,
# the store and the wire all run as they do with the real pad.
#
# Chosen with WALKPAD_PAD=replay:PATH. The script, one directive per line,
# `#` comments:
#
#     pace 0                 seconds of real time per script second: 0 runs
#                            it at once (tests), 1 in real time (sandbox)
#     at -2d18h              set the virtual clock to start time + offset
#                            (start time = when the helper started)
#     pad MAXFREE-FAKE       the pad's name, for found/connected/waiting
#     on                     the pad is switched on and free: Connected;
#                            its counters start from zero
#     resume 180 0.15        the pad is on and free with its counters at
#                            180 s and 0.15 km: a pad a previous run left on
#     belt 3.0 600           the belt runs at 3.0 km/h for 600 s: a frame
#                            every 0.5 s on ffe2, the counters advancing
#     belt 0 120             paused: the pad repeats its frame, counters still
#     wait 30                the clock moves on, nothing is sent
#     drop                   the link drops, the pad stays on (counters kept)
#     back                   the link comes back (after a drop)
#     off                    the pad is switched off: link lost; the next
#                            `on` starts its counters from zero
#     held                   the iPhone holds the pad: Waiting, with BlueZ's
#                            error; `on` ends it
#     raw ffe1 EE,c0,…,FF    one notification verbatim (Latin-1; \xNN escapes)
#     bluetooth off|on       the adapter: Unavailable("Bluetooth is off")
#     end                    stop here and keep the state (default at EOF)
#
# The helper releasing the pad (close) is logged, so a test can tell a stop
# from an exit that leaves the pad connected.
#
# `belt` frames come from frame_for(), which writes the checksum, so the
# script stays readable and garbled frames are `raw` lines on purpose.
#
# set_enabled(False) reports Off and drops frames until enabled again, as the
# real link would; forget() reports Searching then the pad again.

from __future__ import annotations

import asyncio
import math
import re
import time
from dataclasses import dataclass
from pathlib import Path

from link import Connected, KnownPad, LinkState, Off, PadEvents, Searching, Unavailable, Waiting

#: The fake pad's address: not a real one, and not anyone's.
FAKE_ADDRESS = "00:00:00:00:00:00"
#: The pad sends a frame about this often while the belt runs.
FRAME_INTERVAL_S = 0.5
#: What the fake pad counts per km; the real one goes by its own table.
KCAL_PER_KM = 45
#: What BlueZ answers a Connect while the iPhone holds the pad.
HELD_ERROR = "Input/output error"
HELD_RETRY_S = 3.0

_OFFSET = re.compile(r"([+-]?)((?:[0-9]+[dhms])+|0)")
_UNITS = {"d": 86400, "h": 3600, "m": 60, "s": 1}
_ESCAPE = re.compile(r"\\x([0-9a-fA-F]{2})")


@dataclass(frozen=True)
class Directive:
    verb: str
    args: tuple[str, ...]
    line: int


def _offset_s(text: str) -> float | None:
    match = _OFFSET.fullmatch(text)
    if not match:
        return None
    total = sum(int(n) * _UNITS[u] for n, u in re.findall(r"([0-9]+)([dhms])", match.group(2)))
    return -total if match.group(1) == "-" else total


def _number(text: str) -> float | None:
    try:
        value = float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) and value >= 0 else None


def _raw_bytes(text: str) -> bytes | None:
    try:
        return _ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), text).encode("latin-1")
    except UnicodeEncodeError:
        return None


def _check(verb: str, args: list[str]) -> str:
    """Why the directive is wrong, or ""."""
    def count(n: int) -> str:
        return "" if len(args) == n else f"{verb} takes {n} argument{'s' if n != 1 else ''}"

    if verb in ("on", "off", "drop", "back", "held", "end"):
        return count(0)
    if verb == "pace" or verb == "wait":
        return count(1) or ("" if _number(args[0]) is not None else f"{verb} takes seconds, not {args[0]!r}")
    if verb == "at":
        return count(1) or ("" if _offset_s(args[0]) is not None else f"at takes an offset like -2d18h, not {args[0]!r}")
    if verb == "pad":
        return count(1)
    if verb == "resume":
        if error := count(2):
            return error
        if _number(args[0]) is None or _number(args[1]) is None:
            return f"resume takes seconds and km, not {' '.join(args)!r}"
        return ""
    if verb == "belt":
        if error := count(2):
            return error
        if _number(args[0]) is None or _number(args[1]) is None:
            return f"belt takes a speed in km/h and seconds, not {' '.join(args)!r}"
        return ""
    if verb == "raw":
        if error := count(2):
            return error
        if args[0] not in ("ffe1", "ffe2"):
            return f"raw takes ffe1 or ffe2, not {args[0]!r}"
        return "" if _raw_bytes(args[1]) is not None else "raw takes Latin-1 text"
    if verb == "bluetooth":
        return count(1) or ("" if args[0] in ("on", "off") else f"bluetooth takes on or off, not {args[0]!r}")
    return f"unknown directive {verb!r}"


def parse_script(text: str) -> list[Directive] | str:
    """The directives, or the first error as "line N: …". Validates every
    argument up front, so a bad script fails at start, not mid-walk."""
    directives = []
    for number, line in enumerate(text.splitlines(), start=1):
        line = line.split("#", 1)[0].strip() if not line.lstrip().startswith("raw ") else line.strip()
        if not line:
            continue
        verb, *args = line.split()
        if error := _check(verb, args):
            return f"line {number}: {error}"
        directives.append(Directive(verb, tuple(args), number))
    return directives


def frame_for(speed_kmh: float, elapsed_s: int, distance_km: float, calories: int) -> str:
    """A frame as the pad sends it, checksum included."""
    minutes, seconds = divmod(elapsed_s, 60)
    body = (f"EE,c0,sf0,st{20 if speed_kmh > 0 else 10},mp6.0,ms15,mi1.0,ca{calories},"
            f"dis{distance_km:.2f},h00,s0,p{speed_kmh:.1f},t{minutes}.{seconds:02d}")
    return f"{body},{(sum(body.encode('latin-1')) + 162) % 256:03d},FF"


class ReplaySource:
    """link.PadSource over a script. Its clock is virtual: `now()` is the
    script's time, so a pace-0 run of a 3-day script is deterministic."""

    def __init__(self, path: Path, log=lambda _: None) -> None:
        script = parse_script(Path(path).read_text())
        if isinstance(script, str):
            raise ValueError(f"{path}: {script}")
        self._script = script
        self._log = log
        #: What `at` offsets count from: when the helper started.
        self.started_at = time.time()
        self._clock = self.started_at
        self._pace = 0.0
        self._name = "MAXFREE-FAKE"
        self._events: PadEvents | None = None
        self._known: KnownPad | None = None
        self._enabled = True
        self._bluetooth = True
        self._powered = False
        self._dropped = False
        self._held: Waiting | None = None
        self._reported: LinkState | None = None
        self._task: asyncio.Task | None = None
        # The pad's own counters: elapsed in seconds, distance in km.
        self._elapsed = 0.0
        self._km = 0.0

    def now(self) -> float:
        return self._clock

    def start(self, events: PadEvents, known: KnownPad | None, enabled: bool) -> None:
        """Schedules `_play` on the running loop."""
        self._events = events
        self._known = known
        self._enabled = enabled
        self._task = asyncio.get_running_loop().create_task(self._play())

    def set_enabled(self, on: bool) -> None:
        self._enabled = on
        if self._events:
            self._update()

    def forget(self) -> None:
        self._known = None
        if self._events and self._enabled:
            self._report(Searching())
            self._update()

    async def close(self, release: bool = True) -> None:
        self._log("replay: released the pad" if release else "replay: left the pad connected")
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    def _state(self) -> LinkState:
        if not self._enabled:
            return Off()
        if not self._bluetooth:
            return Unavailable("Bluetooth is off")
        if self._held:
            return self._held
        if self._powered and not self._dropped:
            return Connected(self._name)
        if self._known is None:
            return Searching()
        return Waiting(self._known.name)

    def _update(self) -> None:
        state = self._state()
        if isinstance(state, Connected) and self._known != KnownPad(FAKE_ADDRESS, self._name):
            self._known = KnownPad(FAKE_ADDRESS, self._name)
            self._events.pad_found(self._known)
        self._report(state)

    def _report(self, state: LinkState) -> None:
        if state != self._reported:
            self._reported = state
            self._events.link_changed(state, self._clock)

    def _send(self, channel: str, data: bytes) -> None:
        if isinstance(self._reported, Connected):
            self._events.notification(channel, data, self._clock)

    def _frame(self, speed: float) -> bytes:
        km = math.floor(self._km * 100 + 1e-9) / 100
        return frame_for(speed, int(self._elapsed), km, int(km * KCAL_PER_KM)).encode("latin-1")

    async def _advance(self, seconds: float) -> None:
        self._clock += seconds
        await asyncio.sleep(seconds * self._pace)

    async def _play(self) -> None:
        self._update()
        for directive in self._script:
            verb, args = directive.verb, directive.args
            if verb == "end":
                break
            if verb == "pace":
                self._pace = float(args[0])
            elif verb == "at":
                self._clock = self.started_at + _offset_s(args[0])
            elif verb == "pad":
                self._name = args[0]
            elif verb == "wait":
                await self._advance(float(args[0]))
            elif verb == "on":
                if not self._powered or self._held:
                    self._elapsed = self._km = 0.0
                self._powered, self._dropped, self._held = True, False, None
                self._update()
                self._send("ffe2", self._frame(0.0))
            elif verb == "resume":
                self._elapsed, self._km = float(args[0]), float(args[1])
                self._powered, self._dropped, self._held = True, False, None
                self._update()
                self._send("ffe2", self._frame(0.0))
            elif verb == "off":
                self._powered, self._held = False, None
                self._update()
            elif verb == "drop":
                self._dropped = True
                self._update()
            elif verb == "back":
                self._dropped = False
                self._update()
            elif verb == "held":
                self._powered = False
                self._held = Waiting(self._name, self._clock + HELD_RETRY_S, HELD_ERROR)
                self._update()
            elif verb == "bluetooth":
                self._bluetooth = args[0] == "on"
                self._update()
            elif verb == "raw":
                self._send(args[0], _raw_bytes(args[1]))
            elif verb == "belt":
                speed, seconds = float(args[0]), float(args[1])
                for _ in range(max(1, round(seconds / FRAME_INTERVAL_S))):
                    await self._advance(FRAME_INTERVAL_S)
                    if speed > 0:
                        self._elapsed += FRAME_INTERVAL_S
                        self._km += speed * FRAME_INTERVAL_S / 3600
                    self._send("ffe2", self._frame(speed))
        self._log("replay: the script is over; the pad keeps its state")
