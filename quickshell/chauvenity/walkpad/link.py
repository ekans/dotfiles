# The contract between a pad source (bluez.py, the real pad; replay.py, a
# fake one) and the controller. A source knows how to reach a pad and turn it
# into notifications; it knows nothing about frames, walks or the store.
#
# Both sources run on the helper's one event loop and call PadEvents from it,
# so the controller never sees two events at once and needs no lock.

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol

#: The two characteristics the pad sends frames on. Each gets its own
#: FrameBuffer in the controller.
Channel = Literal["ffe2", "ffe1"]


@dataclass(frozen=True)
class KnownPad:
    """The remembered pad. `address` never leaves the helper: the bar sees
    the name only, and the store keeps both under $XDG_DATA_HOME."""
    address: str
    name: str


# LinkState: exactly one of these. What PadLink.State is in walkpad-ios, with
# `retry_at` and `error` added so the panel can say when the next try is.

@dataclass(frozen=True)
class Off:
    """Connect to the pad is switched off: the pad is free for the iPhone."""


@dataclass(frozen=True)
class Unavailable:
    """No adapter, adapter powered off, or bluetoothd not on the bus."""
    reason: str


@dataclass(frozen=True)
class Searching:
    """No remembered pad: looking in BlueZ's cache, then a short LE scan."""


@dataclass(frozen=True)
class Waiting:
    """A known pad that is not connected: connecting now (`retry_at` None),
    or failed and trying again at `retry_at`. Off and held by the iPhone look
    the same from here; `error` is BlueZ's last answer."""
    pad: str
    retry_at: float | None = None
    error: str = ""


@dataclass(frozen=True)
class Connected:
    pad: str


LinkState = Off | Unavailable | Searching | Waiting | Connected


class PadEvents(Protocol):
    """What a source tells the controller. `now` is the source's clock:
    time.time() for BlueZ, the script's virtual time for a replay."""

    def link_changed(self, state: LinkState, now: float) -> None: ...
    def notification(self, channel: Channel, data: bytes, now: float) -> None: ...
    def pad_found(self, pad: KnownPad) -> None: ...


class PadSource(Protocol):
    """A pad the helper can connect to. Every method is idempotent."""

    def start(self, events: PadEvents, known: KnownPad | None, enabled: bool) -> None:
        """Begins reaching the pad in the background on the running loop."""

    def set_enabled(self, on: bool) -> None:
        """Off: release the pad (StopNotify, Disconnect) and report Off.
        On while already on: try now, skipping the rest of the backoff."""

    def forget(self) -> None:
        """Drop the remembered pad, release it, and search again if enabled."""

    async def close(self, release: bool = True) -> None:
        """Stops reaching the pad, reporting nothing: the helper stopping is
        not the link dropping, so it must not finish a walk. `release` hands
        the pad back (StopNotify, Disconnect); without it the link stays up
        for the next helper, which is what an exit to reload wants."""

    def now(self) -> float:
        """The clock events are stamped with; the controller's idle check
        uses it too."""
