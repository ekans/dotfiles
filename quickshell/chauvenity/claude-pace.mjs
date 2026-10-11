// Pacing for the bar's Claude Code usage indicator (ClaudeUsage.qml).
//
// Plain ECMAScript, no QML: the bar imports it and tests/claude-pace.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread, for one. node accepts it, so only `qmllint-qt6 claude-pace.mjs` or
// the bar failing to load will tell you.
//
// "Linear pace" is the share of a window's *working* time already gone. It
// stands still at lunch, in the evening and over the weekend, so a window is
// only ahead of pace when usage outruns the working time spent in it.

// Monday to Friday, 09:00–12:00 and 13:30–18:30, as minutes of the day.
export const WORKING_HOURS = {
    days: [1, 2, 3, 4, 5],
    blocks: [[9 * 60, 12 * 60], [13 * 60 + 30, 18 * 60 + 30]],
};

// The windows the usage endpoint reports, in the order the panel lists them.
// Each is found by its `kind` in the answer's `limits`, the one part of it
// that describes itself; the 5h and weekly windows also have named keys,
// read when `limits` is missing. The endpoint only gives each window's reset
// time, so the start is derived from the window's length.
const WINDOWS = [
    {
        key: "session", label: "5h", name: "5-hour session", minutes: 5 * 60,
        matches: limit => limit.kind === "session", legacyKey: "five_hour",
    },
    {
        key: "weekly", label: "wk", name: "Weekly (all models)", minutes: 7 * 24 * 60,
        matches: limit => limit.kind === "weekly_all", legacyKey: "seven_day",
    },
    {
        key: "fable", label: "fable", name: "Weekly Fable", minutes: 7 * 24 * 60,
        matches: limit => limit.kind === "weekly_scoped"
            && !!limit.scope && !!limit.scope.model && limit.scope.model.display_name === "Fable",
        legacyKey: null,
    },
];

const MINUTE = 60 * 1000;
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// [start, end] millisecond pairs of working time between two dates.
function workIntervals(from, to, hours) {
    const out = [];
    const day = new Date(from.getFullYear(), from.getMonth(), from.getDate());
    for (; day < to; day.setDate(day.getDate() + 1)) {
        if (!hours.days.includes(day.getDay())) continue;
        for (const [open, close] of hours.blocks) {
            // The local-time constructor keeps 09:00 at 09:00 across DST.
            const lo = Math.max(new Date(day.getFullYear(), day.getMonth(), day.getDate(), 0, open).getTime(), from.getTime());
            const hi = Math.min(new Date(day.getFullYear(), day.getMonth(), day.getDate(), 0, close).getTime(), to.getTime());
            if (hi > lo) out.push([lo, hi]);
        }
    }
    return out;
}

export function workMinutes(from, to, hours = WORKING_HOURS) {
    return workIntervals(from, to, hours).reduce((sum, [lo, hi]) => sum + (hi - lo) / MINUTE, 0);
}

// The date `minutes` of working time after `from`, or null if that is past `to`.
function afterWorkMinutes(from, minutes, to, hours) {
    for (const [lo, hi] of workIntervals(from, to, hours)) {
        const length = (hi - lo) / MINUTE;
        if (minutes <= length) return new Date(lo + minutes * MINUTE);
        minutes -= length;
    }
    return null;
}

// Whether linear pace is advancing at `now`, and until when that holds.
export function paceClock(now, hours = WORKING_HOURS) {
    const horizon = new Date(now.getTime() + 8 * 24 * 60 * MINUTE);
    const intervals = workIntervals(now, horizon, hours);
    if (intervals.length === 0) return { running: false, until: null };
    const [lo, hi] = intervals[0];
    return lo <= now.getTime()
        ? { running: true, until: new Date(hi) }
        : { running: false, until: new Date(lo) };
}

function tone(delta) {
    if (delta === null) return "neutral";
    if (delta > 15) return "bad";
    if (delta > 5) return "warn";
    if (delta < -5) return "good";
    return "neutral";
}

// { percent, resetsAt } for one window of the endpoint's answer, or null.
function reported(spec, answer) {
    const limits = Array.isArray(answer.limits) ? answer.limits : [];
    const limit = limits.find(l => l && spec.matches(l));
    if (limit) return { percent: limit.percent, resetsAt: limit.resets_at };
    const named = spec.legacyKey && answer[spec.legacyKey];
    if (named) return { percent: named.utilization, resetsAt: named.resets_at };
    return null;
}

function measure(spec, answer, now, hours) {
    const window = reported(spec, answer);
    const resetsAt = window && typeof window.resetsAt === "string" ? new Date(window.resetsAt) : null;
    if (!window || typeof window.percent !== "number" || !resetsAt || isNaN(resetsAt.getTime()))
        return Object.assign({}, spec, { measured: false, reason: "absent" });
    if (resetsAt <= now) return Object.assign({}, spec, { measured: false, reason: "reset", resetsAt });

    const start = new Date(resetsAt.getTime() - spec.minutes * MINUTE);
    const used = window.percent;
    const total = workMinutes(start, resetsAt, hours);
    const done = workMinutes(start, now, hours);
    const expected = total ? (done * 100) / total : null;
    const delta = expected === null ? null : used - expected;
    // % per working minute so far; nothing to extrapolate from before the first one.
    const rate = done ? used / done : null;
    const projected = rate === null ? null : rate * total;
    const hitAt = rate && used < 100 ? afterWorkMinutes(start, 100 / rate, resetsAt, hours) : null;

    return Object.assign({}, spec, {
        measured: true,
        used,
        start,
        resetsAt,
        expected,
        delta,
        tone: tone(delta),
        leftMinutes: (resetsAt - now) / MINUTE,
        workLeftMinutes: total - done,
        deltaWorkMinutes: delta === null ? null : (delta * total) / 100,
        hitAt,
        projected,
    });
}

// What claude-usage-fetch.sh printed: the response body, then `status <code>`
// on the last line.
export function parseFetch(output) {
    const lines = output.replace(/\n+$/, "").split("\n");
    const last = lines[lines.length - 1];
    if (!last.startsWith("status ")) return { status: null, body: "" };
    return { status: last.slice("status ".length), body: lines.slice(0, -1).join("\n") };
}

// Why a fetch gave no usage, for the panel; null when it did.
export function fetchProblem(status) {
    if (status === "200") return null;
    if (status === "no-credentials") return "Not logged in: run `claude` once.";
    if (status === "401") return "Token expired: Claude Code refreshes it the next time it runs.";
    if (status === "429") return "Rate limited by the usage endpoint; retrying at the next poll.";
    if (status === null || status === "000") return "No answer from api.anthropic.com.";
    return `Usage endpoint answered HTTP ${status}.`;
}

// The usage endpoint's answer, one entry per window. Anything unreadable
// leaves every window unmeasured rather than at zero.
export function readUsage(text, now, hours = WORKING_HOURS) {
    let answer = null;
    try {
        answer = JSON.parse(text);
    } catch (e) {
        answer = null;
    }
    if (!answer || typeof answer !== "object") answer = {};
    return { windows: WINDOWS.map(spec => measure(spec, answer, now, hours)) };
}

// The window the bar should name: furthest ahead of pace, if more than 5 points.
export function worst(windows) {
    const ahead = windows.filter(w => w.measured && w.delta !== null && w.delta > 5);
    return ahead.length ? ahead.reduce((a, b) => (b.delta > a.delta ? b : a)) : null;
}

// What the bar shows: the 5h window against pace whatever its state, plus the
// other window furthest ahead of pace when that is more than 5 points.
export function barWindows(windows) {
    const session = windows.find(w => w.key === "session" && w.measured);
    const other = worst(windows.filter(w => w.key !== "session"));
    return [session, other].filter(w => !!w);
}

// "▲ +18": ahead of pace, "▼ −8": behind it, "≈" within 5 points either way.
// The arrow carries the meaning the colour does, for anyone who cannot tell
// the colours apart.
export function deltaText(delta) {
    if (delta === null) return "–";
    const arrow = Math.abs(delta) <= 5 ? "≈" : delta > 0 ? "▲" : "▼";
    return `${arrow} ${delta >= 0 ? "+" : "−"}${Math.abs(Math.round(delta))}`;
}

export function duration(minutes) {
    const m = Math.max(0, Math.round(minutes));
    const days = Math.floor(m / 1440), hrs = Math.floor((m % 1440) / 60), mins = m % 60;
    if (days) return `${days}d ${hrs}h ${mins}m`;
    if (hrs) return `${hrs}h ${mins}m`;
    return `${mins}m`;
}

// Working time reads in hours only: "27h 20m" of work, never "1d 3h".
export function workDuration(minutes) {
    const m = Math.abs(Math.round(minutes));
    const hrs = Math.floor(m / 60), mins = m % 60;
    return hrs ? `${hrs}h ${String(mins).padStart(2, "0")}m` : `${mins}m`;
}

// Rounded to the nearest minute: the endpoint's resets land a fraction of a
// second before the hour, and 07:59 reads as a different time from 08:00.
export function clockTime(date, now) {
    const t = new Date(Math.round(date.getTime() / MINUTE) * MINUTE);
    const hm = `${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`;
    return t.toDateString() === now.toDateString() ? hm : `${DAYS[t.getDay()]} ${hm}`;
}

// How old the numbers are, for the panel's footer.
export function ago(minutes) {
    return minutes < 1 ? "just now" : `${duration(minutes)} ago`;
}
