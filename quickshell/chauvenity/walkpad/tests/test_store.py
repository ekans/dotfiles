# The walk database: schema, the one-open-walk invariant, the single-writer
# lock and the one-time import of the BB walkpad plugin's history.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import hashlib
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from link import KnownPad
from recorder import ZERO, PadCounters, SpeedPoint, WalkTotals
from store import Settings, Store, StoreLocked, StoreTooNew, Walk

FIXTURES = Path(__file__).parent / "fixtures"
START = 1_800_000_000.0


def totals(at: float, elapsed: int = 60, km: float = 0.05) -> WalkTotals:
    return WalkTotals(started_at=at, ended_at=at + elapsed, counters=PadCounters(elapsed, km, 3), max_speed_kmh=3.0)


class Scratch(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.path = self.root / "data" / "walkpad.db"
        self.logged = []
        self.stores = []

    def tearDown(self):
        for store in self.stores:
            store.close()
        self.dir.cleanup()

    def open(self, import_from=None):
        store, problems = Store.open(self.path, import_from, log=self.logged.append)
        self.stores.append(store)
        return store, problems

    def reopen(self, store, import_from=None):
        store.close()
        self.stores.remove(store)
        return self.open(import_from)


class Schema(Scratch):
    def test_a_new_store_has_no_walks_and_the_default_settings(self):
        store, problems = self.open()
        self.assertEqual(problems, [])
        self.assertEqual(store.walks(), [])
        self.assertEqual(store.settings(), Settings(connect=True, pad=None))

    def test_keeps_walks_samples_and_settings_across_a_restart(self):
        store, _ = self.open()
        walk = store.open_walk(totals(START), closing=None)
        store.add_sample(walk.id, SpeedPoint(START, 3.0, 0.0))
        store.save_settings(Settings(connect=False, pad=KnownPad("00:00:00:00:00:00", "MAXFREE-TEST")))
        store, _ = self.reopen(store)
        self.assertEqual(store.walks(), [Walk(1, totals(START), finished=False)])
        self.assertEqual(store.samples(1), [SpeedPoint(START, 3.0, 0.0)])
        self.assertEqual(store.settings(), Settings(connect=False, pad=KnownPad("00:00:00:00:00:00", "MAXFREE-TEST")))

    def test_forgetting_the_pad_clears_both_its_rows(self):
        store, _ = self.open()
        store.save_settings(Settings(pad=KnownPad("00:00:00:00:00:00", "MAXFREE-TEST")))
        store.save_settings(Settings(pad=None))
        self.assertEqual(store.settings(), Settings(connect=True, pad=None))

    def test_lists_walks_newest_first(self):
        store, _ = self.open()
        first = store.open_walk(totals(START), closing=None)
        second = store.open_walk(totals(START + 3600), closing=first.id)
        self.assertEqual([w.id for w in store.walks()], [second.id, first.id])
        self.assertEqual(store.last_finished().id, first.id)

    def test_refuses_a_second_open_walk(self):
        store, _ = self.open()
        store.open_walk(totals(START), closing=None)
        self.assertIsNone(store.open_walk(totals(START + 3600), closing=None))
        self.assertEqual([(w.id, w.finished) for w in store.walks()], [(1, False)])
        self.assertEqual(len(self.logged), 1)
        self.assertIn("could not open a walk", self.logged[0])

    def test_opening_a_walk_finishes_the_one_it_replaces_in_the_same_transaction(self):
        store, _ = self.open()
        first = store.open_walk(totals(START), closing=None)
        broken = WalkTotals(None, START, PadCounters(1, 0.0, 0), 3.0)
        self.assertIsNone(store.open_walk(broken, closing=first.id))
        self.assertEqual([(w.id, w.finished) for w in store.walks()], [(1, False)])
        store.open_walk(totals(START + 3600), closing=first.id)
        self.assertEqual([(w.id, w.finished) for w in store.walks()], [(2, False), (1, True)])

    def test_deleting_a_walk_deletes_its_samples(self):
        store, _ = self.open()
        walk = store.open_walk(totals(START), closing=None)
        store.add_sample(walk.id, SpeedPoint(START, 3.0, 0.0))
        self.assertTrue(store.delete_walk(walk.id))
        self.assertEqual(store.walks(), [])
        self.assertEqual(store.samples(walk.id), [])
        self.assertFalse(store.delete_walk(walk.id))

    def test_the_revision_moves_on_open_finish_and_delete_but_not_on_update(self):
        store, _ = self.open()
        revisions = [store.revision]
        walk = store.open_walk(totals(START), closing=None)
        revisions.append(store.revision)
        store.update_walk(walk.id, totals(START, elapsed=120, km=0.1))
        revisions.append(store.revision)
        store.finish_walk(walk.id)
        revisions.append(store.revision)
        store.finish_walk(walk.id)
        revisions.append(store.revision)
        store.delete_walk(walk.id)
        revisions.append(store.revision)
        store.delete_walk(walk.id)
        revisions.append(store.revision)
        self.assertEqual(revisions, [0, 1, 1, 2, 2, 3, 3])

    def test_refuses_a_database_a_newer_helper_wrote(self):
        store, _ = self.open()
        store.close()
        self.stores.remove(store)
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("PRAGMA user_version = 2")
        with self.assertRaises(StoreTooNew):
            self.open()


class Lock(Scratch):
    def test_a_second_helper_cannot_open_the_same_database(self):
        store, _ = self.open()
        with self.assertRaises(StoreLocked):
            Store.open(self.path, None)
        self.reopen(store)


class ImportFromTheBbPlugin(Scratch):
    """fixtures/bb-plugin.sql is the plugin's schema (store.ts) with two
    made-up sessions and five samples, times in ms."""

    def setUp(self):
        super().setUp()
        self.plugin = self.root / "bb" / "data.db"
        self.plugin.parent.mkdir()
        with closing(sqlite3.connect(self.plugin)) as db, db:
            db.executescript((FIXTURES / "bb-plugin.sql").read_text())

    def test_imports_sessions_as_finished_walks_with_times_in_seconds(self):
        store, problems = self.open(self.plugin)
        self.assertEqual(problems, [])
        self.assertEqual(store.walks(), [
            Walk(2, WalkTotals(1800090000.0, 1800090300.0, PadCounters(300, 0.25, 11), 3.5, ZERO), finished=True),
            Walk(1, WalkTotals(1800000000.0, 1800000600.0, PadCounters(600, 0.5, 20), 3.0, ZERO), finished=True),
        ])

    def test_imports_samples_under_the_same_walk(self):
        store, _ = self.open(self.plugin)
        self.assertEqual(store.samples(1), [SpeedPoint(1800000000.0, 3.0, 0.0), SpeedPoint(1800000001.0, 3.0, 0.0),
                                            SpeedPoint(1800000600.0, 0.0, 0.5)])
        self.assertEqual(store.samples(2), [SpeedPoint(1800090000.0, 3.5, 0.0), SpeedPoint(1800090300.0, 0.0, 0.25)])

    def test_a_new_walk_after_the_import_takes_the_next_id(self):
        store, _ = self.open(self.plugin)
        self.assertEqual(store.open_walk(totals(START + 200_000), closing=None).id, 3)

    def test_imports_only_when_the_store_is_first_created(self):
        store, _ = self.open(self.plugin)
        store.delete_walk(1)
        store, problems = self.reopen(store, self.plugin)
        self.assertEqual(problems, [])
        self.assertEqual([w.id for w in store.walks()], [2])

    def test_a_missing_plugin_database_is_no_problem(self):
        store, problems = self.open(self.root / "nowhere" / "data.db")
        self.assertEqual(problems, [])
        self.assertEqual(store.walks(), [])

    def test_a_broken_plugin_database_is_a_problem_but_the_store_opens(self):
        self.plugin.write_bytes(b"not a database, but long enough to look like one" * 100)
        store, problems = self.open(self.plugin)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("Could not import the BB walkpad history: "), problems[0])
        self.assertEqual(store.walks(), [])
        self.assertEqual(store.open_walk(totals(START), closing=None).id, 1)

    def test_never_writes_to_the_plugin_database(self):
        before = hashlib.sha256(self.plugin.read_bytes()).hexdigest(), self.plugin.stat().st_mtime_ns
        self.plugin.chmod(0o444)
        store, problems = self.open(self.plugin)
        self.assertEqual(problems, [])
        self.assertEqual(len(store.walks()), 2)
        after = hashlib.sha256(self.plugin.read_bytes()).hexdigest(), self.plugin.stat().st_mtime_ns
        self.assertEqual(after, before)
        self.assertEqual(sorted(p.name for p in self.plugin.parent.iterdir()), ["data.db"])


if __name__ == "__main__":
    unittest.main()
