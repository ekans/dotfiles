// What the lock screen (shell.qml, LockFace.qml) decides: what a message from
// pam_fprintd means, what to do when a fingerprint attempt ends, and the words
// on screen.
//
// Plain ECMAScript, no QML: the lock imports it and tests/lock.test.mjs runs
// it under node. Keep to what Qt's JavaScript engine parses.

// Fingerprint attempts, across the whole time the screen is locked, before
// the sensor is left alone and only the password unlocks. pam_fprintd's own
// max-tries is the same 3, but it counts per PAM run and a run that times out
// starts it again.
export const FINGER_TRIES = 3;

// Fireflies circling the middle, one per character typed; a longer password
// stops adding them.
export const MAX_FIREFLIES = 16;

export function fireflyCount(length) {
    return Math.max(0, Math.min(length, MAX_FIREFLIES));
}

export function ringRadius(count) {
    return 30 + 3.5 * fireflyCount(count);
}

export const EXIT_MS = 700;

export const EMBER_LIFE_MS = 9000;
export const EMBER_LIFE_VARIATION_MS = 3000;
export const PREFILL_EMBERS = 60;

// The scene goes to sleep after SLEEP_MS with no key, no finger and no PAM
// verdict: the embers stop rising, and BURNOUT_MS later, once the last one
// has burnt out, nothing on screen moves. Anything that moves makes Qt redraw
// the whole window every frame, so this is what keeps a lock left for hours
// from costing a few percent of a core all that time.
export const SLEEP_MS = 20000;
export const BURNOUT_MS = EMBER_LIFE_MS + EMBER_LIFE_VARIATION_MS + 1000;

export function wakeBurst(dimmedMs) {
    const burnt = Math.max(0, Math.min(1, dimmedMs / EMBER_LIFE_MS));
    return Math.round(PREFILL_EMBERS * burnt);
}

// What a message pam_fprintd sends means. Its strings, from
// /usr/lib64/security/pam_fprintd.so (the session runs in en_US):
//
//     "Place your right index finger on Goodix MOC Fingerprint Sensor"  info
//     "Failed to match fingerprint"                                     error
//     "Verification timed out"                                          error
//     "Swipe your finger again", "Swipe was too fast, try again", …     error
//
// "prompt": it is waiting for a finger. "nomatch": a finger that is not an
// enrolled one. "retry": a bad read, which pam_fprintd does not count as a
// try. "timeout": nobody touched it for 30 s; a new run starts. "other":
// anything else, shown nowhere.
export function fingerEvent(message, isError) {
    const text = String(message ?? "").toLowerCase();
    if (!isError)
        return /^(place|swipe) your/.test(text) ? "prompt" : "other";
    if (text.includes("failed to match"))
        return "nomatch";
    if (text.includes("timed out"))
        return "timeout";
    if (/again|too (fast|short)|centered|centred/.test(text))
        return "retry";
    return "other";
}

// What to do once a fingerprint PAM run completes.
//
//   result      "success", "failed", "maxtries" or "error" (PamResult)
//   sawPrompt   whether this run got as far as asking for a finger
//   noMatches   unrecognised fingers so far, this run's included
//   deadRuns    runs in a row before this one that never asked for a finger
//
// "unlock", "off" (tries used up: password only), "restart" (a timeout: ask
// again at once), "later" (fprintd or the sensor did not answer: ask again in
// a few seconds) or "unavailable" (it never does: stop asking, hide the
// fingerprint).
export function fingerAfter({ result, sawPrompt, noMatches, deadRuns }) {
    if (result === "success")
        return "unlock";
    if (result === "maxtries" || noMatches >= FINGER_TRIES)
        return "off";
    if (!sawPrompt)
        return deadRuns + 1 >= 3 ? "unavailable" : "later";
    return "restart";
}

// The line under the fingerprint.
//
//   state   "ready", "retry", "nomatch", "match", "off" or "unavailable"
export function fingerText(state, triesLeft) {
    switch (state) {
    case "ready":
        return "Touch the sensor or type your password";
    case "retry":
        return "Try again";
    case "nomatch":
        return `Not recognised · ${triesLeft} ${triesLeft === 1 ? "try" : "tries"} left`;
    case "match":
        return "Recognised";
    case "off":
        return `Fingerprint off after ${FINGER_TRIES} tries — use your password`;
    default:
        return "";
    }
}

// The line under the fireflies.
//
//   state   "idle", "typing", "checking", "wrong", "error" or "unlocked"
export function passwordText(state) {
    switch (state) {
    case "checking":
        return "Checking…";
    case "wrong":
        return "Wrong password";
    case "error":
        return "Could not check the password — try again";
    default:
        return "";
    }
}

// The PamResult enum's value as the names fingerAfter takes.
export function resultName(value, names) {
    if (value === names.Success)
        return "success";
    if (value === names.MaxTries)
        return "maxtries";
    if (value === names.Failed)
        return "failed";
    return "error";
}

// "16:16 · Sat 10 Oct", the line at the top.
export function clockLine(date) {
    const pad = n => String(n).padStart(2, "0");
    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return `${pad(date.getHours())}:${pad(date.getMinutes())} · ${days[date.getDay()]} ${date.getDate()} ${months[date.getMonth()]}`;
}

// Whether any keyboard's Caps Lock LED is lit, from
// `cat /sys/class/leds/*::capslock/brightness`: one number per keyboard.
export function capsLockOn(output) {
    return String(output ?? "").split(/\s+/).some(v => /^[1-9]\d*$/.test(v));
}
