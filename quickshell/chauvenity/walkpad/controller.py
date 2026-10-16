# The walkpad: ties the pad source, the frame decoder, the recorder and the
# store together, and decides when a walk is over. A port of walkpad-ios's
# WalkController.swift without the phone's sensors.
#
# A walk is over when
#   - the pad's counters restart (the recorder opens a new walk),
#   - Finish walk is asked for (`finish`),
#   - the link drops with the belt stopped, speed <= 0 (`link_changed`),
#   - its counters have not moved for IDLE_LIMIT_S (`check_idle`, run on
#     every event and by the server's timer, so a pad switched off mid-pause
#     still ends its walk).
# At start the latest unfinished walk is the open one; older ones are finished.
#
# Synchronous and single-threaded: every method runs on the helper's event
# loop, called by a source (PadEvents) or by the server (commands). It reads
# no clock of its own: events carry `now`, commands use `source.now()`.

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Callable

from frames import FrameBuffer, PadReading
from link import Channel, Connected, KnownPad, LinkState, Off, PadSource
from recorder import Change, SpeedPoint, WalkRecorder
from store import Settings, Store, Walk

#: A walk whose counters have not moved for this long is over.
IDLE_LIMIT_S = 10 * 60


@dataclass(frozen=True)
class View:
    """Everything the bar can be told, at one instant. server.py turns it
    into wire lines; nothing else reads the controller's insides."""
    link: LinkState
    settings: Settings
    #: The pad's latest speed on this connection; None while not connected.
    speed_kmh: float | None
    open: Walk | None
    #: The open walk's speed trace, oldest first; empty without one.
    trace: tuple[SpeedPoint, ...]
    #: Store.revision: the walk list changed shape when this did.
    walks_revision: int
    problems: tuple[str, ...]


class WalkController:
    """Implements link.PadEvents. Owns: the recorder, the per-channel frame
    buffers, the live reading, the open walk's trace, and every write to the
    store."""

    def __init__(self, store: Store, source: PadSource, problems: list[str],
                 log: Callable[[str], None]) -> None:
        self.store = store
        self.source = source
        self.log = log
        #: Called after every event from the source; the server publishes then.
        self.changed: Callable[[], None] = lambda: None
        self._problems = tuple(problems)

        unfinished = store.unfinished()
        # Only the latest can still be going; anything older was cut short.
        for stale in unfinished[1:]:
            store.finish_walk(stale.id)
        self.open: Walk | None = unfinished[0] if unfinished else None
        self.trace: list[SpeedPoint] = store.samples(self.open.id) if self.open else []
        last = store.last_finished()
        self.recorder = WalkRecorder.resume(self.open and self.open.totals, last and last.totals)
        self.link: LinkState = Off()
        self.reading: PadReading | None = None
        self.buffers: dict[Channel, FrameBuffer] = {}
        self.settings = store.settings()
        source.start(self, self.settings.pad, self.settings.connect)
        # A walk left open overnight ends now, not at the first frame.
        self.check_idle(source.now())

    # --- PadEvents (from the source) -----------------------------------------

    def link_changed(self, state: LinkState, now: float) -> None:
        was_connected = isinstance(self.link, Connected)
        self.link = state
        if isinstance(state, Connected) and not was_connected:
            # A new connection starts mid-stream: nothing carries over.
            self.buffers = {}
            self.reading = None
        elif was_connected and not isinstance(state, Connected):
            stopped = (self.reading.speed_kmh if self.reading else 0) <= 0
            self.reading = None
            # Belt still running means the link dropped mid-walk: wait for it.
            if stopped:
                self.finish()
        self.check_idle(now)
        self.changed()

    def notification(self, channel: Channel, data: bytes, now: float) -> None:
        buffer = self.buffers.setdefault(channel, FrameBuffer())
        before = buffer.rejected
        for reading in buffer.append(data):
            self._record(reading, now)
        if buffer.rejected > before and buffer.should_log_rejection():
            self.log(f"rejected {buffer.rejected} frames on {channel}")
        self.changed()

    def pad_found(self, pad: KnownPad) -> None:
        if self.settings.pad != pad:
            self._save(replace(self.settings, pad=pad))
        self.changed()

    def _record(self, reading: PadReading, now: float) -> None:
        self.reading = reading
        change, sample = self.recorder.record(reading, now)
        if change is Change.IGNORED:
            self.check_idle(now)
            return
        if change is Change.OPENED:
            # The pad restarted its counters, so the previous walk is over.
            self.open = self.store.open_walk(self.recorder.current, closing=self.open and self.open.id)
            self.trace = []
        elif self.open:
            self.store.update_walk(self.open.id, self.recorder.current)
            self.open = replace(self.open, totals=self.recorder.current)
        if sample and self.open:
            self.store.add_sample(self.open.id, sample)
            self.trace.append(sample)

    # --- rules and commands -----------------------------------------------------

    def check_idle(self, now: float) -> None:
        """Finishes the open walk once its counters have not moved for
        IDLE_LIMIT_S."""
        if self.open and now - self.open.totals.ended_at > IDLE_LIMIT_S:
            self.finish()

    def finish(self) -> None:
        """Ends the open walk now. Idempotent."""
        self.recorder.finish()
        if self.open:
            self.store.finish_walk(self.open.id)
        self.open = None
        self.trace = []

    def delete(self, walk_id: int) -> bool:
        """Deletes a walk. Deleting the open one first finishes it in the
        recorder, so the pad's still-running counters carry on from it rather
        than fall back into the previous walk (walkpad-app's deleteWalk)."""
        if self.open and self.open.id == walk_id:
            self.recorder.finish()
            self.open = None
            self.trace = []
        return self.store.delete_walk(walk_id)

    def set_connect(self, on: bool) -> None:
        """Persists "Connect to the pad" and tells the source. `on` while on
        retries now: the panel's Try now, and the panel opening while Waiting."""
        if self.settings.connect != on:
            self._save(replace(self.settings, connect=on))
        self.source.set_enabled(on)

    def toggle_connect(self) -> bool:
        """Flips "Connect to the pad"; the new setting."""
        self.set_connect(not self.settings.connect)
        return self.settings.connect

    def forget(self) -> None:
        """Clears the remembered pad, and the source searches again."""
        self._save(replace(self.settings, pad=None))
        self.source.forget()

    def samples(self, walk_id: int) -> list[SpeedPoint]:
        return self.store.samples(walk_id)

    def _save(self, settings: Settings) -> None:
        self.settings = settings
        self.store.save_settings(settings)

    def view(self) -> View:
        connected = isinstance(self.link, Connected)
        return View(
            link=self.link,
            settings=self.settings,
            speed_kmh=self.reading.speed_kmh if connected and self.reading else None,
            open=self.open,
            trace=tuple(self.trace),
            walks_revision=self.store.revision,
            problems=self._problems,
        )
