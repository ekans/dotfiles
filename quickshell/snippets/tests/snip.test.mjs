// Unit tests for the snippet overlay's logic.
//
//   node --test ~/.config/quickshell/snippets/tests/
//
// Dates are built in local time, as the overlay formats them.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    FRESH_MS,
    SEPARATOR,
    parseListing,
    parseSnippet,
    parseTemplate,
    parsePlaceholder,
    splitFrontMatter,
    findSnippet,
    variables,
    extract,
    makeContext,
    trustSelection,
    prepare,
    renderSegments,
    plainText,
    applyModifiers,
    shiftDate,
    formatDate,
    uuid,
    rank,
    frecency,
    forApp,
    styledText,
    styledSegments,
    styledSource,
    highlight,
    selectionLabel,
    describe,
    actionLabel,
    parseProbe,
    isTerminal,
    cursorLefts,
    recordUse,
    rememberValues,
    slugOf,
    keywordFor,
    trimSelection,
    appLabel,
    knownFolders,
    knownTags,
    knownApps,
    complete,
    cleanFolder,
    keywordProblem,
    listItems,
    spotFields,
    spotName,
    spotSegments,
    styledSpots,
    applySpots,
    newSnippetFile,
    parseEditPair,
    afterEdit,
    draftStem,
    renameEntry,
    eachLines,
} from "../snip.mjs";

const NOW = new Date(2026, 9, 7, 10, 45, 30).getTime();

function listing(files) {
    return Object.keys(files).map(path => SEPARATOR + path + "\n" + files[path]).join("");
}

function ctxWith(fields) {
    const probe = Object.assign({ selection: "", clipboard: "", appId: "Slack", title: "#bolt-dev" }, fields || {});
    return makeContext(probe, fields && fields.changedAt !== undefined ? fields.changedAt : NOW - 2000, NOW);
}

function fill(text, values, ctx) {
    const snippet = parseSnippet("t.md", text);
    const prep = prepare(snippet, ctx || ctxWith(), {});
    return plainText(renderSegments(snippet, Object.assign(prep.values, values || {}), prep.sources, ctx || ctxWith()));
}

const PRR = [
    "---",
    "name: Ask for PR review",
    "keyword: prr",
    "tags: [github, review]",
    "apps: [Slack]            # ranked first when Slack has focus",
    "---",
    'Hi {{who options="Alice, Bob, Chloé"}},',
    'could you review {{repo default="bolt"}}#{{pr from=selection match="\\d+"}}?',
    'It fixes {{ticket from=selection match="[A-Z]+-\\d+"}} — {{cursor}}',
    "Thanks!",
    "",
].join("\n");

// --- files ------------------------------------------------------------------

test("front matter sets the name, keyword, tags and apps; comments go", () => {
    const s = parseSnippet("work/prr.md", PRR);
    assert.equal(s.name, "Ask for PR review");
    assert.equal(s.keyword, "prr");
    assert.deepEqual(s.tags, ["github", "review"]);
    assert.deepEqual(s.apps, ["Slack"]);
    assert.equal(s.group, "work");
    assert.equal(s.id, "work/prr.md");
    assert.deepEqual(s.problems, []);
});

test("without front matter, the file name is the name and the keyword", () => {
    const s = parseSnippet("mail/sig.txt", "Best,\nDavid\n");
    assert.equal(s.name, "sig");
    assert.equal(s.keyword, "sig");
    assert.equal(s.body, "Best,\nDavid");
    assert.equal(s.header, null);
});

test("the editor's final newline is not part of the template, other newlines are", () => {
    assert.equal(parseSnippet("a.md", "one\n").body, "one");
    assert.equal(parseSnippet("a.md", "one\n\n").body, "one\n");
    assert.equal(parseSnippet("a.md", "---\nname: x\n---\nbody\r\n").body, "body");
});

test("a front matter that never closes is part of the body", () => {
    assert.deepEqual(splitFrontMatter("---\nname: x\nbody"), { header: null, body: "---\nname: x\nbody" });
    assert.deepEqual(splitFrontMatter("---\nname: x\n---"), { header: "name: x", body: "" });
});

test("flags and actions are read from the front matter", () => {
    const s = parseSnippet("a.md", "---\neach: line\naction: open\npaste: type\nsensitive: true\nlocale: fr\n---\nx");
    assert.equal(s.each, true);
    assert.equal(s.action, "open");
    assert.equal(s.typed, true);
    assert.equal(s.sensitive, true);
    assert.equal(s.locale, "fr");
});

test("unknown keys, bad values and unreadable lines are reported, not fatal", () => {
    const s = parseSnippet("a.md", "---\ntag: x\naction: shout\neach: word\nnonsense\n---\nbody");
    assert.equal(s.action, "paste");
    assert.equal(s.each, false);
    assert.equal(s.problems.length, 4);
    assert.match(s.problems.join("\n"), /unknown key "tag"/);
});

test("parseListing reads every record and links includes", () => {
    const snippets = parseListing(listing({
        "sig.md": "---\nkeyword: sig\n---\nBest,\nDavid\n",
        "mail/reply.md": 'Thanks!\n{{snippet name="sig"}}\n',
    }));
    assert.deepEqual(snippets.map(s => s.id), ["sig.md", "mail/reply.md"]);
    assert.equal(fillSnippet(snippets[1]).text, "Thanks!\nBest,\nDavid");
});

test("parseListing ignores what comes before the first record", () => {
    assert.deepEqual(parseListing("noise" + SEPARATOR + "a.md\nx").map(s => s.body), ["x"]);
    assert.deepEqual(parseListing(""), []);
    assert.deepEqual(parseListing(undefined), []);
});

function fillSnippet(snippet, ctx) {
    const c = ctx || ctxWith();
    const prep = prepare(snippet, c, {});
    return plainText(renderSegments(snippet, prep.values, prep.sources, c));
}

test("an include is one level deep, and a missing one is reported", () => {
    const snippets = parseListing(listing({
        "a.md": 'A{{snippet name="b"}}',
        "b.md": 'B{{snippet name="c"}}',
        "c.md": "C",
        "d.md": 'D{{snippet name="nope"}}',
    }));
    assert.equal(fillSnippet(snippets[0]).text, "AB");
    assert.equal(fillSnippet(snippets[3]).text, "D");
    assert.match(snippets[3].problems[0], /no such snippet/);
});

test("findSnippet goes by keyword, then path, then name", () => {
    const snippets = parseListing(listing({
        "work/prr.md": PRR,
        "sig.md": "x",
    }));
    assert.equal(findSnippet(snippets, "PRR").id, "work/prr.md");
    assert.equal(findSnippet(snippets, "work/prr").id, "work/prr.md");
    assert.equal(findSnippet(snippets, "ask for pr review").id, "work/prr.md");
    assert.equal(findSnippet(snippets, "nope"), null);
    assert.equal(findSnippet(snippets, ""), null);
});

// --- the template language ----------------------------------------------------

test("a placeholder has a name, attributes, flags and modifiers", () => {
    const p = parsePlaceholder(' who default="a | b" options="x, y" multiline | upper | Trim ');
    assert.equal(p.name, "who");
    assert.deepEqual(p.attrs, { default: "a | b", options: "x, y", multiline: true });
    assert.deepEqual(p.mods, ["upper", "trim"]);
});

test("quoted values keep a regex's backslashes; only \\\" is an escape", () => {
    const p = parsePlaceholder('t match="[A-Z]+-\\d+" default="say \\"hi\\""');
    assert.equal(p.attrs.match, "[A-Z]+-\\d+");
    assert.equal(p.attrs.default, 'say "hi"');
});

test("what does not read as a placeholder stays text", () => {
    const { tokens } = parseTemplate("{{ .Values.image }} and {{}} and {{ok}}");
    assert.deepEqual(tokens.map(t => t.type === "text" ? t.text : "<" + t.name + ">"),
        ["{{ .Values.image }} and {{}} and ", "<ok>"]);
});

test("a placeholder does not run past the end of its line", () => {
    const { tokens } = parseTemplate("{{name\n}} and {{x}}");
    assert.deepEqual(tokens.map(t => t.type), ["text", "placeholder"]);
    assert.equal(tokens[0].text, "{{name\n}} and ");
});

test("\\{{ is a literal {{", () => {
    assert.equal(fill("use \\{{name}} for a field").text, "use {{name}} for a field");
});

test("other delimiters leave {{ }} alone", () => {
    const s = parseSnippet("helm.md", '---\ndelimiters: "<% %>"\n---\nimage: {{ .Values.image }}:<%tag default="latest"%>');
    assert.equal(fillSnippet(s).text, "image: {{ .Values.image }}:latest");
});

test("unknown attributes and modifiers and bad regexes are reported", () => {
    const s = parseSnippet("a.md", '{{a colour=red}} {{b | shout}} {{c match="("}} {{d from=window}} {{date offset="soon"}}');
    assert.equal(s.problems.length, 5);
});

test("a built-in given field attributes is reported, as it is not asked", () => {
    const s = parseSnippet("a.md", '{{app default="bolt"}} {{date format="d"}} {{selection | trim}}');
    assert.deepEqual(s.problems, ['{{app}} is built in, not a field: give the field another name']);
});

test("a name used twice is one variable, with the attributes of every use", () => {
    const v = variables(parseTemplate('{{a}} {{b}} {{a default="x"}} {{date}} {{selection}}').tokens);
    assert.deepEqual(v.map(x => [x.name, x.default]), [["a", "x"], ["b", ""]]);
});

// --- filling in -------------------------------------------------------------------

test("extract takes group 1, else the whole match, else null", () => {
    assert.equal(extract("PR #1287 fixes BOLT-412", "\\d+"), "1287");
    assert.equal(extract("PR #1287 fixes BOLT-412", "#(\\d+)"), "1287");
    assert.equal(extract("PR #1287", "[A-Z]+-\\d+"), null);
    assert.equal(extract("", "x"), null);
    assert.equal(extract("text\n\n", ""), "text");
    assert.equal(extract("x", "("), null);
});

test("a fresh selection fills from=selection fields; an old one does not", () => {
    const snippet = parseSnippet("prr.md", PRR);
    const fresh = prepare(snippet, ctxWith({ selection: "PR #1287 fixes BOLT-412" }), {});
    assert.deepEqual(fresh.values, { who: "Alice", repo: "bolt", pr: "1287", ticket: "BOLT-412" });
    assert.deepEqual(fresh.sources, { who: "choice", repo: "default", pr: "selection", ticket: "selection" });

    const old = prepare(snippet, ctxWith({ selection: "PR #1287 fixes BOLT-412", changedAt: NOW - FRESH_MS - 1 }), {});
    assert.deepEqual(old.values, { who: "Alice", repo: "bolt", pr: "", ticket: "" });
});

test("a selection the watcher never saw change is old", () => {
    assert.equal(ctxWith({ selection: "x", changedAt: 0 }).fresh, false);
    assert.equal(ctxWith({ selection: "", changedAt: NOW }).fresh, false);
    assert.equal(trustSelection(ctxWith({ selection: "x", changedAt: 0 })).fresh, true);
    assert.equal(trustSelection(ctxWith({ selection: "", changedAt: 0 })).fresh, false);
});

test("the last value used comes before the default, but not for selection fields", () => {
    const snippet = parseSnippet("prr.md", PRR);
    const prep = prepare(snippet, ctxWith(), { who: "Bob", repo: "smoke", pr: "99" });
    assert.deepEqual([prep.values.who, prep.sources.who], ["Bob", "last used"]);
    assert.deepEqual([prep.values.repo, prep.sources.repo], ["smoke", "last used"]);
    assert.equal(prep.values.pr, "");
});

test("a choice only takes a remembered or default value that is one of its options", () => {
    const snippet = parseSnippet("a.md", '{{env options="dev, prod" default="prod"}}');
    assert.equal(prepare(snippet, ctxWith(), {}).values.env, "prod");
    assert.equal(prepare(snippet, ctxWith(), { env: "dev" }).values.env, "dev");
    assert.equal(prepare(snippet, ctxWith(), { env: "staging" }).values.env, "prod");
});

test("from=clipboard always applies: the clipboard is never stale", () => {
    const snippet = parseSnippet("a.md", "[{{text from=selection}}]({{url from=clipboard}})");
    const prep = prepare(snippet, ctxWith({ clipboard: "https://x.dev", changedAt: 0, selection: "old" }), {});
    assert.deepEqual(prep.values, { text: "", url: "https://x.dev" });
});

test("a multi-line value makes its field multi-line", () => {
    const snippet = parseSnippet("a.md", "{{body from=selection}}");
    assert.equal(prepare(snippet, ctxWith({ selection: "a\nb" }), {}).fields[0].multiline, true);
});

test("{{selection}} is pasted when fresh and asked when old", () => {
    assert.equal(fill("> {{selection}}", {}, ctxWith({ selection: "quote" })).text, "> quote");
    const old = ctxWith({ selection: "quote", changedAt: 0 });
    const snippet = parseSnippet("a.md", "> {{selection}}");
    const prep = prepare(snippet, old, {});
    assert.deepEqual(prep.fields.map(f => f.name), ["selection"]);
    assert.equal(plainText(renderSegments(snippet, { selection: "typed" }, {}, old)).text, "> typed");
});

test("built-ins: clipboard, app, title, dates", () => {
    const ctx = ctxWith({ clipboard: "copied" });
    assert.equal(fill("{{clipboard}}|{{app}}|{{title}}", {}, ctx).text, "copied|Slack|#bolt-dev");
    assert.equal(fill("{{date}} {{time}} {{day}}", {}, ctx).text, "2026-10-07 10:45 Wednesday");
    assert.equal(fill('{{date offset="+1d" format="EEEE d MMMM" locale="fr"}}', {}, ctx).text, "jeudi 8 octobre");
    assert.equal(fill('---\nlocale: fr\n---\n{{day}}', {}, ctx).text, "mercredi");
});

test("the same {{uuid}} slot gives the same value in the preview and the paste", () => {
    const ctx = ctxWith();
    const snippet = parseSnippet("a.md", "{{uuid}} {{uuid}}");
    const first = plainText(renderSegments(snippet, {}, {}, ctx)).text;
    const again = plainText(renderSegments(snippet, {}, {}, ctx)).text;
    assert.equal(first, again);
    const [a, b] = first.split(" ");
    assert.notEqual(a, b);
    assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("{{cursor}} marks where the caret goes; only the first counts", () => {
    const out = fill("Hi {{cursor}}!{{cursor}}\nBye");
    assert.deepEqual(out, { text: "Hi !\nBye", cursor: 3 });
    assert.equal(fill("no cursor").cursor, -1);
});

test("modifiers apply left to right", () => {
    assert.equal(fill('{{x default="  Hello World  " | trim | upper}}').text, "HELLO WORLD");
    assert.equal(applyModifiers("Fix login timeout", ["snake"]), "fix_login_timeout");
    assert.equal(applyModifiers("fixLoginTimeout", ["kebab"]), "fix-login-timeout");
    assert.equal(applyModifiers("fix login timeout", ["camel"]), "fixLoginTimeout");
    assert.equal(applyModifiers("fix login timeout", ["pascal"]), "FixLoginTimeout");
    assert.equal(applyModifiers("Été à Paris!", ["slug"]), "ete-a-paris");
    assert.equal(applyModifiers("a b&c", ["url"]), "a%20b%26c");
    assert.equal(applyModifiers('say "hi"', ["json"]), '"say \\"hi\\""');
    assert.equal(applyModifiers("it's", ["shell"]), "'it'\\''s'");
    assert.equal(applyModifiers("one\ntwo", ["firstline"]), "one");
    assert.equal(applyModifiers(" a \n b ", ["oneline"]), "a b");
    assert.equal(applyModifiers("hello wide world", ["title"]), "Hello Wide World");
    assert.equal(applyModifiers("x", ["nope"]), "x");
});

test("each: line renders once per selected line, with from=selection per line", () => {
    const text = '---\neach: line\n---\ncurl "$BOLT/subscribers/{{iccid from=selection match="\\d+"}}/{{op default="unblock"}}"';
    const snippet = parseSnippet("unbl.md", text);
    const ctx = ctxWith({ selection: "8933 a\n\n8934 b\n" });
    const prep = prepare(snippet, ctx, {});
    assert.deepEqual(prep.fields.map(f => f.name), ["op"]);
    assert.equal(plainText(renderSegments(snippet, prep.values, prep.sources, ctx)).text,
        'curl "$BOLT/subscribers/8933/unblock"\ncurl "$BOLT/subscribers/8934/unblock"');
});

test("each: line without a fresh selection renders once, empty", () => {
    assert.deepEqual(eachLines(ctxWith({ selection: "a\nb", changedAt: 0 })), [""]);
    const snippet = parseSnippet("a.md", "---\neach: line\n---\n- {{selection}}");
    assert.equal(plainText(renderSegments(snippet, {}, {}, ctxWith({ selection: "a\nb" }))).text, "- a\n- b");
});

test("segments tell values from the selection apart from empty fields", () => {
    const snippet = parseSnippet("prr.md", PRR);
    const ctx = ctxWith({ selection: "PR #1287" });
    const prep = prepare(snippet, ctx, {});
    const kinds = renderSegments(snippet, prep.values, prep.sources, ctx).filter(s => s.kind !== "text");
    assert.deepEqual(kinds.map(s => s.kind + ":" + (s.source || s.name || "")),
        ["value:choice", "value:default", "value:selection", "empty:ticket", "cursor:"]);
});

// --- dates -------------------------------------------------------------------------

test("formatDate knows Unicode patterns and quoted text", () => {
    assert.equal(formatDate(NOW, "yyyy-MM-dd'T'HH:mm:ss"), "2026-10-07T10:45:30");
    assert.equal(formatDate(NOW, "EEE d MMM yy, h:mm a"), "Wed 7 Oct 26, 10:45 AM");
    assert.equal(formatDate(NOW, "''HH''"), "'10'");
    assert.equal(formatDate(new Date(2026, 0, 1, 0, 5).getTime(), "hh:mm a"), "12:05 AM");
});

test("shiftDate moves by each part in turn; months end at the month's last day", () => {
    assert.equal(formatDate(shiftDate(NOW, "+3d -2h"), "yyyy-MM-dd HH:mm"), "2026-10-10 08:45");
    assert.equal(formatDate(shiftDate(NOW, "+1w"), "yyyy-MM-dd"), "2026-10-14");
    assert.equal(formatDate(shiftDate(new Date(2026, 0, 31).getTime(), "+1M"), "yyyy-MM-dd"), "2026-02-28");
    assert.equal(formatDate(shiftDate(NOW, "-1y +30m"), "yyyy-MM-dd HH:mm"), "2025-10-07 11:15");
});

test("uuid is a version 4 UUID", () => {
    let n = 0;
    const fixed = () => (n++ % 16) / 16;
    assert.match(uuid(fixed), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

// --- the search ------------------------------------------------------------------------

const LIBRARY = parseListing(listing({
    "work/prr.md": PRR,
    "work/prd.md": "---\nname: PR description\ntags: [github]\n---\n## Why\n{{why}}",
    "team/stand.md": "---\nname: Stand-up update\napps: [Slack]\n---\nYesterday: {{yesterday}}",
    "ops/unbl.md": "---\nname: Unblock ICCID\napps: [ghostty]\n---\ncurl …/{{iccid from=selection}}",
    "sig.md": "Best,\nDavid",
}));

test("an exact keyword comes first, then a keyword prefix, then names", () => {
    assert.deepEqual(rank(LIBRARY, "prr", "", {}, NOW).map(s => s.keyword), ["prr", "prd"]);
    // Two keyword prefixes tie, and go by name.
    assert.deepEqual(rank(LIBRARY, "pr", "", {}, NOW).map(s => s.keyword).slice(0, 2), ["prr", "prd"]);
    assert.equal(rank(LIBRARY, "description", "", {}, NOW)[0].keyword, "prd");
});

test("every word has to match; the body counts too", () => {
    assert.deepEqual(rank(LIBRARY, "pr github", "", {}, NOW).map(s => s.keyword).sort(), ["prd", "prr"]);
    assert.deepEqual(rank(LIBRARY, "david", "", {}, NOW).map(s => s.keyword), ["sig"]);
    assert.deepEqual(rank(LIBRARY, "zzz", "", {}, NOW), []);
});

test("letters in order match within a few words, not across the whole name", () => {
    const md = parseListing(listing({ "md.md": "---\nname: Markdown link from the selection and the clipboard\ntags: [markdown]\n---\nx" }));
    assert.equal(rank(md, "mkl", "", {}, NOW).length, 1);
    // p and r in "clipboard", r in the tag "markdown".
    assert.equal(rank(md, "prr", "", {}, NOW).length, 0);
    // The d of "and", the e of "the", the p of "clipboard": not from a word's start.
    assert.equal(rank(md, "dep", "", {}, NOW).length, 0);
});

test("with no query, the focused app's snippets come first, then the used ones", () => {
    const usage = { "sig.md": { count: 20, last: NOW - 1000 } };
    assert.deepEqual(rank(LIBRARY, "", "Slack", usage, NOW).map(s => s.keyword).slice(0, 3), ["prr", "stand", "sig"]);
    assert.equal(rank(LIBRARY, "", "com.mitchellh.ghostty", {}, NOW)[0].keyword, "unbl");
});

test("frecency grows with use and fades with time", () => {
    assert.equal(frecency(null, NOW), 0);
    assert.ok(frecency({ count: 10, last: NOW }, NOW) > frecency({ count: 2, last: NOW }, NOW));
    assert.ok(frecency({ count: 10, last: NOW }, NOW) > frecency({ count: 10, last: NOW - 40 * 86400000 }, NOW));
    assert.ok(frecency({ count: 1e9, last: NOW }, NOW) <= 80);
});

test("forApp matches part of niri's app_id, ignoring case", () => {
    const unbl = LIBRARY.find(s => s.keyword === "unbl");
    assert.equal(forApp(unbl, "com.mitchellh.ghostty"), true);
    assert.equal(forApp(unbl, "Slack"), false);
    assert.equal(forApp(unbl, ""), false);
});

// --- what the overlay shows ---------------------------------------------------------

test("styledText escapes markup and keeps spaces and line breaks", () => {
    assert.equal(styledText('<img src="x"> & co'), "&lt;img src=&quot;x&quot;&gt; &amp; co");
    assert.equal(styledText("a  b\n c\td"), "a&nbsp;&nbsp;b<br>&nbsp;c&nbsp;&nbsp;&nbsp;&nbsp;d");
});

test("styledSegments colours values by where they came from", () => {
    const html = styledSegments([
        { kind: "text", text: "a" },
        { kind: "value", text: "<s>", source: "selection" },
        { kind: "value", text: "v", source: "typed" },
        { kind: "empty", name: "x" },
        { kind: "cursor" },
    ], { good: "#0f0", accent: "#00f", dim: "#999" });
    assert.equal(html, 'a<font color="#0f0">&lt;s&gt;</font><font color="#00f">v</font>'
        + '<font color="#999">‹x›</font><font color="#00f"><b>▏</b></font>');
});

test("styledSource dims the front matter and shows placeholders as written", () => {
    const s = parseSnippet("a.md", '---\nname: x\n---\nHi {{who default="you"}}');
    assert.equal(styledSource(s, { accent: "#00f", dim: "#999" }),
        '<font color="#999">---<br>name: x<br>---</font><br>Hi <font color="#00f">{{who default=&quot;you&quot;}}</font>');
});

test("highlight escapes and marks the query's words", () => {
    assert.equal(highlight("<b>PR</b> review", "pr", "#f00"),
        '&lt;b&gt;<font color="#f00"><b>PR</b></font>&lt;/b&gt; review');
});

test("selectionLabel says how old and how big the selection is", () => {
    assert.equal(selectionLabel(ctxWith({ selection: "PR #1287" })), "selection · 2s ago · 8 chars");
    assert.equal(selectionLabel(ctxWith({ selection: "a\nb\n", changedAt: 0 })), "selection · older · 2 lines");
    assert.equal(selectionLabel(ctxWith({ selection: "" })), "");
});

test("describe and actionLabel sum a snippet up", () => {
    const s = parseSnippet("ops/x.md", "---\ntags: [a]\napps: [kitty]\neach: line\naction: open\n---\nx");
    assert.equal(describe(s, { count: 3, last: NOW - 7200000 }, NOW),
        "ops/x.md · #a · used 3× · last 2h ago · apps: kitty · each line · opens with xdg-open");
    assert.equal(actionLabel(s), "open");
    assert.equal(actionLabel(parseSnippet("a.md", "---\npaste: type\n---\nx")), "type");
    assert.equal(actionLabel(null), "use");
});

// --- where it goes ------------------------------------------------------------------

test("parseProbe reads niri's output and window, then the selection and clipboard", () => {
    const out = [
        '{"name":"eDP-1","make":"BOE","logical":{"x":0}}\n',
        '{"id":2,"title":"#bolt-dev","app_id":"Slack","pid":1}\n',
        "PR #1287\nfixes",
        "copied\n",
    ].join(SEPARATOR + "\n");
    assert.deepEqual(parseProbe(out), {
        output: "eDP-1", appId: "Slack", title: "#bolt-dev", selection: "PR #1287\nfixes", clipboard: "copied\n",
    });
});

test("parseProbe copes with niri not answering and nothing selected", () => {
    assert.deepEqual(parseProbe(["", "", "", ""].join(SEPARATOR + "\n")),
        { output: "", appId: "", title: "", selection: "", clipboard: "" });
    assert.deepEqual(parseProbe(""), { output: "", appId: "", title: "", selection: "", clipboard: "" });
});

test("terminals are told apart by their app_id", () => {
    assert.equal(isTerminal("com.mitchellh.ghostty"), true);
    assert.equal(isTerminal("org.gnome.Ptyxis"), true);
    assert.equal(isTerminal("Slack"), false);
});

test("cursorLefts counts characters after the caret, not crossing lines in a terminal", () => {
    assert.equal(cursorLefts("Hi !\nBye", 3, false), 5);
    assert.equal(cursorLefts("Hi !\nBye", 3, true), 0);
    assert.equal(cursorLefts("a(é)", 2, true), 2);
    assert.equal(cursorLefts("x", -1, false), 0);
});

// --- what is kept -------------------------------------------------------------------

test("recordUse counts and timestamps without touching the old object", () => {
    const before = { "a.md": { count: 2, last: 1 } };
    const after = recordUse(before, "a.md", NOW);
    assert.deepEqual(after["a.md"], { count: 3, last: NOW });
    assert.equal(before["a.md"].count, 2);
    assert.deepEqual(recordUse({}, "b.md", NOW)["b.md"], { count: 1, last: NOW });
});

test("rememberValues keeps typed values, not the selection or clipboard ones", () => {
    const snippet = parseSnippet("prr.md", PRR + '{{url from=clipboard}}');
    const prep = prepare(snippet, ctxWith({ selection: "PR #1", clipboard: "u" }), {});
    const kept = rememberValues({}, "prr.md", prep.fields, Object.assign(prep.values, { who: "Bob" }));
    assert.deepEqual(kept, { "prr.md": { who: "Bob", repo: "bolt" } });
});

test("renameEntry moves what is kept to the new path, leaving the old object alone", () => {
    const before = { "a.md": { count: 2 }, "b.md": { count: 1 } };
    assert.deepEqual(renameEntry(before, "a.md", "c.md"), { "c.md": { count: 2 }, "b.md": { count: 1 } });
    assert.deepEqual(before["a.md"], { count: 2 });
    assert.deepEqual(renameEntry(before, "zz.md", "c.md"), before);
});

// --- after the editor closes ----------------------------------------------------

test("parseEditPair splits before from after, and knows a file that is gone", () => {
    assert.deepEqual(parseEditPair("old\n" + SEPARATOR + "\npresent\nnew\n"), { before: "old\n", after: "new\n" });
    assert.deepEqual(parseEditPair("old" + SEPARATOR + "\nmissing\n"), { before: "old", after: null });
    assert.deepEqual(parseEditPair(""), { before: "", after: null });
});

test("a file named after its keyword follows it when it changes", () => {
    const before = "---\nkeyword: old\n---\nx";
    assert.equal(afterEdit("work/old.md", before, "---\nkeyword: Été Paris!\n---\nx"), "ete-paris");
    assert.equal(afterEdit("work/old.md", before, "---\nkeyword: \"!!\"\n---\nx"), "");
    assert.equal(afterEdit("old.md", "x", "---\nkeyword: new\n---\nx"), "new");
});

test("a file named on purpose, or whose keyword did not change, keeps its name", () => {
    const named = "---\nkeyword: prr\n---\nx";
    assert.equal(afterEdit("pr-review.md", named, named.replace("prr", "review")), "");
    const plain = "---\nname: a\n---\nx";
    assert.equal(afterEdit("sig.md", plain, plain.replace("name: a", "name: b")), "");
    assert.equal(afterEdit("sig.md", plain, null), "");
});

test("a saved draft is filed under its keyword, or its own name without one", () => {
    const text = newSnippetFile({ name: "A question", keyword: "a-question" }, "body");
    const path = "/run/user/1000/snippet-draft.x/a-question.md";
    assert.equal(draftStem(path, text.replace(/keyword: .*/, "keyword: Latest idiomatic way"), NOW), "latest-idiomatic-way");
    assert.equal(draftStem(path, "no front matter", NOW), "a-question");
    assert.equal(draftStem("/d/x.md", '---\nkeyword: "!!"\n---\nx', NOW), "snippet-20261007-104530");
});

// --- a new snippet ------------------------------------------------------------------

test("the form starts from the selection without blank lines around it", () => {
    assert.equal(trimSelection("\n  \nA question \nsecond\n\n"), "A question \nsecond");
    assert.equal(trimSelection(undefined), "");
    assert.equal(slugOf("A question: when?"), "a-question-when");
    assert.equal(keywordFor("PR #1287 fixes BOLT-412, see https://github.com"), "pr-1287-fixes-bolt");
    assert.equal(keywordFor("Été"), "ete");
    assert.equal(appLabel("com.mitchellh.ghostty"), "ghostty");
    assert.equal(appLabel("Slack"), "Slack");
    assert.equal(appLabel(""), "");
});

test("folders, tags and apps already in use are offered, once each and sorted", () => {
    const library = parseListing(listing({
        "work/a.md": "---\ntags: [github, review]\napps: [Slack]\n---\nx",
        "work/b.md": "---\ntags: [GitHub]\n---\nx",
        "ops/c.md": "---\napps: [ghostty]\n---\nx",
        "d.md": "x",
    }));
    assert.deepEqual(knownFolders(library), ["ops", "work"]);
    assert.deepEqual(knownTags(library), ["github", "review"]);
    assert.deepEqual(knownApps(library, "app.zen_browser.zen"), ["ghostty", "Slack", "zen"]);
});

test("complete offers the rest of the first option the text starts", () => {
    assert.equal(complete("wo", ["ops", "work"], false), "rk");
    assert.equal(complete("WO", ["ops", "work"], false), "rk");
    assert.equal(complete("work", ["ops", "work"], false), "");
    assert.equal(complete("", ["ops"], false), "");
    assert.equal(complete("x", ["ops"], false), "");
});

test("in a list, complete only finishes the last item, with an option not already there", () => {
    assert.equal(complete("github, re", ["github", "review"], true), "view");
    assert.equal(complete("github, ", ["github", "review"], true), "");
    assert.equal(complete("review, g", ["github", "review"], true), "ithub");
    assert.equal(complete("github, g", ["github", "gitlab"], true), "itlab");
});

test("cleanFolder keeps the folder inside the snippets folder", () => {
    assert.equal(cleanFolder(" /work//ops/ "), "work/ops");
    assert.equal(cleanFolder("../../etc"), "etc");
    assert.equal(cleanFolder(""), "");
});

test("a new keyword has to be free", () => {
    const library = parseListing(listing({ "work/pr-review.md": "---\nname: Ask for a PR review\nkeyword: prr\n---\nx" }));
    assert.equal(keywordProblem("PRR", library), 'taken by "Ask for a PR review" (work/pr-review.md)');
    assert.equal(keywordProblem("!!", library), "a keyword is needed");
    assert.equal(keywordProblem("prd", library), "");
});

test("spotFields finds links, emails, UUIDs, tickets, dates, #numbers and long numbers", () => {
    const spots = spotFields("PR #1287 fixes BOLT-412 for ana@example.com, see https://github.com/x/y/pull/1287 "
        + "id 8933150319111234567 run 0b9e4c1a-2f3d-4e5f-8a9b-0c1d2e3f4a5b on 2026-10-01", NOW);
    assert.deepEqual(spots.map(s => [s.kind, s.text, s.name]), [
        ["url", "https://github.com/x/y/pull/1287", "url"],
        ["email", "ana@example.com", "email"],
        ["uuid", "0b9e4c1a-2f3d-4e5f-8a9b-0c1d2e3f4a5b", "id"],
        ["ticket", "BOLT-412", "ticket"],
        ["date", "2026-10-01", "when"],
        ["number", "1287", "number"],
        ["id", "8933150319111234567", "id2"],
    ]);
});

test("the same value found twice is one field; two values of a kind get numbered names", () => {
    const spots = spotFields("BOLT-412 and BOLT-413, again BOLT-412", NOW);
    assert.deepEqual(spots.map(s => [s.name, s.ranges.length]), [["ticket", 2], ["ticket2", 1]]);
});

test("today's date is spotted as {{date}}", () => {
    const [today] = spotFields("deployed on 2026-10-07", NOW);
    assert.deepEqual([today.kind, today.name, today.attrs], ["today", "date", ""]);
});

test("applySpots puts the switched-on fields in, escapes {{, and leaves the rest", () => {
    const text = "PR #1287 fixes BOLT-412 in {{ .Values }}";
    const spots = spotFields(text, NOW);
    const state = {};
    state[spots[0].key] = { on: true, name: "" };
    assert.equal(applySpots(text, spots, state), 'PR #1287 fixes {{ticket from=selection match="[A-Z][A-Z0-9]+-\\d+"}} in \\{{ .Values }}');
    state[spots[1].key] = { on: true, name: "pr" };
    const body = applySpots(text, spots, state);
    assert.equal(body, 'PR #{{pr from=selection match="#(\\d+)"}} fixes {{ticket from=selection match="[A-Z][A-Z0-9]+-\\d+"}} in \\{{ .Values }}');

    // The template gives the selection back.
    const snippet = parseSnippet("t.md", body);
    assert.deepEqual(snippet.problems, []);
    const ctx = ctxWith({ selection: "PR #77 fixes OPS-9" });
    const prep = prepare(snippet, ctx, {});
    assert.equal(plainText(renderSegments(snippet, prep.values, prep.sources, ctx)).text, "PR #77 fixes OPS-9 in {{ .Values }}");
});

test("every spotted kind's regex gives back the value it was spotted from", () => {
    const text = "https://x.dev/a ana@b.io 0b9e4c1a-2f3d-4e5f-8a9b-0c1d2e3f4a5b BOLT-412 2026-10-01 #77 12345678";
    const spots = spotFields(text, NOW);
    assert.equal(spots.length, 7);
    for (const spot of spots) {
        const match = /match="([^"]*)"/.exec(spot.attrs)[1];
        assert.equal(extract(text, match), spot.text, spot.kind);
    }
});

test("a typed field name is used when valid, else the spotted one", () => {
    const [spot] = spotFields("BOLT-412", NOW);
    const named = name => spotName(spot, { [spot.key]: { on: true, name: name } });
    assert.equal(named("issue"), "issue");
    assert.equal(named("9lives"), "ticket");
    assert.equal(named("clipboard"), "ticket");
    assert.equal(named(""), "ticket");
});

test("spotSegments cuts the text at the spotted values, in order", () => {
    const text = "BOLT-412 then #7";
    const spots = spotFields(text, NOW);
    const state = { [spots[1].key]: { on: true, name: "" } };
    assert.deepEqual(spotSegments(text, spots, state).map(s => s.kind === "spot" ? [s.text, s.on, s.name] : s.text),
        [["BOLT-412", false, "ticket"], " then #", ["7", true, "number"]]);
});

test("newSnippetFile writes the front matter the form filled in", () => {
    const text = newSnippetFile({ name: 'Say "hi" #1', keyword: "Say Hi", tags: "team, , github", apps: "Slack" }, "Hi!");
    assert.equal(text, '---\nname: "Say \'hi\' #1"\nkeyword: say-hi\ntags: [team, github]\napps: [Slack]\n---\nHi!\n');
    const parsed = parseSnippet("say-hi.md", text);
    assert.deepEqual([parsed.name, parsed.keyword, parsed.tags, parsed.apps, parsed.body],
        ["Say 'hi' #1", "say-hi", ["team", "github"], ["Slack"], "Hi!"]);
    assert.equal(newSnippetFile({ name: "x", keyword: "x" }, ""), '---\nname: "x"\nkeyword: x\n---\n\n');
    assert.deepEqual(listItems(" a, ,b "), ["a", "b"]);
});

test("styledSpots shows fields switched on as {{name}} and the others underlined", () => {
    const text = "BOLT-412 <b> #7";
    const spots = spotFields(text, NOW);
    const state = { [spots[1].key]: { on: true, name: "pr" } };
    assert.equal(styledSpots(spotSegments(text, spots, state), { accent: "#00f" }),
        // A space opening a piece is kept as &nbsp;, like one opening a line.
        '<u>BOLT-412</u>&nbsp;&lt;b&gt; #<font color="#00f">{{pr}}</font>');
});
