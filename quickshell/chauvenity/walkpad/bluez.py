# BLE link to the walking pad through BlueZ over the system D-Bus: a port of
# the BB walkpad plugin's pad.ts to Gio's awaitable D-Bus calls on the GLib
# event loop (PyGObject >= 3.50 makes Gio's async methods awaitable when no
# callback is given; /usr/bin/python3 has 3.56).
#
# The pad takes one BLE connection at a time. While the helper holds it, the
# iPhone app cannot reach it, so "Connect to the pad" off hands it back:
# StopNotify, then Device1.Disconnect.
#
# Frames are read on both ffe2 and ffe1: the pad sends to whichever was
# subscribed last, and another client enabling ffe1 must not silence us. The
# source only forwards each notification's bytes with its channel; the
# controller keeps one FrameBuffer per channel.

from __future__ import annotations

import asyncio
import re
import time
from dataclasses import dataclass

from gi.repository import Gio, GLib

from link import Connected, KnownPad, LinkState, Off, PadEvents, Searching, Unavailable, Waiting

BLUEZ = "org.bluez"
DEVICE_IFACE = "org.bluez.Device1"
ADAPTER_IFACE = "org.bluez.Adapter1"
CHAR_IFACE = "org.bluez.GattCharacteristic1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager"
DATA_CHAR = "0000ffe2-0000-1000-8000-00805f9b34fb"
#: Two-way serial channel; the pad mirrors its frames here once subscribed.
UART_CHAR = "0000ffe1-0000-1000-8000-00805f9b34fb"
NAME_PREFIX = "MAXFREE"

#: How long an LE scan for an unknown pad lasts.
SCAN_S = 10
#: How long to wait after a scan that found nothing. With the pad off, a
#: scan after every short backoff would disturb the user's headphones.
SCAN_PAUSE_S = 60.0
#: How often to look again while Bluetooth is off or missing.
UNAVAILABLE_POLL_S = 5.0
#: D-Bus call timeout for Connect, which BlueZ answers within about 20 s.
CONNECT_TIMEOUT_MS = 30_000

_REMOTE_ERROR = re.compile(r"^GDBus\.Error:[\w.]+: ")


def backoff_s(failures: int) -> float:
    """How long to wait before the next try. 1 s after a clean drop, then 3,
    6 and 10 s. A Connect to a pad that is off fails fast and costs little,
    and the pad being switched on is when the user wants it."""
    return 1.0 if failures == 0 else min(3.0 * 2 ** (failures - 1), 10.0)


def bluez_message(text: str) -> str:
    """BlueZ's own words, without GDBus's prefix: "Input/output error"."""
    return _REMOTE_ERROR.sub("", text)


@dataclass(frozen=True)
class Device:
    path: str
    pad: KnownPad


def unavailable(objects: dict) -> str:
    """Why the adapter cannot be used, or ""."""
    adapters = [ifaces[ADAPTER_IFACE] for ifaces in objects.values() if ADAPTER_IFACE in ifaces]
    if not adapters:
        return "No Bluetooth adapter"
    if not any(adapter.get("Powered") for adapter in adapters):
        return "Bluetooth is off"
    return ""


def match_device(objects: dict, known: KnownPad | None) -> Device | None:
    """The remembered pad by address, or without one the first device
    named MAXFREE*."""
    for path, ifaces in objects.items():
        device = ifaces.get(DEVICE_IFACE)
        if device is None:
            continue
        address = str(device.get("Address", ""))
        name = str(device.get("Name", ""))
        if known is None:
            if name.upper().startswith(NAME_PREFIX):
                return Device(path, KnownPad(address, name))
        elif address.upper() == known.address.upper():
            return Device(path, KnownPad(address, name or known.name))
    return None


def describe(state: LinkState) -> str:
    """The state as the journal reads it."""
    if isinstance(state, Off):
        return "off"
    if isinstance(state, Unavailable):
        return f"unavailable: {state.reason}"
    if isinstance(state, Searching):
        return "searching"
    if isinstance(state, Connected):
        return f"connected to {state.pad}"
    return f"waiting for {state.pad}" + (f": {state.error}" if state.error else "")


def find_char(objects: dict, device_path: str, uuid: str) -> str | None:
    for path, ifaces in objects.items():
        if path.startswith(f"{device_path}/") and ifaces.get(CHAR_IFACE, {}).get("UUID") == uuid:
            return path
    return None


class BluezError(Exception):
    """A failure on the way to the pad, with the words for the panel."""


class NotFound(BluezError):
    """A scan that found no pad."""


class BluezSource:
    """link.PadSource for the real pad. One asyncio task runs `_run`;
    set_enabled and forget wake it. `bus` is the system bus, or for the
    tests a stand-in with the same call and signal_subscribe."""

    def __init__(self, log, bus=None) -> None:
        self._log = log
        self._events: PadEvents | None = None
        self._known: KnownPad | None = None
        self._enabled = True
        self._release = True
        self._bus = bus
        self._task: asyncio.Task | None = None
        self._reported: LinkState | None = None
        self._logged = ""
        #: Wakes a wait between tries: set_enabled or forget.
        self._wake = asyncio.Event()
        #: Ends a connection: off or forget.
        self._leave = asyncio.Event()

    def now(self) -> float:
        return time.time()

    def start(self, events: PadEvents, known: KnownPad | None, enabled: bool) -> None:
        self._events = events
        self._known = known
        self._enabled = enabled
        self._task = asyncio.get_running_loop().create_task(self._run())

    def set_enabled(self, on: bool) -> None:
        self._enabled = on
        if not on:
            self._leave.set()
        self._wake.set()

    def forget(self) -> None:
        self._known = None
        self._leave.set()
        self._wake.set()

    async def close(self, release: bool = True) -> None:
        """Cancels the task; its `finally` releases the pad unless told not
        to. Reports nothing."""
        self._release = release
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    def _report(self, state: LinkState) -> None:
        if state == self._reported:
            return
        self._reported = state
        # One line per change of state, not one per failed try: a retry
        # only moves retry_at.
        line = describe(state)
        if line != self._logged:
            self._logged = line
            self._log(f"pad link: {line}")
        self._events.link_changed(state, self.now())

    async def _call(self, path: str, iface: str, method: str, args=None, reply: str | None = None,
                    timeout_ms: int = 10_000):
        try:
            result = await self._bus.call(BLUEZ, path, iface, method, args,
                                          GLib.VariantType(reply) if reply else None,
                                          Gio.DBusCallFlags.NONE, timeout_ms, None)
        except GLib.Error as error:
            raise BluezError(bluez_message(error.message)) from None
        return result.unpack() if result is not None else None

    async def _objects(self) -> dict:
        return (await self._call("/", MANAGER_IFACE, "GetManagedObjects", reply="(a{oa{sa{sv}}})"))[0]

    async def _rest(self, seconds: float) -> None:
        """Sleeps, or less if woken."""
        try:
            await asyncio.wait_for(self._wake.wait(), seconds)
        except TimeoutError:
            pass

    async def _run(self) -> None:
        """The link loop, pad.ts's runPadLink."""
        if self._bus is None:
            try:
                self._bus = await Gio.bus_get(Gio.BusType.SYSTEM)
            except GLib.Error as error:
                self._report(Unavailable(f"No system bus: {error.message}"))
                return
        failures = 0
        #: BlueZ's last refusal. It stays on the Waiting state while the
        #: next try runs, so the panel does not flicker between attempts.
        refused = ""
        while True:
            self._wake.clear()
            self._leave.clear()
            pause = backoff_s(0)
            if not self._enabled:
                self._report(Off())
                await self._wake.wait()
                continue
            try:
                try:
                    objects = await self._objects()
                except BluezError:
                    self._report(Unavailable("Bluetooth is not running"))
                    await self._rest(UNAVAILABLE_POLL_S)
                    continue
                if reason := unavailable(objects):
                    self._report(Unavailable(reason))
                    await self._rest(UNAVAILABLE_POLL_S)
                    continue
                device = match_device(objects, self._known) or await self._scan(objects)
                if device is None:
                    raise NotFound("No walking pad found; is it on, and free of the iPhone app?")
                if device.pad != self._known:
                    self._known = device.pad
                    self._events.pad_found(device.pad)
                self._report(Waiting(device.pad.name, None, refused))
                await self._connect_once(device)
                failures, refused = 0, ""
                if self._enabled and self._known:
                    self._report(Waiting(self._known.name, self.now() + backoff_s(0)))
            except BluezError as error:
                failures, refused = failures + 1, str(error)
                pause = SCAN_PAUSE_S if isinstance(error, NotFound) else backoff_s(failures)
                self._report(Waiting(self._known.name, self.now() + pause, refused) if self._known else Searching())
            if self._enabled and not self._wake.is_set():
                await self._rest(pause)

    async def _scan(self, objects: dict) -> Device | None:
        """A short LE discovery, for a pad BlueZ does not know yet."""
        adapter = next(path for path, ifaces in objects.items() if ADAPTER_IFACE in ifaces)
        self._report(Searching())
        try:
            await self._call(adapter, ADAPTER_IFACE, "SetDiscoveryFilter",
                             GLib.Variant("(a{sv})", ({"Transport": GLib.Variant("s", "le")},)))
        except BluezError:
            pass
        await self._call(adapter, ADAPTER_IFACE, "StartDiscovery")
        try:
            for _ in range(SCAN_S):
                await self._rest(1.0)
                if self._leave.is_set():
                    return None
                if found := match_device(await self._objects(), self._known):
                    return found
            return None
        finally:
            try:
                await self._call(adapter, ADAPTER_IFACE, "StopDiscovery")
            except BluezError:
                pass

    async def _connect_once(self, device: Device) -> None:
        """Connects, subscribes, and returns once the link drops or the pad
        is to be let go. As pad.ts's connectOnce."""
        bus = self._bus
        dropped = asyncio.Event()
        subscriptions = []
        notifying = []

        def on_device(_bus, _sender, _path, _iface, _signal, params, _data) -> None:
            iface, changed, _ = params.unpack()
            if iface == DEVICE_IFACE and changed.get("Connected") is False:
                dropped.set()

        def on_removed(_bus, _sender, _path, _iface, _signal, params, _data) -> None:
            if params.unpack()[0] == device.path:
                dropped.set()

        def on_owner(_bus, _sender, _path, _iface, _signal, params, _data) -> None:
            if not params.unpack()[2]:
                dropped.set()

        def on_value(channel):
            def on_char(_bus, _sender, _path, _iface, _signal, params, _data) -> None:
                iface, changed, _ = params.unpack()
                if iface == CHAR_IFACE and "Value" in changed:
                    self._events.notification(channel, bytes(changed["Value"]), self.now())
            return on_char

        def subscribe(sender, iface, member, path, arg0, callback) -> None:
            subscriptions.append(bus.signal_subscribe(sender, iface, member, path, arg0,
                                                      Gio.DBusSignalFlags.NONE, callback, None))

        subscribe(BLUEZ, PROPS_IFACE, "PropertiesChanged", device.path, None, on_device)
        subscribe(BLUEZ, MANAGER_IFACE, "InterfacesRemoved", "/", None, on_removed)
        subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                  BLUEZ, on_owner)
        try:
            # A helper that exited to reload leaves the link up; the next one
            # resumes on it without a Connect.
            if not await self._property(device.path, "Connected"):
                await self._call(device.path, DEVICE_IFACE, "Connect", timeout_ms=CONNECT_TIMEOUT_MS)
            for _ in range(50):
                if await self._property(device.path, "ServicesResolved"):
                    break
                await asyncio.sleep(0.2)
            else:
                raise BluezError("Timed out waiting for the pad's GATT services")
            objects = await self._objects()
            data = find_char(objects, device.path, DATA_CHAR)
            if data is None:
                raise BluezError(f"{device.pad.name} has no ffe2 data characteristic")
            uart = find_char(objects, device.path, UART_CHAR)
            for path, channel in ((data, "ffe2"), (uart, "ffe1")):
                if path is None:
                    continue
                subscribe(BLUEZ, PROPS_IFACE, "PropertiesChanged", path, None, on_value(channel))
                await self._call(path, CHAR_IFACE, "StartNotify")
                notifying.append(path)
            self._report(Connected(device.pad.name))
            leave = asyncio.ensure_future(self._leave.wait())
            drop = asyncio.ensure_future(dropped.wait())
            try:
                await asyncio.wait((leave, drop), return_when=asyncio.FIRST_COMPLETED)
            finally:
                leave.cancel()
                drop.cancel()
        finally:
            for subscription in subscriptions:
                bus.signal_unsubscribe(subscription)
            if self._release:
                for path in notifying:
                    try:
                        await self._call(path, CHAR_IFACE, "StopNotify")
                    except BluezError:
                        pass
                try:
                    await self._call(device.path, DEVICE_IFACE, "Disconnect")
                except BluezError:
                    pass

    async def _property(self, path: str, name: str):
        return (await self._call(path, PROPS_IFACE, "Get", GLib.Variant("(ss)", (DEVICE_IFACE, name)),
                                 reply="(v)"))[0]
