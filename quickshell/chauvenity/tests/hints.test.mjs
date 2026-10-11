// Unit tests for the keys the bar's hints answer to.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import { assignKeys, digitKey, hintTarget, workspaceKey } from "../hints.mjs";

const KEYS = ["c", "v", "b", "t"];

test("digitKey reads the number row by position and the keypad by text", () => {
    assert.equal(digitKey("1", 10), 1);
    assert.equal(digitKey("é", 11), 2); // AZERTY, unshifted
    assert.equal(digitKey("3", 89), 3); // KP_3
    assert.equal(digitKey("", 89), 0); // Num Lock off: End
    assert.equal(digitKey("0", 19), 0);
    assert.equal(digitKey("m", 47), 0);
});

test("workspaceKey numbers the first nine workspaces only", () => {
    assert.equal(workspaceKey(0), "1");
    assert.equal(workspaceKey(8), "9");
    assert.equal(workspaceKey(9), "");
});

test("an item gets the letter it asks for, whatever the case", () => {
    const { keys, problems } = assignKeys([
        { name: "claude", key: "c" },
        { name: "volume", key: "V" },
    ]);
    assert.deepEqual(keys, ["c", "v"]);
    assert.deepEqual(problems, []);
});

test("an item that asks for no letter gets the first free one of its name", () => {
    const { keys, problems } = assignKeys([
        { name: "claude", key: "c" },
        { name: "clock", key: "" },
        { name: "wifi", key: "" },
    ]);
    assert.deepEqual(keys, ["c", "l", "w"]);
    assert.deepEqual(problems, []);
});

test("asked-for letters go first, wherever the item sits on the bar", () => {
    const { keys } = assignKeys([
        { name: "clock", key: "" },
        { name: "claude", key: "c" },
    ]);
    assert.deepEqual(keys, ["l", "c"]);
});

test("a letter asked for twice goes to the first item, the second falls back", () => {
    const { keys, problems } = assignKeys([
        { name: "volume", key: "v" },
        { name: "vpn", key: "v" },
    ]);
    assert.deepEqual(keys, ["v", "p"]);
    assert.deepEqual(problems, ['vpn: hint key "v" is already taken, so it gets "p"']);
});

test("a key that is not one letter is refused", () => {
    const { keys, problems } = assignKeys([
        { name: "mail", key: "1" },
        { name: "net", key: "nt" },
    ]);
    assert.deepEqual(keys, ["m", "n"]);
    assert.deepEqual(problems, [
        'mail: hint key "1" is not a letter, so it gets "m"',
        'net: hint key "nt" is not a letter, so it gets "n"',
    ]);
});

test("a name with no free letter falls back to the alphabet", () => {
    const { keys } = assignKeys([
        { name: "aa", key: "a" },
        { name: "a", key: "" },
    ]);
    assert.deepEqual(keys, ["a", "b"]);
});

test("an item past the 26th gets no letter", () => {
    const items = [..."abcdefghijklmnopqrstuvwxyz"].map(c => ({ name: c, key: c }));
    const { keys, problems } = assignKeys([...items, { name: "extra", key: "" }]);
    assert.equal(keys[26], "");
    assert.deepEqual(problems, ["extra: gets no hint: no letter is left"]);
});

test("two items with the same name are reported", () => {
    const { problems } = assignKeys([
        { name: "volume", key: "v" },
        { name: "volume", key: "" },
    ]);
    assert.deepEqual(problems, ['two items are named "volume": `toggle volume` reaches the first']);
});

test("a digit picks the workspace at that position", () => {
    assert.deepEqual(hintTarget("1", 10, 3, KEYS), { workspace: 0 });
    assert.deepEqual(hintTarget("3", 12, 3, KEYS), { workspace: 2 });
});

test("a digit past the bar's workspaces picks nothing", () => {
    assert.equal(hintTarget("4", 13, 3, KEYS), null);
});

test("the number row counts by position on AZERTY, Shift or not", () => {
    assert.deepEqual(hintTarget("é", 11, 3, KEYS), { workspace: 1 }); // unshifted `2`
    assert.deepEqual(hintTarget("2", 11, 3, KEYS), { workspace: 1 }); // shifted
});

test("the keypad counts by what it types", () => {
    assert.deepEqual(hintTarget("3", 89, 3, KEYS), { workspace: 2 }); // KP_3
    assert.equal(hintTarget("", 89, 3, KEYS), null); // Num Lock off: End
});

test("0 picks nothing", () => {
    assert.equal(hintTarget("0", 19, 3, KEYS), null);
});

test("a letter picks the item showing it, whatever the case", () => {
    assert.deepEqual(hintTarget("c", 54, 3, KEYS), { key: "c" });
    assert.deepEqual(hintTarget("B", 56, 3, KEYS), { key: "b" });
});

test("a letter no item on screen shows picks nothing", () => {
    // A desktop: no battery.
    assert.equal(hintTarget("b", 56, 3, ["c", "v", "t"]), null);
});

test("any other key picks nothing", () => {
    assert.equal(hintTarget("\u001b", 9, 3, KEYS), null); // Escape
    assert.equal(hintTarget("x", 53, 3, KEYS), null);
    assert.equal(hintTarget("", 113, 3, KEYS), null); // Left
});
