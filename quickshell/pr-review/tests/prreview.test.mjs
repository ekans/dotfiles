// Unit tests for the pull request review overlay's logic.
//
//   node --test 'quickshell/pr-review/tests/*.test.mjs'

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    commandError,
    age,
    parseFocusedOutput,
    parseSearch,
    listCommand,
    parsePrs,
    parseHidden,
    hiddenText,
    visiblePrs,
    hiddenCount,
    toggleHidden,
    previewBody,
    plainLinks,
    summarizeChecks,
    CI_LOOK,
    ciDetail,
    parseProjects,
    repoOf,
    findProject,
    threadTitle,
    threadPrompt,
    spawnCommand,
    parseSpawn,
    DIFF_MODES,
    parseDiff,
    diffStats,
    escapeStyled,
    ansiToStyled,
    highlightQueue,
    highlightInput,
    applyHighlight,
    unifiedRows,
    splitRows,
    fileStarts,
    fileNumberAt,
    keyName,
    actionFor,
    KEYS,
    HINTS,
} from "../prreview.mjs";

// --- the list -------------------------------------------------------------------

function check(name, status, conclusion) {
    return { __typename: "CheckRun", name: name, status: status, conclusion: conclusion };
}

function rollup(contexts) {
    return { commits: { nodes: [{ commit: { statusCheckRollup: { contexts: { nodes: contexts } } } }] } };
}

// What `gh api graphql --jq '.data.search.nodes[]'` prints: one node a line.
const NODES = [
    {
        url: "https://github.com/acme/api/pull/1952",
        number: 1952,
        title: "chore(ui): document the dashboard",
        body: "## Why\n\n<!-- template hint -->\nThe cache never expired.",
        updatedAt: "2026-11-05T14:09:00Z",
        author: { login: "mona", __typename: "User" },
        repository: { nameWithOwner: "acme/api", name: "api" },
        labels: { nodes: [{ name: "bug" }, { name: "backend" }] },
        ...rollup([check("build", "COMPLETED", "SUCCESS"), check("test", "COMPLETED", "FAILURE")]),
    },
    {
        url: "https://github.com/acme/web/pull/7",
        number: 7,
        title: "Bump left-pad",
        body: "",
        updatedAt: "2026-11-04T08:00:00Z",
        author: { login: "dependabot", __typename: "Bot" },
        repository: { nameWithOwner: "acme/web", name: "web" },
        labels: { nodes: [] },
        commits: { nodes: [{ commit: { statusCheckRollup: null } }] },
    },
];
const SEARCH_JSON = NODES.map(node => JSON.stringify(node)).join("\n") + "\n";

test("reads the query's pull requests, naming the bot", () => {
    const prs = parsePrs(SEARCH_JSON);
    assert.equal(prs.length, 2);
    assert.deepEqual(prs[0], {
        url: "https://github.com/acme/api/pull/1952",
        repo: "acme/api",
        repoName: "api",
        number: 1952,
        title: "chore(ui): document the dashboard",
        author: "mona",
        bot: false,
        updatedAt: Date.parse("2026-11-05T14:09:00Z"),
        body: "## Why\n\n<!-- template hint -->\nThe cache never expired.",
        labels: ["bug", "backend"],
        ci: { state: "failure", passed: 1, failed: 1, pending: 0, failing: ["test"] },
    });
    assert.equal(prs[1].bot, true);
    assert.equal(prs[1].author, "dependabot");
});

test("reads an empty answer as an empty queue, and refuses what is not JSON", () => {
    assert.deepEqual(parsePrs(""), []);
    assert.deepEqual(parsePrs("\n"), []);
    assert.equal(parsePrs("HTTP 502: Bad Gateway"), null);
    assert.equal(parsePrs(JSON.stringify(NODES[0]) + "\n<html>\n"), null);
});

test("drops nodes that are not pull requests, such as the issues a search can return", () => {
    assert.deepEqual(parsePrs("{}\n" + JSON.stringify({ title: "x" }) + "\nnull\n"), []);
    assert.deepEqual(parsePrs("{}\n" + JSON.stringify(NODES[1]) + "\n").map(p => p.number), [7]);
});

test("keeps a pull request whose author was deleted", () => {
    const [pr] = parsePrs(JSON.stringify(Object.assign({}, NODES[0], { author: null })));
    assert.equal(pr.author, "");
    assert.equal(pr.bot, false);
});

test("reads the CI of the last commit, none when it has no rollup", () => {
    const [failing, bare] = parsePrs(SEARCH_JSON);
    assert.equal(failing.ci.state, "failure");
    assert.equal(bare.ci.state, "none");
    const noCommits = Object.assign({}, NODES[1], { commits: { nodes: [] } });
    assert.equal(parsePrs(JSON.stringify(noCommits))[0].ci.state, "none");
    const pending = Object.assign({}, NODES[1], rollup([{ __typename: "StatusContext", context: "ci/x", state: "PENDING" }]));
    assert.equal(parsePrs(JSON.stringify(pending))[0].ci.state, "pending");
});

// --- the pull requests you will not review ----------------------------------------

const API = "https://github.com/acme/api/pull/1952";
const WEB = "https://github.com/acme/web/pull/7";
const GONE = "https://github.com/acme/old/pull/3";

test("reads the hidden file's URLs, ignoring blank lines and padding", () => {
    assert.deepEqual(parseHidden(API + "\n\n  " + WEB + "  \n"), [API, WEB]);
    assert.deepEqual(parseHidden(""), []);
    assert.deepEqual(parseHidden(null), []);
});

test("writes one URL per line, only those still in the queue", () => {
    const prs = parsePrs(SEARCH_JSON);
    assert.equal(hiddenText([API, GONE, WEB], prs), API + "\n" + WEB + "\n");
    assert.equal(hiddenText([GONE], prs), "");
    assert.deepEqual(parseHidden(hiddenText([WEB, API], prs)), [WEB, API]);
});

test("keeps what was hidden while gh has not answered", () => {
    assert.equal(hiddenText([API], null), API + "\n");
});

test("lists the pull requests not hidden, or only the hidden ones", () => {
    const prs = parsePrs(SEARCH_JSON);
    assert.deepEqual(visiblePrs(prs, [API], false).map(p => p.url), [WEB]);
    assert.deepEqual(visiblePrs(prs, [API], true).map(p => p.url), [API]);
    assert.deepEqual(visiblePrs(prs, [], false).map(p => p.url), [API, WEB]);
    assert.deepEqual(visiblePrs(prs, [], true), []);
    assert.deepEqual(visiblePrs(prs, [API, WEB], false), []);
    assert.deepEqual(visiblePrs(prs, [API, WEB], true).map(p => p.url), [API, WEB]);
    assert.deepEqual(visiblePrs(prs, [GONE], true), []);
});

test("has no list before gh has answered, hidden or not", () => {
    assert.equal(visiblePrs(null, [API], false), null);
    assert.equal(visiblePrs(null, [API], true), null);
});

test("counts the hidden URLs that are in the list, not those that left it", () => {
    const prs = parsePrs(SEARCH_JSON);
    assert.equal(hiddenCount(prs, [API, GONE]), 1);
    assert.equal(hiddenCount(prs, []), 0);
    assert.equal(hiddenCount(null, [API]), 0);
});

test("hides a pull request that is shown and unhides one that is hidden", () => {
    assert.deepEqual(toggleHidden([API], WEB), [API, WEB]);
    assert.deepEqual(toggleHidden([API, WEB], API), [WEB]);
    const before = [API];
    toggleHidden(before, WEB);
    assert.deepEqual(before, [API]);
});

test("strips HTML comments from the preview body", () => {
    assert.equal(previewBody("<!-- a -->\nHello\n<!--\nmulti\nline\n-->\nworld"), "Hello\n\nworld");
    assert.equal(previewBody("<!-- only -->"), "");
    assert.equal(previewBody(null), "");
});

test("shows Markdown links as their labels and bare URLs as code", () => {
    assert.equal(plainLinks("See [the docs](https://acme.dev/docs \"Docs\") now"), "See the docs now");
    assert.equal(plainLinks("![diagram](https://acme.dev/a.png) and [![badge](https://acme.dev/b.svg)](https://acme.dev)"), "diagram and badge");
    assert.equal(plainLinks("Fixes https://acme.dev/issues/4 and <https://acme.dev/x>."), "Fixes `https://acme.dev/issues/4` and `https://acme.dev/x`.");
    assert.equal(plainLinks("(see https://acme.dev/y)"), "(see `https://acme.dev/y`)");
});

test("leaves URLs and links inside code alone", () => {
    const code = "Run `curl https://acme.dev/x [a](b)` then\n```\ncurl https://acme.dev/y\n```";
    assert.equal(plainLinks(code), code);
    assert.equal(plainLinks(""), "");
});

test("says why a command gave nothing", () => {
    assert.equal(commandError("gh", "", "To get started with GitHub CLI, please run:  gh auth login\n", 4), "gh: To get started with GitHub CLI, please run:  gh auth login");
    assert.equal(commandError("gh", "", "", 1), "gh exited with 1");
    assert.equal(commandError("bb", '{"error": {"message": "server down"}}', "", 1), "bb: server down");
});

test("tells the age in the largest unit that fits", () => {
    const now = 10 * 24 * 3600000;
    assert.equal(age(now - 30000, now), "now");
    assert.equal(age(now - 5 * 60000, now), "5m");
    assert.equal(age(now - 3 * 3600000, now), "3h");
    assert.equal(age(now - 3 * 24 * 3600000, now), "3d");
});

test("reads niri's focused output", () => {
    assert.equal(parseFocusedOutput('{"name": "DP-1"}'), "DP-1");
    assert.equal(parseFocusedOutput("nope"), "");
});

test("reads the extra qualifiers, dropping comments and blank lines", () => {
    const text = "# kept out of the public repo\n-repo:acme/old -repo:acme/legacy  # trailing note\n\n  -label:wip\n";
    assert.deepEqual(parseSearch(text), ["-repo:acme/old", "-repo:acme/legacy", "-label:wip"]);
    assert.deepEqual(parseSearch(""), []);
});

// The search text, the value of `-f q=…`.
function searchOf(command) {
    return command.find(arg => arg.indexOf("q=") === 0).slice(2);
}

test("asks GraphQL for the open pull requests waiting on you, the extra qualifiers after them", () => {
    const command = listCommand(["-repo:acme/old", "-label:wip"]);
    assert.deepEqual(command.slice(0, 4), ["gh", "api", "graphql", "--paginate"]);
    assert.ok(command.indexOf("--jq") !== -1);
    assert.ok(searchOf(command).startsWith("is:pr is:open review-requested:@me"));
    assert.ok(searchOf(command).endsWith(" -repo:acme/old -label:wip"));
    assert.equal(searchOf(listCommand([])).indexOf("-repo"), -1);
});

test("leaves drafts out of the queue", () => {
    assert.ok(searchOf(listCommand([])).split(" ").indexOf("draft:false") !== -1);
});

// --- CI -------------------------------------------------------------------------

function run(name, status, conclusion) {
    return { __typename: "CheckRun", name: name, status: status, conclusion: conclusion };
}
function context(name, state) {
    return { __typename: "StatusContext", context: name, state: state };
}

test("sums mixed checks into failure, naming those that failed", () => {
    const ci = summarizeChecks([
        run("build", "COMPLETED", "SUCCESS"),
        run("lint", "COMPLETED", "NEUTRAL"),
        run("docs", "COMPLETED", "SKIPPED"),
        run("test", "COMPLETED", "FAILURE"),
        run("e2e", "COMPLETED", "TIMED_OUT"),
        run("deploy", "IN_PROGRESS", ""),
        context("ci/legacy", "ERROR"),
        context("ci/title", "SUCCESS"),
        context("ci/wait", "EXPECTED"),
    ]);
    assert.deepEqual(ci, { state: "failure", passed: 4, failed: 3, pending: 2, failing: ["test", "e2e", "ci/legacy"] });
});

test("is pending when nothing failed but something is still running", () => {
    const ci = summarizeChecks([run("build", "COMPLETED", "SUCCESS"), run("test", "QUEUED", null), context("ci/x", "PENDING")]);
    assert.equal(ci.state, "pending");
    assert.equal(ci.pending, 2);
    assert.deepEqual(ci.failing, []);
});

test("counts a cancelled run and a run needing action as failed", () => {
    for (const conclusion of ["CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"])
        assert.equal(summarizeChecks([run("a", "COMPLETED", conclusion)]).state, "failure", conclusion);
});

test("passes when every check passed, and has none when there are none", () => {
    assert.equal(summarizeChecks([run("a", "COMPLETED", "SUCCESS"), context("b", "SUCCESS")]).state, "success");
    assert.deepEqual(summarizeChecks([]), { state: "none", passed: 0, failed: 0, pending: 0, failing: [] });
});

test("does not call a conclusion it does not know a pass", () => {
    assert.equal(summarizeChecks([run("a", "COMPLETED", "STALE")]).state, "pending");
});

test("gives every CI state a label and a palette role", () => {
    assert.deepEqual(CI_LOOK.pending, { label: "in progress", color: "warn" });
    assert.deepEqual(CI_LOOK.failure, { label: "failing", color: "bad" });
    assert.deepEqual(CI_LOOK.success, { label: "passed", color: "good" });
    assert.deepEqual(CI_LOOK.none, { label: "no checks", color: "dim" });
});

test("counts the checks that are not zero", () => {
    assert.equal(ciDetail({ passed: 3, failed: 1, pending: 2 }), "3 passed, 1 failed, 2 pending");
    assert.equal(ciDetail({ passed: 0, failed: 0, pending: 0 }), "");
});

// --- projects -------------------------------------------------------------------

test("normalises every remote form to owner/name, lowercase", () => {
    assert.equal(repoOf("git@github:Acme/Api"), "acme/api");
    assert.equal(repoOf("git@github-ekans:acme/api.git"), "acme/api");
    assert.equal(repoOf("git@github.com:acme/api.git"), "acme/api");
    assert.equal(repoOf("https://github.com/acme/api.git"), "acme/api");
    assert.equal(repoOf("https://github.com/acme/api"), "acme/api");
    assert.equal(repoOf(null), null);
    assert.equal(repoOf("/home/me/src/api"), null);
});

const PROJECTS = parseProjects(JSON.stringify([
    { id: "p1", name: "api-scratch", gitRemoteUrl: "git@github:acme/api" },
    { id: "p2", name: "api", gitRemoteUrl: "https://github.com/acme/api.git" },
    { id: "p3", name: "api (archived)", gitRemoteUrl: "git@github.com:acme/api.git" },
    { id: "p4", name: "web (archived)", gitRemoteUrl: "git@github.com:acme/web.git" },
    { id: "p5", name: "notes", gitRemoteUrl: null },
    { id: "p6", name: "docs-site", gitRemoteUrl: "git@github-ekans:acme/docs.git" },
    { id: "p7", name: "docs-mirror", gitRemoteUrl: "git@github.com:acme/docs.git" },
]));

test("finds the project named like the repo among several on one remote", () => {
    assert.equal(findProject(PROJECTS, "acme/api").id, "p2");
});

test("takes the first project when none is named like the repo", () => {
    assert.equal(findProject(PROJECTS, "acme/docs").id, "p6");
});

test("finds no project for an archived-only repo, a null remote or an unknown repo", () => {
    assert.equal(findProject(PROJECTS, "acme/web"), null);
    assert.equal(findProject(PROJECTS, "acme/notes"), null);
    assert.equal(findProject(PROJECTS, "acme/unknown"), null);
    assert.equal(findProject(null, "acme/api"), null);
});

test("matches the repo whatever its case", () => {
    assert.equal(findProject(PROJECTS, "Acme/API").id, "p2");
});

test("reads bb project list, and refuses what is not it", () => {
    assert.equal(parseProjects("nope"), null);
    assert.equal(parseProjects("{}"), null);
    assert.deepEqual(parseProjects('[{"id": "p", "name": "n"}]'), [{ id: "p", name: "n", gitRemoteUrl: null }]);
});

// --- the thread -----------------------------------------------------------------

const PR = parsePrs(SEARCH_JSON)[0];

test("titles the thread with the number and the title, not the repo", () => {
    assert.equal(threadTitle(PR), "#1952: chore(ui): document the dashboard");
});

test("spawns a haiku thread in a new worktree of the project, its prompt on stdin", () => {
    const argv = spawnCommand("bb", "proj_1", PR);
    assert.deepEqual(argv, [
        "bb", "thread", "spawn", "--json", "--provider", "claude-code", "--model", "haiku",
        "--reasoning-level", "low", "--project", "proj_1", "--new-environment", "worktree",
        "--title", "#1952: chore(ui): document the dashboard", "--prompt-file", "-",
    ]);
});

test("keeps the prompt out of the arguments, so the longest description starts a thread", () => {
    // GitHub allows 65536 characters; Linux refuses one argument over 128 KiB.
    const pr = { repo: "acme/api", number: 5, title: "T", url: "https://github.com/acme/api/pull/5", body: "変".repeat(65536) };
    for (const arg of spawnCommand("bb", "proj_1", pr))
        assert.ok(Buffer.byteLength(arg) < 128 * 1024);
});

test("carries the description into the prompt verbatim", () => {
    const body = "- starts with a dash\n<!-- kept -->\n```\n</pr_description>\n```\n  indented";
    const prompt = threadPrompt({ repo: "acme/api", number: 5, title: "T <b>", url: "https://github.com/acme/api/pull/5", body: body });
    assert.ok(prompt.includes("<pr_description>\n" + body + "\n</pr_description>"));
    assert.ok(prompt.includes("<pr_title>\nT <b>\n</pr_title>"));
    assert.ok(prompt.includes("<pr_url>https://github.com/acme/api/pull/5</pr_url>"));
    assert.ok(prompt.startsWith("This thread is about pull request acme/api#5. "));
    assert.ok(prompt.endsWith("then stop and wait for the user."));
});

test("holds the title and the url, and sends the agent nowhere to fetch them", () => {
    const prompt = threadPrompt(PR);
    assert.ok(prompt.includes("<pr_title>\nchore(ui): document the dashboard\n</pr_title>"));
    assert.ok(prompt.includes("<pr_url>https://github.com/acme/api/pull/1952</pr_url>"));
    assert.ok(prompt.includes("nothing to fetch or look up"));
});

test("says so in the prompt when the pull request has no description", () => {
    const prompt = threadPrompt({ repo: "acme/api", number: 5, title: "T", url: "u", body: "" });
    assert.ok(prompt.includes("<pr_description>\n(The pull request has no description.)\n</pr_description>"));
});

test("reads bb thread spawn's answer", () => {
    assert.deepEqual(parseSpawn('{"id": "thr_1"}', "", 0), { id: "thr_1", error: "" });
    assert.deepEqual(parseSpawn('{"thread": {"id": "thr_2"}}', "", 0), { id: "thr_2", error: "" });
    assert.deepEqual(parseSpawn('{"error": {"message": "no such project", "hint": "bb project list"}}', "", 1), { id: "", error: "no such project bb project list" });
    assert.deepEqual(parseSpawn("", "boom\n", 2), { id: "", error: "boom" });
    assert.deepEqual(parseSpawn("", "", 3), { id: "", error: "bb exited with 3" });
});

// --- the diff -------------------------------------------------------------------

const DIFF = [
    "diff --git a/src/app.js b/src/app.js",
    "index 1111111..2222222 100644",
    "--- a/src/app.js",
    "+++ b/src/app.js",
    "@@ -1,5 +1,6 @@ function main() {",
    " const a = 1;",
    "-const b = 2;",
    "-const c = 3;",
    "+const b = 20;",
    "+const c = 30;",
    "+const d = 40;",
    " ",
    " return a;",
    "@@ -20,2 +21,2 @@",
    " tail",
    "-- not a file header",
    "+-- nor this",
    "\\ No newline at end of file",
    "diff --git a/docs/old name.md b/docs/new name.md",
    "similarity index 90%",
    "rename from docs/old name.md",
    "rename to docs/new name.md",
    "index 3333333..4444444 100644",
    "--- a/docs/old name.md",
    "+++ b/docs/new name.md",
    "@@ -1 +1 @@",
    "-Old <title> & more",
    "+New <title> & more",
    "diff --git a/lib/new.py b/lib/new.py",
    "new file mode 100644",
    "index 0000000..5555555",
    "--- /dev/null",
    "+++ b/lib/new.py",
    "@@ -0,0 +1,2 @@",
    "+def f():",
    "+\treturn 1",
    "diff --git a/old.txt b/old.txt",
    "deleted file mode 100644",
    "index 6666666..0000000",
    "--- a/old.txt",
    "+++ /dev/null",
    "@@ -1,2 +0,0 @@",
    "-gone",
    "-also gone",
    "diff --git a/img/logo.png b/img/logo.png",
    "new file mode 100644",
    "index 0000000..7777777",
    "Binary files /dev/null and b/img/logo.png differ",
    "",
].join("\n");

test("parses a multi-file diff, with a rename, an added, a deleted and a binary file", () => {
    const files = parseDiff(DIFF);
    assert.deepEqual(files.map(f => [f.path, f.oldPath, f.status]), [
        ["src/app.js", "src/app.js", "modified"],
        ["docs/new name.md", "docs/old name.md", "renamed"],
        ["lib/new.py", "lib/new.py", "added"],
        ["old.txt", "old.txt", "deleted"],
        ["img/logo.png", "img/logo.png", "binary"],
    ]);
    assert.deepEqual(files[4].lines, []);
});

test("numbers the lines of each hunk on their own side", () => {
    const lines = parseDiff(DIFF)[0].lines;
    assert.deepEqual(lines[0], { kind: "hunk", oldNo: null, newNo: null, text: "@@ -1,5 +1,6 @@ function main() {" });
    assert.deepEqual(lines.slice(1, 8).map(l => [l.kind, l.oldNo, l.newNo, l.text]), [
        ["context", 1, 1, "const a = 1;"],
        ["del", 2, null, "const b = 2;"],
        ["del", 3, null, "const c = 3;"],
        ["add", null, 2, "const b = 20;"],
        ["add", null, 3, "const c = 30;"],
        ["add", null, 4, "const d = 40;"],
        ["context", 4, 5, ""],
    ]);
    // The second hunk starts again from its header.
    assert.deepEqual(lines[9], { kind: "hunk", oldNo: null, newNo: null, text: "@@ -20,2 +21,2 @@" });
    assert.deepEqual([lines[10].oldNo, lines[10].newNo], [20, 21]);
});

test("keeps a deleted line that looks like a file header inside its hunk", () => {
    const lines = parseDiff(DIFF)[0].lines;
    assert.deepEqual(lines.slice(-2).map(l => [l.kind, l.text]), [["del", "- not a file header"], ["add", "-- nor this"]]);
    assert.equal(parseDiff(DIFF)[0].lines.length, 13);
});

test("reads a path with spaces and the lines of a renamed file", () => {
    const rename = parseDiff(DIFF)[1];
    assert.deepEqual(rename.lines.map(l => [l.kind, l.text]), [
        ["hunk", "@@ -1 +1 @@"],
        ["del", "Old <title> & more"],
        ["add", "New <title> & more"],
    ]);
});

test("decodes the paths git quotes, as GitHub sends them", () => {
    const files = parseDiff([
        'diff --git "a/Bren\\303\\251 Brown.md" "b/Bren\\303\\251 Brown.md"',
        "index 1111111..2222222 100644",
        '--- "a/Bren\\303\\251 Brown.md"',
        '+++ "b/Bren\\303\\251 Brown.md"',
        "@@ -1 +1 @@",
        "-x",
        "+y",
        'diff --git "a/D\\\\A.md" "b/D\\\\A.md"',
        "deleted file mode 100644",
        'diff --git a/plain.md "b/caf\\303\\251 \\"menu\\"\\tv2.md"',
        "similarity index 100%",
        "rename from plain.md",
        'rename to "caf\\303\\251 \\"menu\\"\\tv2.md"',
        "",
    ].join("\n"));
    assert.deepEqual(files.map(f => [f.path, f.oldPath, f.status]), [
        ["Brené Brown.md", "Brené Brown.md", "modified"],
        ["D\\A.md", "D\\A.md", "deleted"],
        ["café \"menu\"\tv2.md", "plain.md", "renamed"],
    ]);
});

test("counts the additions and deletions", () => {
    const files = parseDiff(DIFF);
    assert.deepEqual(diffStats(files), { files: 5, adds: 7, dels: 6 });
    assert.deepEqual(diffStats([]), { files: 0, adds: 0, dels: 0 });
});

test("parses nothing from an empty diff", () => {
    assert.deepEqual(parseDiff(""), []);
    assert.deepEqual(parseDiff(null), []);
});

test("has the two modes", () => {
    assert.deepEqual(DIFF_MODES, ["unified", "split"]);
});

// --- the rows -------------------------------------------------------------------

test("lists a file row, its hunks and its lines, in unified mode", () => {
    const rows = unifiedRows(parseDiff(DIFF).slice(0, 1), {});
    assert.deepEqual(rows.slice(0, 4).map(r => r.type), ["file", "hunk", "line", "line"]);
    assert.deepEqual(rows[0], { type: "file", path: "src/app.js", oldPath: "src/app.js", status: "modified", adds: 4, dels: 3 });
    assert.deepEqual(rows[3], { type: "line", kind: "del", oldNo: 2, newNo: null, html: "const&nbsp;b&nbsp;=&nbsp;2;" });
});

test("zips a run of deleted lines with the added ones that follow, in split mode", () => {
    const rows = splitRows(parseDiff(DIFF).slice(0, 1), {});
    assert.deepEqual(rows.slice(0, 7).map(r => r.type), ["file", "hunk", "pair", "pair", "pair", "pair", "pair"]);
    // Context on both sides.
    assert.deepEqual([rows[2].left.kind, rows[2].left.no, rows[2].right.kind, rows[2].right.no], ["context", 1, "context", 1]);
    // Two deletions against three additions: the last has no left side.
    assert.deepEqual([rows[3].left.no, rows[3].right.no], [2, 2]);
    assert.deepEqual([rows[4].left.no, rows[4].right.no], [3, 3]);
    assert.equal(rows[5].left, null);
    assert.deepEqual([rows[5].right.kind, rows[5].right.no], ["add", 4]);
});

test("leaves the right side empty for a deletion with nothing to pair, and the left for an addition", () => {
    const files = parseDiff(DIFF);
    const gone = splitRows([files[3]], {});
    assert.deepEqual(gone.slice(2).map(r => [r.left.kind, r.right]), [["del", null], ["del", null]]);
    const added = splitRows([files[2]], {});
    assert.deepEqual(added.slice(2).map(r => [r.left, r.right.kind, r.right.no]), [[null, "add", 1], [null, "add", 2]]);
});

test("shows a file with no lines as a file row alone", () => {
    const rows = unifiedRows([parseDiff(DIFF)[4]], {});
    assert.deepEqual(rows.map(r => [r.type, r.status]), [["file", "binary"]]);
});

test("uses the highlighted line where there is one and escaped text where there is not", () => {
    const files = parseDiff(DIFF).slice(2, 3);
    const styled = { "lib/new.py": [null, "<font color=\"#c678dd\">def</font>", null] };
    const rows = unifiedRows(files, styled);
    assert.equal(rows[2].html, "<font color=\"#c678dd\">def</font>");
    assert.equal(rows[3].html, "&nbsp;&nbsp;&nbsp;&nbsp;return&nbsp;1");
    const split = splitRows(files, styled);
    assert.equal(split[2].right.html, "<font color=\"#c678dd\">def</font>");
});

test("lists where each file starts, and which file a row is in", () => {
    const rows = unifiedRows(parseDiff(DIFF), {});
    const starts = fileStarts(rows);
    assert.equal(starts.length, 5);
    assert.deepEqual(starts.map(i => rows[i].path), ["src/app.js", "docs/new name.md", "lib/new.py", "old.txt", "img/logo.png"]);
    assert.equal(fileNumberAt(rows, starts[0]), 0);
    assert.equal(fileNumberAt(rows, starts[2] + 1), 2);
    assert.equal(fileNumberAt(rows, rows.length - 1), 4);
});

test("starts the same files in both modes", () => {
    const files = parseDiff(DIFF);
    const unified = unifiedRows(files, {});
    const split = splitRows(files, {});
    assert.deepEqual(fileStarts(unified).map(i => unified[i].path), fileStarts(split).map(i => split[i].path));
    assert.ok(split.length < unified.length);
});

// --- colours --------------------------------------------------------------------

test("escapes markup, keeps spaces and expands tabs in StyledText", () => {
    assert.equal(escapeStyled("a<b> & \tc"), "a&lt;b&gt;&nbsp;&amp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;c");
    assert.equal(escapeStyled("x\r"), "x");
});

test("turns bat's truecolor escapes into font tags, escaping what they wrap", () => {
    const line = "\x1b[38;2;198;120;221mif\x1b[0m\x1b[38;2;171;178;191m (a < b) \x1b[0m\x1b[38;2;152;195;121m\"&\"\x1b[0m";
    assert.equal(ansiToStyled(line),
        "<font color=\"#c678dd\">if</font>"
        + "<font color=\"#abb2bf\">&nbsp;(a&nbsp;&lt;&nbsp;b)&nbsp;</font>"
        + "<font color=\"#98c379\">\"&amp;\"</font>");
});

test("keeps bold and italic until a reset, and drops what it does not draw", () => {
    assert.equal(ansiToStyled("\x1b[1;38;2;0;5;255mA\x1b[0mB"), "<b><font color=\"#0005ff\">A</font></b>B");
    assert.equal(ansiToStyled("\x1b[3mi\x1b[0m"), "<i>i</i>");
    // Underline, a background and a 256-colour foreground are skipped whole, so
    // the numbers inside them are not read as bold or italic.
    assert.equal(ansiToStyled("\x1b[4m\x1b[48;2;1;3;1mx\x1b[38;5;3my\x1b[0m"), "xy");
    assert.equal(ansiToStyled("plain <text>"), "plain&nbsp;&lt;text&gt;");
    assert.equal(ansiToStyled(""), "");
});

test("sends bat the code lines of a file, each ended, and skips the files not worth colouring", () => {
    const files = parseDiff(DIFF);
    assert.equal(highlightInput(files[2]), "def f():\n\treturn 1\n");
    assert.equal(highlightInput(files[0]).split("\n").length, 12);
    // The binary file has no lines.
    assert.deepEqual(highlightQueue(files), [0, 1, 2, 3]);
    const huge = { path: "big.txt", oldPath: "big.txt", status: "added", lines: new Array(3001).fill({ kind: "add", oldNo: null, newNo: 1, text: "x" }) };
    assert.deepEqual(highlightQueue([huge]), []);
    assert.deepEqual(highlightQueue([{ path: "b", oldPath: "b", status: "binary", lines: [{ kind: "add", oldNo: null, newNo: 1, text: "x" }] }]), []);
});

test("aligns bat's lines with the file's lines, leaving the hunk lines null", () => {
    const file = parseDiff(DIFF)[2];
    const out = "\x1b[38;2;198;120;221mdef\x1b[0m f():\n    return 1\n";
    const html = applyHighlight(file, out);
    assert.equal(html.length, file.lines.length);
    assert.equal(html[0], null);
    assert.equal(html[1], "<font color=\"#c678dd\">def</font>&nbsp;f():");
    assert.equal(html[2], "&nbsp;&nbsp;&nbsp;&nbsp;return&nbsp;1");
});

test("refuses bat's output when its line count is not the file's", () => {
    const file = parseDiff(DIFF)[2];
    assert.equal(applyHighlight(file, "only one\n"), null);
    assert.equal(applyHighlight(file, ""), null);
});

// --- keys -----------------------------------------------------------------------

test("names a key press by its special key, its letter, or Ctrl and its letter", () => {
    assert.equal(keyName(0x01000015, "", false), "down");
    assert.equal(keyName(0x01000005, "\r", false), "return");
    assert.equal(keyName(0x4a, "j", false), "j");
    assert.equal(keyName(0x4a, "\n", true), "ctrl+j");
    assert.equal(keyName(0x20, " ", true), "");
});

test("dispatches each key through its view's table", () => {
    assert.equal(actionFor("list", "j"), "next");
    assert.equal(actionFor("list", "ctrl+k"), "prev");
    assert.equal(actionFor("list", "d"), "diff");
    assert.equal(actionFor("list", "escape"), "close");
    assert.equal(actionFor("list", "x"), "hide");
    assert.equal(actionFor("list", "h"), "hidden");
    assert.equal(actionFor("diff", "x"), "");
    assert.equal(actionFor("hidden", "x"), "hide");
    assert.equal(actionFor("hidden", "h"), "back");
    assert.equal(actionFor("hidden", "escape"), "back");
    assert.equal(actionFor("hidden", "ctrl+n"), "next");
    assert.equal(actionFor("hidden", "k"), "prev");
    assert.equal(actionFor("hidden", "pageDown"), "previewDown");
    assert.equal(actionFor("hidden", "return"), "open");
    for (const key of ["t", "d", "r"])
        assert.equal(actionFor("hidden", key), "");
    assert.equal(actionFor("diff", "escape"), "back");
    assert.equal(actionFor("diff", "s"), "mode");
    assert.equal(actionFor("diff", "d"), "");
    assert.equal(actionFor("list", "constructor"), "");
    assert.equal(actionFor("nowhere", "j"), "");
});

test("hints every action a view has a key for", () => {
    assert.deepEqual(Object.keys(HINTS).sort(), ["diff", "hidden", "list"]);
    assert.deepEqual(Object.keys(KEYS).sort(), ["diff", "hidden", "list"]);
    assert.ok(HINTS.diff.some(h => h[1] === "unified/split"));
    const chipFor = { return: "Enter", escape: "Esc", down: "↑↓", up: "↑↓", pageDown: "PgDn", pageUp: "PgUp" };
    for (const view of Object.keys(KEYS)) {
        const chips = HINTS[view].map(h => h[0].split("/")).reduce((all, keys) => all.concat(keys), []);
        for (const key of Object.keys(KEYS[view])) {
            // j/k and Ctrl+J/K/N/P are the arrows' aliases, n/p the diff's one chip.
            if (/^(j|k|ctrl\+.)$/.test(key))
                continue;
            assert.ok(chips.indexOf(chipFor[key] ?? key) !== -1, view + " has no chip for " + key);
        }
    }
});

test("hints the hide keys before refresh in the queue", () => {
    const keys = HINTS.list.map(h => h[0]);
    assert.deepEqual(HINTS.list.filter(h => h[0] === "x" || h[0] === "h"), [["x", "hide"], ["h", "hidden"]]);
    assert.ok(keys.indexOf("x") < keys.indexOf("r") && keys.indexOf("h") < keys.indexOf("r"));
});

test("hints the hidden list's keys: unhide with x, back with h or Esc", () => {
    assert.deepEqual(HINTS.hidden, [["↑↓", "select"], ["PgUp/PgDn", "preview"], ["Enter", "open PR"], ["x", "unhide"], ["h/Esc", "back to queue"]]);
});
