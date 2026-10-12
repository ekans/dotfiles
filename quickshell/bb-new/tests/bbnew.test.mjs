// Unit tests for the new bb thread overlay's logic.
//
//   node --test ~/.config/quickshell/bb-new/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULTS,
    FALLBACK_MODELS,
    NO_PROJECT,
    parseModels,
    parseProjects,
    parseFocusedOutput,
    findModel,
    findProject,
    modelName,
    projectName,
    cycle,
    nextModel,
    nextEffort,
    effortFor,
    normalize,
    changes,
    filterProjects,
    spawnCommand,
    parseSpawn,
    checkDefault,
    leaderArguments,
    readOpenWith,
} from "../bbnew.mjs";

const effort = (id) => ({ reasoningEffort: id, description: id });

// Trimmed from `bb provider models claude-code --json`.
const MODELS_JSON = JSON.stringify([
    {
        id: "claude-opus-5-5", model: "claude-opus-5-5", displayName: "Opus 5.5",
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "ultracode", "max"].map(effort),
        defaultReasoningEffort: "high", isDefault: true,
    },
    {
        id: "claude-sonnet-5-5", model: "claude-sonnet-5-5", displayName: "Sonnet 5.5",
        supportedReasoningEfforts: ["low", "medium", "high", "max"].map(effort),
        defaultReasoningEffort: "medium",
    },
    {
        id: "claude-haiku-5-5", model: "claude-haiku-5-5", displayName: "Haiku 5.5",
        supportedReasoningEfforts: [],
    },
]);

// Trimmed from `bb project list --json`.
const PROJECTS_JSON = JSON.stringify([
    { id: "proj_p7uxxsbccn", kind: "standard", name: "chauvenity-os" },
    { id: "proj_kmyjbmui8h", kind: "standard", name: "bolt" },
    { id: "proj_8e55js9g4f", kind: "standard", name: "bb-plugin-logs (archived)" },
    { id: "proj_nd6khizj7d", kind: "standard", name: "api-backend" },
    { id: "proj_d3ivan5fcn", kind: "standard", name: "bb-plugins" },
]);

const models = parseModels(MODELS_JSON);
const projects = parseProjects(PROJECTS_JSON);
const opus = findModel(models, "claude-opus-5-5");
const sonnet = findModel(models, "claude-sonnet-5-5");
const haiku = findModel(models, "claude-haiku-5-5");

test("parseModels puts the aliases first, then keeps bb's order, names and efforts", () => {
    assert.deepEqual(models.map(m => m.id), ["opus", "sonnet", "haiku", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]);
    assert.deepEqual(opus, {
        id: "claude-opus-5-5", name: "Opus 5.5",
        efforts: ["low", "medium", "high", "xhigh", "ultracode", "max"], defaultEffort: "high",
    });
    assert.deepEqual(haiku.efforts, []);
    assert.equal(haiku.defaultEffort, "");
});

test("an alias takes the efforts of the newest model of its family", () => {
    const listed = parseModels(JSON.stringify([
        { id: "claude-opus-6", supportedReasoningEfforts: ["low", "max"], defaultReasoningEffort: "max" },
        { id: "claude-opus-5-5", supportedReasoningEfforts: ["low", "high"], defaultReasoningEffort: "high" },
        { id: "claude-fable-5-1" },
    ]));
    assert.deepEqual(listed[0], { id: "opus", name: "Opus", efforts: ["low", "max"], defaultEffort: "max" });
    // No alias for a family bb does not list.
    assert.deepEqual(listed.map(m => m.id), ["opus", "claude-opus-6", "claude-opus-5-5", "claude-fable-5-1"]);
});

test("parseModels takes {models: [...]}, plain effort names, and ignores junk", () => {
    const parsed = parseModels(JSON.stringify({ models: [{ id: "m", supportedReasoningEfforts: ["low", effort("high")] }, {}, null] }));
    assert.deepEqual(parsed, [{ id: "m", name: "m", efforts: ["low", "high"], defaultEffort: "" }]);
    assert.deepEqual(parseModels("not json"), []);
    assert.deepEqual(parseModels(""), []);
});

test("the fallback model has the defaults' model and effort", () => {
    assert.equal(FALLBACK_MODELS[0].id, DEFAULTS.model);
    assert.ok(FALLBACK_MODELS[0].efforts.includes(DEFAULTS.effort));
});

test("parseProjects sorts by name and drops archived and personal projects", () => {
    assert.deepEqual(projects.map(p => p.name), ["api-backend", "bb-plugins", "bolt", "chauvenity-os"]);
    const withPersonal = parseProjects(JSON.stringify({ projects: [{ id: "proj_personal", name: "Personal" }, { id: "proj_x", name: "x" }] }));
    assert.deepEqual(withPersonal, [{ id: "proj_x", name: "x" }]);
    assert.deepEqual(parseProjects("{"), []);
});

test("parseFocusedOutput reads niri's focused output", () => {
    assert.equal(parseFocusedOutput('{"name":"eDP-1","make":"BOE","logical":{"x":0}}'), "eDP-1");
    assert.equal(parseFocusedOutput(""), "");
    assert.equal(parseFocusedOutput("null"), "");
});

test("findProject: no project for an empty id, null for one bb does not list", () => {
    assert.equal(findProject(projects, ""), NO_PROJECT);
    assert.equal(findProject(projects, "proj_kmyjbmui8h").name, "bolt");
    assert.equal(findProject(projects, "proj_gone"), null);
    assert.equal(projectName(projects, ""), "No project");
    assert.equal(projectName(projects, "proj_gone"), "proj_gone");
    assert.equal(modelName(models, "claude-sonnet-5-5"), "Sonnet 5.5");
    assert.equal(modelName(models, "claude-gone"), "claude-gone");
});

test("cycle wraps both ways and starts over from an unknown entry", () => {
    assert.equal(cycle(["a", "b", "c"], "c", 1), "a");
    assert.equal(cycle(["a", "b", "c"], "a", -1), "c");
    assert.equal(cycle(["a", "b", "c"], "b", 1), "c");
    assert.equal(cycle(["a", "b", "c"], "x", 1), "a");
    assert.equal(cycle([], "x", 1), "x");
});

test("nextModel and nextEffort cycle what bb lists", () => {
    assert.equal(nextModel(models, "opus", 1), "sonnet");
    assert.equal(nextModel(models, "opus", -1), "claude-haiku-5-5");
    assert.equal(nextEffort(opus, "high", 1), "xhigh");
    assert.equal(nextEffort(opus, "low", -1), "max");
    assert.equal(nextEffort(haiku, "high", 1), "high");
    assert.equal(nextEffort(null, "high", 1), "high");
});

test("effortFor keeps an effort the model takes, else its default, else its first", () => {
    assert.equal(effortFor(sonnet, "high"), "high");
    assert.equal(effortFor(sonnet, "ultracode"), "medium");
    assert.equal(effortFor({ efforts: ["low", "max"], defaultEffort: "" }, "high"), "low");
    // A model that lists no efforts leaves the choice to bb.
    assert.equal(effortFor(haiku, "xhigh"), "xhigh");
    assert.equal(effortFor(null, "xhigh"), "xhigh");
});

test("normalize fits the settings to what bb lists", () => {
    assert.deepEqual(normalize(DEFAULTS, models, projects), DEFAULTS);
    assert.deepEqual(normalize({ model: "claude-sonnet-5-5", effort: "xhigh", project: "proj_kmyjbmui8h" }, models, projects),
        { model: "claude-sonnet-5-5", effort: "medium", project: "proj_kmyjbmui8h", poteto: false });
    // A model bb dropped: its first one.
    assert.equal(normalize({ model: "claude-gone", effort: "high", project: "" }, models, projects).model, "opus");
    // A project bb dropped: no project; before bb answers, it stays.
    assert.equal(normalize({ model: "claude-opus-5-5", effort: "high", project: "proj_gone" }, models, projects).project, "");
    assert.equal(normalize({ model: "claude-opus-5-5", effort: "high", project: "proj_gone" }, models, []).project, "proj_gone");
});

test("changes tells each setting that is not the default", () => {
    assert.deepEqual(changes(DEFAULTS, DEFAULTS), { model: false, effort: false, project: false, poteto: false });
    assert.deepEqual(changes({ model: DEFAULTS.model, effort: "max", project: "proj_x", poteto: false }, DEFAULTS), { model: false, effort: true, project: true, poteto: false });
    assert.equal(changes({ model: "opus", effort: "high", project: "", poteto: true }, DEFAULTS).poteto, true);
});

test("filterProjects: no project first, prefix matches before the rest", () => {
    assert.deepEqual(filterProjects(projects, "").map(p => p.name), ["No project", "api-backend", "bb-plugins", "bolt", "chauvenity-os"]);
    assert.deepEqual(filterProjects(projects, "bo").map(p => p.name), ["bolt"]);
    assert.deepEqual(filterProjects(projects, "b").map(p => p.name), ["bb-plugins", "bolt", "api-backend"]);
    assert.deepEqual(filterProjects(projects, "BB").map(p => p.name), ["bb-plugins"]);
    assert.deepEqual(filterProjects(projects, "none").map(p => p.name), ["No project"]);
    assert.deepEqual(filterProjects(projects, "proj_kmyj").map(p => p.name), ["bolt"]);
    assert.deepEqual(filterProjects(projects, "kmyj"), []);
    assert.deepEqual(filterProjects(projects, "zzz"), []);
});

test("spawnCommand sends a thread with no project to the personal workspace", () => {
    assert.deepEqual(spawnCommand("bb", DEFAULTS, "fix it"), [
        "bb", "thread", "spawn", "--json", "--provider", "claude-code",
        "--model", "opus", "--reasoning-level", "high",
        "--project", "proj_personal", "--environment-provider", "personal-workspace",
        "--prompt=fix it",
    ]);
});

test("spawnCommand leaves the environment of a project to bb", () => {
    const command = spawnCommand("/x/bb", { model: "claude-sonnet-5-5", effort: "max", project: "proj_kmyjbmui8h" }, "-v\nsecond line");
    assert.deepEqual(command.slice(-3), ["--project", "proj_kmyjbmui8h", "--prompt=-v\nsecond line"]);
    assert.ok(!command.includes("--environment-provider"));
});

test("spawnCommand prefixes the prompt with /poteto-mode when poteto is on", () => {
    assert.deepEqual(spawnCommand("bb", { model: "opus", effort: "high", project: "", poteto: true }, "fix it"), [
        "bb", "thread", "spawn", "--json", "--provider", "claude-code",
        "--model", "opus", "--reasoning-level", "high",
        "--project", "proj_personal", "--environment-provider", "personal-workspace",
        "--prompt=/poteto-mode fix it",
    ]);
});

test("spawnCommand does not double a /poteto-mode the prompt already starts with", () => {
    const on = { model: "opus", effort: "high", project: "", poteto: true };
    assert.equal(spawnCommand("bb", on, "/poteto-mode fix it").pop(), "--prompt=/poteto-mode fix it");
    assert.equal(spawnCommand("bb", on, "/poteto-mode").pop(), "--prompt=/poteto-mode");
});

test("spawnCommand leaves the prompt as typed when poteto is off", () => {
    assert.equal(spawnCommand("bb", { model: "opus", effort: "high", project: "", poteto: false }, "fix it").pop(), "--prompt=fix it");
    assert.equal(spawnCommand("bb", { model: "opus", effort: "high", project: "" }, "fix it").pop(), "--prompt=fix it");
});

test("normalize keeps poteto on and defaults a missing one to off", () => {
    assert.equal(normalize({ model: "opus", effort: "high", project: "", poteto: true }, models, projects).poteto, true);
    assert.equal(normalize({ model: "opus", effort: "high", project: "" }, models, projects).poteto, false);
});

test("parseSpawn reads the thread id, or bb's error", () => {
    assert.deepEqual(parseSpawn('{"id":"thr_abc","status":"active"}', "", 0), { id: "thr_abc", error: "" });
    assert.deepEqual(parseSpawn('{"thread":{"id":"thr_def"}}', "", 0), { id: "thr_def", error: "" });
    assert.deepEqual(parseSpawn('{"ok":false,"error":{"code":"error","message":"Machine gone.","hint":"Try another."}}', "Error: Machine gone.", 1),
        { id: "", error: "Machine gone. Try another." });
    assert.deepEqual(parseSpawn("", "warning\nerror: required option '--project <id>' not specified\n", 1),
        { id: "", error: "error: required option '--project <id>' not specified" });
    assert.deepEqual(parseSpawn("", "", 127), { id: "", error: "bb exited with 127" });
    // An id with a failing exit code is not a thread.
    assert.equal(parseSpawn('{"id":"thr_abc"}', "", 1).id, "");
});

test("checkDefault takes ids or names and refuses what bb does not list", () => {
    assert.deepEqual(checkDefault("model", "Sonnet 5.5", models, projects, ""), { value: "claude-sonnet-5-5", error: "" });
    assert.deepEqual(checkDefault("model", "claude-opus-5-5", models, projects, ""), { value: "claude-opus-5-5", error: "" });
    assert.deepEqual(checkDefault("model", "Haiku", models, projects, ""), { value: "haiku", error: "" });
    assert.match(checkDefault("model", "gpt", models, projects, "").error, /unknown model "gpt"; one of opus, sonnet, haiku, claude-opus-5-5/);
    assert.deepEqual(checkDefault("effort", "MAX", models, projects, "claude-sonnet-5-5"), { value: "max", error: "" });
    assert.match(checkDefault("effort", "ultracode", models, projects, "claude-sonnet-5-5").error, /^Sonnet 5\.5 takes low, medium, high, max/);
    assert.deepEqual(checkDefault("project", "Bolt", models, projects, ""), { value: "proj_kmyjbmui8h", error: "" });
    assert.deepEqual(checkDefault("project", "proj_nd6khizj7d", models, projects, ""), { value: "proj_nd6khizj7d", error: "" });
    assert.deepEqual(checkDefault("project", "none", models, projects, ""), { value: "", error: "" });
    assert.deepEqual(checkDefault("project", "No project", models, projects, ""), { value: "", error: "" });
    assert.match(checkDefault("project", "nope", models, projects, "").error, /unknown project "nope"/);
    assert.match(checkDefault("colour", "red", models, projects, "").error, /unknown setting "colour"; model, effort, project or poteto/);
    assert.deepEqual(checkDefault("poteto", "ON", models, projects, ""), { value: true, error: "" });
    assert.deepEqual(checkDefault("poteto", "off", models, projects, ""), { value: false, error: "" });
    assert.deepEqual(checkDefault("poteto", "Yes", models, projects, ""), { value: true, error: "" });
    assert.deepEqual(checkDefault("poteto", "0", models, projects, ""), { value: false, error: "" });
    assert.match(checkDefault("poteto", "maybe", models, projects, "").error, /poteto takes on or off, not "maybe"/);
});

test("leaderArguments offers the aliases and the default model's efforts", () => {
    const args = leaderArguments(models, DEFAULTS);
    assert.deepEqual(args[0], {
        key: "m", name: "model", value: "opus",
        choices: [
            { value: "opus", name: "Opus" },
            { value: "sonnet", name: "Sonnet" },
            { value: "haiku", name: "Haiku" },
        ],
    });
    assert.equal(args[1].value, "high");
    assert.deepEqual(args[1].choices.map(c => c.value), opus.efforts);
});

test("leaderArguments puts a default model past the first ones first", () => {
    const more = models.concat([{ id: "claude-opus-4-6", name: "Opus 4.6", efforts: ["low", "max"], defaultEffort: "max" }]);
    const args = leaderArguments(more, { model: "claude-opus-4-6", effort: "high" });
    assert.deepEqual(args[0].choices.map(c => c.name), ["Opus 4.6", "Opus", "Sonnet", "Haiku"]);
    // An effort the model does not take is shown as the one it starts with.
    assert.equal(args[1].value, "max");
});

test("leaderArguments has no effort for a model that takes none", () => {
    const args = leaderArguments(models, { model: "claude-haiku-5-5", effort: "high" });
    assert.deepEqual(args.map(a => a.name), ["model"]);
});

test("readOpenWith changes only what it is given", () => {
    assert.deepEqual(readOpenWith("", "", "", models, projects), { change: {}, pick: false, error: "" });
    assert.deepEqual(readOpenWith("Sonnet 5.5", "MAX", "bolt", models, projects), {
        change: { model: "claude-sonnet-5-5", effort: "max", project: "proj_kmyjbmui8h" }, pick: false, error: "",
    });
    assert.deepEqual(readOpenWith("", "", "none", models, projects), { change: { project: "" }, pick: false, error: "" });
    assert.deepEqual(readOpenWith("", "low", "?", models, projects), { change: { effort: "low" }, pick: true, error: "" });
});

test("readOpenWith refuses a model or a project bb does not list", () => {
    assert.match(readOpenWith("gpt", "", "", models, projects).error, /unknown model "gpt"/);
    assert.match(readOpenWith("", "", "nope", models, projects).error, /unknown project "nope"/);
});
