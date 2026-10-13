// What the bar's volume indicator (Volume.qml) and its panel show.
//
// Plain ECMAScript, no QML: the bar imports it and tests/audio.test.mjs runs
// it under node. Keep to what Qt's JavaScript engine parses.

// The scroll wheel stops here; past it only another mixer can push the
// volume, and the bar then shows the overdrive in the warn colour.
export const WHEEL_MAX = 1.0;
export const WHEEL_STEP = 0.05;

// Which glyph a sink or source gets, from its PipeWire node name and
// properties. Headphones on a UCM card ("HiFi") are their own sink named after
// the route, so the name alone tells them from the speaker. A source with
// nothing to tell it apart answers "speaker" too: AudioIcon draws a
// microphone for an input whatever the kind, and only reads the kind for its
// badge.
export function nodeKind(name, props) {
    const p = props || {};
    const n = name || "";
    if (n.startsWith("bluez_output.") || n.startsWith("bluez_input.") || p["device.bus"] === "bluetooth")
        return "bluetooth";
    if (n.startsWith("raop_sink.") || n.startsWith("tunnel.") || p["device.bus"] === "network")
        return "network";
    const formFactor = p["device.form-factor"] || "";
    if (formFactor === "headphone" || formFactor === "headset" || /Head(phones|set)/.test(n))
        return "headphones";
    return "speaker";
}

// "muted", "over" (above 100 %, where PipeWire amplifies and clips) or "normal".
export function volumeTone(volume, muted) {
    if (muted) return "muted";
    return volume > 1.0005 ? "over" : "normal";
}

export function percent(volume) {
    return `${Math.round(Math.max(0, volume) * 100)}%`;
}

// One wheel notch, or one arrow key in VolumePanel: snapped to the 5 % grid
// so the bar reads round numbers,
// never above WHEEL_MAX — and never pulled down to it when the volume is
// already above and the wheel goes up.
export function stepVolume(volume, notches) {
    const snapped = Math.round(volume / WHEEL_STEP) * WHEEL_STEP;
    const next = Math.max(0, snapped + notches * WHEEL_STEP);
    if (notches > 0 && next > WHEEL_MAX)
        return Math.max(volume, WHEEL_MAX);
    return Math.round(next * 100) / 100;
}

// A playback stream's name in the panel: the application, else what the
// stream calls itself.
export function streamLabel(props, description, name) {
    const p = props || {};
    return p["application.name"] || p["media.name"] || description || name || "unknown";
}

// A pactl device with ports whose every one says "not available": the GPU's
// HDMI / DisplayPort outputs with no monitor (or a monitor without speakers)
// behind them. A port PipeWire can't probe says "availability unknown" and
// counts as plugged, as does a device with no ports at all.
function isUnplugged(device) {
    return !!device && Array.isArray(device.ports) && device.ports.length > 0
        && device.ports.every(p => p && p.availability === "not available");
}

// The device list of `pactl -f json list sinks|sources`, or [] when the
// output is not one.
function parseDevices(pactlJson) {
    try {
        const devices = JSON.parse(pactlJson);
        return Array.isArray(devices) ? devices : [];
    } catch (e) {
        return [];
    }
}

// The sinks nothing is plugged into, from `pactl -f json list sinks`.
// Unreadable output hides nothing.
export function unpluggedSinks(pactlJson) {
    return parseDevices(pactlJson).filter(isUnplugged).map(s => s.name);
}

// pactl's JSON gives each channel's volume on the same cubic scale as the
// panel's sliders, 65536 being 100 %.
const PA_VOLUME_NORM = 65536;

// The inputs of the panel, from `pactl -f json list sources` and the name
// `pactl get-default-source` printed: `current`, the default, and `shown`,
// the ones the picker lists, each `{ name, label, kind, volume, muted,
// monitor }`. The input side reads pactl rather than Quickshell's nodes
// because pulse sees what they don't: a virtual source (EasyEffects), a sink's
// monitor as a source with its own level and mute, and a port nothing is
// plugged into. A monitor records what a sink plays, so it is never offered,
// and neither is a microphone nothing is plugged into; either is still
// `current` and listed while it is the default. Unreadable output shows
// nothing.
export function inputDevices(sourcesJson, defaultName) {
    const devices = parseDevices(sourcesJson)
        .filter(d => d && typeof d.name === "string")
        .map(d => {
            const channels = Object.values(d.volume || {}).map(c => (c && c.value) || 0);
            const mean = channels.length > 0 ? channels.reduce((a, b) => a + b, 0) / channels.length : 0;
            return {
                device: {
                    name: d.name,
                    label: sinkLabel(d.description, d.name),
                    kind: nodeKind(d.name, d.properties),
                    volume: mean / PA_VOLUME_NORM,
                    muted: !!d.mute,
                    monitor: !!d.monitor_source,
                },
                offered: !d.monitor_source && !isUnplugged(d),
            };
        });
    const current = devices.find(d => d.device.name === defaultName);
    return {
        current: current ? current.device : null,
        shown: devices.filter(d => d.offered || d === current).map(d => d.device),
    };
}

// The integer `pactl set-source-volume` takes for a panel level. Not a
// decimal: pactl reads that as a linear amplitude factor, a different scale
// from the cubic one the panel and its raw values share.
export function paVolume(volume) {
    return Math.max(0, Math.round(volume * PA_VOLUME_NORM));
}

// A sink's or source's name in the panel, short enough not to be cut off: the
// chip without "High Definition Audio Controller", the port as "HDMI/DP n".
export function sinkLabel(description, name) {
    const d = description || name || "unknown";
    return d
        .replace(/\s+(High Definition|HD) Audio Controller\b/, "")
        .replace(/HDMI \/ DisplayPort (\d+) Output/, "HDMI/DP $1");
}

// The bar's level meter (PeakMeter.qml). PipeWire's peaks arrive about 20
// times a second and jump from one to the next; a bar rises with them at
// once and falls back METER_FALL per second, and a tick holds each high for
// METER_HOLD seconds before falling METER_HOLD_FALL per second. From
// METER_WARN up the bar takes the warn colour: the sink is close to clipping.
export const METER_FALL = 1.4;
export const METER_HOLD = 0.6;
export const METER_HOLD_FALL = 0.8;
export const METER_WARN = 0.9;

export const METER_IDLE = { level: 0, hold: 0, holdLeft: 0 };

// Left and right from PwNodePeakMonitor.peaks, each within 0..1: a mono sink
// feeds both bars, a surround one its front pair.
export function stereoPeaks(peaks) {
    const p = peaks || [];
    const clamp = v => Math.min(1, Math.max(0, v || 0));
    const left = clamp(p[0]);
    return [left, p.length > 1 ? clamp(p[1]) : left];
}

// One bar, dt seconds after its last frame. Silence brings it back to
// exactly METER_IDLE, so the meter knows when to stop redrawing.
export function meterStep(bar, peak, dt) {
    const level = peak >= bar.level ? peak : Math.max(peak, bar.level - METER_FALL * dt);
    if (level >= bar.hold)
        return { level, hold: level, holdLeft: level > 0 ? METER_HOLD : 0 };
    const holdLeft = Math.max(0, bar.holdLeft - dt);
    if (holdLeft > 0)
        return { level, hold: bar.hold, holdLeft };
    return { level, hold: Math.max(level, bar.hold - METER_HOLD_FALL * dt), holdLeft: 0 };
}

export function meterIdle(bar) {
    return bar.level === 0 && bar.hold === 0;
}
