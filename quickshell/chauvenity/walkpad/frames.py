# Decoder for the frames a CITYSPORTS walking pad (tested on the CS-WP2)
# streams over BLE. The pad advertises as MAXFREExxxxx and sends ASCII frames
# on the vendor characteristic ffe2 (and ffe1 once subscribed), a few times a
# second:
#
#   EE,c0,sf0,st20,mp6.0,ms15,mi1.0,ca36,dis1.23,h00,s0,p3.0,t24.38,077,FF
#
#   p   current speed, km/h        dis  distance, km
#   ca  calories, kcal             t    elapsed time as minutes.seconds
#   st  status: 10 idle/paused, 20 steady, 30 speeding up, 40 slowing down
#   h   heart rate (0 without a sensor)
#   mp / mi  max / min speed, km/h
#   the number before FF is (byte sum of everything before it + 162) % 256
#
# A port of walkpad-ios's PadFrame.swift, kept to its exact semantics:
# tests/test_frames.py is its PadFrameTests and FrameBufferTests, values
# unchanged. Pure: no I/O, no clock.
#
# Where Python and Swift parse differently, Swift wins:
#   - int() accepts " 7", "7_7" and non-ASCII digits; Swift's Int() does not,
#     so integers go through _INT.
#   - str.isdigit() is true for "²" (a Latin-1 byte); the field check uses
#     the explicit set _NUMBER_CHARS.
#   - round() rounds half to even; Swift's .rounded() rounds half away from
#     zero, so calories go through swift_round().

from __future__ import annotations

import enum
import math
import re
from dataclasses import dataclass

_INT = re.compile(r"[+-]?[0-9]+")
_KEY = re.compile(r"[a-z]*")
_NUMBER_CHARS = frozenset("0123456789.")

#: A notification buffer that grows past this without closing a frame is noise.
BUFFER_CAP = 512


class PadStatus(enum.Enum):
    IDLE = "idle"
    RUNNING = "running"
    SPEEDING_UP = "speeding-up"
    SLOWING_DOWN = "slowing-down"
    UNKNOWN = "unknown"


_STATUSES = {"10": PadStatus.IDLE, "20": PadStatus.RUNNING,
             "30": PadStatus.SPEEDING_UP, "40": PadStatus.SLOWING_DOWN}


@dataclass(frozen=True)
class PadReading:
    speed_kmh: float
    distance_km: float
    calories: int
    elapsed_s: int
    heart_rate: int
    status: PadStatus
    max_speed_kmh: float
    min_speed_kmh: float


def swift_round(x: float) -> int:
    """Half away from zero, as Swift's `Double.rounded()`."""
    return int(math.copysign(math.floor(abs(x) + 0.5), x))


def _integer(text: str) -> int | None:
    return int(text) if _INT.fullmatch(text) else None


def parse_frame(frame: str) -> PadReading | None:
    """One frame, `EE,…,NNN,FF`, as Latin-1 text; None when it is malformed or
    fails its checksum. A field that is not a lower-case key followed by
    digits and dots is skipped rather than fatal, and a missing number reads
    as 0. t is minutes.seconds: "24.38" is 24 * 60 + 38."""
    parts = frame.split(",")
    if len(parts) < 4 or parts[0] != "EE" or parts[-1] != "FF":
        return None
    checksum = _integer(parts[-2])
    if checksum is None or (sum(map(ord, ",".join(parts[:-2]))) + 162) % 256 != checksum:
        return None

    fields: dict[str, str] = {}
    for part in parts[1:-2]:
        key = _KEY.match(part).group()
        value = part[len(key):]
        if key and value and all(c in _NUMBER_CHARS for c in value):
            fields[key] = value

    def number(key: str) -> float:
        try:
            value = float(fields.get(key, "0"))
        except ValueError:
            return 0.0
        return value if math.isfinite(value) else 0.0

    time = fields.get("t", "0.0").split(".")
    minutes = _integer(time[0]) or 0
    seconds = (_integer(time[1]) or 0) if len(time) > 1 else 0
    return PadReading(
        speed_kmh=number("p"),
        distance_km=number("dis"),
        calories=swift_round(number("ca")),
        elapsed_s=minutes * 60 + seconds,
        heart_rate=swift_round(number("h")),
        status=_STATUSES.get(fields.get("st", ""), PadStatus.UNKNOWN),
        max_speed_kmh=number("mp"),
        min_speed_kmh=number("mi"),
    )


class FrameBuffer:
    """Cuts one characteristic's notification stream into readings: one
    notification can carry part of a frame or several of them.

    One buffer per characteristic (ffe2, ffe1): the pad sends to whichever was
    subscribed last, and two streams must never be spliced into one frame.
    """

    def __init__(self) -> None:
        self._buffer = bytearray()
        #: Frames that failed to decode. Worth logging: undecodable frames
        #: otherwise look exactly like a pad that never moves.
        self.rejected = 0

    def append(self, data: bytes) -> list[PadReading]:
        """Readings completed by `data`, in order."""
        self._buffer += data
        readings = []
        while (end := self._buffer.find(b"FF")) != -1:
            frame = bytes(self._buffer[: end + 2])
            del self._buffer[: end + 2]
            start = frame.find(b"EE")
            reading = parse_frame(frame[start:].decode("latin-1")) if start != -1 else None
            if reading:
                readings.append(reading)
            else:
                self.rejected += 1
        if len(self._buffer) > BUFFER_CAP:
            self._buffer.clear()
        return readings

    def should_log_rejection(self) -> bool:
        """True on the 1st, 101st, 201st… rejected frame: the caller logs it
        then, as PadLink.swift and pad.ts do (`rejected % 100 == 1`)."""
        return self.rejected % 100 == 1
