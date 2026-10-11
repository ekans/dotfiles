pragma ComponentBehavior: Bound

// Mod+E's translator: French into English, and English made simple, from the
// keyboard. `qs -c chauvenity ipc call translate choose` (Mod+E in
// ~/.config/niri) reads the selection clipboard (the primary selection, what
// middle-click pastes), and a panel on the right of the focused output
// (TranslatePanel) shows it and offers the three modes, a key each, the way
// Mod+B's hints do, with what each would do with it:
//
//     w  word        a word or a set phrase (faire le point): its senses from
//                    Wiktionary. ←→ pick one, ↵ pastes it over the
//                    selection, c copies it. Nothing selected: type it.
//     p  paragraph   translated by the LLM. ↵ pastes it over the selection,
//                    c copies it; Ctrl+Z in the app undoes a paste
//     f  fix         the LLM's fix, change by change with why. Tab/j/k move,
//                    Space keeps the original wording, ↵ pastes the result,
//                    Esc drops it
//
// All three, every time, whatever is selected: guessing which fit got it
// wrong too often. Any other key closes the chooser; once one shows its
// result, the others' keys switch to them on the same text. Calling `choose`
// again closes whatever is open, as does `close`.
//
// `run` skips the chooser: Super+Space t w, t p and t f (leader-menu.mjs)
// start their mode as soon as the selection has been read.
//
//     qs -c chauvenity ipc call translate run paragraph   # word, paragraph or fix
//
// The primary selection is the last text selected anywhere, and stays so
// after it is no longer highlighted: the panel shows which it is. Pasted over
// text no longer selected, a result lands at the cursor; Ctrl+Z takes it out.
//
// A result replaces the selection only while the window it came from still
// has focus; either way it is left on the clipboard. translate.mjs makes the
// decisions and is tested under node; translate.sh does the talking to niri,
// the clipboard, Wiktionary and `claude -p`.

import QtQuick
import Quickshell
import Quickshell.Io
import "translate.mjs" as Tr

Scope {
    id: tr

    required property var theme
    // The output niri has focused, by name: the panel opens on it.
    required property string outputName

    // Just before it takes the keyboard: shell.qml takes the hints and any
    // open panel down, whose grabs would hold it.
    signal opening()

    readonly property string script: Quickshell.shellPath("translate.sh")
    readonly property alias panel: panel

    // Where it is, all of it in the panel: "" (closed), "probing" (reading
    // the focused window and the selection), "choosing" (the modes, waiting
    // for a key), "typing" (a word), "looking" (waiting on the dictionary),
    // "word" (its senses, or why there are none), "working" (waiting on the
    // LLM, or pasting), "paragraph" (the translation), "fix" (the changes),
    // "done" (how it went, for a few seconds).
    property string stage: ""
    // The output whose panel shows it.
    property string output: ""
    // What the modes work on: the selection, or the word typed.
    property string text: ""
    // Whether `text` is the selection, so a result can replace it.
    property bool selected: false
    property string windowId: ""
    property bool terminal: false

    // The dictionary lookup of `text`: "" (none made), "pending", "found",
    // "none" or "unreachable"; the term asked for, its senses, and the form it
    // was reached from ("feminine singular of décalé"), if any.
    property string lookup: ""
    property string term: ""
    property var senses: []
    property string formNote: ""
    property int gloss: 0
    readonly property var glosses: Tr.flatGlosses(tr.senses)

    // The paragraph's translation.
    property string translation: ""

    // The fix: the text cut into what stays and the changes, the change the
    // panel is on, the ones kept as they were. And how long the LLM took.
    property var parts: []
    property int current: 0
    property var kept: []
    property string answerTime: ""
    readonly property var changes: Tr.changesOf(tr.parts)

    property string mode: ""
    // The mode `run` asked for, picked once the selection is read; "" for
    // the chooser.
    property string preset: ""
    property double startedAt: 0
    // What the panel says while working and once done, with its tone: "good"
    // or "bad". `outcome` is what to say once pasted, or copied.
    property string message: ""
    property string tone: ""
    property var outcome: ({ pasted: "", copied: "" })

    // The panel holds the keyboard meanwhile. Not while the LLM works, nor
    // while pasting: the keys go back to the window the result goes into.
    readonly property bool wantsKeys:
        ["choosing", "typing", "looking", "word", "paragraph", "fix"].indexOf(tr.stage) !== -1

    IpcHandler {
        target: "translate"

        // Calling it again while it is open closes it.
        function choose(): void {
            tr.choose();
        }
        function close(): void {
            tr.close();
        }
        // Answers why not, or "" once it has started.
        function run(mode: string): string {
            return tr.run(mode);
        }
    }

    // In the bar's journal (journalctl --user -u chauvenity-quickshell),
    // with translate.sh's own steps in $XDG_RUNTIME_DIR/translate.log.
    function log(message) {
        console.info(`translate: ${message}`);
    }

    // What `text` is, for the log: its length, and its start on one line.
    function quoted(text) {
        return `(${text.length}) “${Tr.preview(text, 60)}”`;
    }

    function choose() {
        tr.log(`choose: stage was "${tr.stage}", output ${tr.outputName}`);
        if (tr.stage !== "") {
            tr.close();
            return;
        }
        tr.opening();
        tr.reset();
        tr.output = tr.outputName;
        tr.stage = "probing";
        probe.running = true;
    }

    // A mode at once, whatever was open; "" or why not.
    function run(name) {
        const mode = Tr.modeKey(name);
        tr.log(`run ${name}: stage was "${tr.stage}", output ${tr.outputName}`);
        if (mode === "")
            return `unknown mode "${name}": word, paragraph or fix`;
        tr.opening();
        tr.reset();
        tr.preset = mode;
        tr.output = tr.outputName;
        tr.stage = "probing";
        probe.running = true;
        return "";
    }

    function close() {
        tr.reset();
        tr.stage = "";
    }

    // Everything back as it was, but a paste under way: it puts the
    // clipboard back.
    function reset() {
        doneTimeout.stop();
        lookupProcess.running = false;
        llm.running = false;
        tr.text = "";
        tr.selected = false;
        tr.windowId = "";
        tr.terminal = false;
        tr.lookup = "";
        tr.term = "";
        tr.senses = [];
        tr.formNote = "";
        tr.gloss = 0;
        tr.translation = "";
        tr.parts = [];
        tr.current = 0;
        tr.kept = [];
        tr.answerTime = "";
        tr.mode = "";
        tr.preset = "";
        tr.message = "";
        tr.tone = "";
    }

    function finish(good, message) {
        tr.log(`done ${good ? "ok" : "failed"}: ${message}`);
        tr.stage = "done";
        tr.tone = good ? "good" : "bad";
        tr.message = message;
        doneTimeout.interval = good ? 3500 : 6000;
        doneTimeout.restart();
    }

    // --- choosing ------------------------------------------------------------

    function probed(output) {
        if (tr.stage !== "probing")
            return;
        const found = Tr.readProbe(output);
        tr.windowId = found.windowId;
        tr.terminal = found.terminal;
        tr.text = found.selection;
        tr.selected = found.selection.trim() !== "";
        tr.log(`probed: window ${found.windowId}${found.terminal ? " (terminal)" : ""}, selection ${tr.quoted(found.selection)}`);
        // Before w is even pressed, so that it answers at once and the panel
        // says what it found.
        tr.lookUp(found.selection);
        tr.stage = "choosing";
        if (tr.preset !== "")
            tr.pick(tr.preset);
    }

    // Looks `text` up in the dictionary, if it is a word or a set phrase
    // rather than a sentence; says whether it is.
    function lookUp(text) {
        tr.senses = [];
        tr.formNote = "";
        tr.gloss = 0;
        const terms = Tr.lookupTerms(text);
        tr.term = terms[0] ?? "";
        tr.lookup = terms.length > 0 ? "pending" : "";
        if (terms.length === 0)
            return false;
        lookupProcess.exec(["sh", tr.script, "word"].concat(terms));
        return true;
    }

    // A key while the panel holds the keyboard, from TranslatePanel, but
    // while typing. Answers whether it was one of the stage's.
    function panelKey(event) {
        if (tr.theme.modifierKeys.indexOf(event.key) !== -1)
            return false;
        if (tr.stage === "choosing") {
            const picked = Tr.pickedMode(event.text);
            if (picked === "") {
                tr.log(`chooser: key ${event.key} “${event.text}” picks nothing, closing`);
                tr.close();
            } else {
                tr.pick(picked);
            }
            return true;
        }
        if (tr.stage === "looking") {
            if (event.key === Qt.Key_Escape)
                tr.close();
            return true;
        }
        // Another mode on the same text.
        const other = Tr.pickedMode(event.text);
        if (other !== "" && other !== tr.mode) {
            tr.pick(other);
            return true;
        }
        if (tr.stage === "word")
            return tr.wordKey(event);
        if (tr.stage === "paragraph")
            return tr.paragraphKey(event);
        if (tr.stage === "fix")
            return tr.fixKey(event);
        return false;
    }

    function pick(mode) {
        tr.log(`picked ${mode}: selected ${tr.selected}, lookup "${tr.lookup}", text ${tr.quoted(tr.text)}`);
        tr.mode = mode;
        if (mode === "w") {
            if (tr.text.trim() === "")
                tr.stage = "typing";
            else if (tr.lookup === "pending")
                tr.stage = "looking";
            else
                tr.showWord();
        } else if (tr.text.trim() === "") {
            tr.finish(false, "nothing selected");
        } else {
            tr.ask(mode === "p" ? "paragraph" : "fix");
        }
    }

    // A word typed into the panel, from TranslatePanel. A sentence shows as
    // one, for p to translate.
    function typed(text) {
        if (text.trim() === "") {
            tr.close();
            return;
        }
        tr.text = text;
        tr.selected = false;
        if (tr.lookUp(text))
            tr.stage = "looking";
        else
            tr.showWord();
    }

    // --- word ----------------------------------------------------------------

    function looked(output) {
        const answer = Tr.readLookup(output);
        if (tr.lookup !== "pending" || answer.asked !== tr.term)
            return;
        const senses = answer.status === "found" ? Tr.readEntry(answer.body) : [];
        const lemma = Tr.lemmaOf(senses);
        if (lemma !== "" && tr.formNote === "") {
            // Its senses are the lemma's: "décalée" is "feminine singular of
            // décalé". Once only.
            tr.formNote = senses[0].text;
            tr.term = lemma;
            Qt.callLater(() => lookupProcess.exec(["sh", tr.script, "word", lemma]));
            return;
        }
        // As many as fit in the panel.
        tr.senses = senses.slice(0, 8);
        tr.lookup = tr.senses.length > 0 ? "found"
            : answer.status === "unreachable" ? "unreachable"
            : "none";
        if (tr.stage === "looking")
            tr.showWord();
    }

    // Its senses, or why there are none: the panel says so, and p or f take
    // the text on from there.
    function showWord() {
        tr.gloss = 0;
        tr.stage = "word";
    }

    // A key while the senses show. Answers whether it was one of them.
    function wordKey(event) {
        const count = tr.glosses.length;
        if (count === 0) {
            if (event.key !== Qt.Key_Escape && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
                return false;
            tr.close();
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Down) {
            tr.gloss = (tr.gloss + 1) % count;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) {
            tr.gloss = (tr.gloss - 1 + count) % count;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            tr.useGloss(tr.selected);
        } else if (event.text.toLowerCase() === "c") {
            tr.useGloss(false);
        } else if (event.key === Qt.Key_Escape) {
            tr.close();
        } else {
            return false;
        }
        return true;
    }

    function useGloss(paste) {
        const word = tr.glosses[tr.gloss]?.text ?? "";
        if (word === "") {
            tr.close();
            return;
        }
        tr.selected = paste;
        tr.deliver(word, {
            pasted: `“${Tr.preview(word, 30)}” pasted · Ctrl+Z undoes it`,
            copied: `“${Tr.preview(word, 30)}” copied`
        });
    }

    // --- paragraph and fix ---------------------------------------------------

    function ask(kind) {
        tr.stage = "working";
        tr.startedAt = Date.now();
        tr.message = kind === "fix" ? "checking the English…" : "translating…";
        tr.log(`ask ${kind}: ${tr.quoted(tr.text)}`);
        llm.exec(["sh", tr.script, kind, tr.text]);
    }

    function answered(output) {
        if (tr.stage !== "working" || (tr.mode !== "p" && tr.mode !== "f"))
            return;
        const answer = Tr.readReply(output);
        const seconds = ((Date.now() - tr.startedAt) / 1000).toFixed(1);
        tr.log(`answer in ${seconds} s: ${answer.status} ${tr.quoted(answer.body)}`);
        if (answer.status !== "ok") {
            console.warn(`translate: ${answer.status} ${answer.body}`);
            tr.finish(false, Tr.preview(answer.body, 80) || "no answer from claude");
            return;
        }
        if (tr.mode === "p") {
            const english = answer.body.replace(/\n$/, "");
            // Back as it was: nothing French in it, maybe not the text meant.
            if (english.trim() === tr.text.trim()) {
                tr.finish(false, `no French in “${Tr.preview(tr.text, 40)}”`);
                return;
            }
            tr.translation = english;
            tr.answerTime = `${seconds} s`;
            tr.stage = "paragraph";
            return;
        }
        const fix = Tr.readFix(answer.body);
        if (!fix) {
            console.warn(`translate: the fix is not the JSON asked for: ${answer.body}`);
            tr.finish(false, "claude’s answer was not the JSON asked for");
            return;
        }
        const parts = Tr.diffChanges(tr.text, fix.fixed, fix.notes);
        if (Tr.changesOf(parts).length === 0) {
            tr.finish(true, `nothing to fix (${seconds} s)`);
            return;
        }
        tr.parts = parts;
        tr.current = 0;
        tr.kept = [];
        tr.answerTime = `${seconds} s`;
        tr.stage = "fix";
    }

    // A key while the translation shows. Answers whether it was one of them.
    function paragraphKey(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            tr.useTranslation(tr.selected);
        } else if (event.text.toLowerCase() === "c") {
            tr.useTranslation(false);
        } else if (event.key === Qt.Key_Escape) {
            tr.close();
        } else {
            return false;
        }
        return true;
    }

    function useTranslation(paste) {
        tr.selected = paste;
        tr.deliver(tr.translation, {
            pasted: `translated in ${tr.answerTime} · Ctrl+Z undoes it`,
            copied: paste ? "translation copied: the window changed" : "translation copied"
        });
    }

    // A key while the changes show. Answers whether it was one of them.
    function fixKey(event) {
        const count = tr.changes.length;
        const key = event.text.toLowerCase();
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down || key === "j") {
            tr.current = (tr.current + 1) % count;
        } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up || key === "k") {
            tr.current = (tr.current - 1 + count) % count;
        } else if (event.key === Qt.Key_Space) {
            const index = tr.changes[tr.current].index;
            tr.kept = tr.kept.indexOf(index) === -1
                ? tr.kept.concat([index])
                : tr.kept.filter(i => i !== index);
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            tr.applyFix();
        } else if (event.key === Qt.Key_Escape) {
            tr.close();
        } else {
            return false;
        }
        return true;
    }

    function applyFix() {
        const count = tr.changes.length;
        const made = count - tr.kept.length;
        if (made === 0) {
            tr.finish(true, "kept as it was");
            return;
        }
        tr.deliver(Tr.applyChanges(tr.parts, tr.kept), {
            pasted: `${made} of ${count} changes made · Ctrl+Z undoes it`,
            copied: tr.selected ? "fixed text copied: the window changed" : "fixed text copied"
        });
    }

    // --- the result ----------------------------------------------------------

    // Puts `text` in place of the selection while it is still selected, in
    // the window it came from; else on the clipboard.
    function deliver(text, outcome) {
        tr.log(`deliver: ${tr.selected ? `paste into window ${tr.windowId}` : "copy"} ${tr.quoted(text)}`);
        tr.outcome = outcome;
        tr.stage = "working";
        tr.message = tr.selected ? "pasting…" : "copying…";
        paster.exec(tr.selected
            ? ["sh", tr.script, "paste", tr.windowId, text, tr.terminal ? "terminal" : ""]
            : ["sh", tr.script, "copy", text]);
    }

    function delivered(output) {
        const status = Tr.readReply(output).status;
        if (status === "pasted")
            tr.finish(true, tr.outcome.pasted);
        else if (status === "copied")
            tr.finish(true, tr.outcome.copied);
        else
            tr.finish(false, "could not paste, nor copy");
    }

    // --- processes -----------------------------------------------------------

    Process {
        id: probe
        command: ["sh", tr.script, "probe", "4000"]
        stdout: StdioCollector {
            id: probeOutput
            onStreamFinished: tr.probed(probeOutput.text)
        }
    }

    Process {
        id: lookupProcess
        stdout: StdioCollector {
            id: lookupOutput
            onStreamFinished: tr.looked(lookupOutput.text)
        }
    }

    Process {
        id: llm
        stdout: StdioCollector {
            id: llmOutput
            onStreamFinished: tr.answered(llmOutput.text)
        }
    }

    Process {
        id: paster
        stdout: StdioCollector {
            id: pasterOutput
            onStreamFinished: tr.delivered(pasterOutput.text)
        }
    }

    Timer {
        id: doneTimeout
        onTriggered: tr.close()
    }

    TranslatePanel {
        id: panel
        theme: tr.theme
        translator: tr
    }
}
