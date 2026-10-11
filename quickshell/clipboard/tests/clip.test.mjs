// Unit tests for the clipboard history overlay's logic.
//
//   node --test ~/.config/quickshell/clipboard/tests/
//
// The `cliphist list` lines below are as cliphist 0.7 prints them, binary
// entry included.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DETAIL_LIMIT,
    parseList,
    cssColor,
    colorFormats,
    linkHost,
    filterEntries,
    categoryCounts,
    highlight,
    parseDetail,
    textStats,
    describe,
    rowTag,
    parseProbe,
    isTerminal,
    pasteKeys,
    thumbPath,
    humanBytes,
} from "../clip.mjs";

const LIST = [
    "9\t<b>hi</b> & \"q\"",
    "8\t\u0000\u0001\u0002binarystuff",
    "7\t[[ binary data 6 KiB jpeg 256x256 ]]",
    "6\t[[ binary data 216 KiB png 1024x1024 ]]",
    "5\t#62a0ea",
    "4\thttps://github.com/sentriz/cliphist",
    "3\t~/.config/niri/config.kdl",
    "2\trgb(98 160 234 / 50%)",
    "1\thello world again",
    "",
].join("\n");

test("parseList keeps cliphist's order and classifies each entry", () => {
    const entries = parseList(LIST);
    assert.deepEqual(entries.map(e => [e.id, e.kind]), [
        ["9", "text"], ["8", "text"], ["7", "image"], ["6", "image"], ["5", "color"],
        ["4", "link"], ["3", "path"], ["2", "color"], ["1", "text"],
    ]);
});

test("parseList reads an image's format, size and dimensions", () => {
    const png = parseList(LIST).find(e => e.id === "6");
    assert.equal(png.format, "png");
    assert.equal(png.mime, "image/png");
    assert.equal(png.size, "216 KiB");
    assert.equal(png.width, 1024);
    assert.equal(png.height, 1024);
});

test("parseList drops control characters from a binary preview", () => {
    assert.equal(parseList(LIST).find(e => e.id === "8").preview, "binarystuff");
});

test("text entries are handed back as plain text", () => {
    assert.equal(parseList(LIST).find(e => e.id === "9").mime, "text/plain;charset=utf-8");
});

test("parseList skips blank and malformed lines", () => {
    assert.deepEqual(parseList("\nnot an entry\nabc\tx\n12\tok\n").map(e => e.id), ["12"]);
    assert.deepEqual(parseList(""), []);
    assert.deepEqual(parseList(undefined), []);
});

test("a preview that only contains a URL-like word is still text", () => {
    assert.equal(parseList("1\tsee https://example.com").at(0).kind, "text");
    assert.equal(parseList("1\t/").at(0).kind, "text");
});

test("cssColor puts alpha first, as QML spells colours", () => {
    assert.equal(cssColor("#62a0ea"), "#ff62a0ea");
    assert.equal(cssColor("#62A0EA80"), "#8062a0ea");
    assert.equal(cssColor("#fa0"), "#ffffaa00");
    assert.equal(cssColor("#fa08"), "#88ffaa00");
    assert.equal(cssColor("rgb(98, 160, 234)"), "#ff62a0ea");
    assert.equal(cssColor("rgba(98,160,234,0.5)"), "#8062a0ea");
    assert.equal(cssColor("rgb(98 160 234 / 50%)"), "#8062a0ea");
});

test("colorFormats spells a colour back the CSS way", () => {
    assert.deepEqual(colorFormats("#ff62a0ea"), { hex: "#62a0ea", rgb: "rgb(98 160 234)" });
    assert.deepEqual(colorFormats(cssColor("rgb(246 97 81 / 90%)")), { hex: "#f66151e6", rgb: "rgb(246 97 81 / 90%)" });
});

test("cssColor rejects what is not a colour", () => {
    for (const text of ["#62a0e", "#ggg", "rgb(300, 0, 0)", "rgba(1,2,3,2)", "62a0ea", "#62a0ea is blue"])
        assert.equal(cssColor(text), null, text);
});

test("linkHost names the site, without credentials", () => {
    assert.equal(linkHost("https://github.com/sentriz/cliphist"), "github.com");
    assert.equal(linkHost("https://user:pw@example.org:8443/x?y#z"), "example.org:8443");
    assert.equal(linkHost("mailto:someone@example.com"), "example.com");
});

test("filterEntries needs every word, in any order, case-insensitively", () => {
    const entries = parseList(LIST);
    assert.deepEqual(filterEntries(entries, "AGAIN hello", "all").map(e => e.id), ["1"]);
    assert.deepEqual(filterEntries(entries, "hello nope", "all"), []);
    assert.equal(filterEntries(entries, "  ", "all"), entries);
});

test("filterEntries matches a kind by name", () => {
    const entries = parseList(LIST);
    assert.deepEqual(filterEntries(entries, "image", "all").map(e => e.id), ["7", "6"]);
    assert.deepEqual(filterEntries(entries, "link", "all").map(e => e.id), ["4"]);
});

test("filterEntries narrows to a tab, paths counting as text", () => {
    const entries = parseList(LIST);
    assert.deepEqual(filterEntries(entries, "", "text").map(e => e.id), ["9", "8", "3", "1"]);
    assert.deepEqual(filterEntries(entries, "", "color").map(e => e.id), ["5", "2"]);
    assert.deepEqual(filterEntries(entries, "png", "image").map(e => e.id), ["6"]);
});

test("categoryCounts counts what each tab would show for the query", () => {
    const entries = parseList(LIST);
    assert.deepEqual(categoryCounts(entries, ""), { all: 9, text: 4, link: 1, image: 2, color: 2 });
    assert.deepEqual(categoryCounts(entries, "jpeg"), { all: 1, text: 0, link: 0, image: 1, color: 0 });
});

test("highlight escapes the clipboard's markup", () => {
    assert.equal(highlight('<img src="https://x">', "", "#fff"), "&lt;img src=&quot;https://x&quot;&gt;");
});

test("highlight marks every occurrence of every word, merging overlaps", () => {
    assert.equal(
        highlight("Hello <hello>", "hell lo", "#62a0ea"),
        '<font color="#62a0ea"><b>Hello</b></font> &lt;<font color="#62a0ea"><b>hello</b></font>&gt;');
});

test("parseDetail splits the byte count from the text and flags a cut", () => {
    assert.deepEqual(parseDetail("12\nhello\nworld\n"), { total: 12, text: "hello\nworld\n", truncated: false });
    assert.equal(parseDetail((DETAIL_LIMIT + 1) + "\n" + "x").truncated, true);
    assert.deepEqual(parseDetail(""), { total: 0, text: "", truncated: false });
});

test("textStats counts characters, lines and words", () => {
    assert.deepEqual(textStats("hello\nworld again\n"), { chars: 18, lines: 2, words: 3 });
    assert.deepEqual(textStats(""), { chars: 0, lines: 0, words: 0 });
    assert.deepEqual(textStats("é🙂"), { chars: 2, lines: 1, words: 1 });
});

test("describe says what the preview pane shows", () => {
    const entries = parseList(LIST);
    const text = entries.find(e => e.id === "1");
    assert.equal(describe(text, null), "Text");
    assert.equal(describe(text, { id: "1", text: "hello world\nagain", total: 17, truncated: false }),
        "Text · 17 chars · 2 lines · 3 words");
    assert.equal(describe(text, { id: "1", text: "x", total: 3 * 1024 * 1024, truncated: true }),
        "Text · 3.0 MiB, first 64 KiB shown · 1 word");
    assert.equal(describe(entries.find(e => e.id === "6"), null), "Image · PNG · 1024 × 1024 · 216 KiB");
    assert.equal(describe(entries.find(e => e.id === "4"), { id: "4", text: "https://github.com/x", total: 20 }),
        "Link · 20 chars");
    assert.equal(describe(entries.find(e => e.id === "5"), { id: "5", text: "#62a0ea", total: 7 }), "Colour");
});

test("rowTag tags everything but plain text", () => {
    const tags = parseList(LIST).map(rowTag);
    assert.deepEqual(tags, ["", "", "jpeg 256×256", "png 1024×1024", "", "github.com", "path", "", ""]);
});

test("humanBytes groups thousands and picks a unit", () => {
    assert.equal(humanBytes(1), "1 byte");
    assert.equal(humanBytes(1000), "1,000 bytes");
    assert.equal(humanBytes(1536), "1.5 KiB");
    assert.equal(humanBytes(65536), "64 KiB");
});

test("parseProbe reads niri's focused output and window", () => {
    const output = '{"name":"eDP-1","logical":{"x":0,"y":0},"modes":[]}\n{"id":3,"app_id":"com.mitchellh.ghostty","title":"t"}\n';
    assert.deepEqual(parseProbe(output), { output: "eDP-1", appId: "com.mitchellh.ghostty" });
    assert.deepEqual(parseProbe('{"name":"DP-2","logical":{}}\nnull\n'), { output: "DP-2", appId: "" });
    assert.deepEqual(parseProbe("Error: niri is not running\n"), { output: "", appId: "" });
});

test("terminals get Ctrl+Shift+V, everything else Ctrl+V", () => {
    for (const appId of ["com.mitchellh.ghostty", "kitty", "Alacritty", "foot", "org.gnome.Ptyxis",
        "org.gnome.Console", "org.wezfurlong.wezterm", "gnome-terminal-server", "xterm"])
        assert.equal(isTerminal(appId), true, appId);
    for (const appId of ["app.zen_browser.zen", "firefox", "code", "org.gnome.TextEditor", "", null])
        assert.equal(isTerminal(appId), false, String(appId));
    assert.deepEqual(pasteKeys("kitty"), ["-M", "ctrl", "-M", "shift", "v", "-m", "shift", "-m", "ctrl"]);
    assert.deepEqual(pasteKeys("firefox"), ["-M", "ctrl", "v", "-m", "ctrl"]);
});

test("thumbPath names the cached image by id and format", () => {
    assert.equal(thumbPath("/run/user/1000/clipboard-history", parseList(LIST).find(e => e.id === "7")),
        "/run/user/1000/clipboard-history/7.jpeg");
});
