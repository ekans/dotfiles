// Unit tests for the bar's clock and its calendar panel.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import { isoWeek, monthGrid, shiftMonth, shiftMonthDay } from "../clock.mjs";

test("isoWeek numbers an ordinary week", () => {
    assert.deepEqual(isoWeek(new Date(2026, 9, 7)), { week: 41, year: 2026 });
    assert.deepEqual(isoWeek(new Date(2026, 9, 5)), { week: 41, year: 2026 }); // Monday
    assert.deepEqual(isoWeek(new Date(2026, 9, 11)), { week: 41, year: 2026 }); // Sunday
});

test("isoWeek puts the turn of the year in the week that holds its Thursday", () => {
    assert.deepEqual(isoWeek(new Date(2027, 0, 1)), { week: 53, year: 2026 }); // a Friday
    assert.deepEqual(isoWeek(new Date(2024, 11, 30)), { week: 1, year: 2025 }); // a Monday
    assert.deepEqual(isoWeek(new Date(2026, 0, 1)), { week: 1, year: 2026 }); // a Thursday
});

test("isoWeek ignores the time of day and DST changes", () => {
    assert.equal(isoWeek(new Date(2026, 2, 30, 23, 59)).week, 14); // the day after spring forward
    assert.equal(isoWeek(new Date(2026, 9, 26, 0, 1)).week, 44); // the day after fall back
});

test("monthGrid lays out six Monday-first weeks", () => {
    const grid = monthGrid(2026, 9, new Date(2026, 9, 7, 9, 29));
    assert.equal(grid.length, 6);
    assert.ok(grid.every(w => w.days.length === 7));
    // October 2026 starts on a Thursday: Mon 28 Sep … Wed 30 Sep lead in.
    assert.deepEqual(grid[0].days.slice(0, 4).map(d => [d.day, d.inMonth]),
                     [[28, false], [29, false], [30, false], [1, true]]);
    assert.deepEqual(grid.map(w => w.week), [40, 41, 42, 43, 44, 45]);
    assert.deepEqual(grid[5].days.map(d => d.day), [2, 3, 4, 5, 6, 7, 8]);
    assert.deepEqual(grid[0].days[0].date, new Date(2026, 8, 28));
});

test("monthGrid marks today and the weekend", () => {
    const grid = monthGrid(2026, 9, new Date(2026, 9, 7, 9, 29));
    const todays = grid.flatMap(w => w.days).filter(d => d.today);
    assert.deepEqual(todays.map(d => d.day), [7]);
    assert.deepEqual(grid[1].days.map(d => d.weekend), [false, false, false, false, false, true, true]);
    // The same day number in another month is not today.
    assert.equal(monthGrid(2026, 10, new Date(2026, 9, 7)).flatMap(w => w.days).some(d => d.today), false);
});

test("shiftMonth crosses years", () => {
    assert.deepEqual(shiftMonth(2026, 11, 1), { year: 2027, month: 0 });
    assert.deepEqual(shiftMonth(2026, 0, -1), { year: 2025, month: 11 });
    assert.deepEqual(shiftMonth(2026, 9, 0), { year: 2026, month: 9 });
});

test("shiftMonthDay keeps the day of the month, or the month's last", () => {
    assert.deepEqual(shiftMonthDay(new Date(2026, 9, 7), 1), new Date(2026, 10, 7));
    assert.deepEqual(shiftMonthDay(new Date(2027, 0, 31), 1), new Date(2027, 1, 28));
    assert.deepEqual(shiftMonthDay(new Date(2028, 2, 31), -1), new Date(2028, 1, 29));
    assert.deepEqual(shiftMonthDay(new Date(2026, 11, 15), 1), new Date(2027, 0, 15));
});
