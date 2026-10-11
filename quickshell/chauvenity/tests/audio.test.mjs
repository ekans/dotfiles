// Unit tests for the bar's volume indicator.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    sinkKind, volumeTone, percent, stepVolume, streamLabel, unpluggedSinks, sinkLabel,
    stereoPeaks, meterStep, meterIdle, METER_IDLE, METER_FALL, METER_HOLD,
} from "../audio.mjs";

test("sinkKind tells the output devices apart", () => {
    assert.equal(sinkKind("alsa_output.pci-0000_c1_00.6.HiFi__Speaker__sink", { "device.bus": "pci" }), "speaker");
    assert.equal(sinkKind("alsa_output.pci-0000_c1_00.6.HiFi__Headphones__sink", {}), "headphones");
    assert.equal(sinkKind("alsa_output.usb-foo", { "device.form-factor": "headset" }), "headphones");
    assert.equal(sinkKind("bluez_output.EC_66_D1_B8_EB_DC.1", {}), "bluetooth");
    assert.equal(sinkKind("raop_sink.Sejour.local.192.168.1.189.7000", {}), "network");
    assert.equal(sinkKind(undefined, undefined), "speaker");
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
