// Which key picks which bar item while the bar shows its hints
// (`qs -c chauvenity ipc call bar hints`).
//
// Plain ECMAScript, no QML: the bar imports it and tests/hints.test.mjs runs
// it under node. Keep to what Qt's JavaScript engine parses.

const LETTERS = "abcdefghijklmnopqrstuvwxyz";

// The xkb keycode of the number row's `1` (evdev KEY_1, plus 8); `2` … `9`
// follow it.
const DIGIT_ROW_ONE = 10;

// A bar's first nine workspaces get 1–9, in the order the bar lists them,
// as niri's Mod+1 … Mod+9 count them.
export function workspaceKey(position) {
    return position < 9 ? String(position + 1) : "";
}

// The letters of the items that take a hint, `[{ name, key }]` in bar order,
// `key` being the one the item asks for or "". Returns `keys`, one per item
// ("" when no letter is left), and the `problems` worth a warning.
//
// An item gets the letter it asks for unless an item before it asked first;
// then, as do items that ask for none, the first free letter of its name,
// else of the alphabet. Asked-for letters are handed out first, so an item
// that asks for none never takes one from an item that does. The keys depend
// on which items exist, not on which are on screen, so a battery that comes
// and goes does not move anyone else's.
export function assignKeys(items) {
    const keys = items.map(() => "");
    const problems = [];
    const taken = new Set();

    const seen = new Set();
    for (const item of items) {
        if (seen.has(item.name))
            problems.push(`two items are named "${item.name}": \`toggle ${item.name}\` reaches the first`);
        seen.add(item.name);
    }

    // Why an item did not get the letter it asked for.
    const refused = items.map(() => "");
    items.forEach((item, i) => {
        const asked = (item.key || "").toLowerCase();
        if (asked === "")
            return;
        if (asked.length !== 1 || !LETTERS.includes(asked)) {
            refused[i] = `hint key "${item.key}" is not a letter`;
        } else if (taken.has(asked)) {
            refused[i] = `hint key "${asked}" is already taken`;
        } else {
            keys[i] = asked;
            taken.add(asked);
        }
    });

    items.forEach((item, i) => {
        if (keys[i] !== "")
            return;
        const candidates = item.name.toLowerCase() + LETTERS;
        const free = [...candidates].find(c => LETTERS.includes(c) && !taken.has(c));
        if (free !== undefined) {
            keys[i] = free;
            taken.add(free);
        }
        const outcome = free !== undefined ? `gets "${free}"` : "gets no hint: no letter is left";
        if (refused[i] !== "")
            problems.push(`${item.name}: ${refused[i]}, so it ${outcome}`);
        else if (free === undefined)
            problems.push(`${item.name}: ${outcome}`);
    });

    return { keys, problems };
}

// The digit 1–9 a key press stands for, or 0. `text` is what the key typed,
// `scanCode` its xkb keycode. The number row counts by position, as AZERTY
// types symbols there unless Shift is held; the keypad counts by what it
// types. VolumePanel picks an output with it too.
export function digitKey(text, scanCode) {
    if (/^[1-9]$/.test(text))
        return Number(text);
    if (scanCode >= DIGIT_ROW_ONE && scanCode < DIGIT_ROW_ONE + 9)
        return scanCode - DIGIT_ROW_ONE + 1;
    return 0;
}

// What a key press picks: `{ workspace: position }`, `{ key: letter }`, or
// null. `text` and `scanCode` are as digitKey() takes them, and `keys` the
// letters of the items on screen.
export function hintTarget(text, scanCode, workspaceCount, keys) {
    const digit = digitKey(text, scanCode);
    if (digit > 0)
        return digit <= workspaceCount ? { workspace: digit - 1 } : null;

    const letter = text.toLowerCase();
    return letter !== "" && keys.includes(letter) ? { key: letter } : null;
}
