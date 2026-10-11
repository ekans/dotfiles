// What Mod+E's translator decides (Translator.qml): which key picks which
// mode, what translate.sh's answers say, and the text that goes back once the
// fix's changes are kept or dropped.
//
// Plain ECMAScript, no QML: Translator.qml imports it and
// tests/translate.test.mjs runs it under node. Keep to what Qt's JavaScript
// engine parses.

// The modes, in the order the panel shows them: all three, every time.
export const MODES = [
    { key: "w", name: "word" },
    { key: "p", name: "paragraph" },
    { key: "f", name: "fix" },
];

// The longest set phrase looked up in the dictionary: "avoir du pain sur la
// planche". Anything longer is a sentence.
export const MAX_PHRASE_WORDS = 5;

export function countWords(text) {
    const trimmed = String(text ?? "").trim();
    return trimmed === "" ? 0 : trimmed.split(/\s+/).length;
}

// Quotes and punctuation a selection drags along at either end.
const EDGES = /^[\s"'«»“”‘’()[\]{}.,;:!?…-]+|[\s"'«»“”‘’()[\]{}.,;:!?…-]+$/g;

// The terms to ask the dictionary for, in order: the selection as it is, then
// lower-cased (a word at the start of a sentence). None for a sentence: more
// than MAX_PHRASE_WORDS words, or punctuation that ends a clause inside.
export function lookupTerms(text) {
    const term = String(text ?? "").replace(EDGES, "").replace(/\s+/g, " ");
    const words = countWords(term);
    if (words === 0 || words > MAX_PHRASE_WORDS || /[.!?;:\n]/.test(term))
        return [];
    const lower = term.toLowerCase();
    return lower === term ? [term] : [term, lower];
}

// The mode a key in the chooser picks, by the character it types, or "".
export function pickedMode(text) {
    const key = String(text ?? "").toLowerCase();
    return MODES.some(m => m.key === key) ? key : "";
}

// The mode `translate run <mode>` asks for, by its name or its key, or "".
export function modeKey(name) {
    const asked = String(name ?? "").trim().toLowerCase();
    const mode = MODES.find(m => m.key === asked || m.name === asked);
    return mode ? mode.key : "";
}

// The first line of translate.sh's answers says how it went; the rest is the
// answer.
export function readReply(output) {
    const text = String(output ?? "");
    const newline = text.indexOf("\n");
    return newline < 0
        ? { status: text.trim(), body: "" }
        : { status: text.slice(0, newline).trim(), body: text.slice(newline + 1) };
}

// `translate.sh word`: how it went, the term it was asked for first, then
// Wiktionary's answer. The term tells an answer to an earlier lookup from the
// one awaited.
export function readLookup(output) {
    const reply = readReply(output);
    const newline = reply.body.indexOf("\n");
    return newline < 0
        ? { status: reply.status, asked: reply.body.trim(), body: "" }
        : { status: reply.status, asked: reply.body.slice(0, newline), body: reply.body.slice(newline + 1) };
}

// Terminals take Ctrl+Shift+V; a plain Ctrl+V there is a control character.
// As in snippets/snip.mjs and clipboard/clip.mjs.
const TERMINAL_WORDS = ["ghostty", "kitty", "alacritty", "foot", "footclient", "konsole", "console",
    "ptyxis", "tilix", "terminator", "rio", "warp", "kgx", "blackbox"];

export function isTerminal(appId) {
    const parts = String(appId ?? "").toLowerCase().split(/[.\-_]/);
    return parts.some(part => TERMINAL_WORDS.indexOf(part) !== -1 || part.indexOf("term") !== -1);
}

// `translate.sh probe`: niri's focused window, which the result is pasted
// into, an RS line, then the primary selection.
export function readProbe(output) {
    const [windowJson, ...rest] = String(output ?? "").split("\x1e\n");
    let window = null;
    try {
        window = JSON.parse(windowJson);
    } catch (e) {
        window = null;
    }
    return {
        windowId: window && window.id !== undefined && window.id !== null ? String(window.id) : "",
        terminal: isTerminal(window?.app_id),
        selection: rest.join("\x1e\n"),
    };
}

// --- Wiktionary --------------------------------------------------------------

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };

function decodeEntities(text) {
    return text.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (match, name) => {
        if (name[0] === "#") {
            const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
            return Number.isFinite(code) ? String.fromCodePoint(code) : match;
        }
        return ENTITIES[name.toLowerCase()] ?? match;
    });
}

// Wiktionary's definitions are HTML, with the template's CSS inlined in a
// <style>.
export function stripHtml(html) {
    const text = String(html ?? "")
        .replace(/<style[\s\S]*?<\/style>/gi, "")
        .replace(/<[^>]*>/g, "");
    return decodeEntities(text).replace(/\s+/g, " ").trim();
}

// What can stand in for the term in a sentence: a sense without its labels,
// "(colloquial)", and usage notes, "[with sur …]", split on the commas and
// semicolons between its synonyms.
export function glossesOf(sense) {
    let depth = 0;
    let bare = "";
    for (const ch of String(sense ?? "")) {
        if (ch === "(" || ch === "[")
            depth++;
        else if ((ch === ")" || ch === "]") && depth > 0)
            depth--;
        else if (depth === 0)
            bare += ch;
    }
    return bare.split(/[,;]/)
        .map(part => part.replace(/\s+/g, " ").trim())
        .filter(part => part !== "");
}

const PARTS_OF_SPEECH = {
    adjective: "adj.", adverb: "adv.", noun: "noun", verb: "verb", phrase: "phrase",
    "prepositional phrase": "prep. phrase", interjection: "interj.", pronoun: "pron.",
    preposition: "prep.", conjunction: "conj.", "proper noun": "name", participle: "part.",
};

// The French senses of a Wiktionary REST `page/definition` body, as
// `[{ pos, text, glosses, example }]`, `example` being `{ fr, en }` or null.
export function readEntry(body) {
    let json;
    try {
        json = JSON.parse(body);
    } catch (e) {
        return [];
    }
    const senses = [];
    for (const section of json?.fr ?? []) {
        const pos = String(section.partOfSpeech ?? "");
        for (const definition of section.definitions ?? []) {
            const text = stripHtml(definition.definition);
            const glosses = glossesOf(text);
            if (text === "" || glosses.length === 0)
                continue;
            const example = (definition.parsedExamples ?? []).find(e => e && e.example && e.translation);
            senses.push({
                pos: PARTS_OF_SPEECH[pos.toLowerCase()] ?? pos.toLowerCase(),
                text: text,
                glosses: glosses,
                example: example ? { fr: stripHtml(example.example), en: stripHtml(example.translation) } : null,
            });
        }
    }
    return senses;
}

const INFLECTION = /\b(singular|plural|feminine|masculine|participle|person|inflection|infinitive|indicative|subjunctive|imperative|conditional)\b/i;

// The lemma when every sense only says which form of it the term is:
// "décalée" is "feminine singular of décalé", "décale" an "inflection of
// décaler: first/third-person singular present…". "" otherwise.
export function lemmaOf(senses) {
    let lemma = "";
    for (const sense of senses) {
        if (!INFLECTION.test(sense.text))
            return "";
        const match = /^((?:\S+\s+){0,6}?)of\s+([^\s:]+)/i.exec(sense.text);
        if (match && INFLECTION.test(match[1]) && lemma === "")
            lemma = match[2].replace(EDGES, "");
    }
    return lemma;
}

// Every gloss in order, `[{ sense, text }]`, for ←→ to walk.
export function flatGlosses(senses) {
    const all = [];
    (senses ?? []).forEach((sense, i) => {
        for (const gloss of sense.glosses)
            all.push({ sense: i, text: gloss });
    });
    return all;
}

// --- the fix -----------------------------------------------------------------

// The LLM's fix, asked for as JSON `{ fixed, notes: [{ from, why, kind }] }`
// and maybe wrapped in a code fence anyway: the whole text fixed, and why each
// piece of the original was changed. Null when it is not that.
export function readFix(output) {
    let text = String(output ?? "").trim();
    const fence = /```(?:json)?\s*([\s\S]*?)```/.exec(text);
    if (fence)
        text = fence[1];
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start < 0 || end < start)
        return null;
    let json;
    try {
        json = JSON.parse(text.slice(start, end + 1));
    } catch (e) {
        return null;
    }
    if (!json || typeof json.fixed !== "string")
        return null;
    const notes = Array.isArray(json.notes) ? json.notes : [];
    return {
        fixed: json.fixed,
        notes: notes
            .filter(n => n && typeof n.from === "string" && n.from !== "")
            .map(n => ({ from: n.from, why: String(n.why ?? ""), kind: String(n.kind ?? "") })),
    };
}

// Words, the spaces between them, and each other character, so that a diff
// by token is a diff by word. An explicit class rather than \p{L}, which Qt's
// JavaScript engine may not know.
const TOKEN = /\s+|[0-9A-Za-zÀ-ÖØ-öø-ÿŒœÆæ'’_-]+|[^\s]/g;

function tokenize(text) {
    return String(text).match(TOKEN) ?? [];
}

function wordsIn(text) {
    return (String(text).match(/[0-9A-Za-zÀ-ÖØ-öø-ÿŒœÆæ]+/g) ?? []).length;
}

// The source cut into what stays, `{ text }`, and the changes that make it
// `fixed`, `{ from, to, why, kind, index }`, in order. The changes are a word
// diff of the two, two changes one word apart taken as one ("make a point
// on" → "go over"); each gets the notes on the original it overlaps.
export function diffChanges(source, fixed, notes) {
    const a = tokenize(source);
    const b = tokenize(fixed);
    const n = a.length;
    const m = b.length;
    // Longest common subsequence, from the ends.
    const lcs = new Array((n + 1) * (m + 1)).fill(0);
    const at = (i, j) => i * (m + 1) + j;
    for (let i = n - 1; i >= 0; i--) {
        for (let j = m - 1; j >= 0; j--)
            lcs[at(i, j)] = a[i] === b[j] ? lcs[at(i + 1, j + 1)] + 1 : Math.max(lcs[at(i + 1, j)], lcs[at(i, j + 1)]);
    }
    // Runs of what stays and of what changes.
    const runs = [];
    const add = (same, from, to) => {
        const last = runs[runs.length - 1];
        if (last && last.same === same) {
            last.from += from;
            last.to += to;
        } else {
            runs.push({ same: same, from: from, to: to });
        }
    };
    let i = 0;
    let j = 0;
    while (i < n || j < m) {
        if (i < n && j < m && a[i] === b[j]) {
            add(true, a[i], b[j]);
            i++;
            j++;
        } else if (j >= m || (i < n && lcs[at(i + 1, j)] >= lcs[at(i, j + 1)])) {
            add(false, a[i], "");
            i++;
        } else {
            add(false, "", b[j]);
            j++;
        }
    }
    // A change, at most one word, a change: one change.
    for (let k = 1; k + 1 < runs.length; k++) {
        if (runs[k].same && !runs[k - 1].same && !runs[k + 1].same && wordsIn(runs[k].from) <= 1) {
            runs.splice(k - 1, 3, {
                same: false,
                from: runs[k - 1].from + runs[k].from + runs[k + 1].from,
                to: runs[k - 1].to + runs[k].to + runs[k + 1].to,
            });
            k--;
        }
    }
    // Where each note's piece of the original is.
    const placed = notes.map(note => ({ note: note, start: source.indexOf(note.from) }))
        .filter(p => p.start >= 0);
    const parts = [];
    let offset = 0;
    let index = 0;
    for (const run of runs) {
        const start = offset;
        offset += run.from.length;
        if (run.same) {
            parts.push({ text: run.from });
            continue;
        }
        const end = Math.max(offset, start + 1);
        const mine = placed.filter(p => p.start < end && p.start + p.note.from.length > start).map(p => p.note);
        parts.push({
            from: run.from,
            to: run.to,
            why: mine.map(note => note.why).filter(why => why !== "").join(" · "),
            kind: mine.length > 0 ? mine[0].kind : "",
            index: index++,
        });
    }
    return parts;
}

export function changesOf(parts) {
    return parts.filter(part => part.text === undefined);
}

// The text with every change made but the ones kept as they were.
export function applyChanges(parts, kept) {
    return parts.map(part => part.text !== undefined ? part.text
        : kept.indexOf(part.index) !== -1 ? part.from : part.to).join("");
}

function escapeMarkup(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
        .replace(/\n/g, "<br>");
}

// The text with its changes, as Qt's StyledText: what goes struck out in
// `colors.bad`, what comes in `colors.good`, the current change underlined, a
// kept one as it was. Everything from the selection is escaped.
export function diffMarkup(parts, current, kept, colors) {
    return parts.map(part => {
        if (part.text !== undefined)
            return escapeMarkup(part.text);
        const open = part.index === current ? "<u>" : "";
        const close = part.index === current ? "</u>" : "";
        if (kept.indexOf(part.index) !== -1)
            return `${open}${escapeMarkup(part.from)}${close}`;
        return `${open}<s><font color="${colors.bad}">${escapeMarkup(part.from)}</font></s> `
            + `<font color="${colors.good}">${escapeMarkup(part.to)}</font>${close}`;
    }).join("");
}

// One change, for its card in the panel: what goes, struck out, and what
// comes; only what goes, plain, when it is kept.
export function changeMarkup(change, kept, colors) {
    const from = escapeMarkup(preview(change.from, 60));
    const to = escapeMarkup(preview(change.to, 60));
    if (kept)
        return from;
    if (change.from.trim() === "")
        return `<font color="${colors.good}">+ ${to}</font>`;
    if (change.to.trim() === "")
        return `<s><font color="${colors.bad}">${from}</font></s>`;
    return `<s><font color="${colors.bad}">${from}</font></s> → <font color="${colors.good}">${to}</font>`;
}

// At most `max` characters of `text` on one line, for the panel's headings.
export function preview(text, max) {
    const line = String(text ?? "").replace(/\s+/g, " ").trim();
    return line.length > max ? line.slice(0, Math.max(1, max - 1)).replace(/\s+$/, "") + "…" : line;
}

// What the panel's header says about the text the modes work on.
export function describe(text) {
    const words = countWords(text);
    if (words === 0)
        return "nothing selected · w lets you type a word";
    return `“${preview(text, 40)}” · ${words === 1 ? "1 word" : `${words} words`}`;
}

// What a mode would do with the text, under its key while the panel waits
// for one. `state` is the translator's `{ text, selected, lookup, glosses }`:
// the dictionary is asked before w is pressed, so w says what it found.
export function modeHint(key, state) {
    const empty = String(state?.text ?? "").trim() === "";
    if (key === "w") {
        if (empty)
            return "type a French word or set phrase";
        switch (state.lookup) {
        case "pending":
            return "looking it up in Wiktionary…";
        case "found":
            return preview((state.glosses ?? []).map(g => g.text).join(" · "), 60);
        case "none":
            return "no French entry in Wiktionary";
        case "unreachable":
            return "Wiktionary is unreachable";
        default:
            return "a sentence, not a word or a set phrase";
        }
    }
    if (empty)
        return "nothing selected";
    if (key === "p")
        return state.selected ? "French into English, to paste over the selection" : "French into English, to copy";
    if (key === "f")
        return "the English made simple, change by change with why";
    return "";
}

// Why a word has no senses to pick from, once looked up.
export function wordMissing(lookup, text) {
    if (lookup === "unreachable")
        return "Wiktionary is unreachable.";
    if (lookup === "none")
        return `No French entry for “${preview(text, 40)}” in Wiktionary.`;
    return "A sentence: w looks up a word or a set phrase.";
}
