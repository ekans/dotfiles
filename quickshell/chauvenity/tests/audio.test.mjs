// Unit tests for the bar's volume indicator.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    nodeKind, volumeTone, percent, stepVolume, streamLabel, unpluggedSinks, sinkLabel,
    inputDevices, paVolume,
    stereoPeaks, meterStep, meterIdle, METER_IDLE, METER_FALL, METER_HOLD,
} from "../audio.mjs";

test("nodeKind tells the audio devices apart", () => {
    assert.equal(nodeKind("alsa_output.pci-0000_c1_00.6.HiFi__Speaker__sink", { "device.bus": "pci" }), "speaker");
    assert.equal(nodeKind("alsa_output.pci-0000_c1_00.6.HiFi__Headphones__sink", {}), "headphones");
    assert.equal(nodeKind("alsa_output.usb-foo", { "device.form-factor": "headset" }), "headphones");
    assert.equal(nodeKind("bluez_output.EC_66_D1_B8_EB_DC.1", {}), "bluetooth");
    assert.equal(nodeKind("raop_sink.Sejour.local.192.168.1.189.7000", {}), "network");
    assert.equal(nodeKind("bluez_input.EC_66_D1_B8_EB_DC", {}), "bluetooth");
    assert.equal(nodeKind("alsa_input.pci-0000_c1_00.6.HiFi__Mic2__source", { "device.bus": "pci" }), "speaker");
    assert.equal(nodeKind("alsa_input.usb-046d_C922_Pro_Stream_Webcam", { "device.bus": "usb" }), "speaker");
    assert.equal(nodeKind(undefined, undefined), "speaker");
});

test("volumeTone flags mute first, then overdrive", () => {
    assert.equal(volumeTone(0.25, false), "normal");
    assert.equal(volumeTone(1.0, false), "normal");
    assert.equal(volumeTone(1.3, false), "over");
    assert.equal(volumeTone(1.3, true), "muted");
});

test("percent rounds and never goes negative", () => {
    assert.equal(percent(0.254), "25%");
    assert.equal(percent(1.3), "130%");
    assert.equal(percent(-0.01), "0%");
});

test("stepVolume snaps to the 5 % grid", () => {
    assert.equal(stepVolume(0.25, 1), 0.3);
    assert.equal(stepVolume(0.27, 1), 0.3);
    assert.equal(stepVolume(0.27, -1), 0.2);
    assert.equal(stepVolume(0.02, -1), 0);
});

test("stepVolume stops the wheel at 100 % without pulling overdrive down", () => {
    assert.equal(stepVolume(0.98, 1), 1.0);
    assert.equal(stepVolume(1.0, 1), 1.0);
    assert.equal(stepVolume(1.3, 1), 1.3);
    assert.equal(stepVolume(1.3, -1), 1.25);
});

test("streamLabel prefers the application name", () => {
    assert.equal(streamLabel({ "application.name": "Firefox", "media.name": "YouTube" }, "x", "y"), "Firefox");
    assert.equal(streamLabel({ "media.name": "YouTube" }, "x", "y"), "YouTube");
    assert.equal(streamLabel(null, "", "spotify"), "spotify");
});

test("unpluggedSinks lists the sinks whose every port is unavailable", () => {
    const json = JSON.stringify([
        { name: "speaker", ports: [{ name: "[Out] Speaker", availability: "availability unknown" }] },
        { name: "hdmi1", ports: [{ name: "[Out] HDMI1", availability: "not available" }] },
        { name: "hdmi3", ports: [{ name: "[Out] HDMI3", availability: "available" }] },
        { name: "mixed", ports: [{ availability: "not available" }, { availability: "available" }] },
        { name: "portless", ports: [] },
    ]);
    assert.deepEqual(unpluggedSinks(json), ["hdmi1"]);
});

test("unpluggedSinks hides nothing when pactl's output is unreadable", () => {
    assert.deepEqual(unpluggedSinks(""), []);
    assert.deepEqual(unpluggedSinks("Connection failure"), []);
    assert.deepEqual(unpluggedSinks("{}"), []);
});

// `pactl -f json list sources`, cut down to what inputDevices reads.
const channel = value => ({ value, value_percent: "", db: "" });
const MIC = {
    name: "alsa_input.pci-0000_c1_00.6.HiFi__Mic2__source",
    description: "Ryzen HD Audio Controller Internal Stereo Microphone",
    mute: false,
    volume: { "front-left": channel(17990), "front-right": channel(17990) },
    monitor_source: "",
    ports: [{ name: "analog-input-internal-mic", availability: "availability unknown" }],
    properties: { "media.class": "Audio/Source", "device.class": "sound", "device.bus": "pci" },
};
const VIRTUAL = {
    name: "easyeffects_source",
    description: "Easy Effects Source",
    mute: true,
    volume: { "front-left": channel(65536), "front-right": channel(65536) },
    monitor_source: "",
    ports: [],
    properties: { "media.class": "Audio/Source/Virtual" },
};
const MONITOR = {
    name: "alsa_output.pci-0000_c1_00.6.HiFi__Headphones__sink.monitor",
    description: "Monitor of Ryzen HD Audio Controller Headphones",
    mute: false,
    volume: { "front-left": channel(65536), "front-right": channel(65536) },
    monitor_source: "alsa_output.pci-0000_c1_00.6.HiFi__Headphones__sink",
    ports: [{ name: "analog-output-headphones", availability: "available" }],
    properties: { "media.class": "Audio/Sink", "device.class": "monitor", "device.bus": "pci" },
};
const UNPLUGGED = {
    name: "alsa_input.pci-0000_c1_00.6.HiFi__Mic1__source",
    description: "Ryzen HD Audio Controller Digital Microphone",
    mute: false,
    volume: { "front-left": channel(52803), "front-right": channel(52803) },
    monitor_source: "",
    ports: [{ name: "dmic", availability: "not available" }],
    properties: { "media.class": "Audio/Source", "device.class": "sound", "device.bus": "pci" },
};
const UNEQUAL = {
    name: "alsa_input.usb-046d_C922_Pro_Stream_Webcam_39C895FF-02.analog-stereo",
    description: "C922 Pro Stream Webcam Analog Stereo",
    mute: false,
    volume: { "front-left": channel(32768), "front-right": channel(65536) },
    monitor_source: "",
    ports: [{ name: "analog-input-mic", availability: "availability unknown" }],
    properties: { "media.class": "Audio/Source", "device.class": "sound", "device.bus": "usb" },
};
const SOURCES = JSON.stringify([MONITOR, UNEQUAL, UNPLUGGED, MIC, VIRTUAL]);
const names = devices => devices.map(d => d.name);

test("inputDevices lists the microphones, a virtual source included, in pactl's order", () => {
    const { current, shown } = inputDevices(SOURCES, MIC.name);
    assert.deepEqual(names(shown), [UNEQUAL.name, MIC.name, VIRTUAL.name]);
    assert.equal(current.name, MIC.name);
});

test("inputDevices describes a device the way the picker and the head row show it", () => {
    const { shown } = inputDevices(SOURCES, MIC.name);
    assert.deepEqual(shown[1], {
        name: "alsa_input.pci-0000_c1_00.6.HiFi__Mic2__source",
        label: "Ryzen Internal Stereo Microphone",
        kind: "speaker",
        volume: 17990 / 65536,
        muted: false,
        monitor: false,
    });
    assert.deepEqual(shown[2], {
        name: "easyeffects_source",
        label: "Easy Effects Source",
        kind: "speaker",
        volume: 1,
        muted: true,
        monitor: false,
    });
});

test("inputDevices levels a device at the mean of its channels", () => {
    const { shown } = inputDevices(SOURCES, MIC.name);
    assert.equal(shown[0].volume, 0.75);
});

test("inputDevices hides a monitor and an unplugged microphone", () => {
    const { shown } = inputDevices(SOURCES, MIC.name);
    assert.ok(!names(shown).includes(MONITOR.name));
    assert.ok(!names(shown).includes(UNPLUGGED.name));
});

test("inputDevices keeps a monitor that is the default, as itself", () => {
    const { current, shown } = inputDevices(SOURCES, MONITOR.name);
    assert.deepEqual(current, {
        name: "alsa_output.pci-0000_c1_00.6.HiFi__Headphones__sink.monitor",
        label: "Monitor of Ryzen Headphones",
        kind: "headphones",
        volume: 1,
        muted: false,
        monitor: true,
    });
    assert.deepEqual(names(shown), [MONITOR.name, UNEQUAL.name, MIC.name, VIRTUAL.name]);
});

test("inputDevices keeps an unplugged microphone that is the default", () => {
    const { current, shown } = inputDevices(SOURCES, UNPLUGGED.name);
    assert.equal(current.name, UNPLUGGED.name);
    assert.deepEqual(names(shown), [UNEQUAL.name, UNPLUGGED.name, MIC.name, VIRTUAL.name]);
});

test("inputDevices has no current when the default is not a source", () => {
    assert.equal(inputDevices(SOURCES, "").current, null);
    assert.equal(inputDevices(SOURCES, "gone").current, null);
    assert.equal(names(inputDevices(SOURCES, "gone").shown).length, 3);
});

test("inputDevices shows nothing when pactl's output is unreadable", () => {
    assert.deepEqual(inputDevices("", MIC.name), { current: null, shown: [] });
    assert.deepEqual(inputDevices("Connection failure", MIC.name), { current: null, shown: [] });
    assert.deepEqual(inputDevices("{}", MIC.name), { current: null, shown: [] });
});

test("inputDevices reads a source with no channels as silent", () => {
    const bare = JSON.stringify([{ ...MIC, volume: {} }]);
    assert.equal(inputDevices(bare, MIC.name).current.volume, 0);
});

test("paVolume is the raw integer pactl takes", () => {
    assert.equal(paVolume(0.27), 17695);
    assert.equal(paVolume(1), 65536);
    assert.equal(paVolume(0), 0);
    assert.equal(paVolume(-1), 0);
});

test("sinkLabel shortens the chip and the HDMI port", () => {
    assert.equal(sinkLabel("Radeon High Definition Audio Controller HDMI / DisplayPort 3 Output", "x"), "Radeon HDMI/DP 3");
    assert.equal(sinkLabel("Ryzen HD Audio Controller Speaker", "x"), "Ryzen Speaker");
    assert.equal(sinkLabel("Px7 S2", "x"), "Px7 S2");
    assert.equal(sinkLabel("", "bluez_output.1"), "bluez_output.1");
});

test("stereoPeaks feeds both bars from a mono sink and clamps", () => {
    assert.deepEqual(stereoPeaks([0.4, 0.6]), [0.4, 0.6]);
    assert.deepEqual(stereoPeaks([0.4]), [0.4, 0.4]);
    assert.deepEqual(stereoPeaks([0.1, 0.2, 0.9, 0.9, 0.9, 0.9]), [0.1, 0.2]);
    assert.deepEqual(stereoPeaks([1.3, -0.1]), [1, 0]);
    assert.deepEqual(stereoPeaks([]), [0, 0]);
    assert.deepEqual(stereoPeaks(undefined), [0, 0]);
});

test("meterStep rises at once and falls back slowly", () => {
    const up = meterStep(METER_IDLE, 0.8, 0.016);
    assert.equal(up.level, 0.8);
    const down = meterStep(up, 0, 0.1);
    assert.ok(Math.abs(down.level - (0.8 - METER_FALL * 0.1)) < 1e-9);
    assert.equal(meterStep(down, 0.75, 0.016).level, 0.75);
});

test("meterStep holds the tick, then lets it fall", () => {
    let bar = meterStep(METER_IDLE, 0.8, 0.016);
    bar = meterStep(bar, 0.2, METER_HOLD / 2);
    assert.equal(bar.hold, 0.8);
    bar = meterStep(bar, 0.2, METER_HOLD);
    bar = meterStep(bar, 0.2, 0.1);
    assert.ok(bar.hold < 0.8 && bar.hold >= bar.level);
});

test("meterStep comes back to exactly idle in silence", () => {
    let bar = meterStep(METER_IDLE, 1, 0.016);
    for (let i = 0; i < 200 && !meterIdle(bar); i++)
        bar = meterStep(bar, 0, 0.016);
    assert.ok(meterIdle(bar));
    assert.deepEqual(meterStep(METER_IDLE, 0, 0.016), METER_IDLE);
});
