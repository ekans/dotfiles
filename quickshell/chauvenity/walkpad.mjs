// What the bar shows of the walkpad: the helper's lines read into a model,
// the days, the words, the charts' geometry.
//
// Plain ECMAScript, no QML: WalkpadService.qml, Walkpad.qml and
// WalkpadPanel.qml import it and tests/walkpad.test.mjs runs it under node.
// Keep to what Qt's JavaScript engine parses, with no object spread.
//
// The walkpad itself is the helper (walkpad/, a systemd user service): it
// owns the pad, the walks and the rules. This module never decides anything
// about a walk. It reads what the helper says (walkpad/server.py has the
// wire, walkpad/tests/fixtures/wire.jsonl the contract both sides test) and
// derives what the panel draws.
//
// Times in the model are ms since the epoch, as on the wire. `now` comes in
// as an argument, as a Date or as ms.

// walkpad/server.py's PROTOCOL. A different one means the service and the
// bar are from different checkouts until the service is restarted.
export const PROTOCOL = 1;

// How many days the Days page covers.
export const DAYS = 30;

// The panel's pages, in the order Left and Right step through them.
export const PAGES = ["live", "walks", "days", "settings"];

const LINK_STATES = ["off", "unavailable", "searching", "waiting", "connected"];

/**
 * The model, before anything is heard from the helper.
 *
 * {
 *   service: "connecting" | "up" | "down" | "mismatch",
 *   link: { state: "off" | "unavailable" | "searching" | "waiting" | "connected",
 *           pad: string, reason: string, retryAt: number | null, error: string },
 *   connect: bool,            // "Connect to the pad"
 *   pad: string | null,       // the remembered pad's name
 *   speedKmh: number | null,  // null while not connected
 *   open: Walk | null,        // the walk taking readings
 *   trace: { walk: id | null, points: [{ t, speedKmh }] },   // the open walk's
 *   walks: [Walk],            // newest first; the open one carries the live totals
 *   samples: { walk: id, points: [{ t, speedKmh }] } | null, // the last asked for
 *   problems: [string],       // the helper's
 *   commandError: string,     // the last command's, "" when it went through
 * }
 *
 * Walk = { id, startedAt, endedAt, elapsedS, distanceKm, calories, maxSpeedKmh, open }
 */
export function emptyModel() {
    return {
        service: "connecting",
        link: { state: "off", pad: "", reason: "", retryAt: null, error: "" },
        connect: true,
        pad: null,
        speedKmh: null,
        open: null,
        trace: { walk: null, points: [] },
        walks: [],
        samples: null,
        problems: [],
        commandError: "",
    };
}

const num = v => typeof v === "number" && isFinite(v);
const str = v => typeof v === "string";

function readLink(raw) {
    if (!raw || typeof raw !== "object" || LINK_STATES.indexOf(raw.state) < 0) return null;
    const retryAt = raw.retryAt === undefined || raw.retryAt === null ? null : raw.retryAt;
    if (retryAt !== null && !num(retryAt)) return null;
    for (const field of ["pad", "reason", "error"])
        if (raw[field] !== undefined && !str(raw[field])) return null;
    return {
        state: raw.state,
        pad: raw.pad || "",
        reason: raw.reason || "",
        retryAt: retryAt,
        error: raw.error || "",
    };
}

// `open` is told by the walks line, and absent from the status line's walk,
// which is the open one by being there.
function readWalk(raw, open) {
    if (!raw || typeof raw !== "object") return null;
    for (const field of ["id", "startedAt", "endedAt", "elapsedS", "distanceKm", "calories", "maxSpeedKmh"])
        if (!num(raw[field])) return null;
    if (open === undefined && typeof raw.open !== "boolean") return null;
    return {
        id: raw.id,
        startedAt: raw.startedAt,
        endedAt: raw.endedAt,
        elapsedS: raw.elapsedS,
        distanceKm: raw.distanceKm,
        calories: raw.calories,
        maxSpeedKmh: raw.maxSpeedKmh,
        open: open === undefined ? raw.open : open,
    };
}

function readPoint(raw) {
    if (!Array.isArray(raw) || raw.length !== 2 || !num(raw[0]) || !num(raw[1])) return null;
    return { t: raw[0], speedKmh: raw[1] };
}

function readPoints(raw) {
    if (!Array.isArray(raw)) return null;
    const points = [];
    for (const p of raw) {
        const point = readPoint(p);
        if (point === null) return null;
        points.push(point);
    }
    return points;
}

// The status line carries the open walk's live totals and the walks line is
// only resent when the list changes shape, so the totals go onto the open
// walk's row here, at the reader.
function withOpen(walks, open) {
    if (open === null) return walks;
    return walks.map(w => w.id === open.id ? Object.assign({}, w, open) : w);
}

function readStatus(model, msg) {
    if (msg.protocol !== PROTOCOL) return Object.assign({}, model, { service: "mismatch" });
    const link = readLink(msg.link);
    const open = msg.open === null ? null : readWalk(msg.open, true);
    const problems = msg.problems;
    if (link === null || (msg.open !== null && open === null)) return model;
    if (typeof msg.connect !== "boolean" || !(msg.pad === null || str(msg.pad))) return model;
    if (!(msg.speedKmh === null || num(msg.speedKmh))) return model;
    if (!Array.isArray(problems) || !problems.every(str)) return model;
    return Object.assign({}, model, {
        service: "up",
        link: link,
        connect: msg.connect,
        pad: msg.pad,
        speedKmh: msg.speedKmh,
        open: open,
        walks: withOpen(model.walks, open),
        problems: problems.slice(),
    });
}

function readWalks(model, msg) {
    if (!Array.isArray(msg.walks)) return model;
    const walks = [];
    for (const raw of msg.walks) {
        const walk = readWalk(raw);
        if (walk === null) return model;
        walks.push(walk);
    }
    return Object.assign({}, model, { walks: withOpen(walks, model.open) });
}

/**
 * The model after one line from the helper. Junk (bad JSON, an unknown type,
 * a field of the wrong type) returns `model` itself, unchanged: a helper
 * from another version must not take the bar down.
 */
export function apply(model, line) {
    let msg;
    try {
        msg = JSON.parse(line);
    } catch (e) {
        return model;
    }
    if (!msg || typeof msg !== "object") return model;
    switch (msg.type) {
    case "status":
        return readStatus(model, msg);
    case "walks":
        return readWalks(model, msg);
    case "trace": {
        const points = readPoints(msg.points);
        if (points === null || !(msg.walk === null || num(msg.walk))) return model;
        return Object.assign({}, model, { trace: { walk: msg.walk, points: points } });
    }
    case "point": {
        const point = readPoint(msg.point);
        if (point === null || !num(msg.walk)) return model;
        // The helper sends the trace and then points; one for another walk
        // than the trace's is a straggler from before it changed.
        if (msg.walk !== model.trace.walk) return model;
        return Object.assign({}, model, {
            trace: { walk: model.trace.walk, points: model.trace.points.concat([point]) },
        });
    }
    case "samples": {
        const points = readPoints(msg.points);
        if (points === null || !num(msg.walk)) return model;
        return Object.assign({}, model, { samples: { walk: msg.walk, points: points } });
    }
    case "done":
        if (!str(msg.error)) return model;
        return Object.assign({}, model, { commandError: msg.error });
    default:
        return model;
    }
}

/** The socket connected: "connecting" until the first status line. */
export function serviceConnecting(model) {
    return Object.assign({}, model, { service: "connecting" });
}

/**
 * The socket is gone (service stopped, crashed, restarting). Keeps the walks
 * on screen. The link is unknown, so there is no speed and no open walk to
 * count time on.
 */
export function serviceDown(model) {
    return Object.assign({}, model, {
        service: "down",
        link: { state: "off", pad: "", reason: "", retryAt: null, error: "" },
        speedKmh: null,
        open: null,
    });
}

function msOf(now) {
    return +now;
}

/**
 * One entry per local day for the `count` days ending on `now`'s day,
 * oldest first, days without a walk kept at zero so a chart keeps its
 * spacing: walkpad-ios's DayTotals.last, without steps.
 * `[{ day: ms of local midnight, distanceKm, elapsedS, calories, walks }]`.
 * Days step with setDate, so a day stays midnight to midnight across a
 * daylight-saving change.
 */
export function lastDays(count, walks, now) {
    const today = new Date(msOf(now));
    today.setHours(0, 0, 0, 0);
    const days = [];
    const byDay = {};
    for (let back = count - 1; back >= 0; back--) {
        const d = new Date(today.getTime());
        d.setDate(d.getDate() - back);
        const entry = { day: d.getTime(), distanceKm: 0, elapsedS: 0, calories: 0, walks: 0 };
        days.push(entry);
        byDay[entry.day] = entry;
    }
    for (const walk of walks) {
        const start = new Date(walk.startedAt);
        start.setHours(0, 0, 0, 0);
        const entry = byDay[start.getTime()];
        if (!entry) continue;
        entry.distanceKm += walk.distanceKm;
        entry.elapsedS += walk.elapsedS;
        entry.calories += walk.calories;
        entry.walks += 1;
    }
    return days;
}

/**
 * The line under the panel's title, and its tone ("good", "warn", "dim").
 *
 *   connecting  "Connecting to the walkpad service…"
 *   down        "The walkpad service is not running. Its log: journalctl --user -u walkpad"
 *   mismatch    "The walkpad service is from another version: systemctl --user restart walkpad"
 *   off         "Not connecting (see Settings)"
 *   unavailable link.reason, e.g. "Bluetooth is off"
 *   searching   "Looking for the pad…"
 *   waiting     "Waiting for MAXFREE03650: switch it on", and once BlueZ has
 *               refused a connect ", or close the iPhone app"
 *   connected   "Connected to MAXFREE03650"
 */
export function linkLine(model) {
    switch (model.service) {
    case "connecting":
        return { text: "Connecting to the walkpad service…", tone: "dim" };
    case "down":
        return { text: "The walkpad service is not running. Its log: journalctl --user -u walkpad", tone: "warn" };
    case "mismatch":
        return { text: "The walkpad service is from another version: systemctl --user restart walkpad", tone: "warn" };
    }
    const link = model.link;
    switch (link.state) {
    case "off":
        return { text: "Not connecting (see Settings)", tone: "warn" };
    case "unavailable":
        return { text: link.reason || "Bluetooth is not available", tone: "warn" };
    case "searching":
        return { text: "Looking for the pad…", tone: "dim" };
    case "waiting":
        return {
            text: `Waiting for ${link.pad || "the pad"}: switch it on` + (link.error ? ", or close the iPhone app" : ""),
            tone: "dim",
        };
    default:
        return { text: `Connected to ${link.pad || "the pad"}`, tone: "good" };
    }
}

/** "next try in 12 s", or "" when not waiting on a retry. */
export function retryLine(model, now) {
    const link = model.link;
    if (model.service !== "up" || link.state !== "waiting" || link.retryAt === null) return "";
    const seconds = Math.ceil((link.retryAt - msOf(now)) / 1000);
    return seconds > 0 ? `next try in ${seconds} s` : "trying now";
}

/** Whether the bar's glyph is lit: the helper is up and the pad connected. */
export function lit(model) {
    return model.service === "up" && model.link.state === "connected";
}

/** 1:02:03 or 2:03, as walkpad-ios's Format.clock. */
export function clock(seconds) {
    const total = num(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
    const h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
    const pair = n => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${pair(m)}:${pair(s)}` : `${m}:${pair(s)}`;
}

/** "1.23 km" */
export function km(distanceKm) {
    return `${distanceKm.toFixed(2)} km`;
}

/** "3.2"; "–" for null. */
export function speed(kmh) {
    return num(kmh) ? kmh.toFixed(1) : "–";
}

/** "1.23 km · 12:34 · 45 kcal", a walk's row. */
export function walkLine(walk) {
    return `${km(walk.distanceKm)} · ${clock(walk.elapsedS)} · ${walk.calories} kcal`;
}

/** A day's row: its walk line and how many walks made it. */
export function dayLine(day) {
    return `${walkLine(day)} · ${day.walks} ${day.walks === 1 ? "walk" : "walks"}`;
}

/** The page `step` pages from `page` (Left is -1, Right 1), stopping at the ends. */
export function stepPage(page, step) {
    const at = PAGES.indexOf(page);
    return PAGES[Math.min(PAGES.length - 1, Math.max(0, (at < 0 ? 0 : at) + step))];
}

/**
 * A speed trace as pixel points for a Shape's PathPolyline: a staircase
 * (the speed holds until the next point), `t` from `from` to `to` across
 * `width`, 0 to `top` km/h up `height`. At most one step per pixel column
 * (the last speed in it), so an hour-long walk is still about `width` points:
 * where steps are a column apart the polyline itself is the staircase, and
 * only a longer hold gets its corner. `[{x, y}]`, rounded to 0.01.
 */
export function plotTrace(points, { from, to, top, width, height }) {
    if (points.length === 0) return [];
    const round = v => Math.round(v * 100) / 100;
    const y = kmh => round((1 - Math.min(1, Math.max(0, kmh / top))) * height);
    if (!(to > from)) {
        const level = y(points[points.length - 1].speedKmh);
        return [{ x: 0, y: level }, { x: width, y: level }];
    }
    const x = t => round(Math.min(1, Math.max(0, (t - from) / (to - from))) * width);

    // The last point of each pixel column stands for the column, drawn at its
    // left edge so a trace starts flush with the box.
    const steps = [];
    for (const p of points) {
        const column = Math.floor(x(p.t));
        const step = { column: column, x: column, y: y(p.speedKmh) };
        if (steps.length > 0 && steps[steps.length - 1].column === column) steps[steps.length - 1] = step;
        else steps.push(step);
    }

    const out = [{ x: steps[0].x, y: steps[0].y }];
    for (let i = 1; i < steps.length; i++) {
        if (steps[i].column - steps[i - 1].column > 1) out.push({ x: steps[i].x, y: steps[i - 1].y });
        out.push({ x: steps[i].x, y: steps[i].y });
    }
    // The last speed holds to the right edge, where `to` is.
    const last = steps[steps.length - 1];
    if (last.x < width) out.push({ x: width, y: last.y });
    return out;
}

/** The top of a trace's scale: its highest speed rounded up to 1 km/h, at least 4. */
export function traceTop(points) {
    let top = 4;
    for (const p of points) top = Math.max(top, Math.ceil(p.speedKmh));
    return top;
}

/**
 * The Days chart's bars: `[{ x, width, y, height }]`, one per day, scaled to
 * the busiest day; a day with a walk is at least 1 px tall.
 */
export function plotDays(days, { width, height, gap }) {
    if (days.length === 0) return [];
    const round = v => Math.round(v * 100) / 100;
    const barWidth = (width - gap * (days.length - 1)) / days.length;
    let busiest = 0;
    for (const d of days) busiest = Math.max(busiest, d.distanceKm);
    return days.map((d, i) => {
        let h = busiest > 0 ? d.distanceKm / busiest * height : 0;
        if (d.walks > 0) h = Math.max(1, h);
        return { x: round(i * (barWidth + gap)), width: round(barWidth), y: round(height - h), height: round(h) };
    });
}
