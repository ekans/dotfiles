// What the bar shows of the focused window's title: clients tack their own
// name on the end ("… — Zen Browser"), and the bar shows the app's icon.
//
// Plain ECMAScript, no QML: the bar imports it and tests/window-title.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses.

// How clients join a title to their name, as the bar looks for them.
const SEPARATORS = [" — ", " – ", " - ", " | "];

// Lowercase words, so "Zen_Browser" and "zen browser" compare equal.
function words(text) {
    return text.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

// The title without its trailing app name, when it ends in one: the last
// segment goes if it holds the app's name (`appName`, from its desktop entry)
// as whole words, or is the last part of its id (`org.mozilla.firefox` →
// `firefox`). A title that is nothing else is kept, as is one that would
// come out empty.
export function withoutAppName(title, appName, appId) {
    const last = SEPARATORS
        .map(sep => ({ sep, at: title.lastIndexOf(sep) }))
        .reduce((a, b) => b.at > a.at ? b : a, { sep: "", at: -1 });
    if (last.at < 0)
        return title;
    const head = title.slice(0, last.at);
    const segment = words(title.slice(last.at + last.sep.length));
    const name = words(appName ?? "");
    const idName = words((appId ?? "").split(".").pop());
    const isApp = (name !== "" && ` ${segment} `.includes(` ${name} `))
        || (idName !== "" && segment === idName);
    return isApp && head.trim() !== "" ? head : title;
}
