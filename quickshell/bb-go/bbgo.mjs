// Logic for the bb go-to overlay (shell.qml): reading `bb nav list`, the
// rows and how they filter, and what to do with `bb nav open`'s answer.
//
// Plain ECMAScript, no QML: the overlay imports it and tests/bbgo.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread, no regex lookbehind or named groups.

export const THREADS_GROUP = "Needs you";

function parseJson(text) {
    try {
        return JSON.parse(String(text || ""));
    } catch (e) {
        return null;
    }
}

function lastLine(text) {
    const lines = String(text || "").trim().split("\n");
    return lines[lines.length - 1].trim();
}

// `bb nav list --json`: {threads, targets, sidebarReported}, or null when it
// is not that.
export function parseList(text) {
    const value = parseJson(text);
    if (!value || !Array.isArray(value.threads) || !Array.isArray(value.targets))
        return null;
    return {
        threads: value.threads.filter(t => t && typeof t.target === "string"),
        targets: value.targets.filter(t => t && typeof t.target === "string"),
        sidebarReported: value.sidebarReported === true,
    };
}

// Why `bb nav list` gave nothing to show, in one line.
export function listError(stdout, stderr, code) {
    const err = parseJson(stdout);
    if (err && err.error && err.error.message)
        return "bb: " + err.error.message;
    const line = lastLine(stderr) || lastLine(stdout);
    if (/unknown command/i.test(line) && /nav/.test(line))
        return "bb has no `nav` command: install ~/src/bb-plugins/bb-plugin-nav";
    return line ? "bb: " + line : "bb exited with " + code;
}

// "5m", "3h", "2d": how long ago, for a row's corner.
export function age(at, now) {
    const minutes = Math.max(0, Math.floor((now - at) / 60000));
    if (minutes < 1)
        return "now";
    if (minutes < 60)
        return minutes + "m";
    const hours = Math.floor(minutes / 60);
    if (hours < 48)
        return hours + "h";
    return Math.floor(hours / 24) + "d";
}

// --- rows -----------------------------------------------------------------------

// Every row, threads first, in bb's order: {target, label, detail, group,
// thread, unread, waiting, attentionAt}.
export function allRows(list) {
    if (!list)
        return [];
    const rows = [];
    for (const t of list.threads) {
        rows.push({
            target: t.target,
            label: t.title || t.id,
            detail: t.projectName || "",
            group: THREADS_GROUP,
            thread: true,
            unread: t.unread === true,
            waiting: t.waitingOnYou === true,
            attentionAt: t.attentionAt || 0,
        });
    }
    for (const t of list.targets) {
        rows.push({
            target: t.target,
            label: t.label || t.target,
            detail: "",
            group: t.group || "",
            thread: false,
            unread: false,
            waiting: false,
            attentionAt: 0,
        });
    }
    return rows;
}

function haystack(row) {
    return (row.label + " " + row.detail + " " + row.group + " " + row.target).toLowerCase();
}

// The rows holding every word of the query, groups kept in order and, within
// a group, the rows whose label starts with the query first. Each row says
// whether it opens its group, for the header above it.
export function filterRows(rows, query) {
    const q = String(query || "").trim().toLowerCase();
    const words = q === "" ? [] : q.split(/\s+/);
    const groups = [];
    const byGroup = {};
    for (const row of rows) {
        const text = haystack(row);
        if (!words.every(w => text.indexOf(w) !== -1))
            continue;
        if (!byGroup[row.group]) {
            byGroup[row.group] = { starting: [], holding: [] };
            groups.push(row.group);
        }
        if (q !== "" && row.label.toLowerCase().indexOf(q) === 0)
            byGroup[row.group].starting.push(row);
        else
            byGroup[row.group].holding.push(row);
    }
    const out = [];
    for (const group of groups) {
        const members = byGroup[group].starting.concat(byGroup[group].holding);
        for (let i = 0; i < members.length; i++)
            out.push(Object.assign({}, members[i], { first: i === 0 }));
    }
    return out;
}

// The index of the first row of the next (step 1) or previous (-1) group,
// wrapping round.
export function groupJump(rows, index, step) {
    if (rows.length === 0)
        return 0;
    const starts = [];
    for (let i = 0; i < rows.length; i++) {
        if (rows[i].first)
            starts.push(i);
    }
    let current = 0;
    for (let i = 0; i < starts.length; i++) {
        if (starts[i] <= index)
            current = i;
    }
    return starts[(current + step + starts.length) % starts.length];
}

// --- going there ----------------------------------------------------------------

export function openCommand(bb, target) {
    return [bb, "nav", "open", target, "--json"];
}

// `bb nav open --json`'s answer, made into what the overlay does next:
//   {action: "raise", title}   a tab on screen went: raise the window titled so
//   {action: "background"}     only tabs in the background went
//   {action: "browse", url}    no bb tab is connected: open one
//   {error}                    bb refused, or a tab could not go
export function decide(stdout, stderr, code) {
    const value = parseJson(stdout);
    if (code !== 0 || !value || typeof value.url !== "string")
        return { error: listError(stdout, stderr, code) };
    const tabs = Array.isArray(value.tabs) ? value.tabs : [];
    if (tabs.length === 0)
        return { action: "browse", url: value.url };
    const went = tabs.filter(t => t && t.opened);
    if (went.length === 0) {
        const why = tabs.find(t => t && t.error);
        return { error: "bb did not go there: " + (why ? why.error : "no tab could") };
    }
    const shown = went.find(t => t.visible && t.title);
    if (shown)
        return { action: "raise", title: shown.title };
    return { action: "background" };
}

// The window showing a tab titled `title`: browsers append their own name, so
// a window title starting with it. -1 when none does.
export function findWindow(titles, title) {
    if (!title)
        return -1;
    for (let i = 0; i < titles.length; i++) {
        if (String(titles[i] || "").indexOf(title) === 0)
            return i;
    }
    return -1;
}

export function parseFocusedOutput(text) {
    const value = parseJson(text);
    return value && typeof value.name === "string" ? value.name : "";
}
