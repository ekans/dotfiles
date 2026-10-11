// What the bar's network indicator (Network.qml) and its panel show.
//
// Plain ECMAScript, no QML: the bar imports it and tests/network.test.mjs runs
// it under node. Keep to what Qt's JavaScript engine parses. Quickshell's
// enums stay on the QML side, which hands these functions their meaning as
// strings: a connectivity of "full", "limited", "portal", "none" or
// "unknown", a security of "open", "psk" or "other".

// The panel lists at most this many networks; a busy café has dozens, and the
// weakest are the least likely to be picked.
export const MAX_LISTED = 10;

// How many of the glyph's three arcs a signal strength (0..1) lights.
export function signalLevel(strength) {
    if (strength > 0.7) return 3;
    if (strength > 0.45) return 2;
    if (strength > 0.2) return 1;
    return 0;
}

// The Wi-Fi networks the panel lists: the connected one, then any being
// connected to, then by signal. A saved network out of range stays in
// Quickshell's model with no signal; it is not offered.
export function listedNetworks(networks) {
    const rank = n => (n.connected ? 2 : n.stateChanging ? 1 : 0);
    return (networks || [])
        .filter(n => n.connected || n.stateChanging || n.signalStrength > 0)
        .sort((a, b) => rank(b) - rank(a)
            || b.signalStrength - a.signalStrength
            || String(a.name).localeCompare(String(b.name)));
}

// What picking a network that is not connected does: "connect", "password"
// to ask for one first, or "settings" for what only nm-connection-editor
// sets up (enterprise logins, WEP). A saved network is tried as it is; if
// NetworkManager wants a password after all, the panel asks then.
export function connectStep(known, security) {
    if (known || security === "open") return "connect";
    if (security === "psk") return "password";
    return "settings";
}

// Why a connection failed, in the panel, from Quickshell's
// ConnectionFailReason: "secrets", "disconnected", "failed", "timeout",
// "lost" or "unknown". `withPassword` says whether one was just typed.
export function failureText(reason, withPassword) {
    switch (reason) {
    case "secrets":
        return withPassword ? "Wrong password." : "This network needs a password.";
    case "timeout":
        return "The network took too long to answer.";
    case "lost":
        return "The network is out of range.";
    case "disconnected":
    case "failed":
        return "The network refused the connection.";
    default:
        return "Could not connect.";
    }
}

// The line under the panel's heading when the internet is not reachable
// through the connection NetworkManager has, or "".
export function connectivityText(connectivity) {
    switch (connectivity) {
    case "portal":
        return "This network wants you to sign in.";
    case "limited":
        return "Connected, but the internet is not reachable.";
    case "none":
        return "No connection.";
    default:
        return "";
    }
}

// A wired link's speed, given in Mb/s.
export function linkSpeed(mbps) {
    if (!(mbps > 0)) return "";
    return mbps >= 1000 && mbps % 100 === 0 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
}

// The bar's indicator, from
//
//     { wired, wifiOn, wifi: { name, signalStrength, connected, stateChanging } | null,
//       connectivity }
//
// `wired` says whether a cable is connected: NetworkManager routes through it
// before Wi-Fi, so it is what the bar shows. Answers
//
//     { glyph: "wired" | "wifi" | "off" | "none", level: 0..3, label, tone, busy }
//
// with tone "normal", "warn" (connected, internet not reachable) or "dim".
export function barState(s) {
    const tone = s.connectivity === "limited" || s.connectivity === "portal" || s.connectivity === "none"
        ? "warn" : "normal";
    const wifi = s.wifi;
    if (s.wired)
        return { glyph: "wired", level: 0, label: "", tone, busy: false };
    if (!s.wifiOn)
        return { glyph: "off", level: 0, label: "", tone: "dim", busy: false };
    if (wifi && wifi.connected)
        return { glyph: "wifi", level: signalLevel(wifi.signalStrength), label: wifi.name, tone, busy: false };
    if (wifi && wifi.stateChanging)
        return { glyph: "wifi", level: 0, label: wifi.name, tone: "dim", busy: true };
    return { glyph: "none", level: 0, label: "", tone: "dim", busy: false };
}
