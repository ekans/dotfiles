// Unit tests for what the bar shows of the walkpad: the helper's lines read
// into a model, the days, the words and the charts.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
    PROTOCOL, apply, clock, dayLine, emptyModel, km, lastDays, linkLine, lit, plotDays, plotTrace, retryLine,
    serviceConnecting, serviceDown, speed, stepPage, traceTop, walkLine,
} from "../walkpad.mjs";

// walkpad-ios's DayTotalsTests run in Paris; node takes TZ when it changes.
process.env.TZ = "Europe/Paris";

// The lines walkpad/tests/test_server.py checks the helper writes.
const CONTRACT = readFileSync(new URL("../walkpad/tests/fixtures/wire.jsonl", import.meta.url), "utf8")
    .split("\n").filter(line => line !== "");

const read = lines => lines.reduce((model, line) => apply(model, line), emptyModel());

// The contract's status line for a connected pad, with some fields replaced.
const status = fields => JSON.stringify(Object.assign({}, JSON.parse(CONTRACT[3]), fields));

// --- the wire --------------------------------------------------------------------

test("the contract's lines read into the open walk, its trace and the history", () => {
    const model = read(CONTRACT);
    assert.equal(model.service, "up");
    assert.equal(model.link.state, "connected");
    assert.equal(model.speedKmh, 3.0);
    assert.deepEqual(model.walks.map(w => [w.id, w.open]), [[2, true], [1, false]]);
    assert.equal(model.walks[0].elapsedS, 2);   // the status line's totals, not the walks line's
    assert.deepEqual(model.trace.points.map(p => p.t), [1800000020000, 1800000021000]);
    assert.deepEqual(model.samples.points.map(p => p.speedKmh), [3.0, 3.0, 0.0]);
    assert.equal(model.commandError, "no walk 9");
});

test("every line of the contract is taken in, none passed over as junk", () => {
    let model = emptyModel();
    for (const line of CONTRACT) {
        const next = apply(model, line);
        assert.notEqual(next, model, line);
        model = next;
    }
});

test("the waiting, idle and walking statuses of the contract read as the panel will draw them", () => {
    const waiting = apply(emptyModel(), CONTRACT[0]);
    assert.equal(waiting.link.state, "waiting");
    assert.equal(waiting.link.retryAt, 1800000012000);
    assert.equal(waiting.link.error, "Input/output error");
    assert.equal(waiting.pad, "MAXFREE-FAKE");
    assert.equal(waiting.speedKmh, null);

    const idle = apply(waiting, CONTRACT[3]);
    assert.equal(idle.speedKmh, 0);
    assert.equal(idle.open, null);

    const walking = apply(idle, CONTRACT[4]);
    assert.equal(walking.open.id, 2);
    assert.equal(walking.open.open, true);
    assert.equal(walking.open.maxSpeedKmh, 3.0);
});

test("a line that is not the helper's leaves the model as it was", () => {
    const model = read(CONTRACT);
    for (const junk of [
        "", "not json", "{}", "[1]", "null", '{"type":"walks","walks":"x"}', '{"type":"dance"}',
        '{"type":"walks","walks":[{"id":"1"}]}',
        '{"type":"trace","walk":1,"points":[[1,"x"]]}',
        '{"type":"samples","walk":1,"points":"x"}',
        '{"type":"done","cmd":"x","error":3}',
        status({ link: { state: "dancing" } }),
        status({ speedKmh: "fast" }),
        status({ connect: "yes" }),
        status({ problems: [3] }),
        status({ open: { id: 1 } }),
    ])
        assert.equal(apply(model, junk), model, junk);
});

test("a helper speaking another protocol is said so, not misread", () => {
    const model = apply(read(CONTRACT), JSON.stringify({ type: "status", protocol: PROTOCOL + 1 }));
    assert.equal(model.service, "mismatch");
    assert.match(linkLine(model).text, /systemctl --user restart walkpad/);
});

test("a point for another walk than the trace's is dropped", () => {
    const model = read(CONTRACT);
    assert.equal(apply(model, '{"type":"point","walk":1,"point":[1800000022000,3.0]}').trace.points.length, 2);
});

test("a command that went through clears the last one's error", () => {
    assert.equal(apply(read(CONTRACT), '{"type":"done","cmd":"finish","error":""}').commandError, "");
});

test("the status line's totals go on the open walk's row and on no other", () => {
    const row = (id, elapsedS, open) => ({
        id, startedAt: 1, endedAt: 2, elapsedS, distanceKm: 0.4, calories: 9, maxSpeedKmh: 3, open,
    });
    const walks = JSON.stringify({ type: "walks", walks: [row(3, 1, true), row(2, 7, false)] });
    const live = status({ open: { id: 3, startedAt: 1, endedAt: 61000, elapsedS: 60, distanceKm: 0.05, calories: 2, maxSpeedKmh: 3.1 } });
    const model = apply(apply(emptyModel(), walks), live);
    assert.deepEqual(model.walks.map(w => [w.id, w.elapsedS, w.distanceKm, w.open]), [[3, 60, 0.05, true], [2, 7, 0.4, false]]);
});

test("a service that is connecting is not up until the helper has spoken", () => {
    const connecting = serviceConnecting(serviceDown(read(CONTRACT)));
    assert.equal(connecting.service, "connecting");
    assert.equal(connecting.walks.length, 2);
    assert.equal(apply(connecting, CONTRACT[3]).service, "up");
});

test("the service going away keeps the walks but not the speed or the light", () => {
    const model = serviceDown(read(CONTRACT));
    assert.equal(model.walks.length, 2);
    assert.equal(model.speedKmh, null);
    assert.equal(model.open, null);
    assert.equal(lit(model), false);
    assert.match(linkLine(model).text, /journalctl --user -u walkpad/);
});

// --- what the link says -----------------------------------------------------------

test("waiting names the pad, and the iPhone only once BlueZ has refused a connect", () => {
    const waiting = error => apply(emptyModel(), status({
        link: { state: "waiting", pad: "MAXFREE03650", retryAt: 1800000012000, error },
    }));
    assert.deepEqual(linkLine(waiting("")), { text: "Waiting for MAXFREE03650: switch it on", tone: "dim" });
    assert.deepEqual(linkLine(waiting("Input/output error")), {
        text: "Waiting for MAXFREE03650: switch it on, or close the iPhone app",
        tone: "dim",
    });
});

test("each link state has its words and tone", () => {
    const linked = link => apply(emptyModel(), status({ link }));
    assert.deepEqual(linkLine(linked({ state: "off" })), { text: "Not connecting (see Settings)", tone: "warn" });
    assert.deepEqual(linkLine(linked({ state: "unavailable", reason: "Bluetooth is off" })), { text: "Bluetooth is off", tone: "warn" });
    assert.deepEqual(linkLine(linked({ state: "searching" })), { text: "Looking for the pad…", tone: "dim" });
    assert.deepEqual(linkLine(linked({ state: "connected", pad: "MAXFREE03650" })), { text: "Connected to MAXFREE03650", tone: "good" });
    assert.deepEqual(linkLine(emptyModel()), { text: "Connecting to the walkpad service…", tone: "dim" });
});

test("the retry line counts down to the helper's next attempt and is silent otherwise", () => {
    const waiting = apply(emptyModel(), CONTRACT[0]);
    assert.equal(retryLine(waiting, 1800000000000), "next try in 12 s");
    assert.equal(retryLine(waiting, new Date(1800000009500)), "next try in 3 s");
    assert.equal(retryLine(waiting, 1800000012000), "trying now");
    assert.equal(retryLine(apply(waiting, CONTRACT[3]), 1800000000000), "");
    assert.equal(retryLine(serviceDown(waiting), 1800000000000), "");
});

test("the glyph is lit only for a connected pad on a helper that is up", () => {
    assert.equal(lit(emptyModel()), false);
    assert.equal(lit(apply(emptyModel(), CONTRACT[0])), false);
    assert.equal(lit(apply(emptyModel(), CONTRACT[3])), true);
    assert.equal(lit(serviceDown(apply(emptyModel(), CONTRACT[3]))), false);
});

// --- days (walkpad-ios DayTotalsTests, without steps) -------------------------------

test("sums walks per day and keeps empty days", () => {
    const at = (y, m, d, h = 0) => new Date(y, m - 1, d, h).getTime();
    const now = at(2026, 10, 4, 18);
    const walk = (startedAt, distanceKm, elapsedS, calories) => ({ startedAt, distanceKm, elapsedS, calories });
    const days = lastDays(3, [
        walk(at(2026, 10, 4, 9), 1, 600, 30),
        walk(now, 0.5, 300, 15),
        walk(at(2026, 10, 3, 23), 2, 1200, 60),
        walk(at(2026, 9, 1), 9, 9, 9),
    ], now);
    assert.deepEqual(days.map(d => d.walks), [0, 1, 2]);
    assert.deepEqual(days.map(d => d.distanceKm), [0, 2, 1.5]);
    assert.equal(days.at(-1).day, at(2026, 10, 4));
});

test("keeps calendar days across a daylight-saving change", () => {
    // 2026-10-25 is 25 hours long in Paris.
    const days = lastDays(3, [], new Date(2026, 9, 26, 12).getTime());
    assert.deepEqual(days.map(d => new Date(d.day).getDate()), [24, 25, 26]);
    assert.deepEqual(days.map(d => new Date(d.day).getHours()), [0, 0, 0]);
});

// --- words (walkpad-ios Format, walkpad-app format.test.ts) ----------------------------

test("a clock shows hours only when there are some", () => {
    assert.equal(clock(0), "0:00");
    assert.equal(clock(754), "12:34");
    assert.equal(clock(3723), "1:02:03");
});

test("distances and speeds round like the pad shows them", () => {
    assert.equal(km(1.234), "1.23 km");
    assert.equal(speed(3.26), "3.3");   // not a tie: printf and toFixed break ties differently
    assert.equal(speed(null), "–");
});

test("a walk's line and a day's line read as the rows of the lists", () => {
    const walk = { distanceKm: 1.234, elapsedS: 754, calories: 45, walks: 2 };
    assert.equal(walkLine(walk), "1.23 km · 12:34 · 45 kcal");
    assert.equal(dayLine(walk), "1.23 km · 12:34 · 45 kcal · 2 walks");
    assert.equal(dayLine(Object.assign({}, walk, { walks: 1 })), "1.23 km · 12:34 · 45 kcal · 1 walk");
});

test("Left and Right step through the pages and stop at the ends", () => {
    assert.equal(stepPage("live", 1), "walks");
    assert.equal(stepPage("days", -1), "walks");
    assert.equal(stepPage("live", -1), "live");
    assert.equal(stepPage("settings", 1), "settings");
});

// --- charts ---------------------------------------------------------------------

const BOX = { from: 0, to: 100000, top: 4, width: 100, height: 40 };

test("a trace is a staircase across the width", () => {
    // 3 km/h from the start, 4 from the 40th second, 2 from the 70th.
    const points = [[0, 3], [40000, 4], [70000, 2]].map(([t, speedKmh]) => ({ t, speedKmh }));
    assert.deepEqual(plotTrace(points, BOX), [
        { x: 0, y: 10 },
        { x: 40, y: 10 }, { x: 40, y: 0 },
        { x: 70, y: 0 }, { x: 70, y: 20 },
        { x: 100, y: 20 },
    ]);
});

test("a trace past its scale stays in the box, and an empty one draws nothing", () => {
    const points = [{ t: 0, speedKmh: 9 }, { t: 200000, speedKmh: 0 }];
    assert.deepEqual(plotTrace(points, BOX), [{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 100, y: 40 }]);
    assert.deepEqual(plotTrace([], BOX), []);
});

test("a walk of one instant is a flat line across", () => {
    const points = [{ t: 5000, speedKmh: 2 }];
    assert.deepEqual(
        plotTrace(points, { from: 5000, to: 5000, top: 4, width: 100, height: 40 }),
        [{ x: 0, y: 20 }, { x: 100, y: 20 }]);
});

test("an hour-long trace is no more points than pixels", () => {
    // One sample a second for an hour: 3 km/h for the first half, 4 for the second.
    const points = [];
    for (let s = 0; s < 3600; s++) points.push({ t: s * 1000, speedKmh: s < 1800 ? 3 : 4 });
    const line = plotTrace(points, { from: 0, to: 3600000, top: 4, width: 360, height: 40 });
    assert.equal(line.length, 361);
    assert.deepEqual(line[0], { x: 0, y: 10 });
    assert.deepEqual(line[179], { x: 179, y: 10 });
    assert.deepEqual(line[180], { x: 180, y: 0 });
    assert.deepEqual(line[360], { x: 360, y: 0 });
});

test("a trace's scale is its top speed rounded up, and at least 4", () => {
    assert.equal(traceTop([]), 4);
    assert.equal(traceTop([{ t: 0, speedKmh: 3.5 }]), 4);
    assert.equal(traceTop([{ t: 0, speedKmh: 3.5 }, { t: 1, speedKmh: 5.2 }]), 6);
});

test("day bars scale to the busiest day and a day with a walk shows", () => {
    const day = (distanceKm, walks) => ({ distanceKm, walks });
    assert.deepEqual(plotDays([day(0, 0), day(2, 1), day(0.001, 1)], { width: 94, height: 40, gap: 2 }), [
        { x: 0, width: 30, y: 40, height: 0 },
        { x: 32, width: 30, y: 0, height: 40 },
        { x: 64, width: 30, y: 39, height: 1 },
    ]);
    assert.deepEqual(plotDays([day(0, 0)], { width: 10, height: 40, gap: 2 }), [{ x: 0, width: 10, y: 40, height: 0 }]);
    assert.deepEqual(plotDays([], { width: 10, height: 40, gap: 2 }), []);
});
