// Snippet logic for shell.qml: reading the template files, the placeholder
// language, filling a template in, and ranking snippets for the search.
//
// Plain ECMAScript, no QML: the overlay imports it and tests/snip.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread, no regex lookbehind or named groups.
//
// A snippet is a *.md or *.txt file under ~/.local/share/snippets; folders
// group them. An optional front matter comes first:
//
//     ---
//     name: Ask for PR review        shown in the list (default: file name)
//     keyword: prr                   typed to find it first (default: file name)
//     tags: [github, review]
//     apps: [Slack]                  ranked first when that app has focus,
//                                    matched against niri's app_id
//     each: line                     render once per selected line
//     action: paste                  paste (default), copy, or open (xdg-open)
//     paste: type                    type it with wtype instead of Ctrl+V
//     sensitive: true                masked in the overlay, values not kept
//     delimiters: "<% %>"            for bodies that use {{ }} themselves
//     locale: fr                     day and month names (en or fr)
//     ---
//
// The rest is the template, minus the newline editors put at the end. In it:
//
//     {{name}}                       asked in the form; a name used twice is
//                                    one field
//     {{name default="x"}}           pre-filled
//     {{name options="a, b, c"}}     one of these, picked with ← →
//     {{name multiline}}             a multi-line field
//     {{name from=selection}}        pre-filled from the selected text
//     {{name from=clipboard}}        … or from the clipboard
//     {{name … match="[A-Z]+-\d+"}}  only what the regex matches (group 1 if
//                                    it has one)
//     {{selection}} {{clipboard}}    the text itself
//     {{app}} {{title}}              the focused window's app_id and title
//     {{date}} {{time}} {{datetime}} {{day}}
//                                    format="yyyy-MM-dd HH:mm EEEE MMMM"
//                                    offset="+3d -2h" (m h d w M y)
//                                    locale="fr"
//     {{uuid}}                       a random UUID
//     {{cursor}}                     where the caret ends up after a paste
//     {{snippet name="sig"}}         another snippet, by keyword or name
//     {{… | upper | trim}}           modifiers, applied left to right:
//                                    upper lower trim capitalize title snake
//                                    kebab camel pascal slug url json shell
//                                    firstline oneline
//     \{{                            a literal {{
//
// A placeholder stays on one line; anything between the delimiters that does
// not read as one is left as text.

// How long a selection counts as just made, and so fills fields on its own.
export const FRESH_MS = 30 * 1000;

// Bytes of the selection and of the clipboard the probe reads.
export const SELECTION_LIMIT = 64 * 1024;

// What actions.sh prints between the parts of its output.
export const SEPARATOR = "\u001e";

const BUILTINS = ["selection", "clipboard", "app", "title", "date", "time", "datetime", "day", "uuid", "cursor", "snippet"];
const DATE_BUILTINS = ["date", "time", "datetime", "day"];
const FRONT_KEYS = ["name", "keyword", "tags", "apps", "each", "action", "paste", "sensitive", "delimiters", "locale"];
const ATTRIBUTES = ["default", "options", "multiline", "from", "match", "format", "offset", "locale", "name"];
const IDENTIFIER = /^[A-Za-z_][\w-]*$/;

export const DATE_FORMATS = {
    date: "yyyy-MM-dd",
    time: "HH:mm",
    datetime: "yyyy-MM-dd HH:mm",
    day: "EEEE",
};

const NAMES = {
    en: {
        days: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
        months: ["January", "February", "March", "April", "May", "June", "July", "August", "September",
            "October", "November", "December"],
    },
    fr: {
        days: ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"],
        months: ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
            "octobre", "novembre", "décembre"],
    },
};

// --- reading files ------------------------------------------------------------

// `actions.sh list` → each file as SEPARATOR, its path under the snippets
// folder, a newline, then its contents.
export function parseListing(output) {
    const snippets = [];
    const records = String(output || "").split(SEPARATOR);
    for (let i = 1; i < records.length; i++) {
        const newline = records[i].indexOf("\n");
        const path = newline === -1 ? records[i] : records[i].slice(0, newline);
        if (path === "")
            continue;
        snippets.push(parseSnippet(path, newline === -1 ? "" : records[i].slice(newline + 1)));
    }
    return linkSnippets(snippets);
}

function unquote(value) {
    const v = String(value).trim();
    if (v.length >= 2 && (v[0] === '"' || v[0] === "'") && v[v.length - 1] === v[0])
        return v.slice(1, -1);
    return v;
}

// "a, b" or "[a, b]" → ["a", "b"].
function parseList(value) {
    let inner = String(value).trim();
    if (inner.startsWith("[") && inner.endsWith("]"))
        inner = inner.slice(1, -1);
    return inner.split(",").map(unquote).filter(item => item !== "");
}

// A trailing `# comment` goes, unless the value is quoted.
function stripComment(value) {
    const v = value.trim();
    if (v[0] === '"' || v[0] === "'") {
        const end = v.indexOf(v[0], 1);
        return end === -1 ? v : v.slice(0, end + 1);
    }
    return v.replace(/\s+#.*$/, "");
}

export function splitFrontMatter(text) {
    const source = String(text || "").replace(/\r\n/g, "\n");
    if (!source.startsWith("---\n"))
        return { header: null, body: source };
    const close = /\n---[ \t]*(\n|$)/g;
    close.lastIndex = 3;
    const end = close.exec(source);
    if (!end)
        return { header: null, body: source };
    return { header: source.slice(4, end.index), body: source.slice(end.index + end[0].length) };
}

function parseHeader(header, problems) {
    const fields = {};
    for (const line of header.split("\n")) {
        const trimmed = line.trim();
        if (trimmed === "" || trimmed.startsWith("#"))
            continue;
        const pair = /^([A-Za-z][\w-]*)\s*:\s*(.*)$/.exec(trimmed);
        if (!pair) {
            problems.push(`front matter: cannot read "${trimmed}"`);
            continue;
        }
        const key = pair[1].toLowerCase();
        if (FRONT_KEYS.indexOf(key) === -1)
            problems.push(`front matter: unknown key "${pair[1]}"`);
        fields[key] = stripComment(pair[2]);
    }
    return fields;
}

function parseDelimiters(value, problems) {
    if (!value)
        return { open: "{{", close: "}}" };
    const parts = unquote(value).split(/\s+/);
    if (parts.length !== 2 || parts[0] === "" || parts[1] === "") {
        problems.push('delimiters: give two markers, as in "<% %>"');
        return { open: "{{", close: "}}" };
    }
    return { open: parts[0], close: parts[1] };
}

// One file → a snippet. `path` is relative to the snippets folder, and is
// what usage and remembered values are filed under.
export function parseSnippet(path, text) {
    const problems = [];
    const parts = splitFrontMatter(text);
    const head = parts.header === null ? {} : parseHeader(parts.header, problems);
    const stem = path.replace(/\.[^./]+$/, "");
    const slash = stem.lastIndexOf("/");
    const base = stem.slice(slash + 1);

    const each = unquote(head.each || "");
    if (each !== "" && each !== "line")
        problems.push(`each: only "line" is known, not "${each}"`);
    let action = unquote(head.action || "paste");
    if (["paste", "copy", "open"].indexOf(action) === -1) {
        problems.push(`action: paste, copy or open, not "${action}"`);
        action = "paste";
    }
    const paste = unquote(head.paste || "");
    if (paste !== "" && paste !== "type" && paste !== "clipboard")
        problems.push(`paste: type or clipboard, not "${paste}"`);
    const delimiters = parseDelimiters(head.delimiters, problems);
    const body = parts.body.replace(/\n$/, "");
    const template = parseTemplate(body, delimiters.open, delimiters.close);

    return {
        id: path,
        group: slash === -1 ? "" : stem.slice(0, slash),
        name: unquote(head.name || "") || base,
        keyword: unquote(head.keyword || "") || base,
        tags: head.tags ? parseList(head.tags) : [],
        apps: head.apps ? parseList(head.apps) : [],
        each: each === "line",
        action: action,
        typed: paste === "type",
        sensitive: unquote(head.sensitive || "") === "true",
        locale: unquote(head.locale || ""),
        delimiters: delimiters,
        source: String(text || "").replace(/\r\n/g, "\n").replace(/\n$/, ""),
        header: parts.header,
        body: body,
        parsed: template.tokens,
        tokens: template.tokens,
        problems: problems.concat(template.problems),
    };
}

// --- modifiers -------------------------------------------------------------------

function stripAccents(text) {
    return typeof text.normalize === "function" ? text.normalize("NFD").replace(/[\u0300-\u036f]/g, "") : text;
}

function words(text) {
    return String(text).replace(/([a-z0-9])([A-Z])/g, "$1 $2").split(/[^A-Za-z0-9\u00C0-\u024F]+/).filter(w => w !== "");
}

function capitalize(text) {
    return text.charAt(0).toUpperCase() + text.slice(1);
}

const MODIFIERS = {
    upper: s => s.toUpperCase(),
    lower: s => s.toLowerCase(),
    trim: s => s.trim(),
    capitalize: capitalize,
    title: s => s.toLowerCase().replace(/(^|[\s\-_/])(\S)/g, (m, before, c) => before + c.toUpperCase()),
    snake: s => words(s).map(w => w.toLowerCase()).join("_"),
    kebab: s => words(s).map(w => w.toLowerCase()).join("-"),
    camel: s => words(s).map((w, i) => i === 0 ? w.toLowerCase() : capitalize(w.toLowerCase())).join(""),
    pascal: s => words(s).map(w => capitalize(w.toLowerCase())).join(""),
    slug: s => words(stripAccents(s)).map(w => w.toLowerCase()).join("-"),
    url: s => encodeURIComponent(s),
    json: s => JSON.stringify(s),
    shell: s => "'" + s.replace(/'/g, "'\\''") + "'",
    firstline: s => s.split("\n")[0],
    oneline: s => s.replace(/\s+/g, " ").trim(),
};

export const MODIFIER_NAMES = Object.keys(MODIFIERS);

export function applyModifiers(value, mods) {
    let out = value;
    for (const mod of mods || []) {
        if (MODIFIERS[mod])
            out = MODIFIERS[mod](out);
    }
    return out;
}

// --- the template language ----------------------------------------------------------

// Where the placeholder starting at `from` closes, skipping quoted strings;
// -1 if it does not on this line.
function findClose(body, from, close) {
    let quoted = false;
    for (let i = from; i < body.length; i++) {
        const c = body[i];
        if (c === "\n")
            return -1;
        if (quoted) {
            if (c === "\\" && body[i + 1] === '"')
                i++;
            else if (c === '"')
                quoted = false;
            continue;
        }
        if (c === '"')
            quoted = true;
        else if (body.startsWith(close, i))
            return i;
    }
    return -1;
}

// Splits on `separator` outside double quotes.
function splitOutsideQuotes(text, separator) {
    const parts = [];
    let current = "";
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (quoted && c === "\\" && text[i + 1] === '"') {
            current += c + text[i + 1];
            i++;
            continue;
        }
        if (c === '"')
            quoted = !quoted;
        if (!quoted && separator.test(c)) {
            parts.push(current);
            current = "";
        } else {
            current += c;
        }
    }
    parts.push(current);
    return parts;
}

// Inside quotes only \" is an escape, so regexes keep their backslashes.
function attributeValue(raw) {
    if (raw.length >= 2 && raw[0] === '"' && raw[raw.length - 1] === '"')
        return raw.slice(1, -1).replace(/\\"/g, '"');
    return raw;
}

// What is between the delimiters → {name, attrs, mods}, or null if it is not
// a placeholder.
export function parsePlaceholder(inner) {
    const sections = splitOutsideQuotes(inner, /\|/);
    const words = splitOutsideQuotes(sections[0].trim(), /\s/).filter(w => w !== "");
    if (words.length === 0 || !IDENTIFIER.test(words[0]))
        return null;
    const placeholder = {
        type: "placeholder",
        name: words[0],
        attrs: {},
        mods: sections.slice(1).map(m => m.trim().toLowerCase()).filter(m => m !== ""),
    };
    for (const word of words.slice(1)) {
        const eq = word.indexOf("=");
        const key = (eq === -1 ? word : word.slice(0, eq)).toLowerCase();
        if (!IDENTIFIER.test(key))
            return null;
        placeholder.attrs[key] = eq === -1 ? true : attributeValue(word.slice(eq + 1));
    }
    return placeholder;
}

function checkPlaceholder(p, problems) {
    for (const key of Object.keys(p.attrs)) {
        if (ATTRIBUTES.indexOf(key) === -1)
            problems.push(`{{${p.name}}}: unknown attribute "${key}"`);
    }
    for (const mod of p.mods) {
        if (!MODIFIERS[mod])
            problems.push(`{{${p.name}}}: unknown modifier "${mod}"`);
    }
    if (p.attrs.from !== undefined && p.attrs.from !== "selection" && p.attrs.from !== "clipboard")
        problems.push(`{{${p.name}}}: from=selection or from=clipboard, not "${p.attrs.from}"`);
    if (typeof p.attrs.match === "string") {
        try {
            new RegExp(p.attrs.match);
        } catch (e) {
            problems.push(`{{${p.name}}}: match is not a valid regex`);
        }
    }
    if (typeof p.attrs.offset === "string" && !/^\s*([+-]\d+\s*[mhdwMy]\s*)+$/.test(p.attrs.offset))
        problems.push(`{{${p.name}}}: offset reads like "+3d -2h"`);
    if (p.name === "snippet" && typeof p.attrs.name !== "string")
        problems.push('{{snippet}} needs name="…"');
    // `{{app default="bolt"}}` would quietly paste the focused app's id.
    if (isBuiltin(p.name) && ["default", "options", "multiline", "from", "match"].some(a => p.attrs[a] !== undefined))
        problems.push(`{{${p.name}}} is built in, not a field: give the field another name`);
}

// The body → a list of {type: "text", text} and placeholders.
export function parseTemplate(body, open, close) {
    open = open || "{{";
    close = close || "}}";
    const tokens = [];
    const problems = [];
    let text = "";
    let at = 0;
    while (at < body.length) {
        const start = body.indexOf(open, at);
        if (start === -1) {
            text += body.slice(at);
            break;
        }
        if (start > 0 && body[start - 1] === "\\") {
            text += body.slice(at, start - 1) + open;
            at = start + open.length;
            continue;
        }
        text += body.slice(at, start);
        const end = findClose(body, start + open.length, close);
        const placeholder = end === -1 ? null : parsePlaceholder(body.slice(start + open.length, end));
        if (!placeholder) {
            text += open;
            at = start + open.length;
            continue;
        }
        if (text !== "")
            tokens.push({ type: "text", text: text });
        text = "";
        placeholder.raw = body.slice(start, end + close.length);
        checkPlaceholder(placeholder, problems);
        tokens.push(placeholder);
        at = end + close.length;
    }
    if (text !== "")
        tokens.push({ type: "text", text: text });
    return { tokens: tokens, problems: problems };
}

export function findSnippet(snippets, name) {
    const wanted = String(name || "").trim().toLowerCase();
    if (wanted === "")
        return null;
    return snippets.find(s => s.keyword.toLowerCase() === wanted)
        || snippets.find(s => s.id.toLowerCase() === wanted || s.id.replace(/\.[^./]+$/, "").toLowerCase() === wanted)
        || snippets.find(s => s.name.toLowerCase() === wanted)
        || null;
}

// Puts each `{{snippet name="…"}}` in place, one level deep: the included
// snippet's own includes are dropped.
export function linkSnippets(snippets) {
    for (const snippet of snippets) {
        const tokens = [];
        for (const token of snippet.parsed) {
            if (token.type !== "placeholder" || token.name !== "snippet") {
                tokens.push(token);
                continue;
            }
            const target = findSnippet(snippets, token.attrs.name);
            if (!target || target === snippet) {
                snippet.problems.push(`{{snippet name="${token.attrs.name}"}}: no such snippet`);
                continue;
            }
            for (const inner of target.parsed) {
                if (inner.type !== "placeholder" || inner.name !== "snippet")
                    tokens.push(inner);
            }
        }
        snippet.tokens = tokens;
    }
    return snippets;
}

function isBuiltin(name) {
    return BUILTINS.indexOf(name) !== -1;
}

function usesBuiltin(tokens, name) {
    return tokens.some(t => t.type === "placeholder" && t.name === name);
}

// The values a template asks for, in the order they first appear. Attributes
// given on any use of a name count.
export function variables(tokens) {
    const order = [];
    const byName = {};
    for (const token of tokens) {
        if (token.type !== "placeholder" || isBuiltin(token.name))
            continue;
        let v = byName[token.name];
        if (!v) {
            v = { name: token.name, default: "", options: [], multiline: false, from: "", match: "" };
            byName[token.name] = v;
            order.push(v);
        }
        const a = token.attrs;
        if (v.default === "" && typeof a.default === "string")
            v.default = a.default;
        if (v.options.length === 0 && typeof a.options === "string")
            v.options = parseList(a.options);
        if (a.multiline)
            v.multiline = true;
        if (v.from === "" && (a.from === "selection" || a.from === "clipboard"))
            v.from = a.from;
        if (v.match === "" && typeof a.match === "string")
            v.match = a.match;
    }
    return order;
}

// --- filling a template in --------------------------------------------------

// The text `match` picks out of `text`: group 1 if the regex has one, else the
// whole match. Null if there is no text or no match.
export function extract(text, match) {
    const value = String(text || "");
    if (value === "")
        return null;
    if (!match)
        return value.replace(/\n+$/, "");
    let re;
    try {
        re = new RegExp(match);
    } catch (e) {
        return null;
    }
    const found = re.exec(value);
    if (!found)
        return null;
    return found[1] !== undefined ? found[1] : found[0];
}

export function isFresh(changedAt, now) {
    return changedAt > 0 && now - changedAt <= FRESH_MS;
}

// What a template is filled in from: what the probe read when the overlay was
// summoned. `uuids` grows as templates ask for them, so a preview and the
// paste after it agree.
export function makeContext(probe, changedAt, now) {
    const p = probe || {};
    return {
        selection: p.selection || "",
        clipboard: p.clipboard || "",
        app: p.appId || "",
        title: p.title || "",
        changedAt: changedAt || 0,
        fresh: !!p.selection && isFresh(changedAt || 0, now),
        now: now,
        uuids: [],
    };
}

// The same context, with an old selection trusted anyway.
export function trustSelection(ctx) {
    return Object.assign({}, ctx, { fresh: ctx.selection !== "" });
}

// The form for `snippet`: its fields with their starting values, and those
// values by name. A value comes from the selection (when fresh) or the
// clipboard for `from=`, else from the last use, else the default; a choice
// falls back to its first option. In `each: line` snippets, `from=selection`
// fields are filled per line, so they are not asked. `{{selection}}` itself
// is asked when the selection is old, so an old selection is never pasted
// unseen.
export function prepare(snippet, ctx, remembered) {
    const fields = [];
    const values = {};
    const sources = {};
    const last = remembered || {};
    const add = (field, value, source) => {
        field.value = value;
        field.source = source;
        field.multiline = field.multiline || value.indexOf("\n") !== -1;
        fields.push(field);
        values[field.name] = value;
        sources[field.name] = source;
    };

    if (!snippet.each && !ctx.fresh && usesBuiltin(snippet.tokens, "selection"))
        add({ name: "selection", options: [], multiline: false, from: "selection", match: "" }, "", "");

    for (const v of variables(snippet.tokens)) {
        if (snippet.each && v.from === "selection")
            continue;
        const field = { name: v.name, options: v.options, multiline: v.multiline, from: v.from, match: v.match };
        if (v.options.length > 0) {
            const pick = [last[v.name], v.default].find(x => typeof x === "string" && v.options.indexOf(x) !== -1);
            add(field, pick !== undefined ? pick : v.options[0],
                pick === undefined ? "choice" : (pick === last[v.name] ? "last used" : "default"));
            continue;
        }
        let value = null;
        let source = "";
        if (v.from === "selection" && ctx.fresh) {
            value = extract(ctx.selection, v.match);
            source = "selection";
        } else if (v.from === "clipboard") {
            value = extract(ctx.clipboard, v.match);
            source = "clipboard";
        }
        if (value === null && v.from === "" && typeof last[v.name] === "string" && last[v.name] !== "") {
            value = last[v.name];
            source = "last used";
        }
        if (value === null && v.default !== "") {
            value = v.default;
            source = "default";
        }
        add(field, value === null ? "" : value, value === null ? "" : source);
    }
    return { fields: fields, values: values, sources: sources };
}

// The selected lines an `each: line` snippet goes over: one empty round when
// there is no fresh selection.
export function eachLines(ctx) {
    if (!ctx.fresh)
        return [""];
    const lines = String(ctx.selection).split("\n").map(l => l.replace(/\r$/, "")).filter(l => l.trim() !== "");
    return lines.length > 0 ? lines : [""];
}

// The filled-in template as segments: {kind: "text", text}, {kind: "value",
// text, source}, {kind: "empty", name} for a field still empty, and
// {kind: "cursor"}.
export function renderSegments(snippet, values, sources, ctx) {
    const segments = [];
    const counter = { uuid: 0, cursor: false };
    if (snippet.each) {
        const lines = eachLines(ctx);
        for (let i = 0; i < lines.length; i++) {
            if (i > 0)
                segments.push({ kind: "text", text: "\n" });
            const lineCtx = Object.assign({}, ctx, { selection: lines[i], fresh: lines[i] !== "" });
            renderInto(segments, snippet, values, sources, lineCtx, counter, true);
        }
    } else {
        renderInto(segments, snippet, values, sources, ctx, counter, false);
    }
    return segments;
}

function uuidAt(ctx, index) {
    while (ctx.uuids.length <= index)
        ctx.uuids.push(uuid());
    return ctx.uuids[index];
}

function builtinValue(p, snippet, values, ctx, counter) {
    switch (p.name) {
    case "selection":
        return values.selection !== undefined ? values.selection : (ctx.fresh ? ctx.selection : "");
    case "clipboard":
        return ctx.clipboard;
    case "app":
        return ctx.app;
    case "title":
        return ctx.title;
    case "uuid":
        return uuidAt(ctx, counter.uuid++);
    default:
        if (DATE_BUILTINS.indexOf(p.name) !== -1) {
            const when = typeof p.attrs.offset === "string" ? shiftDate(ctx.now, p.attrs.offset) : ctx.now;
            const format = typeof p.attrs.format === "string" ? p.attrs.format : DATE_FORMATS[p.name];
            return formatDate(when, format, typeof p.attrs.locale === "string" ? p.attrs.locale : snippet.locale);
        }
        return "";
    }
}

function renderInto(segments, snippet, values, sources, ctx, counter, perLine) {
    for (const token of snippet.tokens) {
        if (token.type === "text") {
            segments.push({ kind: "text", text: token.text });
            continue;
        }
        if (token.name === "cursor") {
            if (!perLine && !counter.cursor) {
                counter.cursor = true;
                segments.push({ kind: "cursor" });
            }
            continue;
        }
        let value;
        let source;
        let asked = false;
        if (isBuiltin(token.name)) {
            value = builtinValue(token, snippet, values, ctx, counter);
            source = token.name === "selection" || token.name === "clipboard" ? token.name : "builtin";
            asked = token.name === "selection" && values.selection !== undefined;
        } else if (perLine && token.attrs.from === "selection") {
            const found = extract(ctx.selection, typeof token.attrs.match === "string" ? token.attrs.match : "");
            value = found === null ? "" : found;
            source = "selection";
            asked = true;
        } else {
            value = values[token.name] !== undefined ? String(values[token.name]) : "";
            source = sources[token.name] || "";
            asked = true;
        }
        value = applyModifiers(String(value), token.mods);
        if (value !== "")
            segments.push({ kind: "value", text: value, source: source });
        else if (asked)
            segments.push({ kind: "empty", name: token.name });
    }
}

// Segments → the text to paste, and where in it the caret goes (-1: nowhere).
export function plainText(segments) {
    let text = "";
    let cursor = -1;
    for (const s of segments) {
        if (s.kind === "cursor")
            cursor = text.length;
        else if (s.kind !== "empty")
            text += s.text;
    }
    return { text: text, cursor: cursor };
}

// --- dates and UUIDs ---------------------------------------------------------------

function addMonths(date, months) {
    const day = date.getDate();
    date.setDate(1);
    date.setMonth(date.getMonth() + months);
    const last = new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate();
    date.setDate(Math.min(day, last));
}

// `ms` moved by an offset such as "+3d -2h": m minutes, h hours, d days,
// w weeks, M months, y years. A month later than 31 January is the end of
// February.
export function shiftDate(ms, offset) {
    const date = new Date(ms);
    const step = /([+-])(\d+)\s*([mhdwMy])/g;
    let part;
    while ((part = step.exec(String(offset))) !== null) {
        const n = (part[1] === "-" ? -1 : 1) * Number(part[2]);
        switch (part[3]) {
        case "m":
            date.setMinutes(date.getMinutes() + n);
            break;
        case "h":
            date.setHours(date.getHours() + n);
            break;
        case "d":
            date.setDate(date.getDate() + n);
            break;
        case "w":
            date.setDate(date.getDate() + 7 * n);
            break;
        case "M":
            addMonths(date, n);
            break;
        case "y":
            addMonths(date, 12 * n);
            break;
        }
    }
    return date.getTime();
}

function pad(n, width) {
    return String(n).padStart(width, "0");
}

// Unicode date patterns, as Raycast's: yyyy yy MMMM MMM MM M dd d EEEE EEE
// HH H hh h mm m ss s a, and 'quoted' text.
export function formatDate(ms, format, locale) {
    const date = new Date(ms);
    const names = NAMES[String(locale || "en").slice(0, 2).toLowerCase()] || NAMES.en;
    const hours = date.getHours();
    return String(format).replace(/'([^']*)'|yyyy|yy|MMMM|MMM|MM|M|dd|d|EEEE|EEE|HH|H|hh|h|mm|m|ss|s|a/g, (token, quoted) => {
        if (quoted !== undefined)
            return quoted === "" ? "'" : quoted;
        switch (token) {
        case "yyyy": return String(date.getFullYear());
        case "yy": return pad(date.getFullYear() % 100, 2);
        case "MMMM": return names.months[date.getMonth()];
        case "MMM": return names.months[date.getMonth()].slice(0, 3);
        case "MM": return pad(date.getMonth() + 1, 2);
        case "M": return String(date.getMonth() + 1);
        case "dd": return pad(date.getDate(), 2);
        case "d": return String(date.getDate());
        case "EEEE": return names.days[date.getDay()];
        case "EEE": return names.days[date.getDay()].slice(0, 3);
        case "HH": return pad(hours, 2);
        case "H": return String(hours);
        case "hh": return pad((hours + 11) % 12 + 1, 2);
        case "h": return String((hours + 11) % 12 + 1);
        case "mm": return pad(date.getMinutes(), 2);
        case "m": return String(date.getMinutes());
        case "ss": return pad(date.getSeconds(), 2);
        case "s": return String(date.getSeconds());
        default: return hours < 12 ? "AM" : "PM";
        }
    });
}

// A version 4 UUID. Math.random is enough: these name things, they guard
// nothing.
export function uuid(random) {
    const next = random || Math.random;
    const hex = [];
    for (let i = 0; i < 32; i++)
        hex.push(Math.floor(next() * 16).toString(16));
    hex[12] = "4";
    hex[16] = (8 + Math.floor(next() * 4)).toString(16);
    const s = hex.join("");
    return [s.slice(0, 8), s.slice(8, 12), s.slice(12, 16), s.slice(16, 20), s.slice(20)].join("-");
}

// --- the search -------------------------------------------------------------------

export function queryTerms(query) {
    const trimmed = String(query || "").trim().toLowerCase();
    return trimmed === "" ? [] : trimmed.split(/\s+/);
}

// How tightly `term` sits in `text` as a subsequence starting a word, in its
// shortest stretch: 0 if it does not, or only spread over more than a few
// words.
function subsequence(text, term) {
    const longest = Math.max(8, 4 * term.length);
    let best = -1;
    for (let start = text.indexOf(term[0]); start !== -1; start = text.indexOf(term[0], start + 1)) {
        if (start > 0 && !/[\s\-_/.]/.test(text[start - 1]))
            continue;
        let at = start;
        for (let i = 1; i < term.length && at !== -1; i++)
            at = text.indexOf(term[i], at + 1);
        if (at === -1)
            break;
        const span = at - start + 1;
        if (span <= longest && (best === -1 || span < best))
            best = span;
    }
    return best === -1 ? 0 : Math.max(20, 100 - 5 * (best - term.length));
}

function termScore(snippet, term) {
    const keyword = snippet.keyword.toLowerCase();
    if (keyword === term)
        return 1000;
    if (keyword.startsWith(term))
        return 600;
    const parts = [keyword, snippet.name.toLowerCase(), snippet.group.toLowerCase()]
        .concat(snippet.tags.map(t => t.toLowerCase()));
    const meta = parts.join(" ");
    if (meta.split(/[\s\-_/]+/).some(word => word.startsWith(term)))
        return 300;
    if (meta.indexOf(term) !== -1)
        return 200;
    // Each part on its own, so letters are not picked across a name and a tag.
    const loose = Math.max.apply(null, parts.map(part => subsequence(part, term)));
    if (loose > 0)
        return loose;
    return snippet.body.toLowerCase().indexOf(term) !== -1 ? 40 : 0;
}

export function forApp(snippet, appId) {
    const app = String(appId || "").toLowerCase();
    return app !== "" && snippet.apps.some(a => a !== "" && app.indexOf(a.toLowerCase()) !== -1);
}

// Up to 80 for a snippet used often and lately.
export function frecency(use, now) {
    if (!use || !use.count)
        return 0;
    const days = (now - (use.last || 0)) / 86400000;
    const recency = days < 1 ? 1 : days < 7 ? 0.7 : days < 30 ? 0.4 : 0.2;
    return Math.round(Math.min(80, 20 * Math.log2(1 + use.count)) * recency);
}

// The snippets matching every word of the query, best first: how well the
// words match, then whether the snippet is for the focused app, then how much
// it is used.
export function rank(snippets, query, appId, usage, now) {
    const terms = queryTerms(query);
    const scored = [];
    for (const snippet of snippets) {
        let score = 0;
        let matches = true;
        for (const term of terms) {
            const s = termScore(snippet, term);
            if (s === 0) {
                matches = false;
                break;
            }
            score += s;
        }
        if (!matches)
            continue;
        if (forApp(snippet, appId))
            score += 150;
        score += frecency(usage ? usage[snippet.id] : null, now);
        scored.push({ snippet: snippet, score: score });
    }
    scored.sort((a, b) => b.score - a.score || a.snippet.name.localeCompare(b.snippet.name));
    return scored.map(s => s.snippet);
}

// --- what the overlay shows ---------------------------------------------------------

export function escapeHtml(text) {
    return String(text)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

// Plain text as Qt StyledText, spaces and line breaks kept.
export function styledText(text) {
    return escapeHtml(text)
        .replace(/\t/g, "    ")
        .replace(/ {2,}/g, run => "&nbsp;".repeat(run.length))
        .replace(/(^|\n) /g, "$1&nbsp;")
        .replace(/\n/g, "<br>");
}

function font(color, html) {
    return '<font color="' + color + '">' + html + "</font>";
}

// Rendered segments as StyledText: values from the selection or clipboard in
// `good`, other values in `accent`, fields still empty as ‹name› in `dim`.
export function styledSegments(segments, colors) {
    let html = "";
    for (const s of segments) {
        if (s.kind === "text")
            html += styledText(s.text);
        else if (s.kind === "value")
            html += font(s.source === "selection" || s.source === "clipboard" ? colors.good : colors.accent, styledText(s.text));
        else if (s.kind === "empty")
            html += font(colors.dim, "‹" + escapeHtml(s.name) + "›");
        else
            html += font(colors.accent, "<b>▏</b>");
    }
    return html;
}

// The file as StyledText: front matter in `dim`, placeholders in `accent`.
export function styledSource(snippet, colors) {
    let html = "";
    if (snippet.header !== null)
        html += font(colors.dim, styledText("---\n" + snippet.header + "\n---")) + "<br>";
    for (const token of snippet.parsed)
        html += token.type === "text" ? styledText(token.text) : font(colors.accent, styledText(token.raw));
    return html;
}

// `text` as StyledText with the query's words picked out in `color`.
export function highlight(text, query, color) {
    const lower = String(text).toLowerCase();
    const marked = [];
    for (const term of queryTerms(query)) {
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
        html += font(color, "<b>" + escapeHtml(text.slice(range[0], range[1])) + "</b>");
        from = range[1];
    }
    return html + escapeHtml(text.slice(from));
}

export function ago(ms) {
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60)
        return s + "s";
    if (s < 3600)
        return Math.round(s / 60) + "m";
    if (s < 86400)
        return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
}

// The chip at the top right about the selection, or "" when there is none.
export function selectionLabel(ctx) {
    if (ctx.selection === "")
        return "";
    const lines = ctx.selection.replace(/\n+$/, "").split("\n").length;
    const size = lines > 1 ? lines + " lines" : Array.from(ctx.selection).length + " chars";
    const age = ctx.changedAt > 0 ? ago(ctx.now - ctx.changedAt) + " ago" : "older";
    return "selection · " + age + " · " + size;
}

// The line under a snippet's name in the preview.
export function describe(snippet, use, now) {
    const parts = [snippet.id];
    if (snippet.tags.length > 0)
        parts.push(snippet.tags.map(t => "#" + t).join(" "));
    if (use && use.count)
        parts.push("used " + use.count + "× · last " + ago(now - use.last) + " ago");
    if (snippet.apps.length > 0)
        parts.push("apps: " + snippet.apps.join(", "));
    if (snippet.each)
        parts.push("each line");
    if (snippet.action === "open")
        parts.push("opens with xdg-open");
    else if (snippet.action === "copy")
        parts.push("copies");
    if (snippet.typed)
        parts.push("typed");
    if (snippet.sensitive)
        parts.push("sensitive");
    return parts.join(" · ");
}

// What Enter does with this snippet, for the footer.
export function actionLabel(snippet) {
    if (!snippet)
        return "use";
    if (snippet.action === "open")
        return "open";
    if (snippet.action === "copy")
        return "copy";
    return snippet.typed ? "type" : "paste";
}

// --- where it goes ------------------------------------------------------------------

// `actions.sh probe` → where to open, the window a paste goes back to, the
// selection and the clipboard.
export function parseProbe(output) {
    const parts = String(output || "").split(SEPARATOR + "\n");
    const found = { output: "", appId: "", title: "", selection: parts[2] || "", clipboard: parts[3] || "" };
    for (const part of [parts[0] || "", parts[1] || ""]) {
        for (const line of part.split("\n")) {
            let value;
            try {
                value = JSON.parse(line);
            } catch (e) {
                continue;
            }
            if (!value || typeof value !== "object")
                continue;
            if (value.app_id !== undefined) {
                found.appId = String(value.app_id || "");
                found.title = String(value.title || "");
            } else if (typeof value.name === "string" && value.logical !== undefined) {
                found.output = value.name;
            }
        }
    }
    return found;
}

// Terminals take Ctrl+Shift+V; a plain Ctrl+V there is a control character.
// As in clipboard/clip.mjs.
const TERMINAL_WORDS = ["ghostty", "kitty", "alacritty", "foot", "footclient", "konsole", "console",
    "ptyxis", "tilix", "terminator", "rio", "warp", "kgx", "blackbox"];

export function isTerminal(appId) {
    const parts = String(appId || "").toLowerCase().split(/[.\-_]/);
    return parts.some(part => TERMINAL_WORDS.indexOf(part) !== -1 || part.indexOf("term") !== -1);
}

// How many times to press Left after the paste for the caret to land on
// {{cursor}}. None in a terminal when that would cross a line: a shell's line
// editor does not go back up.
export function cursorLefts(text, cursor, terminal) {
    if (cursor < 0)
        return 0;
    const tail = text.slice(cursor);
    if (terminal && tail.indexOf("\n") !== -1)
        return 0;
    return Array.from(tail).length;
}

// --- what is kept between uses ------------------------------------------------

export function recordUse(usage, id, now) {
    const next = Object.assign({}, usage || {});
    const before = next[id] || { count: 0, last: 0 };
    next[id] = { count: (before.count || 0) + 1, last: now };
    return next;
}

// The values typed into the form, by snippet, for next time. The selection
// and clipboard ones are not kept: they are read again each time.
export function rememberValues(kept, id, fields, values) {
    const next = Object.assign({}, kept || {});
    const mine = {};
    for (const field of fields) {
        if (field.name !== "selection" && field.from === "" && typeof values[field.name] === "string")
            mine[field.name] = values[field.name];
    }
    if (Object.keys(mine).length > 0)
        next[id] = mine;
    return next;
}

// What is kept about the snippet at `from`, filed under `to` instead.
export function renameEntry(kept, from, to) {
    const next = Object.assign({}, kept || {});
    if (next[from] !== undefined && from !== to) {
        next[to] = next[from];
        delete next[from];
    }
    return next;
}

// --- a new snippet ------------------------------------------------------------------
// The overlay's "new snippet" form: its suggestions, the fields it spots in
// the selection, and the file it writes.

export function slugOf(text) {
    return MODIFIERS.slug(String(text || ""));
}

// The keyword a new snippet starts with: its name's first four words.
export function keywordFor(name) {
    return words(stripAccents(String(name || ""))).slice(0, 4).map(w => w.toLowerCase()).join("-");
}

// The selection a new snippet starts from, blank lines around it aside.
export function trimSelection(text) {
    return String(text || "").replace(/^(\s*\n)+/, "").replace(/\s+$/, "");
}

// "com.mitchellh.ghostty" → "ghostty": enough for `apps:`, which matches part
// of the app_id.
export function appLabel(appId) {
    const parts = String(appId || "").split(".");
    return parts[parts.length - 1];
}

function uniqueSorted(items) {
    const seen = {};
    const out = [];
    for (const item of items) {
        if (item !== "" && !seen[item.toLowerCase()]) {
            seen[item.toLowerCase()] = true;
            out.push(item);
        }
    }
    return out.sort((a, b) => a.localeCompare(b));
}

export function knownFolders(snippets) {
    return uniqueSorted(snippets.map(s => s.group));
}

export function knownTags(snippets) {
    return uniqueSorted([].concat.apply([], snippets.map(s => s.tags)));
}

export function knownApps(snippets, appId) {
    return uniqueSorted([].concat.apply([appLabel(appId)], snippets.map(s => s.apps)));
}

// What is left to type of the first option `text` starts, shown greyed after
// the caret and taken with →. With `list`, `text` is a comma list and only its
// last item is completed, with an option it does not hold yet.
export function complete(text, options, list) {
    const value = String(text || "");
    const items = list ? value.split(",").map(t => t.trim()) : [value];
    const head = items[items.length - 1];
    if (head === "")
        return "";
    const held = items.slice(0, -1).map(t => t.toLowerCase());
    const found = options.find(o => o.length > head.length && o.toLowerCase().startsWith(head.toLowerCase())
        && held.indexOf(o.toLowerCase()) === -1);
    return found ? found.slice(head.length) : "";
}

// A folder under the snippets folder, without leading, trailing or doubled
// slashes, nor ways out of it.
export function cleanFolder(folder) {
    return String(folder || "").split("/").map(s => s.trim()).filter(s => s !== "" && s !== "." && s !== "..").join("/");
}

// Why `keyword` cannot be used for a new snippet, or "".
export function keywordProblem(keyword, snippets) {
    const wanted = slugOf(keyword);
    if (wanted === "")
        return "a keyword is needed";
    const taken = snippets.find(s => s.keyword.toLowerCase() === wanted);
    return taken ? `taken by "${taken.name}" (${taken.id})` : "";
}

export function listItems(text) {
    return String(text || "").split(",").map(t => t.trim()).filter(t => t !== "");
}

// The kinds of value the form offers to turn into fields, in the order they
// are looked for: an earlier kind keeps the text a later one would also
// match. Their regexes have no group but the one to extract, if any.
const SPOTTERS = [
    { kind: "url", re: /https?:\/\/[^\s<>"'`)\]]+/g, name: "url", attrs: 'from=clipboard match="https?://\\S+"' },
    { kind: "email", re: /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, name: "email", attrs: 'from=selection match="[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+"' },
    { kind: "uuid", re: /\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b/g, name: "id",
        attrs: 'from=selection match="[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"' },
    { kind: "ticket", re: /\b[A-Z][A-Z0-9]+-\d+\b/g, name: "ticket", attrs: 'from=selection match="[A-Z][A-Z0-9]+-\\d+"' },
    { kind: "date", re: /\b\d{4}-\d{2}-\d{2}\b/g, name: "when", attrs: 'from=selection match="\\d{4}-\\d{2}-\\d{2}"' },
    { kind: "number", re: /#(\d+)\b/g, name: "number", attrs: 'from=selection match="#(\\d+)"' },
    { kind: "id", re: /\b\d{6,}\b/g, name: "id", attrs: 'from=selection match="\\d{6,}"' },
];

// The values in `text` that look like fields: links, emails, UUIDs, tickets
// (BOLT-412), dates, #numbers, long numbers. Each is {key, kind, text, name,
// attrs, ranges}: the same text found twice is one field, at both places. A
// date that is today becomes {{date}} rather than a field.
export function spotFields(text, now) {
    const source = String(text || "");
    const covered = [];
    const byKey = {};
    const spots = [];
    const used = {};
    const today = formatDate(now, "yyyy-MM-dd");
    const free = (start, end) => covered.every(r => end <= r[0] || start >= r[1]);
    for (const spotter of SPOTTERS) {
        spotter.re.lastIndex = 0;
        let found;
        while ((found = spotter.re.exec(source)) !== null) {
            const value = found[1] !== undefined ? found[1] : found[0];
            const start = found.index + found[0].indexOf(value);
            const end = start + value.length;
            if (!free(start, end))
                continue;
            covered.push([start, end]);
            const key = spotter.kind + ":" + value;
            let spot = byKey[key];
            if (!spot) {
                const builtin = spotter.kind === "date" && value === today;
                let name = builtin ? "date" : spotter.name;
                if (!builtin) {
                    used[spotter.name] = (used[spotter.name] || 0) + 1;
                    if (used[spotter.name] > 1)
                        name = spotter.name + used[spotter.name];
                }
                spot = { key: key, kind: builtin ? "today" : spotter.kind, text: value, name: name,
                    attrs: builtin ? "" : spotter.attrs, ranges: [] };
                byKey[key] = spot;
                spots.push(spot);
            }
            spot.ranges.push([start, end]);
        }
    }
    return spots;
}

// The name a spotted field goes by: as typed in the form when that is a valid
// field name, else as spotted. {{date}} for today stays {{date}}.
export function spotName(spot, state) {
    const typed = state && state[spot.key] ? String(state[spot.key].name || "") : "";
    if (spot.kind === "today" || typed === "" || !IDENTIFIER.test(typed) || isBuiltin(typed))
        return spot.name;
    return typed;
}

function spotOn(spot, state) {
    return !!(state && state[spot.key] && state[spot.key].on);
}

// `text` cut at the spotted values: {kind: "text", text} and {kind: "spot",
// text, spot, on, name}, for the form's preview.
export function spotSegments(text, spots, state) {
    const source = String(text || "");
    const marks = [];
    for (const spot of spots) {
        for (const range of spot.ranges)
            marks.push({ start: range[0], end: range[1], spot: spot });
    }
    marks.sort((a, b) => a.start - b.start);
    const segments = [];
    let at = 0;
    for (const mark of marks) {
        if (mark.start > at)
            segments.push({ kind: "text", text: source.slice(at, mark.start) });
        segments.push({ kind: "spot", text: source.slice(mark.start, mark.end), spot: mark.spot,
            on: spotOn(mark.spot, state), name: spotName(mark.spot, state) });
        at = mark.end;
    }
    if (at < source.length)
        segments.push({ kind: "text", text: source.slice(at) });
    return segments;
}

// spotSegments as StyledText: a field switched on as {{name}} in `accent`, one
// still off underlined.
export function styledSpots(segments, colors) {
    let html = "";
    for (const s of segments) {
        if (s.kind === "text")
            html += styledText(s.text);
        else if (s.on)
            html += font(colors.accent, styledText("{{" + s.name + "}}"));
        else
            html += "<u>" + styledText(s.text) + "</u>";
    }
    return html;
}

export function spotPlaceholder(spot, state) {
    const name = spotName(spot, state);
    return "{{" + name + (spot.attrs !== "" ? " " + spot.attrs : "") + "}}";
}

// The template body: the fields switched on as placeholders, and the rest as
// it was, a {{ in it escaped so it is not read as one.
export function applySpots(text, spots, state) {
    let body = "";
    for (const s of spotSegments(text, spots, state)) {
        if (s.kind === "spot" && s.on)
            body += spotPlaceholder(s.spot, state);
        else
            body += s.text.replace(/\{\{/g, "\\{{");
    }
    return body;
}

// The file for a new snippet: its front matter, then `body`.
export function newSnippetFile(fields, body) {
    // Quoted, so a # in it is not read as a comment.
    const lines = ["---", 'name: "' + String(fields.name || "").trim().replace(/"/g, "'") + '"', "keyword: " + slugOf(fields.keyword)];
    const tags = listItems(fields.tags);
    if (tags.length > 0)
        lines.push("tags: [" + tags.join(", ") + "]");
    const apps = listItems(fields.apps);
    if (apps.length > 0)
        lines.push("apps: [" + apps.join(", ") + "]");
    lines.push("---");
    return lines.join("\n") + "\n" + body + (body.endsWith("\n") ? "" : "\n");
}

// `actions.sh pair` → the file as it was before the editor opened, and as it
// is now: null if it is gone.
export function parseEditPair(output) {
    const text = String(output || "");
    const at = text.indexOf(SEPARATOR + "\n");
    if (at === -1)
        return { before: text, after: null };
    const rest = text.slice(at + 2);
    if (!rest.startsWith("present\n"))
        return { before: text.slice(0, at), after: null };
    return { before: text.slice(0, at), after: rest.slice("present\n".length) };
}

// The new name of a snippet whose editor has just closed, or "" to keep its
// name: a file named after its keyword follows it when it changes. A file
// named on purpose (pr-review.md, keyword prr) keeps its name.
export function afterEdit(path, before, after) {
    if (after === null)
        return "";
    const stem = path.slice(path.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "");
    const was = parseSnippet(path, before);
    const now = parseSnippet(path, after);
    if (was.keyword !== stem || now.keyword === was.keyword)
        return "";
    const next = MODIFIERS.slug(now.keyword);
    return next === stem ? "" : next;
}

// The name a saved draft is filed under: its keyword, made fit for a file
// name. A keyword left out defaults to the draft's own name.
export function draftStem(path, text, now) {
    return MODIFIERS.slug(parseSnippet(path, text).keyword) || "snippet-" + formatDate(now, "yyyyMMdd-HHmmss");
}
