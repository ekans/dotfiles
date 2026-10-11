// Unit tests for the bb go-to overlay's logic.
//
//   node --test ~/.config/quickshell/bb-go/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    THREADS_GROUP,
    parseList,
    listError,
    age,
    allRows,
    filterRows,
    groupJump,
    openCommand,
    decide,
    findWindow,
    parseFocusedOutput,
} from "../bbgo.mjs";

const LIST = {
    threads: [
        { target: "thread:thr_a", id: "thr_a", title: "Fix the login", projectName: "bolt", unread: true, waitingOnYou: false, attentionAt: 2000 },
        { target: "thread:thr_b", id: "thr_b", title: "", projectName: null, unread: false, waitingOnYou: true, attentionAt: 1000 },
    ],
    targets: [
        { target: "sidebar:__bb__/skills", label: "Skills", group: "Sidebar" },
        { target: "sidebar:fleet/fleet", label: "Fleet", group: "Sidebar" },
        { target: "settings:keyboard", label: "Keyboard", group: "Settings" },
        { target: "settings:plugins/fleet", label: "Fleet", group: "Plugin settings" },
    ],
    sidebarReported: true,
};

test("reads bb nav list, and refuses what is not it", () => {
    const list = parseList(JSON.stringify(LIST));
    assert.equal(list.threads.length, 2);
    assert.equal(list.targets.length, 4);
    assert.equal(list.sidebarReported, true);
    assert.equal(parseList(""), null);
    assert.equal(parseList("{\"threads\": 1}"), null);
});

test("says why bb listed nothing", () => {
    assert.equal(listError('{"ok": false, "error": {"code": "x", "message": "server down"}}', "", 1), "bb: server down");
    assert.equal(listError("", "error: unknown command 'nav'\n", 1), "bb has no `nav` command: install ~/src/bb-plugins/bb-plugin-nav");
    assert.equal(listError("", "", 3), "bb exited with 3");
});

test("tells the age in the largest unit that fits", () => {
    const now = 10 * 24 * 3600000;
    assert.equal(age(now - 30000, now), "now");
    assert.equal(age(now - 5 * 60000, now), "5m");
    assert.equal(age(now - 3 * 3600000, now), "3h");
    assert.equal(age(now - 3 * 24 * 3600000, now), "3d");
});

test("puts the threads first, a thread with no title shown by its id", () => {
    const rows = allRows(parseList(JSON.stringify(LIST)));
    assert.deepEqual(rows.map(r => [r.group, r.label]), [
        [THREADS_GROUP, "Fix the login"],
        [THREADS_GROUP, "thr_b"],
        ["Sidebar", "Skills"],
        ["Sidebar", "Fleet"],
        ["Settings", "Keyboard"],
        ["Plugin settings", "Fleet"],
    ]);
    assert.equal(rows[0].unread, true);
    assert.equal(rows[1].waiting, true);
    assert.deepEqual(allRows(null), []);
});

test("filters on every word, keeping groups in order and marking where each starts", () => {
    const rows = allRows(parseList(JSON.stringify(LIST)));
    assert.deepEqual(filterRows(rows, "fleet").map(r => [r.group, r.label, r.first]), [
        ["Sidebar", "Fleet", true],
        ["Plugin settings", "Fleet", true],
    ]);
    assert.deepEqual(filterRows(rows, "fleet plugin").map(r => r.target), ["settings:plugins/fleet"]);
    // The project name is searched too.
    assert.deepEqual(filterRows(rows, "bolt").map(r => r.target), ["thread:thr_a"]);
    assert.equal(filterRows(rows, "").length, rows.length);
});

test("puts the rows starting with the query first within their group", () => {
    const rows = allRows({ threads: [], targets: [
        { target: "a", label: "Plugin marketplaces", group: "Settings" },
        { target: "b", label: "Installed plugins", group: "Settings" },
    ] });
    assert.deepEqual(filterRows(rows, "inst").map(r => r.target), ["b"]);
    assert.deepEqual(filterRows(rows, "plugin").map(r => r.target), ["a", "b"]);
    assert.deepEqual(filterRows(rows, "i").map(r => r.target), ["b", "a"]);
});

test("jumps between groups, wrapping round", () => {
    const rows = filterRows(allRows(parseList(JSON.stringify(LIST))), "");
    assert.equal(groupJump(rows, 0, 1), 2);
    assert.equal(groupJump(rows, 3, 1), 4);
    assert.equal(groupJump(rows, 5, 1), 0);
    assert.equal(groupJump(rows, 0, -1), 5);
    assert.equal(groupJump([], 0, 1), 0);
});

test("asks bb nav to open the target", () => {
    assert.deepEqual(openCommand("bb", "settings:keyboard"), ["bb", "nav", "open", "settings:keyboard", "--json"]);
});

function answer(tabs) {
    return JSON.stringify({ target: "x", path: "/x", url: "http://127.0.0.1:38886/x", delivered: tabs.filter(t => t.opened).length, tabs });
}

test("raises the window of a tab on screen that went", () => {
    const stdout = answer([
        { title: "bb", visible: false, opened: true, error: null },
        { title: "Settings", visible: true, opened: true, error: null },
    ]);
    assert.deepEqual(decide(stdout, "", 0), { action: "raise", title: "Settings" });
});

test("says when only background tabs went", () => {
    assert.deepEqual(decide(answer([{ title: "bb", visible: false, opened: true, error: null }]), "", 0), { action: "background" });
});

test("opens a tab when none is connected", () => {
    assert.deepEqual(decide(answer([]), "", 0), { action: "browse", url: "http://127.0.0.1:38886/x" });
});

test("reports why no tab went, and bb's refusals", () => {
    const stdout = answer([{ title: "bb", visible: true, opened: false, error: "no sidebar item gone/x in this tab" }]);
    assert.deepEqual(decide(stdout, "", 0), { error: "bb did not go there: no sidebar item gone/x in this tab" });
    assert.deepEqual(decide('{"ok": false, "error": {"code": "invalid_target", "message": "not a target: x"}}', "", 1), { error: "bb: not a target: x" });
});

test("finds the window whose title starts with the tab's", () => {
    const titles = ["Workflow runs — Mozilla Firefox", "Settings — Zen Browser"];
    assert.equal(findWindow(titles, "Settings"), 1);
    assert.equal(findWindow(titles, "Skills"), -1);
    assert.equal(findWindow(titles, ""), -1);
});

test("reads niri's focused output", () => {
    assert.equal(parseFocusedOutput('{"name": "DP-1"}'), "DP-1");
    assert.equal(parseFocusedOutput("nope"), "");
});
