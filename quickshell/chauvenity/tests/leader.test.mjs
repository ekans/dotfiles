// Unit tests for the leader menu's logic, and the menu itself.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    answer,
    argumentKey,
    checkMenu,
    childrenOf,
    choose,
    command,
    pageAt,
    readArguments,
    stepArgument,
} from "../leader.mjs";
import { MENU } from "../leader-menu.mjs";

const menu = [
    { key: "b", name: "bb", children: [
        { key: "n", name: "new thread", run: ["new", "{model}", "{effort}"] },
    ] },
    { key: "v", name: "clipboard", run: ["clip"] },
    { key: "o", name: "bar panel", bar: ["bar", "toggle", "{item}"] },
    { key: "?", name: "keys", run: ["keys"] },
];
const barItems = [{ key: "v", name: "volume" }, { key: "c", name: "clock" }];

test("pageAt follows the keys typed down the menu", () => {
    assert.deepEqual(pageAt(menu, [], barItems), { entry: null, entries: menu });
    const bb = pageAt(menu, ["b"], barItems);
    assert.equal(bb.entry.name, "bb");
    assert.deepEqual(bb.entries.map(e => e.key), ["n"]);
});

test("pageAt has no page for a key that leads nowhere, or to a command", () => {
    assert.equal(pageAt(menu, ["x"], barItems), null);
    assert.equal(pageAt(menu, ["v"], barItems), null);
    assert.equal(pageAt(menu, ["b", "n"], barItems), null);
});

test("a bar page has the bar's items, under the letters Super+Space h gives them", () => {
    const page = pageAt(menu, ["o"], barItems);
    assert.deepEqual(page.entries, [
        { key: "v", name: "volume", run: ["bar", "toggle", "volume"] },
        { key: "c", name: "clock", run: ["bar", "toggle", "clock"] },
    ]);
    assert.deepEqual(childrenOf(menu[2], undefined), []);
    assert.equal(childrenOf(menu[1], barItems), null);
});

test("answer picks by the character typed, a capital from Caps Lock too", () => {
    assert.equal(answer(menu, "v").name, "clipboard");
    assert.equal(answer(menu, "V").name, "clipboard");
    assert.equal(answer(menu, "?").name, "keys");
    assert.equal(answer(menu, "x"), null);
    assert.equal(answer(menu, ""), null);
    // Return and Space type a character, and pick nothing.
    assert.equal(answer(menu, "\r"), null);
    assert.equal(answer([{ key: "V", name: "capital" }, { key: "v", name: "small" }], "V").name, "capital");
});

test("command fills in the arguments changed, and leaves the others empty", () => {
    assert.deepEqual(command(["new", "{model}", "{effort}", ""], { effort: "max" }), ["new", "", "max", ""]);
    assert.deepEqual(command(["clip"], {}), ["clip"]);
    assert.deepEqual(command(["a{x}b"], { x: "-" }), ["a-b"]);
});

const ARGS = JSON.stringify([
    { key: "m", name: "model", value: "opus", choices: [{ value: "opus", name: "Opus 5.5" }, { value: "fable", name: "Fable 5.1" }] },
    { key: "e", name: "effort", value: "high", choices: [{ value: "low" }, { value: "high" }, { value: "max" }] },
]);

test("readArguments reads the page's arguments, choices named", () => {
    const args = readArguments(ARGS);
    assert.equal(args.length, 2);
    assert.deepEqual(args[0].choices[1], { value: "fable", name: "Fable 5.1" });
    assert.deepEqual(args[1].choices[0], { value: "low", name: "low" });
    assert.equal(args[1].value, "high");
});

test("readArguments puts a default missing from the choices first", () => {
    const [arg] = readArguments(JSON.stringify([{ key: "m", name: "model", value: "haiku", choices: [{ value: "opus" }] }]));
    assert.deepEqual(arg.choices.map(c => c.value), ["haiku", "opus"]);
});

test("readArguments drops what is not an argument, and anything not a list", () => {
    assert.deepEqual(readArguments(""), []);
    assert.deepEqual(readArguments("no bb-new running"), []);
    assert.deepEqual(readArguments("{}"), []);
    assert.deepEqual(readArguments(JSON.stringify([
        { key: "mm", name: "model", choices: [{ value: "a" }] },
        { key: "e", name: "effort", choices: [] },
        null,
    ])), []);
});

test("argumentKey steps forward on the key, back on its capital", () => {
    const args = readArguments(ARGS);
    assert.deepEqual(argumentKey(args, "e"), { arg: args[1], step: 1 });
    assert.deepEqual(argumentKey(args, "E"), { arg: args[1], step: -1 });
    assert.equal(argumentKey(args, "x"), null);
    assert.equal(argumentKey(args, "-"), null);
});

test("stepArgument wraps round the choices", () => {
    const effort = readArguments(ARGS)[1];
    assert.equal(stepArgument(effort, "high", 1), "max");
    assert.equal(stepArgument(effort, "max", 1), "low");
    assert.equal(stepArgument(effort, "low", -1), "max");
    assert.equal(stepArgument(effort, "gone", 1), "high");
});

test("choose keeps only the arguments changed from their default", () => {
    const [model, effort] = readArguments(ARGS);
    let chosen = choose({}, effort, "max");
    assert.deepEqual(chosen, { effort: "max" });
    chosen = choose(chosen, model, "fable");
    assert.deepEqual(chosen, { effort: "max", model: "fable" });
    assert.deepEqual(choose(chosen, effort, "high"), { model: "fable" });
});

test("checkMenu finds shared keys, long keys and entries that do nothing", () => {
    assert.deepEqual(checkMenu(menu), []);
    assert.deepEqual(checkMenu([
        { key: "a", name: "one", run: ["x"] },
        { key: "a", name: "two", run: ["y"] },
        { key: "bb", name: "long", run: ["z"] },
        { key: "c", name: "idle" },
        { key: "d", name: "both", run: ["x"], children: [{ key: "e", name: "inner" }] },
        { key: "f", name: "flat", args: ["a"], run: ["x"] },
    ]), [
        'SPC a: both "one" and "two"',
        "SPC bb (long): a key is one character",
        "SPC c (idle): needs one of run, children or bar",
        "SPC d (both): needs one of run, children or bar",
        "SPC d e (inner): needs one of run, children or bar",
        "SPC f (flat): args are for a page with children",
    ]);
});

test("the leader menu itself checks out, and reaches each plugin", () => {
    assert.deepEqual(checkMenu(MENU), []);
    const runs = JSON.stringify(MENU);
    for (const config of ["bb-new", "bb-go", "clipboard", "snippets", "chauvenity", "pick-to-bb"])
        assert.ok(runs.includes(config), config);
});

test("the walkpad page opens the panel, finishes the walk and flips the connection", () => {
    const page = pageAt(MENU, ["w"], []);
    assert.equal(page.entry.name, "walkpad");
    assert.deepEqual(page.entries.map(e => [e.key, command(e.run, {}).slice(-2).join(" ")]), [
        ["w", "toggle walkpad"],
        ["f", "walkpad finish"],
        ["c", "walkpad connect"],
    ]);
    // The same targets shell.qml's IpcHandlers answer to.
    assert.ok(page.entries.every(e => e.run.slice(0, 2).join(" ") === "qs -c" && e.run[2] === "chauvenity"));
});
