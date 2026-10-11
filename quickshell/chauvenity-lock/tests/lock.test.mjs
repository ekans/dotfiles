// Unit tests for the lock screen.
//
//   node --test ~/.config/quickshell/chauvenity-lock/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    FINGER_TRIES, MAX_DOTS, dotCount, fingerEvent, fingerAfter, fingerText, passwordText,
    resultName, clockLine, capsLockOn,
} from "../lock.mjs";

test("dotCount follows the password and stops at the row's length", () => {
    assert.equal(dotCount(0), 0);
    assert.equal(dotCount(7), 7);
    assert.equal(dotCount(40), MAX_DOTS);
});

test("fingerEvent reads pam_fprintd's messages", () => {
    assert.equal(fingerEvent("Place your right index finger on Goodix MOC Fingerprint Sensor", false), "prompt");
    assert.equal(fingerEvent("Swipe your finger across Validity Sensor", false), "prompt");
    assert.equal(fingerEvent("Failed to match fingerprint", true), "nomatch");
    assert.equal(fingerEvent("Verification timed out", true), "timeout");
    assert.equal(fingerEvent("Swipe your finger again", true), "retry");
    assert.equal(fingerEvent("Swipe was too fast, try again", true), "retry");
    assert.equal(fingerEvent("Your finger was not centered, try swiping your finger again", true), "retry");
});

test("fingerEvent shows nothing for what it does not know", () => {
    assert.equal(fingerEvent("Password: ", false), "other");
    assert.equal(fingerEvent("Something went wrong", true), "other");
    assert.equal(fingerEvent(undefined, true), "other");
});

test("fingerAfter unlocks on a match, whatever came before", () => {
    assert.equal(fingerAfter({ result: "success", sawPrompt: true, noMatches: 2, deadRuns: 0 }), "unlock");
});

test("fingerAfter turns the sensor off once the tries are used up", () => {
    assert.equal(fingerAfter({ result: "failed", sawPrompt: true, noMatches: FINGER_TRIES, deadRuns: 0 }), "off");
    assert.equal(fingerAfter({ result: "maxtries", sawPrompt: true, noMatches: 1, deadRuns: 0 }), "off");
});

test("fingerAfter asks again at once after a timeout", () => {
    assert.equal(fingerAfter({ result: "failed", sawPrompt: true, noMatches: 1, deadRuns: 0 }), "restart");
    assert.equal(fingerAfter({ result: "error", sawPrompt: true, noMatches: 0, deadRuns: 2 }), "restart");
});

test("fingerAfter backs off from a sensor that never asks, then gives up", () => {
    assert.equal(fingerAfter({ result: "failed", sawPrompt: false, noMatches: 0, deadRuns: 0 }), "later");
    assert.equal(fingerAfter({ result: "error", sawPrompt: false, noMatches: 0, deadRuns: 1 }), "later");
    assert.equal(fingerAfter({ result: "error", sawPrompt: false, noMatches: 0, deadRuns: 2 }), "unavailable");
});

test("fingerText counts down the tries", () => {
    assert.equal(fingerText("nomatch", 2), "Not recognised · 2 tries left");
    assert.equal(fingerText("nomatch", 1), "Not recognised · 1 try left");
    assert.equal(fingerText("off", 0), "Fingerprint off after 3 tries — use your password");
    assert.equal(fingerText("unavailable", 3), "");
});

test("passwordText speaks only when there is something to say", () => {
    assert.equal(passwordText("idle"), "");
    assert.equal(passwordText("typing"), "");
    assert.equal(passwordText("wrong"), "Wrong password");
    assert.equal(passwordText("checking"), "Checking…");
});

test("resultName maps the PamResult enum", () => {
    const names = { Success: 0, Failed: 1, Error: 2, MaxTries: 3 };
    assert.equal(resultName(0, names), "success");
    assert.equal(resultName(1, names), "failed");
    assert.equal(resultName(2, names), "error");
    assert.equal(resultName(3, names), "maxtries");
    assert.equal(resultName(99, names), "error");
});

test("clockLine is 24-hour, English and zero-padded", () => {
    assert.equal(clockLine(new Date(2026, 9, 10, 16, 5)), "16:05 · Sat 10 Oct");
    assert.equal(clockLine(new Date(2027, 0, 1, 0, 0)), "00:00 · Fri 1 Jan");
});

test("capsLockOn is on when any keyboard's LED is", () => {
    assert.equal(capsLockOn("0\n"), false);
    assert.equal(capsLockOn("0\n1\n"), true);
    assert.equal(capsLockOn(""), false);
    assert.equal(capsLockOn(undefined), false);
});
