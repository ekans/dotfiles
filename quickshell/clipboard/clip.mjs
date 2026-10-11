// Clipboard history logic for shell.qml: reading `cliphist list`, telling
// links, colours, paths and images apart, filtering, and the small texts the
// overlay shows.
//
// Plain ECMAScript, no QML: the overlay imports it and tests/clip.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread, no regex lookbehind or named groups.

// How much of an entry the preview pane decodes. Anything longer is cut, and
// the pane says so.
export const DETAIL_LIMIT = 64 * 1024;

// Characters of each entry `cliphist list` returns, and so what the filter
// searches. cliphist collapses all whitespace in them to single spaces.
export const PREVIEW_WIDTH = 300;

// `[[ binary data 216 KiB png 1024x1024 ]]` — cliphist's preview of anything
// Go's image decoders could read.
const IMAGE_PREVIEW = /^\[\[ binary data (.+?) ([a-z0-9]+) (\d+)x(\d+) \]\]$/;

const IMAGE_MIME = {
    png: "image/png",
    jpeg: "image/jpeg",
    gif: "image/gif",
    bmp: "image/bmp",
    webp: "image/webp",
};

// Words the filter also matches each kind on, so "image" or "link" finds them.
const KIND_WORDS = {
    text: "text",
    link: "link url",
    color: "color colour",
    path: "path file",
    image: "image picture",
};

// Control characters other than tab: a binary entry cliphist could not read as
// an image still comes through as its raw bytes.
const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f]/g;

// `cliphist list` → newest first, one entry per line: `<id>\t<preview>`.
export function parseList(output) {
    const entries = [];
    for (const line of String(output || "").split("\n")) {
        const tab = line.indexOf("\t");
        if (tab <= 0)
            continue;
        const id = line.slice(0, tab);
        if (!/^\d+$/.test(id))
            continue;
        entries.push(classify(id, line.slice(tab + 1)));
    }
    return entries;
}

export function classify(id, rawPreview) {
    const preview = rawPreview.replace(CONTROL, "").trim();
    const image = IMAGE_PREVIEW.exec(preview);
    if (image) {
        const format = image[2];
        return {
            id: id,
            kind: "image",
            preview: preview,
            size: image[1],
            format: format,
            mime: IMAGE_MIME[format] || "",
            width: Number(image[3]),
            height: Number(image[4]),
        };
    }

    // Stored by `wl-paste --type text`, so handed back as plain text: left to
    // guess, wl-copy would offer `<b>hi</b>` as text/html.
    const entry = { id: id, kind: "text", preview: preview, mime: "text/plain;charset=utf-8" };
    const color = cssColor(preview);
    if (color) {
        entry.kind = "color";
        entry.color = color;
    } else if (/^(https?|ftp|file):\/\/\S+$/i.test(preview) || /^mailto:\S+@\S+$/i.test(preview)) {
        entry.kind = "link";
        entry.host = linkHost(preview);
    } else if (/^~?\/\S*$/.test(preview) && preview.length > 1) {
        entry.kind = "path";
    }
    return entry;
}

export function linkHost(url) {
    const match = /^[a-z]+:\/\/([^/?#]+)/i.exec(url);
    if (match)
        return match[1].replace(/^[^@]*@/, "");
    const mail = /^mailto:\S+@([^?\s]+)/i.exec(url);
    return mail ? mail[1] : "";
}

function hex2(n) {
    const clamped = Math.max(0, Math.min(255, Math.round(n)));
    return (clamped < 16 ? "0" : "") + clamped.toString(16);
}

// A CSS colour as QML spells it, `#aarrggbb`, or null. QML puts alpha first
// and CSS last, so `#62a0ea80` has to be turned round.
export function cssColor(text) {
    const value = String(text).trim();

    const hex = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.exec(value);
    if (hex) {
        let digits = hex[1].toLowerCase();
        if (digits.length <= 4)
            digits = digits.split("").map(d => d + d).join("");
        const alpha = digits.length === 8 ? digits.slice(6) : "ff";
        return "#" + alpha + digits.slice(0, 6);
    }

    // rgb(98, 160, 234) · rgba(98,160,234,0.5) · rgb(98 160 234 / 50%)
    const rgb = /^rgba?\(\s*(\d{1,3})[\s,]+(\d{1,3})[\s,]+(\d{1,3})(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/i.exec(value);
    if (rgb) {
        const channels = [rgb[1], rgb[2], rgb[3]].map(Number);
        if (channels.some(c => c > 255))
            return null;
        let alpha = 1;
        if (rgb[4] !== undefined)
            alpha = rgb[4].endsWith("%") ? parseFloat(rgb[4]) / 100 : parseFloat(rgb[4]);
        if (!(alpha >= 0 && alpha <= 1))
            return null;
        return "#" + hex2(alpha * 255) + channels.map(hex2).join("");
    }
    return null;
}

// A QML `#aarrggbb` colour back in the two CSS spellings, alpha last.
export function colorFormats(qmlColor) {
    const alpha = parseInt(qmlColor.slice(1, 3), 16);
    const channels = [3, 5, 7].map(at => parseInt(qmlColor.slice(at, at + 2), 16));
    const opaque = alpha === 255;
    return {
        hex: "#" + qmlColor.slice(3) + (opaque ? "" : qmlColor.slice(1, 3)),
        rgb: "rgb(" + channels.join(" ") + (opaque ? "" : " / " + Math.round(alpha / 2.55) + "%") + ")",
    };
}

export function queryTerms(query) {
    const trimmed = String(query || "").trim().toLowerCase();
    return trimmed === "" ? [] : trimmed.split(/\s+/);
}

// The tabs above the list, cycled with Tab. Paths count as text.
export const CATEGORIES = [
    { key: "all", label: "All" },
    { key: "text", label: "Text" },
    { key: "link", label: "Links" },
    { key: "image", label: "Images" },
    { key: "color", label: "Colours" },
];

export function inCategory(entry, category) {
    if (category === "all")
        return true;
    if (category === "text")
        return entry.kind === "text" || entry.kind === "path";
    return entry.kind === category;
}

// Every whitespace-separated word of the query has to appear, in any order,
// in the entry or in the words for its kind. History order is kept.
export function matchesQuery(entry, terms) {
    const haystack = (entry.preview + " " + KIND_WORDS[entry.kind]).toLowerCase();
    return terms.every(term => haystack.indexOf(term) !== -1);
}

export function filterEntries(entries, query, category) {
    const terms = queryTerms(query);
    const tab = category || "all";
    if (terms.length === 0 && tab === "all")
        return entries;
    return entries.filter(entry => inCategory(entry, tab) && matchesQuery(entry, terms));
}

// How many entries matching the query each tab holds.
export function categoryCounts(entries, query) {
    const terms = queryTerms(query);
    const counts = {};
    for (const category of CATEGORIES)
        counts[category.key] = 0;
    for (const entry of entries) {
        if (!matchesQuery(entry, terms))
            continue;
        for (const category of CATEGORIES) {
            if (inCategory(entry, category.key))
                counts[category.key] += 1;
        }
    }
    return counts;
}

export function escapeHtml(text) {
    return String(text)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

// `text` as Qt StyledText with the query's words picked out in `color`.
// Everything taken from the clipboard is escaped: StyledText would otherwise
// render tags in it, <img src="https://…"> included, and fetch that URL.
export function highlight(text, query, color) {
    const terms = queryTerms(query);
    const lower = String(text).toLowerCase();
    const marked = [];
    for (const term of terms) {
        let from = 0;
        let at;
        while ((at = lower.indexOf(term, from)) !== -1) {
            marked.push([at, at + term.length]);
            from = at + term.length;
        }
    }
    if (marked.length === 0)
        return escapeHtml(text);

    marked.sort((a, b) => a[0] - b[0]);
    const merged = [marked[0].slice()];
    for (const range of marked.slice(1)) {
        const last = merged[merged.length - 1];
        if (range[0] <= last[1])
            last[1] = Math.max(last[1], range[1]);
        else
            merged.push(range.slice());
    }

    let html = "";
    let from = 0;
    for (const range of merged) {
        html += escapeHtml(text.slice(from, range[0]));
        html += '<font color="' + color + '"><b>' + escapeHtml(text.slice(range[0], range[1])) + "</b></font>";
        from = range[1];
    }
    return html + escapeHtml(text.slice(from));
}

// The detail job prints the entry's size in bytes on its first line, then at
// most DETAIL_LIMIT bytes of it.
export function parseDetail(output) {
    const text = String(output || "");
    const newline = text.indexOf("\n");
    const total = parseInt(newline === -1 ? text : text.slice(0, newline), 10) || 0;
    return {
        total: total,
        text: newline === -1 ? "" : text.slice(newline + 1),
        truncated: total > DETAIL_LIMIT,
    };
}

export function textStats(text) {
    const body = String(text);
    const lines = body === "" ? 0 : body.replace(/\n$/, "").split("\n").length;
    const words = (body.match(/\S+/g) || []).length;
    return { chars: Array.from(body).length, lines: lines, words: words };
}

// Grouped by hand: Qt's toLocaleString ignores the locale it is given.
export function count(n, singular, plural) {
    const grouped = String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return grouped + " " + (n === 1 ? singular : (plural || singular + "s"));
}

export function humanBytes(bytes) {
    if (bytes < 1024)
        return count(bytes, "byte");
    if (bytes < 1024 * 1024)
        return (bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0) + " KiB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MiB";
}

// What the preview pane's header says about an entry.
export function describe(entry, detail) {
    if (entry.kind === "image")
        return ["Image", entry.format.toUpperCase(), entry.width + " × " + entry.height, entry.size].join(" · ");
    const label = { text: "Text", link: "Link", color: "Colour", path: "Path" }[entry.kind];
    if (entry.kind === "color" || !detail || detail.id !== entry.id)
        return label;
    const stats = textStats(detail.text);
    const parts = [label];
    if (detail.truncated)
        parts.push(humanBytes(detail.total) + ", first " + humanBytes(DETAIL_LIMIT) + " shown");
    else
        parts.push(count(stats.chars, "char"));
    if (stats.lines > 1)
        parts.push(count(stats.lines, "line"));
    if (entry.kind === "text")
        parts.push(count(stats.words, "word"));
    return parts.join(" · ");
}

// The short tag a row shows on its right; empty for plain text.
export function rowTag(entry) {
    switch (entry.kind) {
    case "image":
        return entry.format + " " + entry.width + "×" + entry.height;
    case "link":
        return entry.host || "link";
    case "path":
        return "path";
    default:
        return "";
    }
}

// `niri msg --json focused-output; niri msg --json focused-window` → where to
// open, and which window a paste goes back to. Either may be missing or null.
export function parseProbe(output) {
    const found = { output: "", appId: "" };
    for (const line of String(output || "").split("\n")) {
        let value;
        try {
            value = JSON.parse(line);
        } catch (e) {
            continue;
        }
        if (!value || typeof value !== "object")
            continue;
        if (value.app_id !== undefined)
            found.appId = String(value.app_id || "");
        else if (typeof value.name === "string" && value.logical !== undefined)
            found.output = value.name;
    }
    return found;
}

// Terminals take Ctrl+Shift+V; a plain Ctrl+V there is a control character.
const TERMINAL_WORDS = ["ghostty", "kitty", "alacritty", "foot", "footclient", "konsole", "console",
    "ptyxis", "tilix", "terminator", "rio", "warp", "kgx", "blackbox"];

export function isTerminal(appId) {
    const parts = String(appId || "").toLowerCase().split(/[.\-_]/);
    return parts.some(part => TERMINAL_WORDS.indexOf(part) !== -1 || part.indexOf("term") !== -1);
}

// wtype arguments for the paste shortcut of the window that had focus.
export function pasteKeys(appId) {
    return isTerminal(appId)
        ? ["-M", "ctrl", "-M", "shift", "v", "-m", "shift", "-m", "ctrl"]
        : ["-M", "ctrl", "v", "-m", "ctrl"];
}

// Where an image entry's decoded bytes are cached. cliphist never reuses an
// id, not even after a wipe, so the id alone names the file.
export function thumbPath(dir, entry) {
    return dir + "/" + entry.id + "." + (entry.format || "bin");
}
