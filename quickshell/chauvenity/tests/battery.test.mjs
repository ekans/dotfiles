// Unit tests for the bar's battery indicator and its history panel.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    STATE,
    batteryTone,
    alertPulse,
    percent,
    stateLabel,
    remaining,
    historyObjectPath,
    parseHistory,
    plotHistory,
    chargingSpans,
} from "../battery.mjs";

const T = 1_791_360_000; // 2026-10-07, in seconds like UPower's history

test("batteryTone: charging wins, then alert ≤ 10 %, low ≤ 20 %", () => {
    assert.equal(batteryTone(0.05, STATE.Charging), "charging");
    assert.equal(batteryTone(0.03, STATE.Charging), "charging");
    assert.equal(batteryTone(0.05, STATE.PendingCharge), "normal");
    assert.equal(batteryTone(0.03, STATE.PendingCharge), "normal");
    assert.equal(batteryTone(0.044, STATE.Discharging), "alert"); // shown as 4 %
    assert.equal(batteryTone(0, STATE.Empty), "alert");
    assert.equal(batteryTone(0.10, STATE.Discharging), "alert");
    assert.equal(batteryTone(0.104, STATE.Discharging), "alert"); // shown as 10 %
    assert.equal(batteryTone(0.105, STATE.Discharging), "low"); // shown as 11 %
    assert.equal(batteryTone(0.20, STATE.Discharging), "low");
    assert.equal(batteryTone(0.35, STATE.Discharging), "normal");
    assert.equal(batteryTone(1.0, STATE.FullyCharged), "normal");
});

test("alertPulse beats faster and redder as the level falls", () => {
    assert.deepEqual(alertPulse(0.10), { period: 3000, peak: 0.12 });
    assert.deepEqual(alertPulse(0.01), { period: 900, peak: 0.62 });
    assert.deepEqual(alertPulse(0), alertPulse(0.01));
    const levels = [0.10, 0.08, 0.05, 0.03, 0.01].map(alertPulse);
    for (let i = 1; i < levels.length; i++) {
        assert.ok(levels[i].period < levels[i - 1].period, "faster at a lower level");
        assert.ok(levels[i].peak > levels[i - 1].peak, "redder at a lower level");
    }
});

test("percent rounds a 0–1 fraction and clamps it", () => {
    assert.equal(percent(0.354), "35%");
    assert.equal(percent(1.2), "100%");
    assert.equal(percent(-0.1), "0%");
});

test("stateLabel names UPower's states", () => {
    assert.equal(stateLabel(STATE.Discharging), "Discharging");
    assert.equal(stateLabel(STATE.FullyCharged), "Fully charged");
    assert.equal(stateLabel(STATE.PendingCharge), "Not charging");
    assert.equal(stateLabel(42), "Unknown");
});

test("remaining says how long, and to what", () => {
    assert.equal(remaining(STATE.Discharging, 9600, 0), "2h 40m left");
    assert.equal(remaining(STATE.Charging, 0, 3900), "1h 05m to full");
    assert.equal(remaining(STATE.Charging, 0, 1500), "25m to full");
    // UPower reports 0 while it is still estimating.
    assert.equal(remaining(STATE.Discharging, 0, 0), "");
    assert.equal(remaining(STATE.FullyCharged, 0, 0), "");
});

test("historyObjectPath follows UPower's naming of the battery object", () => {
    assert.equal(historyObjectPath("BAT1"), "/org/freedesktop/UPower/devices/battery_BAT1");
    assert.equal(historyObjectPath("/sys/class/power_supply/BAT0"), "/org/freedesktop/UPower/devices/battery_BAT0");
    assert.equal(historyObjectPath("hid-d8:4d:03-battery"), "/org/freedesktop/UPower/devices/battery_hid_d8_4d_03_battery");
    assert.equal(historyObjectPath(""), "");
});

test("parseHistory reads busctl's JSON oldest first and drops the boot-time zeros", () => {
    const body = JSON.stringify({
        type: "a(udu)",
        data: [[
            [T, 33, 0],
            [T - 600, 0, 0],
            [T - 1200, 41.5, 2],
            [T - 1800, 54, 1],
        ]],
    });
    assert.deepEqual(parseHistory(body), [
        { t: T - 1800, value: 54, state: 1 },
        { t: T - 1200, value: 41.5, state: 2 },
        { t: T, value: 33, state: 0 },
    ]);
});

test("parseHistory answers null for anything that is not a history", () => {
    assert.equal(parseHistory(""), null);
    assert.equal(parseHistory("Call failed: device does not support getting history"), null);
    assert.equal(parseHistory(JSON.stringify({ data: "nope" })), null);
});

test("plotHistory holds each level until the next sample, inside the window", () => {
    const points = [
        { t: T - 7200, value: 80, state: 2 }, // before the window: its level opens it
        { t: T - 1800, value: 60, state: 2 },
    ];
    // 1 h window, 100 × 50 box; the line ends at `now` on the live level.
    const xy = plotHistory(points, { now: T, span: 3600, level: 50, width: 100, height: 50 });
    assert.deepEqual(xy, [
        { x: 0, y: 10 },
        { x: 50, y: 10 },
        { x: 50, y: 20 },
        { x: 100, y: 20 },
        { x: 100, y: 25 },
    ]);
});

test("plotHistory with nothing recorded draws the live level flat", () => {
    const xy = plotHistory([], { now: T, span: 3600, level: 35, width: 100, height: 100 });
    assert.deepEqual(xy, [{ x: 0, y: 65 }, { x: 100, y: 65 }]);
});

test("chargingSpans finds the stretches spent charging, clipped to the window", () => {
    const points = [
        { t: T - 7200, value: 40, state: 1 },
        { t: T - 2700, value: 90, state: 4 },
        { t: T - 1800, value: 88, state: 2 },
        { t: T - 900, value: 70, state: 1 },
    ];
    const spans = chargingSpans(points, { now: T, span: 3600, width: 100, charging: true });
    assert.deepEqual(spans, [
        { x: 0, width: 25 },
        { x: 75, width: 25 },
    ]);
});
