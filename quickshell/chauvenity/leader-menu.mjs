// What Super+Space leads to: the leader menu's keys (Leader.qml), in the
// order its pages show them. leader.mjs says what an entry can hold; Quickshell
// reloads the bar when this file is saved, and tests/leader.test.mjs checks it.
//
// Every pick runs a command once the menu has given the keyboard back, so a
// plugin is reached the way its niri bind reaches it, and those binds
// (Mod+N, Mod+G, Mod+T, …) still work on their own.

// `qs -c <config> ipc call <target> <function> <args…>`
function qs(config, target, fn) {
    return ["qs", "-c", config, "ipc", "call", target, fn].concat(Array.prototype.slice.call(arguments, 3));
}

export const MENU = [
    { key: "b", name: "bb", args: qs("bb-new", "bbnew", "choices"), children: [
        // "" leaves a setting as bb-new has it; a project "?" opens its list.
        { key: "n", name: "new thread", run: qs("bb-new", "bbnew", "openWith", "{model}", "{effort}", "") },
        { key: "p", name: "new thread in a project…", run: qs("bb-new", "bbnew", "openWith", "{model}", "{effort}", "?") },
        { key: "g", name: "go to…", run: qs("bb-go", "bbgo", "toggle") },
        { key: "a", name: "ask about the screen", run: ["sh", "-c", "exec \"$HOME/.local/bin/pick-to-bb\""] },
    ] },
    { key: "v", name: "clipboard", run: qs("clipboard", "clipboard", "toggle") },
    { key: "s", name: "snippets", children: [
        { key: "s", name: "insert a snippet", run: qs("snippets", "snippets", "toggle") },
        { key: "c", name: "capture the selection", run: qs("snippets", "snippets", "capture") },
    ] },
    { key: "t", name: "translate", children: [
        { key: "w", name: "word", run: qs("chauvenity", "translate", "run", "word") },
        { key: "p", name: "paragraph", run: qs("chauvenity", "translate", "run", "paragraph") },
        { key: "f", name: "fix the English", run: qs("chauvenity", "translate", "run", "fix") },
    ] },
    { key: "c", name: "caffeine", run: qs("chauvenity", "caffeine", "toggle") },
    { key: "o", name: "bar panel", bar: qs("chauvenity", "bar", "toggle", "{item}") },
    { key: "h", name: "bar hints", run: qs("chauvenity", "bar", "hints") },
    { key: "?", name: "keyboard shortcuts", run: qs("chauvenity", "keys", "toggle") },
];
