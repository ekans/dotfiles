# Walk history and the walkpad's settings, in SQLite under
# $XDG_DATA_HOME/walkpad/ (or WALKPAD_DB). Laid out like walkpad-ios's
# Models.swift, without what needs the iPhone (steps, Health export):
# times are seconds since the epoch (REAL), one row per walk and its speed
# samples.
#
# The helper is the only process that opens it, and the controller the only
# code that writes it: Store.open takes an exclusive lock next to the file and
# fails if another helper has it. The bar never reads the database.
#
# A failed write is logged and the helper carries on: losing one sample or
# one update beats stopping the walk (as Models.swift).

from __future__ import annotations

import fcntl
import os
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from link import KnownPad
from recorder import PadCounters, SpeedPoint, WalkTotals

SCHEMA_VERSION = 1

# PRAGMA user_version 0 -> 1. Run in one transaction with the BB import, so a
# crash halfway leaves an empty file that is migrated (and imported) again.
_SCHEMA = """
CREATE TABLE walks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at REAL NOT NULL,
  ended_at REAL NOT NULL,
  elapsed_s INTEGER NOT NULL,
  distance_km REAL NOT NULL,
  calories INTEGER NOT NULL,
  max_speed REAL NOT NULL,
  offset_elapsed_s INTEGER NOT NULL,
  offset_distance_km REAL NOT NULL,
  offset_calories INTEGER NOT NULL,
  finished INTEGER NOT NULL
);
-- At most one walk takes readings: the schema refuses a second open one.
CREATE UNIQUE INDEX one_open_walk ON walks(finished) WHERE finished = 0;
CREATE TABLE samples (
  walk_id INTEGER NOT NULL REFERENCES walks(id) ON DELETE CASCADE,
  t REAL NOT NULL,
  speed REAL NOT NULL,
  distance_km REAL NOT NULL
);
CREATE INDEX samples_by_walk ON samples(walk_id, t);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

# The BB walkpad plugin's sessions (times in ms, counters as the pad gave
# them, never finished by the plugin, so no offset). Ids are kept: the new
# table is empty when this runs.
_IMPORT_BB = """
INSERT INTO walks
  SELECT id, started_at / 1000.0, ended_at / 1000.0, elapsed_s, distance_km,
         calories, max_speed, 0, 0, 0, 1
  FROM bb.sessions;
INSERT INTO samples
  SELECT session_id, ts / 1000.0, speed, distance_km FROM bb.samples;
"""

_WALK_COLUMNS = """id, started_at, ended_at, elapsed_s, distance_km, calories, max_speed,
  offset_elapsed_s, offset_distance_km, offset_calories, finished"""
_NEWEST_FIRST = "ORDER BY started_at DESC, id DESC"


@dataclass(frozen=True)
class Walk:
    """A stored walk, as the wire and the controller see it."""
    id: int
    totals: WalkTotals
    finished: bool


@dataclass(frozen=True)
class Settings:
    #: "Connect to the pad": persisted, on by default.
    connect: bool = True
    pad: KnownPad | None = None


class StoreLocked(Exception):
    """Another helper holds this database."""


class StoreTooNew(Exception):
    """A newer helper wrote this database; this one would misread it."""


def _stderr(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def _walk(row) -> Walk:
    (id, started_at, ended_at, elapsed_s, distance_km, calories, max_speed,
     offset_elapsed_s, offset_distance_km, offset_calories, finished) = row
    return Walk(id, WalkTotals(started_at, ended_at, PadCounters(elapsed_s, distance_km, calories),
                               max_speed, PadCounters(offset_elapsed_s, offset_distance_km, offset_calories)),
                bool(finished))


def _totals_row(totals: WalkTotals) -> tuple:
    return (totals.started_at, totals.ended_at, totals.counters.elapsed_s, totals.counters.distance_km,
            totals.counters.calories, totals.max_speed_kmh, totals.pad_offset.elapsed_s,
            totals.pad_offset.distance_km, totals.pad_offset.calories)


class Store:
    """The only gateway to the database. `revision` grows whenever the walk
    list changes shape (a walk opened, finished, deleted); updating the open
    walk's totals does not bump it, because the bar takes those from the
    status line."""

    def __init__(self, db: sqlite3.Connection, lock: int, log: Callable[[str], None]) -> None:
        self._db = db
        self._lock = lock
        self._log = log
        self.revision = 0

    @classmethod
    def open(cls, path: Path, import_from: Path | None,
             log: Callable[[str], None] = _stderr) -> tuple["Store", list[str]]:
        """Opens or creates the database; returns it with problems to show.
        Raises StoreLocked or StoreTooNew when this helper must not use it."""
        path = Path(path).absolute()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = os.open(f"{path}.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(lock)
            raise StoreLocked(f"another walkpad has {path} open") from None

        # A URI connection, so that ATTACH below can open the plugin's
        # database with mode=ro.
        db = sqlite3.connect(path.as_uri(), uri=True, autocommit=True)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=NORMAL")
        db.execute("PRAGMA foreign_keys=ON")
        store = cls(db, lock, log)
        problems: list[str] = []
        version = db.execute("PRAGMA user_version").fetchone()[0]
        if version > SCHEMA_VERSION:
            store.close()
            raise StoreTooNew(f"{path} is schema {version}; this walkpad reads {SCHEMA_VERSION}")
        if version == 0:
            store._create(import_from, problems)
        return store, problems

    def _create(self, import_from: Path | None, problems: list[str]) -> None:
        # SQLite refuses ATTACH and DETACH inside a transaction, so the
        # plugin's database is attached around it.
        attached = False
        if import_from is not None and import_from.exists():
            try:
                self._db.execute("ATTACH ? AS bb", (Path(import_from).absolute().as_uri() + "?mode=ro",))
                attached = True
            except sqlite3.Error as error:
                problems.append(f"Could not import the BB walkpad history: {error}")
        self._db.execute("BEGIN IMMEDIATE")
        try:
            self._db.executescript(_SCHEMA)
            if attached:
                self._db.execute("SAVEPOINT import")
                try:
                    self._db.executescript(_IMPORT_BB)
                except sqlite3.Error as error:
                    self._db.execute("ROLLBACK TO import")
                    problems.append(f"Could not import the BB walkpad history: {error}")
                self._db.execute("RELEASE import")
            self._db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            self._db.execute("COMMIT")
        except BaseException:
            self._db.execute("ROLLBACK")
            raise
        finally:
            if attached:
                self._db.execute("DETACH bb")

    def _write(self, what: str, *statements: tuple[str, tuple]) -> sqlite3.Cursor | None:
        """Runs `statements` in one transaction; the last one's cursor, or
        None once the failure is logged."""
        try:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                for sql, args in statements:
                    cursor = self._db.execute(sql, args)
                self._db.execute("COMMIT")
                return cursor
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
        except sqlite3.Error as error:
            self._log(f"store: could not {what}: {error}")
            return None

    # --- walks -------------------------------------------------------------

    def walks(self) -> list[Walk]:
        """Every walk, newest first."""
        return [_walk(row) for row in self._db.execute(f"SELECT {_WALK_COLUMNS} FROM walks {_NEWEST_FIRST}")]

    def unfinished(self) -> list[Walk]:
        """Unfinished walks, newest first. More than one only in a database
        an older helper wrote; the controller finishes all but the first."""
        return [_walk(row) for row in self._db.execute(
            f"SELECT {_WALK_COLUMNS} FROM walks WHERE finished = 0 {_NEWEST_FIRST}")]

    def last_finished(self) -> Walk | None:
        row = self._db.execute(f"SELECT {_WALK_COLUMNS} FROM walks WHERE finished = 1 {_NEWEST_FIRST} LIMIT 1").fetchone()
        return _walk(row) if row else None

    def open_walk(self, totals: WalkTotals, closing: int | None) -> Walk | None:
        """In one transaction: finish walk `closing` (the one the counters
        restarting ended), then insert `totals` as the open walk. A crash
        cannot leave two open walks or none between them. None if it failed."""
        statements = [("UPDATE walks SET finished = 1 WHERE id = ?", (closing,))] if closing is not None else []
        statements.append(("INSERT INTO walks (started_at, ended_at, elapsed_s, distance_km, calories, max_speed,"
                           " offset_elapsed_s, offset_distance_km, offset_calories, finished)"
                           " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)", _totals_row(totals)))
        cursor = self._write("open a walk", *statements)
        if cursor is None:
            return None
        self.revision += 1
        return Walk(cursor.lastrowid, totals, False)

    def update_walk(self, walk_id: int, totals: WalkTotals) -> None:
        """The open walk's totals after a reading."""
        self._write("update a walk", (
            "UPDATE walks SET started_at = ?, ended_at = ?, elapsed_s = ?, distance_km = ?, calories = ?,"
            " max_speed = ?, offset_elapsed_s = ?, offset_distance_km = ?, offset_calories = ? WHERE id = ?",
            _totals_row(totals) + (walk_id,)))

    def finish_walk(self, walk_id: int) -> None:
        """Idempotent: finishing a finished walk changes nothing."""
        cursor = self._write("finish a walk", ("UPDATE walks SET finished = 1 WHERE id = ? AND finished = 0", (walk_id,)))
        if cursor is not None and cursor.rowcount:
            self.revision += 1

    def delete_walk(self, walk_id: int) -> bool:
        """Deletes the walk and, by cascade, its samples. False if it was not
        there."""
        cursor = self._write("delete a walk", ("DELETE FROM walks WHERE id = ?", (walk_id,)))
        if cursor is None or not cursor.rowcount:
            return False
        self.revision += 1
        return True

    def add_sample(self, walk_id: int, point: SpeedPoint) -> None:
        self._write("add a sample", ("INSERT INTO samples VALUES (?, ?, ?, ?)",
                                     (walk_id, point.t, point.speed_kmh, point.distance_km)))

    def samples(self, walk_id: int) -> list[SpeedPoint]:
        """The walk's speed trace, oldest first, every point: the bar reduces
        it to the chart's width."""
        return [SpeedPoint(*row) for row in self._db.execute(
            "SELECT t, speed, distance_km FROM samples WHERE walk_id = ? ORDER BY t, rowid", (walk_id,))]

    # --- settings ----------------------------------------------------------

    def settings(self) -> Settings:
        rows = dict(self._db.execute("SELECT key, value FROM settings"))
        pad = KnownPad(rows["pad_address"], rows["pad_name"]) if "pad_address" in rows and "pad_name" in rows else None
        return Settings(connect=rows.get("connect", "1") == "1", pad=pad)

    def save_settings(self, settings: Settings) -> None:
        upsert = "INSERT OR REPLACE INTO settings VALUES (?, ?)"
        statements = [(upsert, ("connect", "1" if settings.connect else "0"))]
        if settings.pad:
            statements += [(upsert, ("pad_address", settings.pad.address)), (upsert, ("pad_name", settings.pad.name))]
        else:
            statements.append(("DELETE FROM settings WHERE key IN ('pad_address', 'pad_name')", ()))
        self._write("save the settings", *statements)

    def close(self) -> None:
        self._db.close()
        os.close(self._lock)
