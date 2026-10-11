// What Super+Space's leader menu (Leader.qml) decides: which page the keys
// typed so far lead to, what a key on it does, a page's arguments and the
// command a pick runs with them.
//
// Plain ECMAScript, no QML: Leader.qml imports it and tests/leader.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread.
//
// A menu is a list of entries, `{ key, name }` and one of:
//
//     run: [argv]             the command a pick runs. "{name}" in it is the
//                             page's argument of that name, if one was
//                             changed, else "": the command's own default.
//     children: [entries]     a page of its own
//     bar: [argv]             a page of the bar's items, a key each, the
//                             letters Mod+B gives them; "{item}" in the
//                             command is the item's name
//
// and, on an entry with children, optionally
//
//     args: [argv]            a command answering the page's arguments as
//                             JSON: [{ key, name, value, choices: [{ value,
//                             name }] }], `value` the default. "-" then the
//                             key steps one forward, "-" then the key in
//                             upper case one back.

// The entries the keys in `path` lead to from the menu's top, and the entry
// whose page they are (null at the top); null when a key leads nowhere.
// `barItems` are the bar's `[{ key, name }]`.
export function pageAt(menu, path, barItems) {
    let entries = menu;
    let entry = null;
    for (const key of path) {
        entry = entries.find(e => e.key === key) || null;
        if (!entry)
            return null;
        entries = childrenOf(entry, barItems);
        if (!entries)
            return null;
    }
    return { entry: entry, entries: entries };
}

// An entry's page, or null for one that runs a command.
export function childrenOf(entry, barItems) {
    if (entry.children)
        return entry.children;
    if (entry.bar)
        return (barItems || []).map(item => ({
            key: item.key,
            name: item.name,
            run: entry.bar.map(part => part.split("{item}").join(item.name)),
        }));
    return null;
}

// The entry a key picks, by the character it types; a letter typed with
// Caps Lock on still picks its entry, unless one has the capital itself.
export function answer(entries, text) {
    const typed = String(text || "");
    if (typed === "")
        return null;
    return entries.find(e => e.key === typed)
        || entries.find(e => e.key === typed.toLowerCase())
        || null;
}

// `argv` with each "{name}" replaced by `values[name]`, "" when it has none.
export function command(argv, values) {
    return argv.map(part => part.replace(/\{(\w+)\}/g, (whole, name) =>
        Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : ""));
}

// A page's arguments, from its `args` command's answer; [] for anything but
// the list it should be. A value that is not among its choices is put first.
export function readArguments(text) {
    let list;
    try {
        list = JSON.parse(String(text || ""));
    } catch (e) {
        return [];
    }
    if (!Array.isArray(list))
        return [];
    const args = [];
    for (const a of list) {
        if (!a || typeof a.key !== "string" || a.key.length !== 1 || typeof a.name !== "string" || !Array.isArray(a.choices))
            continue;
        const choices = a.choices
            .filter(c => c && typeof c.value === "string")
            .map(c => ({ value: c.value, name: typeof c.name === "string" && c.name !== "" ? c.name : c.value }));
        const value = typeof a.value === "string" ? a.value : (choices[0] ? choices[0].value : "");
        if (value !== "" && !choices.some(c => c.value === value))
            choices.unshift({ value: value, name: value });
        if (choices.length > 0)
            args.push({ key: a.key, name: a.name, value: value, choices: choices });
    }
    return args;
}

// The argument the key after "-" sets, and which way it steps it: its key
// one forward, the same in upper case one back. null for neither.
export function argumentKey(args, text) {
    const typed = String(text || "");
    const forward = args.find(a => a.key === typed);
    if (forward)
        return { arg: forward, step: 1 };
    const back = typed !== typed.toLowerCase() ? args.find(a => a.key === typed.toLowerCase()) : null;
    return back ? { arg: back, step: -1 } : null;
}

// The value `step` places after `value` among `arg`'s choices, wrapping round.
export function stepArgument(arg, value, step) {
    const values = arg.choices.map(c => c.value);
    const i = values.indexOf(value);
    const n = values.length;
    return values[(((i === -1 ? 0 : i) + step) % n + n) % n];
}

// `chosen` with `name` set to `value`, or dropped when that is the default:
// a command is only handed the arguments changed from its own defaults.
export function choose(chosen, arg, value) {
    const next = {};
    for (const name in chosen) {
        if (name !== arg.name)
            next[name] = chosen[name];
    }
    if (value !== arg.value)
        next[arg.name] = value;
    return next;
}

// What is wrong with a menu, for the log: a key two entries of a page share,
// a key that is not one character, an entry that does nothing.
export function checkMenu(menu, where) {
    const problems = [];
    const seen = {};
    const at = where || "SPC";
    for (const entry of menu) {
        const label = `${at} ${entry.key}`;
        if (typeof entry.key !== "string" || entry.key.length !== 1)
            problems.push(`${label} (${entry.name}): a key is one character`);
        else if (seen[entry.key])
            problems.push(`${label}: both "${seen[entry.key]}" and "${entry.name}"`);
        seen[entry.key] = entry.name;
        const does = ["run", "children", "bar"].filter(k => entry[k]);
        if (does.length !== 1)
            problems.push(`${label} (${entry.name}): needs one of run, children or bar`);
        if (entry.args && !entry.children)
            problems.push(`${label} (${entry.name}): args are for a page with children`);
        if (entry.children)
            Array.prototype.push.apply(problems, checkMenu(entry.children, label));
    }
    return problems;
}
