// What the bar's clock (Clock.qml) and its calendar panel show.
//
// Plain ECMAScript, no QML: the bar imports it and tests/clock.test.mjs runs
// it under node. Keep to what Qt's JavaScript engine parses.

// The ISO 8601 week: weeks start on Monday, and week 1 is the one holding the
// year's first Thursday — so 1 January can be in week 52 or 53 of the year
// before, and 31 December in week 1 of the next.
export function isoWeek(date) {
    const d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    // The Thursday of this week decides which year the week belongs to.
    d.setDate(d.getDate() + 3 - (d.getDay() + 6) % 7);
    const year = d.getFullYear();
    const firstThursday = new Date(year, 0, 4);
    firstThursday.setDate(firstThursday.getDate() + 3 - (firstThursday.getDay() + 6) % 7);
    // Rounded: a DST change in between makes the span an hour off.
    const week = 1 + Math.round((d - firstThursday) / (7 * 24 * 3600 * 1000));
    return { week, year };
}

// The month as the panel lays it out: always six Monday-first weeks, so the
// panel keeps its height from one month to the next. Each week carries its
// ISO number; each day its date, and whether it is in the month, a weekend,
// or today.
export function monthGrid(year, month, today) {
    const first = new Date(year, month, 1);
    const start = new Date(year, month, 1 - (first.getDay() + 6) % 7);
    const weeks = [];
    for (let w = 0; w < 6; w++) {
        const days = [];
        for (let i = 0; i < 7; i++) {
            const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + w * 7 + i);
            days.push({
                date: d,
                day: d.getDate(),
                inMonth: d.getMonth() === month,
                weekend: i >= 5,
                today: !!today && sameDay(d, today),
            });
        }
        weeks.push({ week: isoWeek(new Date(start.getFullYear(), start.getMonth(), start.getDate() + w * 7)).week, days });
    }
    return weeks;
}

// The month `delta` months away, as { year, month } with month 0–11.
export function shiftMonth(year, month, delta) {
    const d = new Date(year, month + delta, 1);
    return { year: d.getFullYear(), month: d.getMonth() };
}

// The day `delta` months from `date`: the same day of the month, or the
// month's last when it is shorter — a month on from 31 January is 28
// February.
export function shiftMonthDay(date, delta) {
    const next = shiftMonth(date.getFullYear(), date.getMonth(), delta);
    const last = new Date(next.year, next.month + 1, 0).getDate();
    return new Date(next.year, next.month, Math.min(date.getDate(), last));
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear()
        && a.getMonth() === b.getMonth()
        && a.getDate() === b.getDate();
}
