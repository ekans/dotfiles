// Logic for the new bb thread overlay (shell.qml): reading what bb lists,
// cycling the model and the effort, the project list, and the
// `bb thread spawn` command.
//
// Plain ECMAScript, no QML: the overlay imports it and tests/bbnew.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses — no object
// spread, no regex lookbehind or named groups.

export const PROVIDER = "claude-code";

// bb's projectless home: a thread there gets a scratch workspace, no repo.
// pick-to-bb starts its threads there too.
export const PERSONAL_PROJECT = "proj_personal";
export const PERSONAL_ENVIRONMENT = "personal-workspace";

export const NO_PROJECT = { id: "", name: "No project" };

// What a thread starts with until Ctrl+S saves something else. Ids; "" is no
// project.
export const DEFAULTS = { model: "opus", effort: "high", project: "" };

// Claude Code's aliases, offered ahead of the models bb lists: a thread
// started with one gets the newest model of that family, so no version is
// named here.
export const ALIASES = [
    { id: "opus", name: "Opus" },
    { id: "sonnet", name: "Sonnet" },
    { id: "haiku", name: "Haiku" },
];

// Until bb has listed its models once: enough to start a thread with the
// defaults.
export const FALLBACK_MODELS = [
    { id: "opus", name: "Opus", efforts: ["low", "medium", "high", "xhigh", "ultracode", "max"], defaultEffort: "high" },
];

const SETTINGS = ["model", "effort", "project"];

function parseJson(text) {
    try {
        return JSON.parse(String(text || ""));
    } catch (e) {
        return null;
    }
}

function listOf(value, key) {
    if (Array.isArray(value))
        return value;
    if (value && Array.isArray(value[key]))
        return value[key];
    return [];
}

function lastLine(text) {
    const lines = String(text || "").trim().split("\n");
    return lines[lines.length - 1].trim();
}

// --- what bb lists ------------------------------------------------------------------

// The aliases bb has a model for, then `models`. An alias takes the efforts
// of the model it stands for today, the first of its family: bb lists the
// newest first.
function withAliases(models) {
    const aliases = [];
    for (const alias of ALIASES) {
        const newest = models.find(m => m.id.indexOf("claude-" + alias.id + "-") === 0);
        if (newest)
            aliases.push({ id: alias.id, name: alias.name, efforts: newest.efforts.slice(), defaultEffort: newest.defaultEffort });
    }
    return aliases.concat(models);
}

// `bb provider models claude-code --json`, the aliases first, then in bb's
// order: [{id, name, efforts, defaultEffort}].
export function parseModels(text) {
    const models = [];
    for (const m of listOf(parseJson(text), "models")) {
        const id = m && (m.model || m.id);
        if (!id)
            continue;
        const efforts = (Array.isArray(m.supportedReasoningEfforts) ? m.supportedReasoningEfforts : [])
            .map(e => typeof e === "string" ? e : (e && e.reasoningEffort) || "")
            .filter(e => e !== "");
        models.push({
            id: String(id),
            name: String(m.displayName || id),
            efforts: efforts,
            defaultEffort: String(m.defaultReasoningEffort || ""),
        });
    }
    return withAliases(models);
}

// bb marks an archived project only in its name.
const ARCHIVED = / \(archived\)$/;

// `bb project list --json`, by name, without the archived ones: [{id, name}].
export function parseProjects(text) {
    const projects = [];
    for (const p of listOf(parseJson(text), "projects")) {
        if (!p || !p.id || !p.name || p.id === PERSONAL_PROJECT || ARCHIVED.test(p.name))
            continue;
        projects.push({ id: String(p.id), name: String(p.name) });
    }
    projects.sort((a, b) => {
        const x = a.name.toLowerCase();
        const y = b.name.toLowerCase();
        return x < y ? -1 : x > y ? 1 : 0;
    });
    return projects;
}

// The output niri has focused, from `niri msg --json focused-output`.
export function parseFocusedOutput(text) {
    const value = parseJson(text);
    return value && typeof value.name === "string" ? value.name : "";
}

export function findModel(models, id) {
    return models.find(m => m.id === id) || null;
}

// NO_PROJECT for "", null for an id bb does not list.
export function findProject(projects, id) {
    if (!id)
        return NO_PROJECT;
    return projects.find(p => p.id === id) || null;
}

export function modelName(models, id) {
    const model = findModel(models, id);
    return model ? model.name : id;
}

export function projectName(projects, id) {
    const project = findProject(projects, id);
    return project ? project.name : id;
}

// --- changing the settings ------------------------------------------------------------

// The entry `step` places after `current` in `list`, wrapping round; the first
// one when `current` is not in it.
export function cycle(list, current, step) {
    if (list.length === 0)
        return current;
    const i = list.indexOf(current);
    if (i === -1)
        return list[0];
    return list[((i + step) % list.length + list.length) % list.length];
}

export function nextModel(models, id, step) {
    return cycle(models.map(m => m.id), id, step);
}

export function nextEffort(model, effort, step) {
    return model ? cycle(model.efforts, effort, step) : effort;
}

// `effort` if `model` takes it, else the model's own default, else its first.
export function effortFor(model, effort) {
    if (!model || model.efforts.length === 0 || model.efforts.indexOf(effort) !== -1)
        return effort;
    if (model.efforts.indexOf(model.defaultEffort) !== -1)
        return model.defaultEffort;
    return model.efforts[0];
}

// `settings` made to fit what bb lists: a model it has, an effort that model
// takes, and no project in place of one it no longer lists. An empty project
// list is bb not having answered yet, so the project stays.
export function normalize(settings, models, projects) {
    const model = findModel(models, settings.model) || models[0] || null;
    let project = settings.project || "";
    if (project !== "" && projects.length > 0 && !findProject(projects, project))
        project = "";
    return {
        model: model ? model.id : settings.model,
        effort: effortFor(model, settings.effort),
        project: project,
    };
}

// Whether each setting differs from the default.
export function changes(settings, defaults) {
    const changed = {};
    for (const key of SETTINGS)
        changed[key] = settings[key] !== defaults[key];
    return changed;
}

// --- the project list -----------------------------------------------------------------

// What a query is looked for in. Ids only for a query that starts like one: a
// letter or two would find themselves in most of them.
function searchText(project, query) {
    if (project === NO_PROJECT)
        return "no project none personal";
    return (query.indexOf("proj_") === 0 ? project.id : project.name).toLowerCase();
}

// "No project" and the projects, those whose name starts with `query` first,
// then those whose name holds it, or whose id does for a query starting
// "proj_".
export function filterProjects(projects, query) {
    const all = [NO_PROJECT].concat(projects);
    const q = String(query || "").trim().toLowerCase();
    if (q === "")
        return all;
    const starting = [];
    const holding = [];
    for (const p of all) {
        if (p.name.toLowerCase().indexOf(q) === 0)
            starting.push(p);
        else if (searchText(p, q).indexOf(q) !== -1)
            holding.push(p);
    }
    return starting.concat(holding);
}

// --- starting the thread --------------------------------------------------------------

// `bb thread spawn` for `prompt` with these settings. `--prompt=` keeps a prompt
// that starts with a dash from reading as an option.
export function spawnCommand(bb, settings, prompt) {
    const command = [bb, "thread", "spawn", "--json", "--provider", PROVIDER,
        "--model", settings.model, "--reasoning-level", settings.effort];
    if (settings.project)
        command.push("--project", settings.project);
    else
        command.push("--project", PERSONAL_PROJECT, "--environment-provider", PERSONAL_ENVIRONMENT);
    command.push("--prompt=" + prompt);
    return command;
}

// What `bb thread spawn --json` answered: {id, error}, one of them empty.
export function parseSpawn(stdout, stderr, code) {
    const answer = parseJson(stdout);
    const id = answer && (answer.id || (answer.thread && answer.thread.id));
    if (code === 0 && id)
        return { id: String(id), error: "" };
    const failure = answer && answer.error;
    let error = (failure && failure.message) || lastLine(stderr) || lastLine(stdout) || "bb exited with " + code;
    if (failure && failure.hint)
        error += " " + failure.hint;
    return { id: "", error: error };
}

// --- defaults over IPC ----------------------------------------------------------------

// A default set with `qs ipc call bbnew set <key> <value>`, checked against what
// bb lists: {value, error}, value the id to store. A model or a project may be
// given by id or by name, no project as "none"; an effort has to be one the
// default model takes.
export function checkDefault(key, value, models, projects, modelId) {
    const v = String(value || "").trim();
    const lower = v.toLowerCase();
    if (key === "model") {
        const model = models.find(m => m.id === v || m.name.toLowerCase() === lower);
        if (model)
            return { value: model.id, error: "" };
        return { value: "", error: "unknown model " + JSON.stringify(v) + "; one of " + models.map(m => m.id).join(", ") };
    }
    if (key === "effort") {
        const model = findModel(models, modelId);
        const efforts = model ? model.efforts : [];
        if (efforts.indexOf(lower) !== -1)
            return { value: lower, error: "" };
        return { value: "", error: modelName(models, modelId) + " takes " + efforts.join(", ") + ", not " + JSON.stringify(v) };
    }
    if (key === "project") {
        if (lower === "" || lower === "none" || lower === NO_PROJECT.name.toLowerCase())
            return { value: "", error: "" };
        const project = projects.find(p => p.id === v || p.name.toLowerCase() === lower);
        if (project)
            return { value: project.id, error: "" };
        return { value: "", error: "unknown project " + JSON.stringify(v) + "; see `bb project list`, or none" };
    }
    return { value: "", error: "unknown setting " + JSON.stringify(key) + "; model, effort or project" };
}

// --- Super+Space's bb page ----------------------------------------------------------------
// chauvenity's leader menu (its leader-menu.mjs) asks `ipc call bbnew
// choices` what its bb page offers, then opens the overlay with
// `ipc call bbnew openWith <model> <effort> <project>`.

// How many of the models the bb page steps through: the aliases, which come
// first.
export const LEADER_MODELS = 3;

// The bb page's arguments, in the shape chauvenity's leader.mjs reads: the
// first models bb lists (and the default model, if it is not one of them),
// and the default model's efforts, each with its default as its value.
export function leaderArguments(models, defaults) {
    const model = findModel(models, defaults.model);
    const offered = models.slice(0, LEADER_MODELS);
    if (model && offered.indexOf(model) === -1)
        offered.unshift(model);
    const args = [{
        key: "m", name: "model", value: defaults.model,
        choices: offered.map(m => ({ value: m.id, name: m.name })),
    }];
    if (model && model.efforts.length > 0)
        args.push({
            key: "e", name: "effort", value: effortFor(model, defaults.effort),
            choices: model.efforts.map(e => ({ value: e, name: e })),
        });
    return args;
}

// What `openWith` asked for, checked: {change, pick, error}. `change` holds
// the settings given, as ids, to put over those the overlay opens with: ""
// leaves a setting as it is, a project "none" is no project, and "?" opens
// the project list instead.
export function readOpenWith(model, effort, project, models, projects) {
    const change = {};
    if (String(model || "").trim() !== "") {
        const checked = checkDefault("model", model, models, projects, "");
        if (checked.error)
            return { change: {}, pick: false, error: checked.error };
        change.model = checked.value;
    }
    const e = String(effort || "").trim().toLowerCase();
    if (e !== "")
        change.effort = e;
    const p = String(project || "").trim();
    if (p !== "" && p !== "?") {
        const checked = checkDefault("project", p, models, projects, "");
        if (checked.error)
            return { change: {}, pick: false, error: checked.error };
        change.project = checked.value;
    }
    return { change: change, pick: p === "?", error: "" };
}
