# Turns the pad's readings into walks. A port of walkpad-ios's
# WalkRecorder.swift; tests/test_recorder.py is its WalkRecorderTests with the
# same literal values. Pure: times come in as arguments (seconds since the
# epoch, float), nothing here reads the clock or the store.
#
# A walk follows the pad's own counters: it opens when the belt first moves,
# keeps absorbing readings while elapsed time and distance only grow (a pause
# keeps the counters, so it stays one walk), and a new one opens once the
# counters restart, which the pad does when it is switched off or a walk is
# finished on the remote.
#
# The helper can also finish a walk itself (Finish walk, idle, link lost with
# the belt stopped). If the pad then carries on with the same counters, the
# next walk starts from where the finished one stopped (`pad_offset`) instead
# of counting it twice.

from __future__ import annotations

import enum
from dataclasses import dataclass, field, replace

from frames import PadReading, swift_round

#: A gap this long starts a new walk even if the counters look continuous.
MAX_GAP_S = 12 * 60 * 60
#: Speed points are kept at most this often; the pad sends several per second.
SAMPLE_INTERVAL_S = 1.0


def _metres(km: float) -> float:
    # Distances are rounded to the metre (the pad reports 10 m steps): the
    # pad's counters are rebuilt as walk + offset and compared with its next
    # reading, so float residue must not make them look like they went back.
    return swift_round(km * 1000) / 1000


@dataclass(frozen=True)
class PadCounters:
    """The pad's running totals for a walk."""
    elapsed_s: int
    distance_km: float
    calories: int

    @staticmethod
    def of(reading: PadReading) -> "PadCounters":
        return PadCounters(reading.elapsed_s, reading.distance_km, reading.calories)

    def follows(self, earlier: "PadCounters") -> bool:
        """Whether these counters can follow `earlier` on the same walk."""
        return self.elapsed_s >= earlier.elapsed_s and self.distance_km >= earlier.distance_km

    def __add__(self, other: "PadCounters") -> "PadCounters":
        return PadCounters(self.elapsed_s + other.elapsed_s,
                           _metres(self.distance_km + other.distance_km),
                           self.calories + other.calories)

    def __sub__(self, other: "PadCounters") -> "PadCounters":
        return PadCounters(self.elapsed_s - other.elapsed_s,
                           max(0.0, _metres(self.distance_km - other.distance_km)),
                           max(0, self.calories - other.calories))


ZERO = PadCounters(0, 0.0, 0)


@dataclass(frozen=True)
class WalkTotals:
    started_at: float
    #: When the counters last moved.
    ended_at: float
    counters: PadCounters
    max_speed_kmh: float
    #: What the pad's counters read when this walk was at zero: non-zero when
    #: it picked up after a walk the helper finished.
    pad_offset: PadCounters = ZERO

    @property
    def pad_counters(self) -> PadCounters:
        """The pad's own counters at the walk's last reading."""
        return self.counters + self.pad_offset


@dataclass(frozen=True)
class SpeedPoint:
    t: float
    speed_kmh: float
    distance_km: float


class Change(enum.Enum):
    IGNORED = "ignored"
    OPENED = "opened"
    UPDATED = "updated"


@dataclass
class WalkRecorder:
    """In-memory state of the walk being recorded. The controller rebuilds it
    from the store at start (`open`, `last_finished`), so it survives the
    helper restarting: the store is the durable copy, this is the cursor."""

    current: WalkTotals | None = None
    #: Where the pad's counters stood when the helper last finished a walk,
    #: and when.
    _finished: tuple[PadCounters, float] | None = field(default=None, repr=False)
    _last_sample_at: float | None = field(default=None, repr=False)
    _last_speed: float = field(default=-1.0, repr=False)

    @classmethod
    def resume(cls, open: WalkTotals | None, last_finished: WalkTotals | None = None) -> "WalkRecorder":
        """`open` is the walk still taking readings; `last_finished` the
        latest finished one, so a pad that kept counting carries on from it.
        `last_finished` is ignored when `open` is set (as in Swift)."""
        recorder = cls(current=open)
        if open is None and last_finished is not None:
            recorder._finished = (last_finished.pad_counters, last_finished.ended_at)
        return recorder

    def record(self, reading: PadReading, now: float) -> tuple[Change, SpeedPoint | None]:
        """Records a reading; the sample is the speed point to keep, if any."""
        pad = PadCounters.of(reading)
        walk = self.current
        if walk and now - walk.ended_at < MAX_GAP_S and pad.follows(walk.pad_counters):
            previous = walk.pad_counters
            moved = pad.elapsed_s != previous.elapsed_s or pad.distance_km != previous.distance_km
            # A paused pad repeats the same frame; only a speed change is news,
            # and the first idle frame after a restart is not (_last_speed
            # starts at -1).
            if not moved and (reading.speed_kmh == self._last_speed
                              or (reading.speed_kmh <= 0 and self._last_speed <= 0)):
                self._last_speed = reading.speed_kmh
                return Change.IGNORED, None
            if moved:
                self.current = replace(walk, ended_at=now, counters=pad - walk.pad_offset,
                                       max_speed_kmh=max(walk.max_speed_kmh, reading.speed_kmh))
            change = Change.UPDATED
        else:
            # Frozen or zeroed counters on an idle pad are not a walk.
            if reading.speed_kmh <= 0:
                return Change.IGNORED, None
            offset = ZERO
            if self._finished:
                counters, at = self._finished
                if now - at < MAX_GAP_S and pad.follows(counters):
                    offset = counters
            self._finished = None
            self.current = WalkTotals(now, now, pad - offset, reading.speed_kmh, offset)
            self._last_sample_at = None
            change = Change.OPENED

        # The point where the speed changes is always kept, so stops show sharp.
        sample = None
        if (self._last_sample_at is None or now - self._last_sample_at >= SAMPLE_INTERVAL_S
                or reading.speed_kmh != self._last_speed):
            sample = SpeedPoint(now, reading.speed_kmh, self.current.counters.distance_km)
            self._last_sample_at = now
        self._last_speed = reading.speed_kmh
        return change, sample

    def finish(self) -> None:
        """Ends the open walk; the next moving reading opens a new one, from
        the pad's counters as they stood. Idempotent: no open walk, no-op."""
        if self.current is None:
            return
        self._finished = (self.current.pad_counters, self.current.ended_at)
        self.current = None
