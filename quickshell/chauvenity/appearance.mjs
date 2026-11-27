// The light/dark switch (Appearance.qml): GNOME's colour-scheme key, which
// xdg-desktop-portal hands to every app that asks for the system's
// appearance (GTK 4, Qt, browsers, Electron).
//
// Plain ECMAScript, no QML: the bar imports it and tests/appearance.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses.

// "dark", "light", or null for a line that holds no scheme. Takes the output
// of `gsettings get` and the lines of `gsettings monitor` alike. "default"
// and "prefer-light" are both light.
export function readScheme(line) {
    const match = /'(default|prefer-light|prefer-dark)'/.exec(line);
    if (!match) return null;
    return match[1] === "prefer-dark" ? "dark" : "light";
}

// The command that sets the scheme to `mode`, "light" or "dark".
export function setScheme(mode) {
    return ["gsettings", "set", "org.gnome.desktop.interface", "color-scheme",
        mode === "dark" ? "prefer-dark" : "default"];
}
