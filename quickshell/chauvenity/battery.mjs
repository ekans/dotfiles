// What the bar's battery indicator (Battery.qml) and its panel show.
//
// Plain ECMAScript, no QML: the bar imports it and tests/battery.test.mjs runs
// it under node. Keep to what Qt's JavaScript engine parses.

// UPower's device states. Quickshell's UPowerDeviceState enum and the third
// column of GetHistory both use this numbering.
export const STATE = {
    Unknown: 0,
    Charging: 1,
    Discharging: 2,
    Empty: 3,
    FullyCharged: 4,
    PendingCharge: 5,
    PendingDischarge: 6,
};

// "charging", "alert" (≤ 5 %), "critical" (≤ 10 %), "low" (≤ 20 %) or
// "normal", judged on the level as the bar rounds it. Plugged in but held by a
// charge threshold is never low: nothing is draining.
export function batteryTone(fraction, state) {
    if (state === STATE.Charging) return "charging";
    if (state === STATE.PendingCharge || state === STATE.FullyCharged) return "normal";
    const shown = Math.round(fraction * 100);
    if (shown <= 5) return "alert";
    if (shown <= 10) return "critical";
    if (shown <= 20) return "low";
    return "normal";
}

export function percent(fraction) {
    return `${Math.round(Math.min(1, Math.max(0, fraction)) * 100)}%`;
}

const LABELS = ["Unknown", "Charging", "Discharging", "Empty", "Fully charged", "Not charging", "Discharging"];

export function stateLabel(state) {
    return LABELS[state] ?? "Unknown";
}

function hoursMinutes(seconds) {
    const m = Math.round(seconds / 60);
    const hrs = Math.floor(m / 60), mins = m % 60;
    return hrs ? `${hrs}h ${String(mins).padStart(2, "0")}m` : `${mins}m`;
}

// UPower's estimate, or "" while it has none (it reports 0 then).
export function remaining(state, timeToEmpty, timeToFull) {
    if (state === STATE.Charging && timeToFull > 0) return `${hoursMinutes(timeToFull)} to full`;
    if (state === STATE.Discharging && timeToEmpty > 0) return `${hoursMinutes(timeToEmpty)} left`;
    return "";
}

// The D-Bus object UPower keeps the battery's history on. The DisplayDevice
// has none ("device does not support getting history"), so it is the real
// battery's: "battery_" and the basename of its native path, with what D-Bus
// does not allow in a path turned into "_".
export function historyObjectPath(nativePath) {
    const base = (nativePath || "").split("/").pop();
    if (!base) return "";
    return `/org/freedesktop/UPower/devices/battery_${base.replace(/[^A-Za-z0-9_]/g, "_")}`;
}

// `busctl --json=short call … GetHistory suu charge <span> <resolution>`
// answers {"type":"a(udu)","data":[[[time, value, state], …]]}, newest first.
// Returned oldest first, without the 0 % "unknown" rows UPower writes at boot
// before it has read the battery. null when the call did not answer that.
export function parseHistory(body) {
    let parsed;
    try {
        parsed = JSON.parse(body);
    } catch (e) {
        return null;
    }
    const rows = parsed && Array.isArray(parsed.data) ? parsed.data[0] : null;
    if (!Array.isArray(rows)) return null;
    return rows
        .filter(r => Array.isArray(r) && r.length === 3 && !(r[1] === 0 && r[2] === STATE.Unknown))
        .map(r => ({ t: r[0], value: r[1], state: r[2] }))
        .sort((a, b) => a.t - b.t);
}

// The charge line over the last `span` seconds up to `now`, in a box
// `width` × `height` (0 % at the bottom). UPower only records a change, so a
// level holds until the next sample: the line is a staircase, and the sample
// just before the window gives its opening level. It ends on the live
// `level` (0–100), which the history may not have caught up with.
export function plotHistory(points, { now, span, level, width, height }) {
    const start = now - span;
    const x = t => Math.round((t - start) / span * width * 100) / 100;
    const y = v => Math.round((1 - Math.min(100, Math.max(0, v)) / 100) * height * 100) / 100;

    const before = points.filter(p => p.t <= start);
    let current = before.length ? before[before.length - 1].value : null;
    const out = [];
    for (const p of points) {
        if (p.t <= start || p.t > now) continue;
        if (current === null) {
            current = p.value;
            out.push({ x: x(p.t), y: y(current) });
            continue;
        }
        if (out.length === 0) out.push({ x: 0, y: y(current) });
        if (p.value !== current) {
            out.push({ x: x(p.t), y: y(current) });
            out.push({ x: x(p.t), y: y(p.value) });
            current = p.value;
        }
    }
    if (current === null) current = level;
    if (out.length === 0) out.push({ x: 0, y: y(current) });
    out.push({ x: width, y: y(current) });
    if (level !== current) out.push({ x: width, y: y(level) });
    return out;
}

// The stretches of the window spent charging, as {x, width} along it.
// `charging` is the live state, which extends the last sample to `now`.
export function chargingSpans(points, { now, span, width, charging }) {
    const start = now - span;
    const x = t => Math.round((Math.min(now, Math.max(start, t)) - start) / span * width * 100) / 100;
    const spans = [];
    let from = null;
    for (const p of points) {
        const isCharging = p.state === STATE.Charging;
        if (isCharging && from === null) from = p.t;
        else if (!isCharging && from !== null) {
            if (p.t > start) spans.push({ x: x(from), width: x(p.t) - x(from) });
            from = null;
        }
    }
    if (from !== null && charging) spans.push({ x: x(from), width: width - x(from) });
    return spans.filter(s => s.width > 0);
}
