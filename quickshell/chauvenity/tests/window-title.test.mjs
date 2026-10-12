// Unit tests for the focused window's title in the bar's centre.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import { withoutAppName } from "../window-title.mjs";

test("withoutAppName drops the app's name after an em dash", () => {
    assert.equal(
        withoutAppName("PR #42 · ekans/dotfiles — Zen Browser", "Zen Browser", "app.zen_browser.zen"),
        "PR #42 · ekans/dotfiles");
});

test("withoutAppName drops only the last segment of several", () => {
    assert.equal(
        withoutAppName("shell.qml - dotfiles - Visual Studio Code", "Visual Studio Code", "com.microsoft.VSCode"),
        "shell.qml - dotfiles");
});

test("withoutAppName matches the app's name as whole words", () => {
    assert.equal(withoutAppName("Inbox - Mozilla Firefox", "Firefox", "org.mozilla.firefox"), "Inbox");
    assert.equal(withoutAppName("Docs | Firefoxy", "Firefox", ""), "Docs | Firefoxy");
});

test("withoutAppName falls back to the last part of the app id", () => {
    assert.equal(withoutAppName("Inbox – Firefox", "", "org.mozilla.firefox"), "Inbox");
    assert.equal(withoutAppName("Inbox | firefox", undefined, "org.mozilla.firefox"), "Inbox");
});

test("withoutAppName keeps a title whose last segment is something else", () => {
    assert.equal(withoutAppName("Notes - code review", "Visual Studio Code", "com.microsoft.VSCode"), "Notes - code review");
    assert.equal(withoutAppName("~/src/dotfiles", "Ghostty", "com.mitchellh.ghostty"), "~/src/dotfiles");
});

test("withoutAppName never empties a title", () => {
    assert.equal(withoutAppName("Zen Browser", "Zen Browser", "app.zen_browser.zen"), "Zen Browser");
    assert.equal(withoutAppName(" - Zen Browser", "Zen Browser", "app.zen_browser.zen"), " - Zen Browser");
    assert.equal(withoutAppName("", "Zen Browser", "app.zen_browser.zen"), "");
});
