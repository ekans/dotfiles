# Where the helper reads, writes and listens, and the niri-sandbox guard.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import tempfile
import unittest
from pathlib import Path

from config import Bluez, Config, Replay, resolve

HOME = {"HOME": "/home/u", "XDG_RUNTIME_DIR": "/run/user/1000"}
SANDBOX = {"HOME": "/home/u", "XDG_RUNTIME_DIR": "/run/user/1000/niri-sandbox/thr_x", "NIRI_SANDBOX": "thr_x"}


class Defaults(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.script = Path(self.dir.name) / "walk.replay"
        self.script.write_text("pace 0\n")

    def tearDown(self):
        self.dir.cleanup()

    def test_the_service_reads_the_real_pad_into_the_real_database(self):
        self.assertEqual(resolve(HOME), Config(
            pad=Bluez(), db=Path("/home/u/.local/share/walkpad/walkpad.db"),
            socket=Path("/run/user/1000/walkpad.sock"), import_from=Path("/home/u/.bb/plugins/walkpad/data.db")))

    def test_follows_xdg_data_home(self):
        config = resolve(dict(HOME, XDG_DATA_HOME="/data"))
        self.assertEqual(config.db, Path("/data/walkpad/walkpad.db"))

    def test_every_path_can_be_chosen(self):
        config = resolve(dict(HOME, WALKPAD_PAD=f"replay:{self.script}", WALKPAD_DB="/tmp/w.db",
                              WALKPAD_SOCKET="/tmp/w.sock", WALKPAD_IMPORT="/tmp/bb.db"))
        self.assertEqual(config, Config(Replay(self.script), Path("/tmp/w.db"), Path("/tmp/w.sock"), Path("/tmp/bb.db")))

    def test_an_empty_variable_is_the_default(self):
        config = resolve(dict(HOME, WALKPAD_PAD="", WALKPAD_DB="", WALKPAD_SOCKET=""))
        self.assertEqual((config.pad, str(config.db), str(config.socket)),
                         (Bluez(), "/home/u/.local/share/walkpad/walkpad.db", "/run/user/1000/walkpad.sock"))

    def test_an_empty_import_imports_nothing(self):
        self.assertIsNone(resolve(dict(HOME, WALKPAD_IMPORT="")).import_from)

    def test_a_replay_script_that_does_not_exist_is_an_error(self):
        self.assertEqual(resolve(dict(HOME, WALKPAD_PAD="replay:/nowhere/walk.replay")),
                         "WALKPAD_PAD: no replay script at /nowhere/walk.replay")

    def test_an_unknown_pad_is_an_error(self):
        self.assertEqual(resolve(dict(HOME, WALKPAD_PAD="usb")), 'WALKPAD_PAD is "bluez" or "replay:PATH", not "usb"')

    def test_no_runtime_dir_is_an_error(self):
        self.assertEqual(resolve({"HOME": "/home/u"}), "set XDG_RUNTIME_DIR or WALKPAD_SOCKET")


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.script = Path(self.dir.name) / "sandbox.replay"
        self.script.write_text("pace 0\n")
        self.replay = f"replay:{self.script}"

    def tearDown(self):
        self.dir.cleanup()

    def test_refuses_the_real_pad(self):
        self.assertEqual(resolve(dict(SANDBOX, WALKPAD_DB="/tmp/x.db", WALKPAD_IMPORT="")),
                         "in niri-sandbox the pad must be WALKPAD_PAD=replay:…, not the real one")

    def test_refuses_the_default_database(self):
        refused = "in niri-sandbox set WALKPAD_DB to a scratch file, not the real database"
        for db in (None, "/home/u/.local/share/walkpad/walkpad.db", "/home/u/.local/share/walkpad/../walkpad/walkpad.db"):
            with self.subTest(db):
                env = dict(SANDBOX, WALKPAD_PAD=self.replay, WALKPAD_IMPORT="")
                if db:
                    env["WALKPAD_DB"] = db
                self.assertEqual(resolve(env), refused)

    def test_refuses_the_database_under_home_when_xdg_data_home_points_elsewhere(self):
        env = dict(SANDBOX, XDG_DATA_HOME="/scratch", WALKPAD_PAD=self.replay, WALKPAD_IMPORT="",
                   WALKPAD_DB="/home/u/.local/share/walkpad/walkpad.db")
        self.assertEqual(resolve(env), "in niri-sandbox set WALKPAD_DB to a scratch file, not the real database")

    def test_refuses_an_implicit_import(self):
        self.assertEqual(resolve(dict(SANDBOX, WALKPAD_PAD=self.replay, WALKPAD_DB="/tmp/x.db")),
                         'in niri-sandbox set WALKPAD_IMPORT ("" for none)')

    def test_is_recognised_by_its_runtime_dir_alone(self):
        env = {"HOME": "/home/u", "XDG_RUNTIME_DIR": "/run/user/1000/niri-sandbox/thr_x"}
        self.assertEqual(resolve(env), "in niri-sandbox the pad must be WALKPAD_PAD=replay:…, not the real one")

    def test_is_recognised_by_niri_sandbox_alone(self):
        env = dict(HOME, NIRI_SANDBOX="thr_x")
        self.assertEqual(resolve(env), "in niri-sandbox the pad must be WALKPAD_PAD=replay:…, not the real one")

    def test_runs_a_replay_on_a_scratch_database(self):
        config = resolve(dict(SANDBOX, WALKPAD_PAD=self.replay, WALKPAD_DB="/tmp/x.db", WALKPAD_IMPORT=""))
        self.assertEqual(config, Config(Replay(self.script), Path("/tmp/x.db"),
                                        Path("/run/user/1000/niri-sandbox/thr_x/walkpad.sock"), None))


if __name__ == "__main__":
    unittest.main()
