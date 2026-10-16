# The BlueZ link, against a stand-in for BlueZ on the system bus: finding the
# pad, connecting, both characteristics, drops, retries, handing the pad back,
# and leaving it connected for the next helper. Nothing here reaches D-Bus.
#
#   /usr/bin/python3 -B -m unittest discover -s quickshell/chauvenity/walkpad/tests -t quickshell/chauvenity/walkpad

import asyncio
import unittest
from unittest import mock

from gi.repository import GLib

from bluez import (ADAPTER_IFACE, CHAR_IFACE, DATA_CHAR, DEVICE_IFACE, UART_CHAR, BluezSource, backoff_s,
                   bluez_message, find_char, match_device, unavailable)
from link import Connected, KnownPad, Off, Searching, Unavailable, Waiting

ADAPTER = "/org/bluez/hci0"
DEVICE = "/org/bluez/hci0/dev_00_00_00_00_00_00"
DATA = f"{DEVICE}/service0010/char0011"
UART = f"{DEVICE}/service0010/char0014"
PAD = KnownPad("00:00:00:00:00:00", "MAXFREE-TEST")


def _variant(value):
    return GLib.Variant("b" if isinstance(value, bool) else "s", value)


class FakeBluez:
    """What helper sees of BlueZ: managed objects, method calls, signals."""

    def __init__(self, powered=True, pad=True, connected=False):
        self.objects = {"/": {}, ADAPTER: {ADAPTER_IFACE: {"Powered": powered}}}
        self.calls = []
        self.fail = {}
        self.subscriptions = {}
        #: Devices that only show up once a scan runs.
        self.hidden = {}
        if pad:
            self.add_pad(self.objects, connected)

    def add_pad(self, objects, connected=False):
        objects[DEVICE] = {DEVICE_IFACE: {"Address": PAD.address, "Name": PAD.name, "Connected": connected,
                                          "ServicesResolved": connected}}
        objects[DATA] = {CHAR_IFACE: {"UUID": DATA_CHAR}}
        objects[UART] = {CHAR_IFACE: {"UUID": UART_CHAR}}

    def methods(self):
        return [method for method, _ in self.calls if method not in ("GetManagedObjects", "Get")]

    async def call(self, _name, path, _iface, method, args, _reply, _flags, _timeout, _cancellable):
        self.calls.append((method, path))
        if method in self.fail:
            raise GLib.Error(f"GDBus.Error:org.bluez.Error.Failed: {self.fail[method]}")
        if method == "GetManagedObjects":
            return GLib.Variant("(a{oa{sa{sv}}})", ({path: {iface: {k: _variant(v) for k, v in props.items()}
                                                            for iface, props in ifaces.items()}
                                                     for path, ifaces in self.objects.items()},))
        if method == "Get":
            iface, name = args.unpack()
            return GLib.Variant("(v)", (_variant(self.objects[path][iface][name]),))
        if method == "Connect":
            self.objects[DEVICE][DEVICE_IFACE].update(Connected=True, ServicesResolved=True)
        if method == "Disconnect":
            self.objects[DEVICE][DEVICE_IFACE].update(Connected=False, ServicesResolved=False)
        if method == "StartDiscovery":
            self.objects.update(self.hidden)
        return None

    def signal_subscribe(self, _sender, _iface, member, path, _arg0, _flags, callback, _data):
        number = len(self.subscriptions) + 1
        self.subscriptions[number] = (member, path, callback)
        return number

    def signal_unsubscribe(self, number):
        del self.subscriptions[number]

    def emit(self, member, path, params):
        for subscribed, at, callback in list(self.subscriptions.values()):
            if subscribed == member and at == path:
                callback(self, "org.bluez", path, "", member, params, None)

    def changed(self, path, iface, **props):
        self.emit("PropertiesChanged", path,
                  GLib.Variant("(sa{sv}as)", (iface, {k: GLib.Variant("ay" if isinstance(v, bytes) else "b", v)
                                                      for k, v in props.items()}, [])))


class Events:
    def __init__(self):
        self.links = []
        self.notifications = []
        self.found = []

    def link_changed(self, state, now):
        self.links.append(state)

    def notification(self, channel, data, now):
        self.notifications.append((channel, data))

    def pad_found(self, pad):
        self.found.append(pad)


class Link(unittest.TestCase):
    def run_link(self, bluez, script, known=PAD, enabled=True):
        """Starts the link on `bluez`, then runs `script(source, events)`."""
        self.logged = []

        async def run():
            events = Events()
            source = BluezSource(self.logged.append, bus=bluez)
            source.start(events, known, enabled)
            try:
                await script(source, events)
            finally:
                await source.close(release=getattr(self, "release", True))
            return events

        with mock.patch("bluez.backoff_s", lambda failures: 0.05):
            return asyncio.run(asyncio.wait_for(run(), 10))

    @staticmethod
    async def until(test):
        while not test():
            await asyncio.sleep(0.01)

    def test_connects_to_the_remembered_pad_and_reads_both_characteristics(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)
            bluez.changed(UART, CHAR_IFACE, Value=b"EE,p1.0,")
            bluez.changed(DATA, CHAR_IFACE, Value=b"EE,p2.0,")

        events = self.run_link(bluez, script)
        self.assertEqual(events.links, [Waiting(PAD.name), Connected(PAD.name)])
        self.assertEqual(events.notifications, [("ffe1", b"EE,p1.0,"), ("ffe2", b"EE,p2.0,")])
        self.assertEqual(events.found, [])
        self.assertEqual(bluez.methods(), ["Connect", "StartNotify", "StartNotify", "StopNotify", "StopNotify",
                                           "Disconnect"])
        self.assertEqual(self.logged, ["pad link: waiting for MAXFREE-TEST", "pad link: connected to MAXFREE-TEST"])

    def test_a_link_left_up_by_the_last_helper_is_used_without_a_connect(self):
        bluez = FakeBluez(connected=True)

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)

        self.release = False
        self.run_link(bluez, script)
        self.assertEqual(bluez.methods(), ["StartNotify", "StartNotify"])

    def test_leaving_to_reload_keeps_the_pad_connected(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)

        self.release = False
        events = self.run_link(bluez, script)
        self.assertEqual(bluez.methods(), ["Connect", "StartNotify", "StartNotify"])
        self.assertTrue(bluez.objects[DEVICE][DEVICE_IFACE]["Connected"])
        self.assertEqual(events.links, [Waiting(PAD.name), Connected(PAD.name)])

    def test_the_pad_switched_off_is_tried_again_with_bluez_s_answer(self):
        bluez = FakeBluez()
        bluez.fail["Connect"] = "Input/output error"

        async def script(source, events):
            await self.until(lambda: bluez.methods().count("Connect") >= 3)
            del bluez.fail["Connect"]
            await self.until(lambda: Connected(PAD.name) in events.links)

        events = self.run_link(bluez, script)
        refused = [link for link in events.links if isinstance(link, Waiting) and link.error]
        self.assertEqual({link.error for link in refused}, {"Input/output error"})
        self.assertTrue(all(link.retry_at for link in refused[::2]))
        self.assertEqual(events.links[-1], Connected(PAD.name))
        # One line per change of state, however many tries.
        self.assertEqual(self.logged, ["pad link: waiting for MAXFREE-TEST",
                                       "pad link: waiting for MAXFREE-TEST: Input/output error",
                                       "pad link: connected to MAXFREE-TEST"])

    def test_a_drop_is_reported_at_once_and_the_pad_reached_for_again(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)
            bluez.objects[DEVICE][DEVICE_IFACE].update(Connected=False, ServicesResolved=False)
            bluez.changed(DEVICE, DEVICE_IFACE, Connected=False)
            await self.until(lambda: events.links.count(Connected(PAD.name)) == 2)

        events = self.run_link(bluez, script)
        self.assertIsInstance(events.links[2], Waiting)
        self.assertEqual((events.links[2].pad, events.links[2].error), (PAD.name, ""))
        self.assertEqual(bluez.methods().count("Connect"), 2)

    def test_connect_off_hands_the_pad_back_and_on_reaches_for_it(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)
            source.set_enabled(False)
            await self.until(lambda: Off() in events.links)
            self.assertEqual(bluez.methods()[-3:], ["StopNotify", "StopNotify", "Disconnect"])
            self.assertFalse(bluez.objects[DEVICE][DEVICE_IFACE]["Connected"])
            source.set_enabled(True)
            await self.until(lambda: events.links.count(Connected(PAD.name)) == 2)

        events = self.run_link(bluez, script)
        self.assertEqual(events.links[:3], [Waiting(PAD.name), Connected(PAD.name), Off()])

    def test_starting_off_leaves_the_pad_alone(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: events.links)
            await asyncio.sleep(0.1)

        events = self.run_link(bluez, script, enabled=False)
        self.assertEqual(events.links, [Off()])
        self.assertEqual(bluez.calls, [])

    def test_stopping_reports_nothing(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)

        events = self.run_link(bluez, script)
        self.assertEqual(events.links, [Waiting(PAD.name), Connected(PAD.name)])

    def test_finds_an_unknown_pad_by_its_name_with_a_scan(self):
        bluez = FakeBluez(pad=False)
        bluez.add_pad(bluez.hidden)

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)

        events = self.run_link(bluez, script, known=None)
        self.assertEqual(events.found, [PAD])
        self.assertEqual(events.links, [Searching(), Waiting(PAD.name), Connected(PAD.name)])
        self.assertEqual(bluez.methods()[:4], ["SetDiscoveryFilter", "StartDiscovery", "StopDiscovery", "Connect"])

    def test_forget_lets_go_and_looks_for_a_pad_again(self):
        bluez = FakeBluez()

        async def script(source, events):
            await self.until(lambda: Connected(PAD.name) in events.links)
            source.forget()
            await self.until(lambda: events.found)

        events = self.run_link(bluez, script)
        self.assertEqual(events.found, [PAD])
        self.assertIn("Disconnect", bluez.methods())

    def test_bluetooth_off_is_unavailable(self):
        async def script(source, events):
            await self.until(lambda: events.links)

        events = self.run_link(FakeBluez(powered=False), script)
        self.assertEqual(events.links, [Unavailable("Bluetooth is off")])

    def test_no_bluetoothd_is_unavailable(self):
        bluez = FakeBluez()
        bluez.fail["GetManagedObjects"] = "The name is not activatable"

        async def script(source, events):
            await self.until(lambda: events.links)

        self.assertEqual(self.run_link(bluez, script).links, [Unavailable("Bluetooth is not running")])


class Helpers(unittest.TestCase):
    def test_backs_off_to_ten_seconds(self):
        self.assertEqual([backoff_s(n) for n in range(6)], [1.0, 3.0, 6.0, 10.0, 10.0, 10.0])

    def test_keeps_bluez_s_own_words(self):
        self.assertEqual(bluez_message("GDBus.Error:org.bluez.Error.Failed: Input/output error"), "Input/output error")
        self.assertEqual(bluez_message("Timeout was reached"), "Timeout was reached")

    def test_says_why_the_adapter_cannot_be_used(self):
        self.assertEqual(unavailable({}), "No Bluetooth adapter")
        self.assertEqual(unavailable({ADAPTER: {ADAPTER_IFACE: {"Powered": False}}}), "Bluetooth is off")
        self.assertEqual(unavailable({ADAPTER: {ADAPTER_IFACE: {"Powered": True}}}), "")

    def test_matches_the_remembered_address_or_else_the_name(self):
        objects = {"/a": {DEVICE_IFACE: {"Address": "11:22:33:44:55:66", "Name": "Headphones"}},
                   DEVICE: {DEVICE_IFACE: {"Address": PAD.address, "Name": PAD.name}}}
        self.assertEqual(match_device(objects, None).pad, PAD)
        self.assertEqual(match_device(objects, KnownPad("11:22:33:44:55:66", "x")).path, "/a")
        self.assertIsNone(match_device(objects, KnownPad("AA:AA:AA:AA:AA:AA", "MAXFREE-OLD")))

    def test_finds_a_characteristic_under_its_device_only(self):
        objects = {DATA: {CHAR_IFACE: {"UUID": DATA_CHAR}}, "/org/bluez/hci0/dev_X/char1": {CHAR_IFACE: {"UUID": UART_CHAR}}}
        self.assertEqual(find_char(objects, DEVICE, DATA_CHAR), DATA)
        self.assertIsNone(find_char(objects, DEVICE, UART_CHAR))


if __name__ == "__main__":
    unittest.main()
