// What the keyboard shortcuts panel shows (`qs -c chauvenity ipc call keys
// toggle`, Mod+Shift+/ in ~/.config/niri/config.kdl): niri's binds, read from
// its config files the way niri reads them, grouped and worded for reading.
//
// Plain ECMAScript, no QML: the bar imports it and tests/keys.test.mjs runs it
// under node. Keep to what Qt's JavaScript engine parses.

// --- KDL ----------------------------------------------------------------------
// Enough of KDL v1 for niri's config: nodes, string and bare values,
// properties, children, comments of every kind, raw strings. Type annotations
// are skipped. Throws an Error naming the line on input it cannot read.

const PUNCTUATION = "{};=";

function tokenize(text) {
    const tokens = [];
    let i = 0;
    let line = 1;
    const fail = message => { throw new Error(`line ${line}: ${message}`); };
    const push = (type, value) => tokens.push({ type, value, line });

    while (i < text.length) {
        const c = text[i];
        const next = text[i + 1];
        if (c === "\n") {
            push("newline");
            line++;
            i++;
        } else if (c === " " || c === "\t" || c === "\r" || c === "﻿") {
            i++;
        } else if (c === "/" && next === "/") {
            while (i < text.length && text[i] !== "\n")
                i++;
        } else if (c === "/" && next === "*") {
            let depth = 0;
            do {
                if (i >= text.length)
                    fail("unclosed /* comment");
                if (text[i] === "/" && text[i + 1] === "*") {
                    depth++;
                    i += 2;
                } else if (text[i] === "*" && text[i + 1] === "/") {
                    depth--;
                    i += 2;
                } else {
                    if (text[i] === "\n")
                        line++;
                    i++;
                }
            } while (depth > 0);
        } else if (c === "/" && next === "-") {
            push("slashdash");
            i += 2;
        } else if (c === "\\") {
            // A line continuation: the node goes on on the next line.
            i++;
            while (i < text.length && text[i] !== "\n")
                i++;
            i++;
            line++;
        } else if (c === "(") {
            // A type annotation, which niri does not use.
            while (i < text.length && text[i] !== ")")
                i++;
            i++;
        } else if (PUNCTUATION.includes(c)) {
            push(c);
            i++;
        } else if (c === '"') {
            i++;
            let value = "";
            for (;;) {
                if (i >= text.length)
                    fail("unclosed string");
                const s = text[i];
                if (s === '"')
                    break;
                if (s === "\n")
                    line++;
                if (s !== "\\") {
                    value += s;
                    i++;
                    continue;
                }
                const e = text[i + 1];
                const simple = { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", "\\": "\\", "/": "/", '"': '"' };
                if (e in simple) {
                    value += simple[e];
                    i += 2;
                } else if (e === "u" && text[i + 2] === "{") {
                    const end = text.indexOf("}", i);
                    value += String.fromCodePoint(parseInt(text.slice(i + 3, end), 16));
                    i = end + 1;
                } else {
                    fail(`unknown escape \\${e}`);
                }
            }
            i++;
            push("string", value);
        } else if ((c === "r" && (next === '"' || next === "#")) || (c === "#" && (next === '"' || next === "#"))) {
            // r"…", r#"…"# (KDL v1) or #"…"# (KDL v2).
            let j = c === "r" ? i + 1 : i;
            let hashes = 0;
            while (text[j] === "#") {
                hashes++;
                j++;
            }
            if (text[j] !== '"') {
                // Not a raw string after all, e.g. #null: a bare word.
                i = readWord(text, i, push);
                continue;
            }
            const close = '"' + "#".repeat(hashes);
            const end = text.indexOf(close, j + 1);
            if (end < 0)
                fail("unclosed raw string");
            const value = text.slice(j + 1, end);
            line += value.split("\n").length - 1;
            push("string", value);
            i = end + close.length;
        } else {
            i = readWord(text, i, push);
        }
    }
    push("eof");
    return tokens;
}

function readWord(text, start, push) {
    let i = start;
    while (i < text.length && !" \t\r\n\"\\(".includes(text[i]) && !PUNCTUATION.includes(text[i])
           && !(text[i] === "/" && (text[i + 1] === "/" || text[i + 1] === "*")))
        i++;
    push("word", text.slice(start, i));
    return i;
}

function bareValue(word) {
    const w = word.replace(/^#/, "");
    if (w === "null")
        return null;
    if (w === "true")
        return true;
    if (w === "false")
        return false;
    if (/^[+-]?\d+(\.\d+)?$/.test(w))
        return Number(w);
    return word;
}

// `[{ name, args, props, children }]`, the top-level nodes of `text`.
export function parseKdl(text) {
    const tokens = tokenize(text);
    let pos = 0;
    const peek = () => tokens[pos];
    const take = () => tokens[pos++];
    const fail = message => { throw new Error(`line ${peek().line}: ${message}`); };

    function value(token) {
        return token.type === "string" ? token.value : bareValue(token.value);
    }

    // One argument, property or children block; null at the node's end.
    function entry() {
        const t = peek();
        if (t.type === "{") {
            take();
            const children = nodes(true);
            return { children };
        }
        if (t.type !== "string" && t.type !== "word")
            return null;
        take();
        if (peek().type === "=") {
            take();
            const v = peek();
            if (v.type !== "string" && v.type !== "word")
                fail(`no value for property ${t.value}`);
            take();
            return { prop: t.value, value: value(v) };
        }
        return { arg: value(t) };
    }

    function node() {
        const name = take();
        const result = { name: name.value, args: [], props: {}, children: [] };
        for (;;) {
            const t = peek();
            if (t.type === "newline" || t.type === ";" || t.type === "}" || t.type === "eof")
                return result;
            const skip = t.type === "slashdash";
            if (skip)
                take();
            const e = entry();
            if (e === null)
                fail(`unexpected ${peek().type}`);
            if (skip)
                continue;
            if (e.children)
                result.children = e.children;
            else if (e.prop !== undefined)
                result.props[e.prop] = e.value;
            else
                result.args.push(e.arg);
        }
    }

    function nodes(inBlock) {
        const list = [];
        for (;;) {
            const t = peek();
            if (t.type === "newline" || t.type === ";") {
                take();
            } else if (t.type === "}") {
                if (!inBlock)
                    fail("unexpected }");
                take();
                return list;
            } else if (t.type === "eof") {
                if (inBlock)
                    fail("a { is never closed");
                return list;
            } else if (t.type === "slashdash") {
                take();
                while (peek().type === "newline")
                    take();
                node();
            } else if (t.type === "string" || t.type === "word") {
                list.push(node());
            } else {
                fail(`unexpected ${t.type}`);
            }
        }
    }

    return nodes(false);
}

// --- niri's config files ------------------------------------------------------

const TITLE = "hotkey-overlay-title";

function dirname(path) {
    const i = path.lastIndexOf("/");
    return i <= 0 ? "/" : path.slice(0, i);
}

// `..` and `.` folded away, as niri's include paths are compared by name.
function normalize(path) {
    const parts = [];
    for (const part of path.split("/")) {
        if (part === "" || part === ".")
            continue;
        if (part === "..")
            parts.pop();
        else
            parts.push(part);
    }
    return "/" + parts.join("/");
}

function includePath(target, from, home) {
    if (target.startsWith("~/"))
        return normalize(`${home}/${target.slice(2)}`);
    if (target.startsWith("/"))
        return normalize(target);
    return normalize(`${dirname(from)}/${target}`);
}

// Where niri looks for its config, first one that exists wins.
function candidates(env) {
    if (env.NIRI_CONFIG)
        return [env.NIRI_CONFIG];
    const xdg = env.XDG_CONFIG_HOME || `${env.HOME}/.config`;
    return [`${xdg}/niri/config.kdl`, "/etc/niri/config.kdl"];
}

// The binds niri ends up with, from `files` (path → text, or null for one
// that cannot be read). Asks for one file at a time: returns `{ need: path }`
// until it has every file it reads, then `{ root, files, binds, problems }`,
// `files` the paths it read in order and `binds`
// `[{ key, action, args, title, file }]`. `title` is the bind's
// hotkey-overlay-title: a string, null to hide it, or undefined.
//
// Includes are positional, as in niri: a bind overrides an earlier bind of
// the same key, wherever that came from, and takes its place in the order.
export function resolveBinds(files, env) {
    let root = null;
    const tried = candidates(env);
    for (const path of tried) {
        if (!(path in files))
            return { need: path };
        if (files[path] !== null) {
            root = path;
            break;
        }
    }
    if (root === null)
        return { root: null, files: [], binds: [], problems: [`no niri config: tried ${tried.join(", ")}`] };

    const binds = new Map();
    const problems = [];
    const read = [];
    let need = null;

    function visit(path, stack) {
        if (stack.includes(path)) {
            problems.push(`include cycle: ${[...stack, path].join(" → ")}`);
            return;
        }
        if (!(path in files)) {
            need = path;
            return;
        }
        if (files[path] === null) {
            problems.push(`cannot read ${path}`);
            return;
        }
        read.push(path);
        let nodes;
        try {
            nodes = parseKdl(files[path]);
        } catch (e) {
            problems.push(`${path}: ${e.message}`);
            return;
        }
        for (const node of nodes) {
            if (need !== null)
                return;
            if (node.name === "include" && typeof node.args[0] === "string") {
                visit(includePath(node.args[0], path, env.HOME), [...stack, path]);
            } else if (node.name === "binds") {
                for (const child of node.children) {
                    const action = child.children[0];
                    if (!action)
                        continue;
                    binds.set(bindId(child.name), {
                        key: child.name,
                        action: action.name,
                        args: action.args,
                        title: TITLE in child.props ? child.props[TITLE] : undefined,
                        file: path,
                    });
                }
            }
        }
    }

    visit(root, []);
    if (need !== null)
        return { need };
    return { root, files: read, binds: [...binds.values()], problems };
}

// --- keys -----------------------------------------------------------------------

// Modifier spelling → [label, rank in a chord].
const MODIFIERS = {
    mod: ["Super", 0],
    super: ["Super", 0],
    win: ["Super", 0],
    ctrl: ["Ctrl", 1],
    control: ["Ctrl", 1],
    alt: ["Alt", 2],
    iso_level3_shift: ["AltGr", 3],
    mod5: ["AltGr", 3],
    iso_level5_shift: ["Level5", 4],
    shift: ["Shift", 5],
};

const KEY_LABELS = {
    left: "←", right: "→", up: "↑", down: "↓",
    return: "Enter", kp_enter: "Enter", escape: "Esc", tab: "Tab", space: "Space",
    backspace: "⌫", delete: "Del", insert: "Ins", print: "PrtSc",
    page_up: "PgUp", prior: "PgUp", page_down: "PgDn", next: "PgDn", home: "Home", end: "End",
    slash: "/", backslash: "\\", minus: "-", equal: "=", plus: "+", comma: ",", period: ".",
    semicolon: ";", apostrophe: "'", grave: "`", bracketleft: "[", bracketright: "]",
    wheelscrollup: "Wheel ↑", wheelscrolldown: "Wheel ↓",
    wheelscrollleft: "Wheel ←", wheelscrollright: "Wheel →",
    mouseleft: "Left click", mouseright: "Right click", mousemiddle: "Middle click",
    touchpadscrollup: "Scroll ↑", touchpadscrolldown: "Scroll ↓",
    touchpadscrollleft: "Scroll ←", touchpadscrollright: "Scroll →",
    xf86audioraisevolume: "Vol +", xf86audiolowervolume: "Vol −", xf86audiomute: "Mute",
    xf86audiomicmute: "Mic mute", xf86audioplay: "Play", xf86audiopause: "Pause",
    xf86audiostop: "Stop", xf86audionext: "Next", xf86audioprev: "Prev",
    xf86monbrightnessup: "Bright +", xf86monbrightnessdown: "Bright −",
};

function splitKey(key) {
    const parts = key.split("+");
    return { mods: parts.slice(0, -1), key: parts[parts.length - 1] };
}

// A key as it reads: `{ mods: ["Super", "Shift"], key: "/" }` for Mod+Shift+Slash.
export function chord(key) {
    const parts = splitKey(key);
    const mods = parts.mods
        .map(m => MODIFIERS[m.toLowerCase()] ?? [m, 9])
        .sort((a, b) => a[1] - b[1])
        .map(m => m[0]);
    const name = parts.key;
    const lower = name.toLowerCase();
    let label = KEY_LABELS[lower];
    if (label === undefined) {
        if (name.length === 1)
            label = name.toUpperCase();
        else if (/^xf86/i.test(name))
            label = name.slice(4);
        else
            label = name;
    }
    return { mods, key: label };
}

// The same for every spelling of the same key, as niri matches them.
export function bindId(key) {
    const parts = splitKey(key);
    const mods = parts.mods.map(m => {
        const known = MODIFIERS[m.toLowerCase()];
        return known ? known[0] : m.toLowerCase();
    }).sort();
    return [...mods, parts.key.toLowerCase()].join("+");
}

// --- wording ----------------------------------------------------------------------

// How common actions read, in the context of their group's name.
const WORDING = {
    "close-window": "Close window",
    "fullscreen-window": "Fullscreen",
    "toggle-windowed-fullscreen": "Windowed fullscreen",
    "toggle-window-floating": "Float or tile",
    "switch-focus-between-floating-and-tiling": "Focus floating or tiling",
    "toggle-column-tabbed-display": "Tabbed column",
    "center-column": "Center column",
    "center-window": "Center window",
    "center-visible-columns": "Center visible columns",
    "maximize-column": "Maximize column",
    "maximize-window-to-edges": "Maximize to the edges",
    "consume-window-into-column": "Pull next window into column",
    "expel-window-from-column": "Push window out of column",
    "consume-or-expel-window-left": "Into or out of column, left",
    "consume-or-expel-window-right": "Into or out of column, right",
    "focus-column-first": "First column",
    "focus-column-last": "Last column",
    "focus-workspace": n => `Workspace ${n}`,
    "focus-workspace-up": "Workspace up",
    "focus-workspace-down": "Workspace down",
    "focus-workspace-previous": "Previous workspace",
    "move-column-to-workspace": n => `Move column to ${n}`,
    "move-column-to-workspace-up": "Move column up",
    "move-column-to-workspace-down": "Move column down",
    "move-window-to-workspace": n => `Move window to ${n}`,
    "move-window-to-workspace-up": "Move window up",
    "move-window-to-workspace-down": "Move window down",
    "move-workspace-up": "Move workspace up",
    "move-workspace-down": "Move workspace down",
    "toggle-overview": "Overview",
    "switch-preset-column-width": "Cycle column width",
    "switch-preset-window-width": "Cycle window width",
    "switch-preset-window-height": "Cycle window height",
    "set-column-width": a => `Column width ${a}`,
    "set-window-width": a => `Window width ${a}`,
    "set-window-height": a => `Window height ${a}`,
    "reset-window-height": "Reset window height",
    "expand-column-to-available-width": "Fill the free width",
    "screenshot": "Pick a region",
    "screenshot-screen": "Whole screen",
    "screenshot-window": "Focused window",
    "quit": "Quit niri",
    "power-off-monitors": "Turn monitors off",
    "power-on-monitors": "Turn monitors on",
    "show-hotkey-overlay": "niri's hotkey list",
    "toggle-keyboard-shortcuts-inhibit": "Let the app have the shortcuts",
};

// Groups in the order they show, each with the actions it takes and the verb
// its rows leave out, as the group's name says it.
const GROUPS = [
    { name: "Launch", test: a => a === "spawn" || a === "spawn-sh" },
    { name: "Windows", test: a => /^(close|fullscreen|toggle-window|toggle-column|switch-focus|center|maximize|consume|expel)/.test(a) },
    { name: "Workspaces", test: a => a.includes("workspace") || a.endsWith("-overview") },
    { name: "Focus", test: a => a.startsWith("focus-"), verb: "focus-" },
    { name: "Move", test: a => a.startsWith("move-"), verb: "move-" },
    { name: "Size", test: a => /^(switch-preset|set-|reset-window|expand-column)/.test(a) },
    { name: "Screenshots", test: a => a.startsWith("screenshot") },
    { name: "Session", test: a => /^(quit|power-|show-hotkey|toggle-keyboard-shortcuts|suspend)/.test(a) },
    { name: "Other", test: () => true },
];
const SHOWN_ORDER = ["Launch", "Windows", "Focus", "Move", "Workspaces", "Size", "Screenshots", "Session", "Other"];

function groupOf(action) {
    return GROUPS.find(g => g.test(action));
}

function stripMarkup(title) {
    return title.replace(/<[^>]*>/g, "")
        .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
        .replace(/&amp;/g, "&");
}

function capitalize(text) {
    return text.charAt(0).toUpperCase() + text.slice(1);
}

// What a bind does, in a few words.
export function describe(bind) {
    if (typeof bind.title === "string")
        return stripMarkup(bind.title);
    const args = bind.args ?? [];
    if (bind.action === "spawn" || bind.action === "spawn-sh") {
        const program = String(args[0] ?? "").trim().split(/\s+/)[0];
        return `Run ${program.slice(program.lastIndexOf("/") + 1)}`;
    }
    const wording = WORDING[bind.action];
    if (typeof wording === "function")
        return wording(args.join(" "));
    if (wording !== undefined)
        return wording;
    const verb = groupOf(bind.action).verb ?? "";
    const name = bind.action.startsWith(verb) ? bind.action.slice(verb.length) : bind.action;
    return capitalize([name.replace(/-/g, " "), ...args].join(" "));
}

// --- groups -------------------------------------------------------------------------

// Opposite actions that share a row, first one first.
const OPPOSITES = [["-left", "-right"], ["-up", "-down"], ["-first", "-last"]];

function sameArgs(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
}

// "Column left" and "Column right" → "Column left / right".
function pairText(a, b) {
    const x = a.split(" ");
    const y = b.split(" ");
    let start = 0;
    while (start < x.length - 1 && start < y.length - 1 && x[start] === y[start])
        start++;
    let end = 0;
    while (end < x.length - start - 1 && end < y.length - start - 1
           && x[x.length - 1 - end] === y[y.length - 1 - end])
        end++;
    const middle = `${x.slice(start, x.length - end).join(" ")} / ${y.slice(start, y.length - end).join(" ")}`;
    return [...x.slice(0, start), middle, ...x.slice(x.length - end)].join(" ");
}

// "First / Last column" → "First / last column": the word after the slash
// goes on the sentence, not starts one.
function pairCase(words) {
    const slash = words.indexOf(" / ");
    if (slash < 0)
        return words;
    return words.slice(0, slash + 3) + words.charAt(slash + 3).toLowerCase() + words.slice(slash + 4);
}

// Whether two entries are opposites; the first one first, or null.
function opposites(a, b) {
    if (a.title !== undefined || b.title !== undefined)
        return null;
    if (a.action === b.action && a.args.length === 1 && b.args.length === 1) {
        const x = String(a.args[0]);
        const y = String(b.args[0]);
        if (x.slice(1) === y.slice(1) && x.length > 1) {
            if (x[0] === "-" && y[0] === "+")
                return [a, b];
            if (x[0] === "+" && y[0] === "-")
                return [b, a];
        }
        return null;
    }
    if (!sameArgs(a.args, b.args))
        return null;
    for (const [one, other] of OPPOSITES) {
        if (a.action.endsWith(one) && b.action === a.action.slice(0, -one.length) + other)
            return [a, b];
        if (b.action.endsWith(one) && a.action === b.action.slice(0, -one.length) + other)
            return [b, a];
    }
    return null;
}

function sameMods(a, b) {
    return a.join("+") === b.join("+");
}

// Keys that are each other's opposite, by label.
const KEY_PARTNERS = [["←", "→"], ["↑", "↓"], ["H", "L"], ["K", "J"], ["PgUp", "PgDn"],
                      ["Home", "End"], ["-", "="], ["[", "]"], [",", "."], ["Wheel ↑", "Wheel ↓"]];

function partners(x, y) {
    return KEY_PARTNERS.some(([p, q]) => (x === p && y === q) || (x === q && y === p));
}

// Each of `a`'s keys with the key of `b` it pairs with, or null when the
// two do not line up: the same modifiers, and the opposite key where there
// is one, else the next key left in order.
function matchKeys(a, b) {
    if (a.length !== b.length)
        return null;
    const left = [...b];
    const matched = [];
    for (const k of a) {
        const sameModsAt = left.filter(o => sameMods(o.mods, k.mods));
        const other = sameModsAt.find(o => partners(k.key, o.key)) ?? sameModsAt[0];
        if (!other)
            return null;
        left.splice(left.indexOf(other), 1);
        matched.push([k, other]);
    }
    return matched;
}

// Chords that share their modifiers become one, with the keys as alternatives.
function mergeChords(chords) {
    const merged = [];
    for (const c of chords) {
        const same = merged.find(m => sameMods(m.mods, c.mods));
        if (same)
            same.keys.push(...c.keys);
        else
            merged.push({ mods: c.mods, keys: [...c.keys] });
    }
    return merged;
}

const HARDWARE_KEY = /^XF86/i;

// The rows of the panel, `[{ name, rows: [{ text, chords: [{ mods, keys }] }] }]`
// in a fixed group order, from `binds` as resolveBinds returns them.
//
// A null title hides a bind, as it hides it from niri's own list, and so does
// a hardware key (volume, brightness, …) without a title: its label is on the
// key. One action on several keys is one row; opposite actions (left and
// right, up and down, first and last, -10% and +10%) share a row when their
// keys line up; a run of numbered actions on their own digits is one row.
export function groupBinds(binds) {
    // One entry per action, its keys in the order they came.
    const entries = [];
    for (const b of binds) {
        if (b.title === null)
            continue;
        if (b.title === undefined && HARDWARE_KEY.test(splitKey(b.key).key))
            continue;
        const args = b.args ?? [];
        const same = entries.find(e => e.action === b.action && sameArgs(e.args, args)
                                     && (e.title === b.title || b.title === undefined));
        if (same) {
            same.keys.push(chord(b.key));
            continue;
        }
        entries.push({ action: b.action, args, title: b.title, keys: [chord(b.key)] });
    }

    const rows = [];
    const used = new Set();
    entries.forEach((entry, index) => {
        if (used.has(entry))
            return;

        // Numbered: focus-workspace 1 … 9 on Mod+1 … Mod+9.
        const numbered = e => e.title === undefined && e.args.length === 1 && Number.isInteger(e.args[0])
            && e.keys.length === 1 && e.keys[0].key === String(e.args[0]);
        if (numbered(entry)) {
            const run = entries.filter(e => !used.has(e) && e.action === entry.action && numbered(e)
                                            && sameMods(e.keys[0].mods, entry.keys[0].mods));
            const numbers = run.map(e => e.args[0]).sort((a, b) => a - b);
            const consecutive = numbers.every((n, i) => i === 0 || n === numbers[i - 1] + 1);
            if (run.length >= 3 && consecutive) {
                const span = `${numbers[0]}–${numbers[numbers.length - 1]}`;
                run.forEach(e => used.add(e));
                rows.push({ action: entry.action, text: describe({ action: entry.action, args: [span] }),
                            chords: [{ mods: entry.keys[0].mods, keys: [span] }] });
                return;
            }
        }

        // Opposites whose keys line up, modifier for modifier.
        for (const other of entries.slice(index + 1)) {
            if (used.has(other))
                continue;
            const pair = opposites(entry, other);
            const matched = pair && matchKeys(pair[0].keys, pair[1].keys);
            if (!matched)
                continue;
            used.add(entry);
            used.add(other);
            rows.push({
                action: entry.action,
                text: pairCase(pairText(describe(pair[0]), describe(pair[1]))),
                chords: mergeChords(matched.map(([k, o]) => ({ mods: k.mods, keys: [`${k.key} ${o.key}`] }))),
            });
            return;
        }

        used.add(entry);
        rows.push({ action: entry.action, text: describe(entry),
                    chords: mergeChords(entry.keys.map(k => ({ mods: k.mods, keys: [k.key] }))) });
    });

    return SHOWN_ORDER
        .map(name => ({ name, rows: rows.filter(r => groupOf(r.action).name === name)
                                         .map(r => ({ text: r.text, chords: r.chords })) }))
        .filter(g => g.rows.length > 0);
}

// The rows every word of `query` is found in: in the row's text, its keys or
// its group's name, whatever the case.
export function filterGroups(groups, query) {
    const words = query.toLowerCase().split(/\s+/).filter(w => w !== "");
    if (words.length === 0)
        return groups;
    return groups
        .map(g => ({
            name: g.name,
            rows: g.rows.filter(row => {
                // Not flatMap: Qt's JavaScript engine has none.
                const keys = row.chords.map(c => [...c.mods, ...c.keys].join(" "));
                const haystack = [g.name, row.text, ...keys].join(" ").toLowerCase();
                return words.every(w => haystack.includes(w));
            }),
        }))
        .filter(g => g.rows.length > 0);
}

// The groups cut into at most `count` columns, in order, so that the
// tallest column is as short as it can be. A group is as tall as its rows
// plus two for its heading.
export function packColumns(groups, count) {
    const n = Math.min(Math.max(1, count), groups.length);
    if (n === 0)
        return [];
    const heights = groups.map(g => g.rows.length + 2);
    const sum = (from, to) => heights.slice(from, to).reduce((a, b) => a + b, 0);

    // best[k][i]: the shortest tallest column for the first i groups in k
    // columns, and where the last column starts.
    const best = [[{ height: 0, start: 0 }]];
    for (let i = 1; i <= groups.length; i++)
        best[0][i] = { height: Infinity, start: 0 };
    for (let k = 1; k <= n; k++) {
        best[k] = [{ height: 0, start: 0 }];
        for (let i = 1; i <= groups.length; i++) {
            let choice = { height: Infinity, start: 0 };
            for (let j = k - 1; j < i; j++) {
                const height = Math.max(best[k - 1][j].height, sum(j, i));
                if (height < choice.height)
                    choice = { height, start: j };
            }
            best[k][i] = choice;
        }
    }

    const columns = [];
    let end = groups.length;
    for (let k = n; k > 0; k--) {
        const start = best[k][end].start;
        columns.unshift(groups.slice(start, end));
        end = start;
    }
    return columns.filter(c => c.length > 0);
}
