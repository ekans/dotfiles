// What the notification island (NotificationIsland.qml), the bar's bell
// (Notifications.qml) and its panel show, and when.
//
// Plain ECMAScript, no QML: the bar imports it and tests/notifications.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses.

// NotificationUrgency's values.
export const URGENCY = { Low: 0, Normal: 1, Critical: 2 };

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" };

// A body as plain text. The server does not advertise markup, but some apps
// send it anyway; shown as markup, an <img src="https://…"> in it would be
// fetched. Line breaks survive, every tag goes.
export function plainText(text) {
    return String(text ?? "")
        .replace(/<br\s*\/?>/gi, "\n")
        .replace(/<[^>]*>/g, "")
        .replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (whole, name) => {
            if (name[0] === "#") {
                const code = name[1] === "x" || name[1] === "X"
                    ? parseInt(name.slice(2), 16)
                    : parseInt(name.slice(1), 10);
                return Number.isFinite(code) ? String.fromCodePoint(code) : whole;
            }
            return ENTITIES[name.toLowerCase()] ?? whole;
        })
        .trim();
}

// The first line with text in it, for the one-line island.
export function firstLine(text) {
    return String(text ?? "").split("\n").map(line => line.trim()).find(line => line !== "") ?? "";
}

// How long the island shows a notification, in ms; 0 for until dismissed.
// expireTimeout is the app's, in seconds: -1 asks for the server's default
// and 0 for "never", which here means the panel keeps it, not the island.
export function popupDuration(urgency, expireTimeout) {
    if (urgency === URGENCY.Critical)
        return 0;
    if (expireTimeout > 0)
        return Math.min(20000, Math.max(3000, Math.round(expireTimeout * 1000)));
    return urgency === URGENCY.Low ? 4000 : 6000;
}

// Whether a notification pops up; with do-not-disturb on, only critical ones
// do. Every one of them goes to the panel either way.
export function popsUp(urgency, dnd) {
    return !dnd || urgency === URGENCY.Critical;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// How long ago a notification arrived, as the panel lists it.
export function ageLabel(arrived, now) {
    if (!arrived)
        return "";
    const a = new Date(arrived);
    const n = new Date(now);
    const minutes = Math.floor((n - a) / 60000);
    const midnight = new Date(n.getFullYear(), n.getMonth(), n.getDate());
    if (minutes < 1)
        return "now";
    if (a >= midnight)
        return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h`;
    const dayBefore = new Date(n.getFullYear(), n.getMonth(), n.getDate() - 1);
    if (a >= dayBefore)
        return "yesterday";
    return `${a.getDate()} ${MONTHS[a.getMonth()]}`;
}

// The bell's badge.
export function countLabel(count) {
    if (count <= 0)
        return "";
    return count > 99 ? "99+" : String(count);
}

// What to draw for a notification: its image (often the sender's picture),
// else the app's icon, as a path or URL (`source`) or a theme name (`icon`).
export function iconSource(image, appIcon) {
    const asUrl = path => path.startsWith("/") ? `file://${path}` : path;
    if (image)
        return { source: asUrl(image), icon: "" };
    if (!appIcon)
        return { source: "", icon: "" };
    if (appIcon.startsWith("/") || /^[a-z]+:\/\//.test(appIcon))
        return { source: asUrl(appIcon), icon: "" };
    return { source: "", icon: appIcon };
}

// The action a click on the notification itself invokes, or null.
export function defaultAction(actions) {
    return (actions ?? []).find(action => action.identifier === "default") ?? null;
}

// The actions that get a button: all but the default one, and none without a
// label.
export function buttonActions(actions) {
    return (actions ?? []).filter(action => action.identifier !== "default" && action.text !== "");
}
