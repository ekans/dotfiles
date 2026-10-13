// Unit tests for the notification island, the bar's bell and its panel.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    URGENCY,
    plainText,
    firstLine,
    popupDuration,
    popsUp,
    ageLabel,
    countLabel,
    iconSource,
    defaultAction,
    buttonActions,
} from "../notifications.mjs";

test("plainText: drops markup, keeps line breaks, decodes entities", () => {
    assert.equal(plainText("<b>Léa</b> said <i>hi</i>"), "Léa said hi");
    assert.equal(plainText("one<br>two<br/>three"), "one\ntwo\nthree");
    assert.equal(plainText('<a href="https://x">link</a> &amp; &lt;tag&gt; &quot;q&quot; &#39;s&#39;'), "link & <tag> \"q\" 's'");
    assert.equal(plainText('<img src="https://tracker.example/p.png" alt="pic"/>after'), "after");
    assert.equal(plainText("  padded \n"), "padded");
    assert.equal(plainText(""), "");
    assert.equal(plainText(undefined), "");
});

test("plainText: plain text that only looks like markup stays", () => {
    assert.equal(plainText("Bob <bob@example.com>"), "Bob <bob@example.com>");
    assert.equal(plainText("if x < 3 and y > 2"), "if x < 3 and y > 2");
    assert.equal(plainText("Re: <urgent> fix"), "Re: <urgent> fix");
    assert.equal(plainText("<abbr>ok</abbr>"), "<abbr>ok</abbr>");
    assert.equal(plainText("<U>under</U> <A HREF='x'>a</A>"), "under a");
    assert.equal(plainText('<span foreground="red">Hi</span> <strong>there</strong>'), "Hi there");
    assert.equal(plainText("one</br>two"), "one\ntwo");
});

test("plainText: a character reference past Unicode stays as written", () => {
    assert.equal(plainText("&#99999999; tail"), "&#99999999; tail");
    assert.equal(plainText("&#xFFFFFFF;"), "&#xFFFFFFF;");
    assert.equal(plainText("&#x1F600;"), "\u{1F600}");
});

test("firstLine: the first line with text in it", () => {
    assert.equal(firstLine("\n\n  hello \nworld"), "hello");
    assert.equal(firstLine("single"), "single");
    assert.equal(firstLine(""), "");
});

test("popupDuration: critical stays, the app's timeout is clamped, else by urgency", () => {
    assert.equal(popupDuration(URGENCY.Critical, 5000), 0);
    assert.equal(popupDuration(URGENCY.Normal, 8000), 8000);
    assert.equal(popupDuration(URGENCY.Normal, 500), 3000);
    assert.equal(popupDuration(URGENCY.Normal, 600000), 20000);
    // -1 asks for the server's default, 0 for "never": a popup still goes,
    // the notification stays in the panel.
    assert.equal(popupDuration(URGENCY.Normal, -1), 6000);
    assert.equal(popupDuration(URGENCY.Normal, 0), 6000);
    assert.equal(popupDuration(URGENCY.Low, -1), 4000);
});

test("popsUp: do-not-disturb lets only critical through", () => {
    assert.equal(popsUp(URGENCY.Normal, false), true);
    assert.equal(popsUp(URGENCY.Low, false), true);
    assert.equal(popsUp(URGENCY.Normal, true), false);
    assert.equal(popsUp(URGENCY.Low, true), false);
    assert.equal(popsUp(URGENCY.Critical, true), true);
});

test("ageLabel: now, minutes, hours, yesterday, then the date", () => {
    const now = new Date(2026, 9, 7, 14, 32);
    const ago = ms => new Date(now.getTime() - ms);
    assert.equal(ageLabel(ago(20 * 1000), now), "now");
    assert.equal(ageLabel(ago(5 * 60 * 1000), now), "5 min");
    assert.equal(ageLabel(ago(3 * 3600 * 1000), now), "3 h");
    assert.equal(ageLabel(new Date(2026, 9, 6, 23, 50), now), "yesterday");
    assert.equal(ageLabel(new Date(2026, 9, 2, 9, 0), now), "2 Oct");
    // A clock that went backwards is not "in the future".
    assert.equal(ageLabel(new Date(now.getTime() + 60 * 1000), now), "now");
    assert.equal(ageLabel(null, now), "");
});

test("ageLabel: hours stop at midnight, after which it is yesterday", () => {
    const now = new Date(2026, 9, 7, 1, 0);
    assert.equal(ageLabel(new Date(2026, 9, 6, 22, 0), now), "yesterday");
    assert.equal(ageLabel(new Date(2026, 9, 7, 0, 10), now), "50 min");
});

test("countLabel: nothing for none, capped at 99+", () => {
    assert.equal(countLabel(0), "");
    assert.equal(countLabel(3), "3");
    assert.equal(countLabel(99), "99");
    assert.equal(countLabel(250), "99+");
});

test("iconSource: the image first, then the app icon as a path or a theme name", () => {
    assert.deepEqual(iconSource("image://qsimage/12", "slack"), { source: "image://qsimage/12", icon: "" });
    assert.deepEqual(iconSource("/tmp/avatar.png", ""), { source: "file:///tmp/avatar.png", icon: "" });
    assert.deepEqual(iconSource("", "file:///usr/share/icons/x.svg"), { source: "file:///usr/share/icons/x.svg", icon: "" });
    assert.deepEqual(iconSource("", "/usr/share/pixmaps/x.png"), { source: "file:///usr/share/pixmaps/x.png", icon: "" });
    assert.deepEqual(iconSource("", "org.mozilla.firefox"), { source: "", icon: "org.mozilla.firefox" });
    assert.deepEqual(iconSource("", ""), { source: "", icon: "" });
});

test("defaultAction and buttonActions: the default is the click, the rest are buttons", () => {
    const actions = [
        { identifier: "default", text: "Open" },
        { identifier: "reply", text: "Reply" },
        { identifier: "mute", text: "" },
    ];
    assert.equal(defaultAction(actions).identifier, "default");
    assert.deepEqual(buttonActions(actions).map(a => a.identifier), ["reply"]);
    assert.equal(defaultAction([]), null);
    assert.deepEqual(buttonActions(null), []);
});
