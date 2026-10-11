// Unit tests for Mod+E's translator.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    MODES, countWords, lookupTerms, pickedMode, modeKey, readReply, readProbe,
    stripHtml, glossesOf, readEntry, lemmaOf, flatGlosses, readFix, diffChanges, changesOf,
    applyChanges, diffMarkup, changeMarkup, preview, describe, readLookup, modeHint, wordMissing,
} from "../translate.mjs";

const FR_PARAGRAPH = "Suite à notre échange de ce matin, je vous confirme que la mise en production est décalée à jeudi. "
    + "L’équipe a besoin de deux jours de plus pour finir les tests de non-régression.";
const FRENGLISH = "I take the opportunity of this mail to remind you that we must absolutely make a point on the "
    + "planning before the end of the week, because actually we are late on several subjects.";

test("countWords counts what whitespace separates", () => {
    assert.equal(countWords(""), 0);
    assert.equal(countWords("  \n "), 0);
    assert.equal(countWords("débrouillard"), 1);
    assert.equal(countWords(" faire  le\npoint "), 3);
});

test("lookupTerms takes a word or a set phrase, never a sentence", () => {
    assert.deepEqual(lookupTerms("débrouillard"), ["débrouillard"]);
    assert.deepEqual(lookupTerms("« Débrouillard, »"), ["Débrouillard", "débrouillard"]);
    assert.deepEqual(lookupTerms("faire  le point"), ["faire le point"]);
    assert.deepEqual(lookupTerms("avoir du pain sur la planche"), []);
    assert.deepEqual(lookupTerms("du pain sur la planche"), ["du pain sur la planche"]);
    assert.deepEqual(lookupTerms("Bon. On y va"), []);
    assert.deepEqual(lookupTerms(FR_PARAGRAPH), []);
    assert.deepEqual(lookupTerms("  "), []);
});

test("the chooser offers every mode, always in the same order", () => {
    assert.deepEqual(MODES.map(m => m.key), ["w", "p", "f"]);
});

test("modeKey takes a mode by its name or its key", () => {
    assert.equal(modeKey("word"), "w");
    assert.equal(modeKey(" Paragraph "), "p");
    assert.equal(modeKey("f"), "f");
    assert.equal(modeKey("fixes"), "");
    assert.equal(modeKey(""), "");
    assert.equal(modeKey(undefined), "");
});

test("pickedMode takes w, p or f, whatever the case, and nothing else", () => {
    assert.equal(pickedMode("w"), "w");
    assert.equal(pickedMode("P"), "p");
    assert.equal(pickedMode("f"), "f");
    assert.equal(pickedMode("x"), "");
    assert.equal(pickedMode(""), "");
    assert.equal(pickedMode("\r"), "");
});

test("readReply splits the status line from the answer", () => {
    assert.deepEqual(readReply("ok\nHello\nthere"), { status: "ok", body: "Hello\nthere" });
    assert.deepEqual(readReply("none"), { status: "none", body: "" });
    assert.deepEqual(readReply(""), { status: "", body: "" });
});

test("readLookup tells which term an answer is for", () => {
    assert.deepEqual(readLookup("found\nfaire le point\n{\"fr\":[]}"), { status: "found", asked: "faire le point", body: "{\"fr\":[]}" });
    assert.deepEqual(readLookup("none\nzzqxv\n"), { status: "none", asked: "zzqxv", body: "" });
    assert.deepEqual(readLookup("none\nzzqxv"), { status: "none", asked: "zzqxv", body: "" });
});

test("readProbe reads the focused window and the primary selection", () => {
    assert.deepEqual(readProbe(`{"id":42,"app_id":"com.mitchellh.ghostty","title":"nvim"}\n\x1e\nfaire le point`),
        { windowId: "42", terminal: true, selection: "faire le point" });
    assert.deepEqual(readProbe(`{"id":7,"app_id":"app.zen_browser.zen"}\x1e\n`), { windowId: "7", terminal: false, selection: "" });
    assert.deepEqual(readProbe("null\n\x1e\nmot"), { windowId: "", terminal: false, selection: "mot" });
    assert.deepEqual(readProbe(""), { windowId: "", terminal: false, selection: "" });
});

// As https://en.wiktionary.org/api/rest_v1/page/definition/<term> answers.
const STYLE = `<style data-mw-deduplicate="TemplateStyles:r1">.mw-parser-output .object-usage-tag{font-style:italic}</style>`;
const ENTRIES = {
    "débrouillard": { fr: [{ partOfSpeech: "Adjective", language: "French", definitions: [{
        definition: `<a rel="mw:WikiLink" href="/wiki/resourceful">resourceful</a>, <a href="/wiki/self-reliant">self-reliant</a>, able to <a href="/wiki/cope">cope</a>, crafty, wily`,
    }] }] },
    "faire le point": { fr: [{ partOfSpeech: "Verb", language: "French", definitions: [{
        definition: `to <a href="/wiki/review">review</a>, to take stock of, to get a fix on ${STYLE}<span>[</span><i>with</i> <b>sur</b> <small>‘something, e.g. a situation’</small><span>]</span>`,
        parsedExamples: [{ example: "faire le point sur la situation", translation: "to review the situation" }],
    }] }] },
    "décalée": { fr: [{ partOfSpeech: "Participle", definitions: [{ definition: `feminine singular of <a href="/wiki/décalé">décalé</a>` }] }] },
    "décale": { fr: [{ partOfSpeech: "Verb", definitions: [
        { definition: "inflection of <i>décaler</i>:\n<ol><li>first/third-person singular present indicative/subjunctive</li></ol>" },
        { definition: "first/third-person singular present indicative/subjunctive" },
        { definition: "second-person singular imperative" },
    ] }] },
    "régime": { fr: [{ partOfSpeech: "Noun", definitions: [{ definition: "a form of government, (politics) regime" }, { definition: "diet" }] }] },
    "only english": { en: [{ partOfSpeech: "Noun", definitions: [{ definition: "a thing" }] }] },
};

test("stripHtml drops tags, the inlined CSS, and decodes entities", () => {
    assert.equal(stripHtml(`to <a href="x">review</a>${STYLE} &amp; &#233;tat&nbsp;!`), "to review & état !");
});

test("glossesOf splits synonyms and drops labels and usage notes", () => {
    assert.deepEqual(glossesOf("resourceful, self-reliant, able to cope, crafty, wily"),
        ["resourceful", "self-reliant", "able to cope", "crafty", "wily"]);
    assert.deepEqual(glossesOf("to review, to take stock of, to get a fix on [with sur ‘something, e.g. a situation’]"),
        ["to review", "to take stock of", "to get a fix on"]);
    assert.deepEqual(glossesOf("(colloquial) to have bread on the table (to have enough to live on)"),
        ["to have bread on the table"]);
    assert.deepEqual(glossesOf("(archaic)"), []);
});

test("readEntry reads the French senses, with an example when there is one", () => {
    const [sense] = readEntry(JSON.stringify(ENTRIES["faire le point"]));
    assert.equal(sense.pos, "verb");
    assert.deepEqual(sense.glosses, ["to review", "to take stock of", "to get a fix on"]);
    assert.deepEqual(sense.example, { fr: "faire le point sur la situation", en: "to review the situation" });
    assert.equal(readEntry(JSON.stringify(ENTRIES["débrouillard"]))[0].pos, "adj.");
    assert.deepEqual(readEntry(JSON.stringify(ENTRIES["only english"])), []);
    assert.deepEqual(readEntry("not json"), []);
});

test("lemmaOf follows a form to its lemma, and only a form", () => {
    assert.equal(lemmaOf(readEntry(JSON.stringify(ENTRIES["décalée"]))), "décalé");
    assert.equal(lemmaOf(readEntry(JSON.stringify(ENTRIES["décale"]))), "décaler");
    assert.equal(lemmaOf(readEntry(JSON.stringify(ENTRIES["régime"]))), "");
    assert.equal(lemmaOf(readEntry(JSON.stringify(ENTRIES["débrouillard"]))), "");
    assert.equal(lemmaOf([]), "");
});

test("flatGlosses lists every gloss with its sense, for the arrows", () => {
    const senses = readEntry(JSON.stringify(ENTRIES["régime"]));
    assert.deepEqual(flatGlosses(senses).map(g => `${g.sense}:${g.text}`),
        ["0:a form of government", "0:regime", "1:diet"]);
});

const FIXED = "I’m writing to remind you that we really need to go over the schedule before the end of the week, "
    + "because we are currently behind on several topics.";
const NOTES = [
    { from: "I take the opportunity of this mail", why: "« je profite de ce mail ».", kind: "gallicism" },
    { from: "make a point on", why: "« faire le point sur ».", kind: "gallicism" },
    { from: "planning", why: "« le planning » is the schedule.", kind: "faux ami" },
    { from: "actually", why: "actually ≠ actuellement.", kind: "faux ami" },
    { from: "nowhere in the text", why: "lost", kind: "style" },
];
const FIX_ANSWER = JSON.stringify({ fixed: FIXED, notes: NOTES });

test("readFix reads the fixed text and the notes, fenced or not", () => {
    assert.equal(readFix(FIX_ANSWER).fixed, FIXED);
    assert.equal(readFix(FIX_ANSWER).notes.length, 5);
    assert.equal(readFix("```json\n" + FIX_ANSWER + "\n```").fixed, FIXED);
    assert.deepEqual(readFix(`{"fixed":"x","notes":[{"from":"","why":"a"},{"from":"b"},"c"]}`),
        { fixed: "x", notes: [{ from: "b", why: "", kind: "" }] });
    assert.deepEqual(readFix(`{"fixed":"x"}`), { fixed: "x", notes: [] });
    assert.equal(readFix("Sorry, I can't"), null);
    assert.equal(readFix(`{"hunks":[]}`), null);
});

test("diffChanges cuts the fix into word changes, one word apart taken as one", () => {
    const parts = diffChanges(FRENGLISH, FIXED, NOTES);
    assert.deepEqual(changesOf(parts).map(c => [c.from, c.to]), [
        ["I take the opportunity of this mail", "I’m writing"],
        ["must absolutely make a point on the planning", "really need to go over the schedule"],
        ["actually ", ""],
        ["late ", "currently behind "],
        ["subjects", "topics"],
    ]);
});

test("diffChanges gives each change the notes on what it changes", () => {
    const changes = changesOf(diffChanges(FRENGLISH, FIXED, NOTES));
    assert.equal(changes[0].kind, "gallicism");
    assert.equal(changes[1].why, "« faire le point sur ». · « le planning » is the schedule.");
    assert.equal(changes[2].why, "actually ≠ actuellement.");
    assert.equal(changes[4].why, "");
});

test("applyChanges makes the fix, keeping what you kept as it was", () => {
    const parts = diffChanges(FRENGLISH, FIXED, NOTES);
    assert.equal(applyChanges(parts, []), FIXED);
    assert.equal(applyChanges(parts, [0, 1, 2, 3, 4]), FRENGLISH);
    assert.equal(applyChanges(parts, [4]), FIXED.replace("topics", "subjects"));
});

test("diffChanges finds nothing to change in a text already right", () => {
    assert.deepEqual(changesOf(diffChanges("one two three", "one two three", [])), []);
    assert.deepEqual(changesOf(diffChanges("We meet in monday.", "We meet on Monday.", [])).map(c => [c.from, c.to]),
        [["in monday", "on Monday"]]);
    assert.deepEqual(changesOf(diffChanges("It is very very good", "It is very good", [])).map(c => [c.from, c.to]),
        [["very ", ""]]);
});

test("diffMarkup escapes the selection and marks the current change", () => {
    const parts = diffChanges("a <b> & c", "a <i> & c", []);
    const colors = { good: "#0f0", bad: "#f00" };
    assert.equal(diffMarkup(parts, 0, [], colors),
        `a &lt;<u><s><font color="#f00">b</font></s> <font color="#0f0">i</font></u>&gt; &amp; c`);
    assert.equal(diffMarkup(parts, -1, [0], colors), "a &lt;b&gt; &amp; c");
});

test("changeMarkup shows a change, a deletion, an addition, and a kept one", () => {
    const colors = { good: "#0f0", bad: "#f00" };
    assert.equal(changeMarkup({ from: "a<b", to: "c" }, false, colors), `<s><font color="#f00">a&lt;b</font></s> → <font color="#0f0">c</font>`);
    assert.equal(changeMarkup({ from: "actually ", to: "" }, false, colors), `<s><font color="#f00">actually</font></s>`);
    assert.equal(changeMarkup({ from: "", to: "the" }, false, colors), `<font color="#0f0">+ the</font>`);
    assert.equal(changeMarkup({ from: "planning", to: "schedule" }, true, colors), "planning");
});

test("preview and describe say what the chooser works on", () => {
    assert.equal(preview("  a\nb  ", 10), "a b");
    assert.equal(preview("abcdefghij", 5), "abcd…");
    assert.equal(describe("débrouillard"), "“débrouillard” · 1 word");
    assert.equal(describe(FR_PARAGRAPH), "“Suite à notre échange de ce matin, je v…” · 33 words");
    assert.equal(describe("  "), "nothing selected · w lets you type a word");
});

test("modeHint says what each mode would do with the selection", () => {
    const glosses = flatGlosses([{ pos: "adj.", text: "", glosses: ["resourceful", "streetwise"] }]);
    const selected = { text: "débrouillard", selected: true, lookup: "found", glosses };
    assert.equal(modeHint("w", selected), "resourceful · streetwise");
    assert.equal(modeHint("w", { ...selected, lookup: "pending" }), "looking it up in Wiktionary…");
    assert.equal(modeHint("w", { ...selected, lookup: "none" }), "no French entry in Wiktionary");
    assert.equal(modeHint("w", { ...selected, lookup: "" }), "a sentence, not a word or a set phrase");
    assert.equal(modeHint("p", selected), "French into English, to paste over the selection");
    assert.equal(modeHint("p", { ...selected, selected: false }), "French into English, to copy");
    assert.match(modeHint("f", selected), /simple/);
});

test("modeHint with nothing selected: w types a word, p and f have nothing", () => {
    const nothing = { text: " ", selected: false, lookup: "", glosses: [] };
    assert.equal(modeHint("w", nothing), "type a French word or set phrase");
    assert.equal(modeHint("p", nothing), "nothing selected");
    assert.equal(modeHint("f", nothing), "nothing selected");
});

test("wordMissing says why there are no senses", () => {
    assert.equal(wordMissing("unreachable", "x"), "Wiktionary is unreachable.");
    assert.equal(wordMissing("none", "tartempion"), "No French entry for “tartempion” in Wiktionary.");
    assert.equal(wordMissing("", FR_PARAGRAPH), "A sentence: w looks up a word or a set phrase.");
});
