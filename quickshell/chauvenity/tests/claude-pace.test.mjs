// Unit tests for the Claude usage pacing the niri bar shows.
//
//   node --test ~/.config/quickshell/chauvenity/tests/
//
// Dates are built with the local-time constructor, so these hold in any
// timezone; none of the windows below crosses a DST change.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    workMinutes,
    paceClock,
    parseFetch,
    fetchProblem,
    readUsage,
    worst,
    barWindows,
    duration,
    workDuration,
    clockTime,
    ago,
    deltaText,
} from "../claude-pace.mjs";

const at = (d, h, m = 0) => new Date(2026, 9, d, h, m); // October 2026; the 5th is a Monday

// The usage endpoint's answer: windows described by `kind` in `limits`.
function usage({ session, weekly, fable } = {}) {
    const limits = [];
    if (session) limits.push({ kind: "session", group: "session", percent: session[0], resets_at: session[1].toISOString(), scope: null });
    if (weekly) limits.push({ kind: "weekly_all", group: "weekly", percent: weekly[0], resets_at: weekly[1].toISOString(), scope: null });
    if (fable) limits.push({
        kind: "weekly_scoped", group: "weekly", percent: fable[0], resets_at: fable[1].toISOString(),
        scope: { model: { id: null, display_name: "Fable" } },
    });
    return JSON.stringify({ five_hour: null, seven_day: null, limits });
}
const row = (summary, key) => summary.windows.find(w => w.key === key);
const NOW = at(6, 15, 10);

test("a working day is 9:00–12:00 plus 13:30–18:30", () => {
    assert.equal(workMinutes(at(6, 0), at(7, 0)), 8 * 60);
});

test("lunch, evenings and weekends hold no working time", () => {
    assert.equal(workMinutes(at(6, 12), at(6, 13, 30)), 0);
    assert.equal(workMinutes(at(6, 18, 30), at(7, 9)), 0);
    assert.equal(workMinutes(at(10, 0), at(12, 0)), 0); // Sat + Sun
});

test("a full week is 40 working hours", () => {
    assert.equal(workMinutes(at(1, 10), at(8, 10)), 40 * 60);
});

test("the 5h window's linear pace only counts its working minutes", () => {
    // 12:40 → 17:40 spans lunch: 250 working minutes, 100 of them gone at 15:10.
    const w = row(readUsage(usage({ session: [58, at(6, 17, 40)] }), NOW), "session");
    assert.equal(w.measured, true);
    assert.equal(w.used, 58);
    assert.equal(w.expected, 40);
    assert.equal(w.delta, 18);
    assert.equal(w.tone, "bad");
});

test("the weekly window runs from seven days before its reset", () => {
    const w = row(readUsage(usage({ weekly: [61, at(8, 10)] }), NOW), "weekly");
    assert.equal(w.start.getTime(), at(1, 10).getTime());
    assert.ok(Math.abs(w.expected - 1660 / 24) < 1e-9);
    assert.equal(w.tone, "good");
});

test("the Fable window is the weekly limit scoped to the Fable model", () => {
    const w = row(readUsage(usage({ fable: [44, at(12, 8)] }), NOW), "fable");
    assert.equal(w.measured, true);
    assert.equal(w.used, 44);
    assert.equal(w.tone, "warn"); // pace 760 / 2400 working minutes = 31.7%
    assert.equal(clockTime(w.hitAt, NOW), "Thu 15:17");
});

test("without `limits`, the 5h and weekly windows come from the named keys", () => {
    const text = JSON.stringify({
        five_hour: { utilization: 58.0, resets_at: at(6, 17, 40).toISOString() },
        seven_day: { utilization: 61.0, resets_at: at(8, 10).toISOString() },
    });
    const s = readUsage(text, NOW);
    assert.equal(row(s, "session").used, 58);
    assert.equal(row(s, "weekly").used, 61);
    assert.equal(row(s, "fable").measured, false);
});

test("a window more than 5 points ahead warns, more than 15 is bad, within 5 is neutral", () => {
    const tone = used => row(readUsage(usage({ session: [used, at(6, 17, 40)] }), NOW), "session").tone;
    assert.equal(tone(45), "neutral");
    assert.equal(tone(35), "neutral");
    assert.equal(tone(46), "warn");
    assert.equal(tone(56), "bad");
    assert.equal(tone(34), "good");
});

test("pace stands still outside working hours", () => {
    const data = usage({ weekly: [61, at(8, 10)] });
    const evening = row(readUsage(data, at(6, 20)), "weekly");
    const nextMorning = row(readUsage(data, at(7, 9)), "weekly");
    assert.equal(evening.expected, nextMorning.expected);
});

test("time left counts the wall clock, work left counts working time", () => {
    const w = row(readUsage(usage({ weekly: [61, at(8, 10)] }), NOW), "weekly");
    assert.equal(w.leftMinutes, 42 * 60 + 50);
    assert.equal(w.workLeftMinutes, 12 * 60 + 20);
});

test("the gap from pace is also given in working minutes", () => {
    const w = row(readUsage(usage({ session: [58, at(6, 17, 40)] }), NOW), "session");
    assert.equal(w.deltaWorkMinutes, 45);
});

test("ahead of pace, the current rate says when the limit is hit", () => {
    // 58% in 100 working minutes: 100% after 172.4 of them, i.e. 16:22.
    const w = row(readUsage(usage({ session: [58, at(6, 17, 40)] }), NOW), "session");
    assert.equal(clockTime(w.hitAt, NOW), "16:22");
});

test("when the current rate does not reach the limit, it gives where the window ends", () => {
    const w = row(readUsage(usage({ weekly: [61, at(8, 10)] }), NOW), "weekly");
    assert.equal(w.hitAt, null);
    assert.equal(Math.round(w.projected), 88);
});

test("a window with no working time in it has no pace", () => {
    // Saturday 10:00 → 15:00.
    const w = row(readUsage(usage({ session: [20, at(10, 15)] }), at(10, 12)), "session");
    assert.equal(w.measured, true);
    assert.equal(w.expected, null);
    assert.equal(w.delta, null);
    assert.equal(w.tone, "neutral");
});

test("usage before the first working minute is all ahead of pace, with no projection", () => {
    // 07:00 → 12:00, read at 08:30.
    const w = row(readUsage(usage({ session: [10, at(6, 12)] }), at(6, 8, 30)), "session");
    assert.equal(w.expected, 0);
    assert.equal(w.delta, 10);
    assert.equal(w.hitAt, null);
    assert.equal(w.projected, null);
});

test("a window whose reset has passed is reported as reset, not measured", () => {
    const w = row(readUsage(usage({ session: [90, at(6, 14)] }), NOW), "session");
    assert.equal(w.measured, false);
    assert.equal(w.reason, "reset");
    assert.equal(w.resetsAt.getTime(), at(6, 14).getTime());
});

test("a window the endpoint did not report is not measured", () => {
    const s = readUsage(usage({ weekly: [61, at(8, 10)] }), NOW);
    assert.equal(row(s, "session").measured, false);
    assert.equal(row(s, "session").reason, "absent");
    assert.equal(row(s, "fable").reason, "absent");
});

test("the windows are listed 5h, weekly, Fable", () => {
    const s = readUsage(usage({ session: [1, at(6, 17)], weekly: [1, at(8, 10)], fable: [1, at(12, 8)] }), NOW);
    assert.deepEqual(s.windows.map(w => w.label), ["5h", "wk", "fable"]);
});

test("no answer, or one that does not parse, leaves every window unmeasured", () => {
    for (const text of ["", "{not json", "null"]) {
        const s = readUsage(text, NOW);
        assert.ok(s.windows.every(w => !w.measured && w.reason === "absent"), JSON.stringify(text));
    }
});

test("the fetch output splits into the body and the status on its last line", () => {
    assert.deepEqual(parseFetch('{"limits":[]}\nstatus 200\n'), { status: "200", body: '{"limits":[]}' });
    assert.deepEqual(parseFetch("status no-credentials\n"), { status: "no-credentials", body: "" });
    assert.deepEqual(parseFetch(""), { status: null, body: "" });
});

test("only a 200 counts as an answer; anything else says what went wrong", () => {
    assert.equal(fetchProblem("200"), null);
    assert.match(fetchProblem("no-credentials"), /not logged in/i);
    assert.match(fetchProblem("401"), /expired/i);
    assert.match(fetchProblem("429"), /rate.limited/i);
    assert.match(fetchProblem("000"), /no answer/i);
    assert.match(fetchProblem("503"), /HTTP 503/);
    assert.match(fetchProblem(null), /no answer/i);
});

test("the bar names the window furthest ahead of pace, and nothing when all are within 5", () => {
    const ahead = readUsage(usage({ session: [58, at(6, 17, 40)], weekly: [75, at(8, 10)] }), NOW);
    assert.equal(worst(ahead.windows).key, "session");
    const calm = readUsage(usage({ session: [42, at(6, 17, 40)], weekly: [61, at(8, 10)] }), NOW);
    assert.equal(worst(calm.windows), null);
});

test("the pace clock says until when it runs or stays paused", () => {
    assert.deepEqual(paceClock(NOW), { running: true, until: at(6, 18, 30) });
    assert.deepEqual(paceClock(at(6, 12, 5)), { running: false, until: at(6, 13, 30) });
    assert.deepEqual(paceClock(at(9, 19)), { running: false, until: at(12, 9) }); // Fri evening → Mon
});

test("durations read as days, hours and minutes; working time in hours only", () => {
    assert.equal(duration(150), "2h 30m");
    assert.equal(duration(42 * 60 + 50), "1d 18h 50m");
    assert.equal(duration(12), "12m");
    assert.equal(duration(-3), "0m");
    assert.equal(workDuration(45), "45m");
    assert.equal(workDuration(27 * 60 + 20), "27h 20m");
    assert.equal(workDuration(-196), "3h 16m");
});

test("a clock time names the weekday unless it is today", () => {
    assert.equal(clockTime(at(6, 17, 40), NOW), "17:40");
    assert.equal(clockTime(at(8, 10), NOW), "Thu 10:00");
});

test("the gap from pace reads as an arrow and signed points", () => {
    assert.equal(deltaText(18), "▲ +18");
    assert.equal(deltaText(-8.2), "▼ −8");
    assert.equal(deltaText(4.6), "≈ +5");
    assert.equal(deltaText(-5), "≈ −5");
    assert.equal(deltaText(null), "–");
});

test("the bar always shows the 5h window against pace, even on pace", () => {
    const s = readUsage(usage({ session: [42, at(6, 17, 40)], weekly: [61, at(8, 10)] }), NOW);
    assert.deepEqual(barWindows(s.windows).map(w => w.key), ["session"]);
});

test("the bar adds another window when it is more than 5 points ahead of pace", () => {
    const s = readUsage(usage({ session: [42, at(6, 17, 40)], weekly: [61, at(8, 10)], fable: [44, at(12, 8)] }), NOW);
    assert.deepEqual(barWindows(s.windows).map(w => w.key), ["session", "fable"]);
});

test("the bar adds only the other window furthest ahead of pace", () => {
    // Weekly is 5.8 points ahead, Fable 12.3: Fable wins, whatever the 5h window does.
    const s = readUsage(usage({ session: [58, at(6, 17, 40)], weekly: [75, at(8, 10)], fable: [44, at(12, 8)] }), NOW);
    assert.deepEqual(barWindows(s.windows).map(w => w.key), ["session", "fable"]);
});

test("without a 5h window, the bar shows only a window ahead of pace, if any", () => {
    const ahead = readUsage(usage({ fable: [44, at(12, 8)] }), NOW);
    assert.deepEqual(barWindows(ahead.windows).map(w => w.key), ["fable"]);
    assert.deepEqual(barWindows(readUsage("", NOW).windows), []);
});

test("a clock time rounds to the nearest minute", () => {
    // The endpoint gives resets like 05:59:59.6 UTC; that is 08:00, not 07:59.
    assert.equal(clockTime(new Date(2026, 9, 12, 7, 59, 59, 600), NOW), "Mon 08:00");
    assert.equal(clockTime(new Date(2026, 9, 6, 17, 40, 29), NOW), "17:40");
});

test("the age of the numbers reads 'just now' under a minute", () => {
    assert.equal(ago(0), "just now");
    assert.equal(ago(0.6), "just now");
    assert.equal(ago(1), "1m ago");
    assert.equal(ago(72), "1h 12m ago");
});
