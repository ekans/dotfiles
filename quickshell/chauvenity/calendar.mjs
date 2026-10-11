// What the clock's panel (ClockPanel.qml) shows of the calendars: the
// snapshots calendar-events.py prints, read into dates, the days that have
// events, and the agenda of one day or of the days after it.
//
// Plain ECMAScript, no QML: the bar imports it and tests/calendar.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread, for one.

// Before calendar-events.py has said anything.
export function emptyFeed() {
    return { loaded: false, from: null, to: null, calendars: [], events: [], problems: [] };
}

// One line of calendar-events.py's output, or null when it is not one.
export function readFeed(line) {
    let raw;
    try {
        raw = JSON.parse(line);
    } catch (e) {
        return null;
    }
    if (!raw || !Array.isArray(raw.calendars) || !Array.isArray(raw.events))
        return null;
    const calendars = raw.calendars.map(c => ({ name: String(c.name ?? ""), color: String(c.color ?? "") }));
    const none = { name: "", color: "" };
    return {
        loaded: true,
        from: new Date(raw.from),
        to: new Date(raw.to),
        calendars,
        events: raw.events.map(e => ({
            title: String(e.title ?? ""),
            location: String(e.location ?? ""),
            link: String(e.link ?? ""),
            start: new Date(e.start),
            end: new Date(Math.max(e.end, e.start)),
            allDay: !!e.allDay,
            tentative: !!e.tentative,
            calendar: calendars[e.calendar] ?? none,
        })),
        problems: (raw.problems ?? []).map(String),
    };
}

// The local day a date falls on, as a key: `2026-10-7`.
export function dayKey(date) {
    return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

// Local midnight, built from the day rather than by adding 24 hours, which a
// DST change would throw off.
function startOfDay(date) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function nextDay(date) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
}

// Whether the feed has read that day: calendar-events.py only reads a few
// months around today, and no events outside them is not the same as none.
export function covers(feed, day) {
    return feed.loaded && day >= feed.from && day < feed.to;
}

// Whether an event lasts a day at most. An all-day one is measured in days
// rather than hours: the day DST ends has 25 of them.
function brief(e) {
    return e.allDay ? e.end <= nextDay(e.start) : e.end - e.start <= 24 * 3600 * 1000;
}

// The days with an event, as `{ [dayKey]: true }`. Only events of a day or
// less count: an absence or an on-call rotation spans weeks, and would mark
// nearly every day. An event ending at midnight does not reach into the day
// that starts then.
export function busyDays(feed) {
    const busy = {};
    if (!feed.loaded)
        return busy;
    for (const e of feed.events) {
        if (!brief(e))
            continue;
        const last = e.end > e.start ? new Date(e.end.getTime() - 1) : e.start;
        const stop = last < feed.to ? last : new Date(feed.to.getTime() - 1);
        for (let d = startOfDay(e.start < feed.from ? feed.from : e.start); d <= stop; d = nextDay(d))
            busy[dayKey(d)] = true;
    }
    return busy;
}

const DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function hhmm(date) {
    return String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0");
}

// `Wed 7 Oct`, as Qt's "ddd d MMM" writes it in the bar.
export function shortDate(date) {
    return `${DAY_NAMES[date.getDay()]} ${date.getDate()} ${MONTH_NAMES[date.getMonth()]}`;
}

// An event's time as listed under the day `from`–`to`: `14:00–15:00`, `all
// day`, and for one that runs on past that day where it ends — `22:00 → Thu
// 8 Oct 02:00`, `until Thu 15 Oct` — or, from the day before, `→ 02:00`.
function when(e, from, to) {
    if (e.allDay)
        return e.end <= to ? "all day" : `until ${shortDate(new Date(e.end.getTime() - 1))}`;
    const startsHere = e.start >= from;
    const endsHere = e.end <= to;
    if (startsHere && endsHere)
        return e.end > e.start ? `${hhmm(e.start)}–${hhmm(e.end)}` : hhmm(e.start);
    if (startsHere)
        return `${hhmm(e.start)} → ${shortDate(e.end)} ${hhmm(e.end)}`;
    if (endsHere)
        return `→ ${hhmm(e.end)}`;
    return `until ${shortDate(e.end)} ${hhmm(e.end)}`;
}

// The events of `days` days from `day`, as the panel lists them: a list of
// items, each `{ kind: "event", … }`, or for more than one day also a
// `{ kind: "day", label }` heading each day that has events. An event is
// listed once, under the first of its days in the list, so that an absence
// over three weeks is not thirty rows. Within a day all-day events come
// first, then by start; a timed event that covers the whole day counts as
// all-day there. `past` and `ongoing` are against `now`, and an all-day
// event is never ongoing, as it would be all day. A location that is only a
// link — a Slack huddle's, say — is left out: the row's link opens it.
export function agenda(feed, day, days, now) {
    const first = startOfDay(day);
    const last = new Date(first.getFullYear(), first.getMonth(), first.getDate() + days);
    const groups = {};
    for (const e of feed.events) {
        const instant = e.end.getTime() === e.start.getTime();
        if (e.start >= last || (instant ? e.start < first : e.end <= first))
            continue;
        const from = e.start < first ? first : startOfDay(e.start);
        const to = nextDay(from);
        const allDay = e.allDay || (e.start <= from && e.end >= to);
        const key = dayKey(from);
        (groups[key] = groups[key] ?? { day: from, rows: [] }).rows.push({
            kind: "event",
            title: e.title,
            location: /^https?:\/\/\S+$/.test(e.location.trim()) ? "" : e.location,
            link: e.link,
            calendar: e.calendar.name,
            color: e.calendar.color,
            tentative: e.tentative,
            allDay,
            start: e.start,
            time: when(e, from, to),
            past: instant ? e.start < now : e.end <= now,
            ongoing: !allDay && e.start <= now && now < e.end,
        });
    }
    const items = [];
    for (const group of Object.values(groups).sort((a, b) => a.day - b.day)) {
        if (days > 1) {
            const relative = relativeDay(group.day, now);
            items.push({ kind: "day", label: (relative ? relative + " · " : "") + shortDate(group.day) });
        }
        group.rows.sort((a, b) => (b.allDay - a.allDay) || (a.start - b.start) || a.title.localeCompare(b.title));
        for (const row of group.rows)
            items.push(row);
    }
    return items;
}

// The item to scroll the agenda to, so that the meetings already over
// scroll out of the way: the first timed event not over yet, or the heading
// of its day when there is one. 0 when there is none.
export function firstUpcoming(items) {
    let i = items.findIndex(item => item.kind === "event" && !item.allDay && !item.past);
    if (i < 0)
        return 0;
    for (let j = i; j >= 0; j--) {
        if (items[j].kind === "day")
            return j;
    }
    return i;
}

// The event Tab moves to from the item at `at`, `step` 1 forward or -1
// back, stopping at either end. From none — `at` -1, or no longer an event —
// it is the next meeting: the first timed event not over yet, else the first
// event not over, else the first. -1 when there are no events.
export function stepEvent(items, at, step) {
    const events = [];
    items.forEach((item, i) => {
        if (item.kind === "event")
            events.push(i);
    });
    if (events.length === 0)
        return -1;
    const k = events.indexOf(at);
    if (k < 0)
        return events.find(i => !items[i].allDay && !items[i].past)
            ?? events.find(i => !items[i].past)
            ?? events[0];
    return events[Math.min(Math.max(k + step, 0), events.length - 1)];
}

// `Today`, `Tomorrow` or `Yesterday`, or "" for any other day.
export function relativeDay(day, now) {
    const today = startOfDay(now);
    const offset = Math.round((startOfDay(day) - today) / (24 * 3600 * 1000));
    return { "-1": "Yesterday", "0": "Today", "1": "Tomorrow" }[String(offset)] ?? "";
}

// What the agenda of `days` days from `day` says besides its events: in
// their place when there are none, and below them when some of its days
// were not read. "" when there is nothing to say.
export function agendaNote(feed, day, days, items) {
    const last = new Date(day.getFullYear(), day.getMonth(), day.getDate() + days - 1);
    if (items.length > 0 && !covers(feed, day))
        return `Events before ${shortDate(feed.from)} are not read.`;
    if (items.length > 0)
        return covers(feed, last) ? "" : `Events after ${shortDate(new Date(feed.to.getTime() - 1))} are not read.`;
    if (!feed.loaded)
        return feed.problems.length > 0 ? "Events could not be read." : "Reading calendars…";
    if (!covers(feed, day))
        return "Not read: only last month to three months ahead are.";
    if (feed.calendars.length === 0)
        return "No calendars. Add Google or Microsoft 365 in Settings → Online Accounts.";
    return days === 1 ? "No events" : `No events in these ${days} days`;
}
