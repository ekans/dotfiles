# The wire: commands in, lines out, and the helper end to end on a replayed
# pad. fixtures/wire.jsonl is the contract with walkpad.mjs:
# test_lines_match_the_contract writes the lines a scripted walk produces and
# compares them with it; tests/walkpad.test.mjs reads the same file.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from controller import WalkController
from link import Connected, KnownPad, Off, Searching, Unavailable, Waiting
from recorder import PadCounters, SpeedPoint, WalkTotals
from replay import FAKE_ADDRESS
from server import Command, Cursor, done_line, encode_link, parse_command, publish, run_command
from store import Store
from tests.test_controller import START, HandSource, pad_frame

WALKPAD = Path(__file__).resolve().parent.parent
FIXTURES = WALKPAD / "tests" / "fixtures"
CONTRACT = FIXTURES / "wire.jsonl"
FAKE = KnownPad(FAKE_ADDRESS, "MAXFREE-FAKE")
DAY = 86400


class Scratch(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store, _ = Store.open(Path(self.dir.name) / "walkpad.db", import_from=None)
        self.source = HandSource()
        self.controller = WalkController(self.store, self.source, [], log=lambda _: None)

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def publish(self, cursor):
        return [json.loads(line) for line in publish(self.controller.view(), cursor, self.controller.walks)]


class Commands(Scratch):
    def test_reads_every_command(self):
        self.assertEqual([parse_command(line) for line in
                          ("watch", "finish", "delete 12", "connect on", "connect off", "connect toggle",
                           "forget", "samples 12", "  samples   3  ")],
                         [Command("watch"), Command("finish"), Command("delete", 12), Command("connect", "on"),
                          Command("connect", "off"), Command("connect", "toggle"), Command("forget"),
                          Command("samples", 12), Command("samples", 3)])

    def test_answers_a_bad_command_with_the_reason(self):
        self.assertEqual([parse_command(line) for line in
                          ("delete x", "delete", "samples ٣", "connect maybe", "finish now", "dance", "")],
                         ["delete takes a walk id", "delete takes a walk id", "samples takes a walk id",
                          "connect takes on, off or toggle", "finish takes no argument", 'unknown command "dance"',
                          "empty command"])

    def test_finish_and_delete_reach_the_walks(self):
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        open_id = self.controller.view().open.id
        self.assertEqual(run_command(self.controller, Command("finish")), ("", []))
        self.assertTrue(self.store.walks()[0].finished)
        self.assertEqual(run_command(self.controller, Command("delete", open_id)), ("", []))
        self.assertEqual(run_command(self.controller, Command("delete", open_id)), (f"no walk {open_id}", []))

    def test_connect_toggles_and_forget_reach_the_link(self):
        for command in (Command("connect", "toggle"), Command("connect", "on"), Command("forget")):
            self.assertEqual(run_command(self.controller, command), ("", []))
        self.assertEqual(self.source.calls[1:], [("enabled", False), ("enabled", True), ("forget",)])

    def test_samples_of_a_walk_that_is_not_there(self):
        self.assertEqual(run_command(self.controller, Command("samples", 4)), ("no walk 4", []))

    def test_the_done_line(self):
        self.assertEqual(done_line("delete 12", ""), '{"type":"done","cmd":"delete 12","error":""}')


class Publish(Scratch):
    def test_encodes_every_link_state(self):
        self.assertEqual([encode_link(s) for s in (Off(), Unavailable("Bluetooth is off"), Searching(),
                                                   Waiting("P"), Waiting("P", START + 0.5, "Input/output error"),
                                                   Connected("P"))],
                         [{"state": "off"}, {"state": "unavailable", "reason": "Bluetooth is off"},
                          {"state": "searching"}, {"state": "waiting", "pad": "P", "retryAt": None, "error": ""},
                          {"state": "waiting", "pad": "P", "retryAt": 1800000000500, "error": "Input/output error"},
                          {"state": "connected", "pad": "P"}])

    def test_a_new_client_gets_status_walks_and_trace(self):
        self.assertEqual([m["type"] for m in self.publish(Cursor())], ["status", "walks", "trace"])

    def test_an_unchanged_state_sends_nothing(self):
        cursor = Cursor()
        self.publish(cursor)
        self.assertEqual(self.publish(cursor), [])
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.publish(cursor)
        self.source.send(0.2, 3.0, 60, 0.05)
        self.assertEqual(self.publish(cursor), [])

    def test_a_new_speed_point_is_sent_as_a_point_not_the_whole_trace(self):
        cursor = Cursor()
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.publish(cursor)
        self.source.send(1, 3.2, 61, 0.05)
        self.source.send(2, 3.4, 62, 0.06)
        messages = self.publish(cursor)
        self.assertEqual([m["type"] for m in messages], ["status", "point", "point"])
        self.assertEqual([m["point"] for m in messages[1:]], [[1800000001000, 3.2], [1800000002000, 3.4]])

    def test_a_new_walk_resends_the_trace(self):
        cursor = Cursor()
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5)
        self.publish(cursor)
        self.source.send(10, 0.0, 0, 0.0)
        self.source.send(20, 2.0, 1, 0.0)
        trace = [m for m in self.publish(cursor) if m["type"] == "trace"]
        self.assertEqual(trace, [{"type": "trace", "walk": 2, "points": [[1800000020000, 2.0]]}])

    def test_finishing_sends_an_empty_trace(self):
        cursor = Cursor()
        self.source.connect()
        self.source.send(0, 3.0, 600, 0.5)
        self.publish(cursor)
        self.controller.finish()
        messages = self.publish(cursor)
        self.assertEqual([m["type"] for m in messages], ["status", "walks", "trace"])
        self.assertEqual((messages[0]["open"], messages[2]), (None, {"type": "trace", "walk": None, "points": []}))

    def test_the_walk_list_is_sent_only_when_it_changes_shape(self):
        cursor = Cursor()
        self.source.connect()
        self.source.send(0, 3.0, 60, 0.05)
        self.assertIn("walks", [m["type"] for m in self.publish(cursor)])
        self.source.send(1, 3.0, 61, 0.06)
        self.assertNotIn("walks", [m["type"] for m in self.publish(cursor)])
        self.controller.finish()
        self.assertIn("walks", [m["type"] for m in self.publish(cursor)])

    def test_lines_match_the_contract(self):
        # Set WALKPAD_WRITE_CONTRACT=1 to rewrite fixtures/wire.jsonl after a
        # deliberate change, then run the node tests against it.
        lines = self.contract_lines()
        if os.environ.get("WALKPAD_WRITE_CONTRACT") == "1":
            CONTRACT.write_text("".join(f"{line}\n" for line in lines))
        self.assertEqual(lines, CONTRACT.read_text().splitlines())

    def contract_lines(self):
        """A pad found while it is held, then walked on, read by one bar."""
        walk = self.store.open_walk(WalkTotals(START - DAY, START - DAY + 600, PadCounters(600, 0.5, 20), 3.0), None)
        for point in (SpeedPoint(START - DAY, 3.0, 0.0), SpeedPoint(START - DAY + 1, 3.0, 0.0),
                      SpeedPoint(START - DAY + 600, 0.0, 0.5)):
            self.store.add_sample(walk.id, point)
        self.store.finish_walk(walk.id)
        self.controller.pad_found(FAKE)
        cursor, lines = Cursor(), []

        def bar():
            lines.extend(publish(self.controller.view(), cursor, self.controller.walks))

        self.source.events.link_changed(Waiting(FAKE.name, START + 12, "Input/output error"), START + 2)
        bar()
        self.source.events.link_changed(Connected(FAKE.name), START + 15)
        self.source.events.notification("ffe2", pad_frame(0.0, 0, 0.0), START + 16)
        bar()
        self.source.events.notification("ffe2", pad_frame(3.0, 1, 0.0), START + 20)
        bar()
        self.source.events.notification("ffe2", pad_frame(3.0, 2, 0.0), START + 21)
        bar()
        lines += run_command(self.controller, Command("samples", walk.id))[1]
        error, _ = run_command(self.controller, Command("delete", 9))
        lines.append(done_line("delete 9", error))
        return lines


class Helper:
    """`walkpad serve` as a subprocess, in an environment built from scratch:
    HOME, XDG_* and WALKPAD_* all under `root`."""

    def __init__(self, root: Path, script: Path, code: Path = WALKPAD, **env):
        self.root = root
        self.socket = root / "run" / "walkpad.sock"
        self.env = {"HOME": str(root / "home"), "XDG_RUNTIME_DIR": str(root / "run"),
                    "PATH": "/usr/bin:/bin", "WALKPAD_PAD": f"replay:{script}", "WALKPAD_IMPORT": ""}
        self.env.update(env)
        (root / "run").mkdir(mode=0o700, exist_ok=True)
        self.process = subprocess.Popen(["/usr/bin/python3", "-B", str(code), "serve"], env=self.env,
                                        stdin=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

    def wait_serving(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError(f"the helper exited: {self.process.stderr.read()}")
            try:
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.connect(str(self.socket))
                return self
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.05)
        raise AssertionError("the helper never listened")

    def stop(self, signum=signal.SIGTERM):
        self.process.send_signal(signum)
        return self.finish()

    def finish(self, timeout=10):
        """The exit status and what the helper logged."""
        _, err = self.process.communicate(timeout=timeout)
        return self.process.returncode, err

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate()


class Client:
    def __init__(self, path: Path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(10)
        self.socket.connect(str(path))
        self.file = self.socket.makefile("rw", encoding="utf-8", newline="\n")

    def send(self, line: str):
        self.file.write(f"{line}\n")
        self.file.flush()

    def read(self) -> dict:
        line = self.file.readline()
        if not line:
            raise AssertionError("the helper closed the connection")
        return json.loads(line)

    def until(self, test) -> dict:
        while not test(message := self.read()):
            pass
        return message

    def close(self):
        self.file.close()
        self.socket.close()


def settled(message):
    """The status walk.replay ends on: the walk with a drop, 180 s long."""
    return (message["type"] == "status" and message["link"]["state"] == "connected"
            and (message["open"] or {}).get("elapsedS") == 180 and message["speedKmh"] == 3.5)


class EndToEnd(unittest.TestCase):
    """On fixtures/walk.replay at pace 0, so its outcome is exact."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.helpers = []
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        for helper in self.helpers:
            helper.kill()
        self.dir.cleanup()

    def start(self, script="walk.replay", **kwargs) -> Helper:
        helper = Helper(self.root, FIXTURES / script, **kwargs)
        self.helpers.append(helper)
        return helper.wait_serving()

    def watch(self, helper) -> Client:
        client = Client(helper.socket)
        self.clients.append(client)
        client.send("watch")
        return client

    def walks(self, helper):
        """The walk list a bar starting now would get."""
        return [(w["id"], w["elapsedS"], w["distanceKm"], w["open"])
                for w in self.watch(helper).until(lambda m: m["type"] == "walks")["walks"]]

    def test_records_the_replayed_walks(self):
        helper = self.start()
        client = self.watch(helper)
        status = client.until(settled)
        self.assertEqual(status["open"]["id"], 3)
        self.assertEqual(self.walks(helper), [(3, 180, 0.15, True), (2, 300, 0.2, False), (1, 600, 0.5, False)])
        self.assertTrue((self.root / "home/.local/share/walkpad/walkpad.db").exists())

    def test_a_watching_client_sees_the_open_walk_and_its_trace(self):
        client = self.watch(self.start())
        client.until(settled)
        client.close()
        client = self.watch(self.helpers[0])
        status, walks, trace = client.read(), client.read(), client.read()
        self.assertEqual((status["type"], walks["type"], trace["type"]), ("status", "walks", "trace"))
        self.assertEqual((status["pad"], status["connect"], status["problems"]), ("MAXFREE-FAKE", True, []))
        self.assertEqual(trace["walk"], 3)
        self.assertEqual((trace["points"][0][1], trace["points"][-1][1]), (3.0, 3.5))
        self.assertEqual(trace["points"][-1][0], status["open"]["endedAt"])

    def test_a_client_reconnecting_gets_the_same_state(self):
        helper = self.start()
        self.watch(helper).until(settled)
        first, second = self.watch(helper), self.watch(helper)
        self.assertEqual([first.read() for _ in range(3)], [second.read() for _ in range(3)])

    def test_finish_finishes_it(self):
        helper = self.start()
        client = self.watch(helper)
        client.until(settled)
        client.send("finish")
        self.assertEqual(client.until(lambda m: m["type"] == "done"), {"type": "done", "cmd": "finish", "error": ""})
        self.assertIsNone(client.until(lambda m: m["type"] == "status")["open"])
        self.assertEqual(self.walks(helper), [(3, 180, 0.15, False), (2, 300, 0.2, False), (1, 600, 0.5, False)])

    def test_samples_and_delete_answer_their_sender(self):
        client = self.watch(self.start())
        client.until(settled)
        client.send("samples 1")
        samples = client.until(lambda m: m["type"] == "samples")
        self.assertEqual((samples["walk"], samples["points"][0][1], samples["points"][-1][1]), (1, 3.0, 0.0))
        client.send("delete 9")
        self.assertEqual(client.until(lambda m: m["type"] == "done"),
                         {"type": "done", "cmd": "delete 9", "error": "no walk 9"})
        client.send("dance")
        self.assertEqual(client.until(lambda m: m["type"] == "done"),
                         {"type": "done", "cmd": "dance", "error": 'unknown command "dance"'})

    def test_connect_off_hands_the_pad_back(self):
        client = self.watch(self.start())
        client.until(settled)
        client.send("connect toggle")
        status = client.until(lambda m: m["type"] == "status" and m["link"]["state"] == "off")
        self.assertEqual((status["connect"], status["speedKmh"]), (False, None))
        # The belt was running: the walk waits for the pad to come back.
        self.assertEqual(status["open"]["id"], 3)

    def test_a_second_helper_on_the_same_socket_exits(self):
        first = self.start()
        second = Helper(self.root, FIXTURES / "walk.replay", WALKPAD_DB=str(self.root / "other.db"))
        self.helpers.append(second)
        status, err = second.finish()
        self.assertEqual(status, 1)
        self.assertIn(f"walkpad: another walkpad serves {first.socket}", err)
        self.assertFalse((self.root / "other.db").exists())

    def test_stopping_does_not_finish_the_open_walk_and_a_restart_resumes_it(self):
        helper = self.start()
        self.watch(helper).until(settled)
        status, err = helper.stop()
        self.assertEqual(status, 0)
        self.assertIn("replay: released the pad", err)
        self.assertFalse(helper.socket.exists())
        helper = self.start("resume.replay")
        status = self.watch(helper).until(lambda m: m["type"] == "status" and (m["open"] or {}).get("elapsedS") == 190)
        self.assertEqual(status["open"]["id"], 3)
        self.assertEqual(self.walks(helper), [(3, 190, 0.15, True), (2, 300, 0.2, False), (1, 600, 0.5, False)])

    def test_a_change_to_its_code_makes_it_exit_without_releasing_the_pad(self):
        code = self.root / "walkpad"
        shutil.copytree(WALKPAD, code, ignore=shutil.ignore_patterns("tests", "__pycache__"))
        helper = self.start(code=code)
        self.watch(helper).until(settled)
        (code / "frames.py").touch()
        (code / "store.py").touch()
        began = time.monotonic()
        status, err = helper.finish()
        self.assertEqual(status, 0)
        self.assertGreaterEqual(time.monotonic() - began, 0.5)
        self.assertIn("walkpad: its code changed; exiting so that the new code starts", err)
        self.assertIn("replay: left the pad connected", err)
        self.assertNotIn("replay: released the pad", err)
        self.assertEqual(sorted(p.name for p in code.iterdir() if p.name.startswith("__")), ["__main__.py"])

    def test_refuses_to_start_in_the_sandbox_on_the_real_pad_and_database(self):
        helper = Helper(self.root, FIXTURES / "walk.replay", NIRI_SANDBOX="thr_x", WALKPAD_PAD="bluez")
        self.helpers.append(helper)
        self.assertEqual(helper.finish(), (2, "walkpad: in niri-sandbox the pad must be WALKPAD_PAD=replay:…, "
                                              "not the real one\n"))
        helper = Helper(self.root, FIXTURES / "walk.replay", NIRI_SANDBOX="thr_x")
        self.helpers.append(helper)
        self.assertEqual(helper.finish(), (2, "walkpad: in niri-sandbox set WALKPAD_DB to a scratch file, "
                                              "not the real database\n"))
        self.assertFalse((self.root / "home").exists())
        self.assertFalse(helper.socket.exists())

    @unittest.skipUnless((WALKPAD.parent / "WalkpadService.qml").exists(), "the bar's WalkpadService.qml is not here")
    def test_the_bar_computes_the_same_socket_path(self):
        qml = (WALKPAD.parent / "WalkpadService.qml").read_text()
        for name in ("WALKPAD_SOCKET", "XDG_RUNTIME_DIR", "/walkpad.sock"):
            self.assertIn(name, qml)


if __name__ == "__main__":
    unittest.main()
