// Unit tests for what the clock's panel shows of the calendars.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    agenda, agendaNote, busyDays, covers, dayKey, emptyFeed, firstUpcoming, readFeed, relativeDay, shortDate, stepEvent,
} from "../calendar.mjs";

// A calendar-events.py line, its times given as local [y, m, d, h, min].
function line(events, extra = {}) {
    const at = parts => new Date(...parts).getTime();
    return JSON.stringify(Object.assign({
        from: at([2026, 8, 1]),
        to: at([2027, 1, 1]),
        calendars: [{ name: "Calendar", color: "#34616a" }, { name: "Holidays", color: "#36634d" }],
        events: events.map(e => Object.assign({ calendar: 0, location: "", link: "", allDay: false, tentative: false },
                                              e, { start: at(e.start), end: at(e.end) })),
        problems: [],
    }, extra));
}

const now = new Date(2026, 9, 7, 14, 30);
const today = new Date(2026, 9, 7);

// The agenda as [title, time] pairs, with each day heading as its label.
function listed(feed, day, days) {
    return agenda(feed, day, days, now).map(item => item.kind === "day" ? item.label : [item.title, item.time]);
}

test("readFeed turns a line into dates and calendars", () => {
    const feed = readFeed(line([{ title: "Standup", start: [2026, 9, 7, 9, 30], end: [2026, 9, 7, 9, 45], calendar: 1 }]));
    assert.equal(feed.loaded, true);
    assert.deepEqual(feed.from, new Date(2026, 8, 1));
    assert.deepEqual(feed.events[0].start, new Date(2026, 9, 7, 9, 30));
    assert.deepEqual(feed.events[0].calendar, { name: "Holidays", color: "#36634d" });
});

test("readFeed refuses what is not a snapshot", () => {
    assert.equal(readFeed("Traceback (most recent call last):"), null);
    assert.equal(readFeed("{}"), null);
    assert.equal(readFeed("null"), null);
});

test("a day's agenda lists all-day events first, then by start, with no heading", () => {
    const feed = readFeed(line([
        { title: "Review", start: [2026, 9, 7, 16, 0], end: [2026, 9, 7, 17, 0] },
        { title: "Standup", start: [2026, 9, 7, 9, 30], end: [2026, 9, 7, 9, 45] },
        { title: "Holiday", start: [2026, 9, 7], end: [2026, 9, 8], allDay: true, calendar: 1 },
        { title: "Tomorrow", start: [2026, 9, 8, 9, 30], end: [2026, 9, 8, 10, 0] },
    ]));
    assert.deepEqual(listed(feed, today, 1),
                     [["Holiday", "all day"], ["Standup", "09:30–09:45"], ["Review", "16:00–17:00"]]);
    assert.equal(agenda(feed, today, 1, now)[0].color, "#36634d");
});

test("the agenda leaves out a location that is only a link", () => {
    const feed = readFeed(line([
        { title: "Huddle", start: [2026, 9, 7, 9, 0], end: [2026, 9, 7, 10, 0],
          location: "https://app.slack.com/huddle/T1/C2", link: "https://app.slack.com/huddle/T1/C2" },
        { title: "Lunch", start: [2026, 9, 7, 12, 0], end: [2026, 9, 7, 13, 0], location: "Cafeteria, https://maps" },
    ]));
    assert.deepEqual(agenda(feed, today, 1, now).map(r => [r.location, r.link]),
                     [["", "https://app.slack.com/huddle/T1/C2"], ["Cafeteria, https://maps", ""]]);
});

test("the agenda says which events are over and which are under way", () => {
    const feed = readFeed(line([
        { title: "Holiday", start: [2026, 9, 7], end: [2026, 9, 8], allDay: true },
        { title: "Done", start: [2026, 9, 7, 9, 0], end: [2026, 9, 7, 10, 0] },
        { title: "Now", start: [2026, 9, 7, 14, 0], end: [2026, 9, 7, 15, 0] },
        { title: "Later", start: [2026, 9, 7, 16, 0], end: [2026, 9, 7, 17, 0] },
        { title: "Reminder", start: [2026, 9, 7, 11, 0], end: [2026, 9, 7, 11, 0] },
    ]));
    const rows = agenda(feed, today, 1, now);
    assert.deepEqual(rows.map(r => [r.title, r.past, r.ongoing]),
                     [["Holiday", false, false], ["Done", true, false], ["Reminder", true, false],
                      ["Now", false, true], ["Later", false, false]]);
    assert.equal(rows[2].time, "11:00");
    assert.equal(firstUpcoming(rows), 3);
});

test("a day's agenda shows where an event spanning days ends", () => {
    const feed = readFeed(line([
        { title: "Deploy", start: [2026, 9, 7, 22, 0], end: [2026, 9, 9, 2, 0] },
        { title: "OOO", start: [2026, 9, 5], end: [2026, 9, 16], allDay: true },
    ]));
    assert.deepEqual(listed(feed, today, 1), [["OOO", "until Thu 15 Oct"], ["Deploy", "22:00 → Fri 9 Oct 02:00"]]);
    assert.deepEqual(listed(feed, new Date(2026, 9, 8), 1),
                     [["OOO", "until Thu 15 Oct"], ["Deploy", "until Fri 9 Oct 02:00"]]);
    assert.deepEqual(listed(feed, new Date(2026, 9, 9), 1), [["OOO", "until Thu 15 Oct"], ["Deploy", "→ 02:00"]]);
    assert.deepEqual(listed(feed, new Date(2026, 9, 16), 1), []);
});

test("an all-day event ends at the midnight it ends on", () => {
    const feed = readFeed(line([
        { title: "OOO", start: [2026, 9, 5], end: [2026, 9, 8], allDay: true },
    ]));
    // Its last day, and so all of the day.
    assert.deepEqual(listed(feed, today, 1), [["OOO", "all day"]]);
    assert.deepEqual(listed(feed, new Date(2026, 9, 8), 1), []);
});

test("several days' agenda heads each day that has events, and lists an event once", () => {
    const feed = readFeed(line([
        { title: "Standup", start: [2026, 9, 7, 9, 30], end: [2026, 9, 7, 9, 45] },
        { title: "OOO", start: [2026, 9, 5], end: [2026, 9, 16], allDay: true },
        { title: "Review", start: [2026, 9, 9, 16, 0], end: [2026, 9, 9, 17, 0] },
        { title: "Retro", start: [2026, 9, 8, 11, 0], end: [2026, 9, 8, 12, 0] },
        { title: "Next week", start: [2026, 9, 14, 10, 0], end: [2026, 9, 14, 11, 0] },
    ]));
    assert.deepEqual(listed(feed, today, 7), [
        "Today · Wed 7 Oct", ["OOO", "until Thu 15 Oct"], ["Standup", "09:30–09:45"],
        "Tomorrow · Thu 8 Oct", ["Retro", "11:00–12:00"],
        "Fri 9 Oct", ["Review", "16:00–17:00"],
    ]);
    assert.equal(listed(feed, today, 30).filter(item => typeof item === "string").length, 4);
});

test("firstUpcoming scrolls to the heading of the day of the next meeting", () => {
    const feed = readFeed(line([
        { title: "Done", start: [2026, 9, 7, 9, 0], end: [2026, 9, 7, 10, 0] },
        { title: "Retro", start: [2026, 9, 8, 11, 0], end: [2026, 9, 8, 12, 0] },
    ]));
    const items = agenda(feed, today, 7, now);
    assert.equal(items[firstUpcoming(items)].label, "Tomorrow · Thu 8 Oct");
    assert.equal(firstUpcoming([]), 0);
});

test("stepEvent starts at the next meeting, then goes through the events and stops at the ends", () => {
    const feed = readFeed(line([
        { title: "OOO", start: [2026, 9, 5], end: [2026, 9, 16], allDay: true },
        { title: "Done", start: [2026, 9, 7, 9, 0], end: [2026, 9, 7, 10, 0] },
        { title: "Now", start: [2026, 9, 7, 14, 0], end: [2026, 9, 7, 15, 0] },
        { title: "Retro", start: [2026, 9, 8, 11, 0], end: [2026, 9, 8, 12, 0] },
    ]));
    const items = agenda(feed, today, 7, now);
    const title = i => items[i].title;
    assert.equal(title(stepEvent(items, -1, 1)), "Now");
    assert.equal(title(stepEvent(items, -1, -1)), "Now");
    // Over the heading of tomorrow.
    assert.equal(title(stepEvent(items, stepEvent(items, -1, 1), 1)), "Retro");
    const last = items.length - 1;
    assert.equal(title(stepEvent(items, last, 1)), "Retro");
    assert.equal(title(stepEvent(items, 1, -1)), "OOO");
    // A heading is no event to step from.
    assert.equal(title(stepEvent(items, 0, 1)), "Now");
    assert.equal(stepEvent([], -1, 1), -1);
});

test("stepEvent falls back on the first event not over, then on the first", () => {
    const past = readFeed(line([
        { title: "Done", start: [2026, 9, 7, 9, 0], end: [2026, 9, 7, 10, 0] },
        { title: "Holiday", start: [2026, 9, 7], end: [2026, 9, 8], allDay: true },
    ]));
    let items = agenda(past, today, 1, now);
    assert.equal(items[stepEvent(items, -1, 1)].title, "Holiday");
    items = agenda(past, new Date(2026, 9, 7), 1, new Date(2026, 9, 9));
    assert.equal(items[stepEvent(items, -1, 1)].title, "Holiday");
});

test("busyDays marks the days of events lasting a day at most", () => {
    const feed = readFeed(line([
        { title: "Standup", start: [2026, 9, 7, 9, 30], end: [2026, 9, 7, 9, 45] },
        { title: "Holiday", start: [2026, 9, 12], end: [2026, 9, 13], allDay: true },
        { title: "Deploy", start: [2026, 9, 14, 22, 0], end: [2026, 9, 15, 2, 0] },
        { title: "Ends at midnight", start: [2026, 9, 20, 23, 0], end: [2026, 9, 21, 0, 0] },
    ]));
    assert.deepEqual(Object.keys(busyDays(feed)),
                     ["2026-10-7", "2026-10-12", "2026-10-14", "2026-10-15", "2026-10-20"]);
});

test("busyDays leaves out events spanning several days", () => {
    const feed = readFeed(line([
        { title: "OOO", start: [2026, 9, 5], end: [2026, 9, 8], allDay: true },
        { title: "On call", start: [2026, 9, 5, 9, 0], end: [2026, 9, 12, 9, 0] },
    ]));
    assert.deepEqual(busyDays(feed), {});
});

test("busyDays counts the day DST ends as one day", () => {
    // Europe falls back on 25 October 2026, a day 25 hours long.
    const feed = readFeed(line([
        { title: "Holiday", start: [2026, 9, 25], end: [2026, 9, 26], allDay: true },
    ]));
    assert.deepEqual(Object.keys(busyDays(feed)), ["2026-10-25"]);
});

test("busyDays stays inside what the feed read", () => {
    const feed = readFeed(line([
        { title: "Late", start: [2027, 0, 31, 22, 0], end: [2027, 1, 1, 2, 0] },
    ]));
    assert.deepEqual(Object.keys(busyDays(feed)), ["2027-1-31"]);
});

test("covers is only true inside the window read", () => {
    const feed = readFeed(line([]));
    assert.equal(covers(feed, new Date(2026, 8, 1)), true);
    assert.equal(covers(feed, new Date(2026, 7, 31)), false);
    assert.equal(covers(feed, new Date(2027, 1, 1)), false);
    assert.equal(covers(emptyFeed(), today), false);
});

test("agendaNote tells no events from not read", () => {
    assert.equal(agendaNote(emptyFeed(), today, 1, []), "Reading calendars…");
    assert.equal(agendaNote(Object.assign(emptyFeed(), { problems: ["boom"] }), today, 1, []), "Events could not be read.");
    const feed = readFeed(line([]));
    assert.equal(agendaNote(feed, today, 1, []), "No events");
    assert.equal(agendaNote(feed, today, 7, []), "No events in these 7 days");
    assert.match(agendaNote(feed, new Date(2027, 5, 1), 1, []), /^Not read/);
    assert.match(agendaNote(readFeed(line([], { calendars: [] })), today, 1, []), /^No calendars/);
    assert.equal(agendaNote(feed, today, 1, [{}]), "");
});

test("agendaNote says when the days listed run past what was read", () => {
    const feed = readFeed(line([]));
    assert.equal(agendaNote(feed, new Date(2027, 0, 20), 30, [{}]), "Events after Sun 31 Jan are not read.");
    assert.equal(agendaNote(feed, new Date(2026, 7, 20), 30, [{}]), "Events before Tue 1 Sep are not read.");
    assert.equal(agendaNote(feed, new Date(2027, 0, 2), 30, [{}]), "");
});

test("relativeDay names the days next to today", () => {
    assert.equal(relativeDay(today, now), "Today");
    assert.equal(relativeDay(new Date(2026, 9, 8), now), "Tomorrow");
    assert.equal(relativeDay(new Date(2026, 9, 6), now), "Yesterday");
    assert.equal(relativeDay(new Date(2026, 9, 9), now), "");
    // Across the end of DST, 25 October is 25 hours long.
    assert.equal(relativeDay(new Date(2026, 9, 26), new Date(2026, 9, 25, 23, 30)), "Tomorrow");
});

test("dayKey and shortDate are the local day", () => {
    assert.equal(dayKey(new Date(2026, 9, 7, 23, 59)), "2026-10-7");
    assert.equal(shortDate(new Date(2026, 9, 7, 23, 59)), "Wed 7 Oct");
});
