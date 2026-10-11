// Unit tests for the bar's network indicator and its panel.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    signalLevel, listedNetworks, connectStep, failureText, connectivityText, linkSpeed, barState,
} from "../network.mjs";

const net = (name, signalStrength, extra) =>
    Object.assign({ name, signalStrength, connected: false, stateChanging: false, known: false }, extra);

test("signalLevel lights up to three arcs", () => {
    assert.equal(signalLevel(0), 0);
    assert.equal(signalLevel(0.2), 0);
    assert.equal(signalLevel(0.3), 1);
    assert.equal(signalLevel(0.6), 2);
    assert.equal(signalLevel(0.71), 3);
    assert.equal(signalLevel(1), 3);
});

test("listedNetworks puts the connected network first, then by signal", () => {
    const names = listedNetworks([
        net("weak", 0.3),
        net("home", 0.4, { connected: true }),
        net("strong", 0.9),
        net("joining", 0.1, { stateChanging: true }),
    ]).map(n => n.name);
    assert.deepEqual(names, ["home", "joining", "strong", "weak"]);
});

test("listedNetworks leaves out saved networks that are out of range", () => {
    const names = listedNetworks([net("office", 0, { known: true }), net("cafe", 0.5)]).map(n => n.name);
    assert.deepEqual(names, ["cafe"]);
});

test("listedNetworks orders equal signals by name and copes with no list", () => {
    assert.deepEqual(listedNetworks([net("b", 0.5), net("a", 0.5)]).map(n => n.name), ["a", "b"]);
    assert.deepEqual(listedNetworks(undefined), []);
});

test("connectStep tries saved and open networks, asks for a WPA password first", () => {
    assert.equal(connectStep(true, "psk"), "connect");
    assert.equal(connectStep(true, "other"), "connect");
    assert.equal(connectStep(false, "open"), "connect");
    assert.equal(connectStep(false, "psk"), "password");
    assert.equal(connectStep(false, "other"), "settings");
});

test("failureText tells a wrong password from a missing one", () => {
    assert.equal(failureText("secrets", true), "Wrong password.");
    assert.equal(failureText("secrets", false), "This network needs a password.");
    assert.equal(failureText("lost", false), "The network is out of range.");
    assert.equal(failureText("whatever", false), "Could not connect.");
});

test("connectivityText is silent when the internet is reachable or unchecked", () => {
    assert.equal(connectivityText("full"), "");
    assert.equal(connectivityText("unknown"), "");
    assert.equal(connectivityText("portal"), "This network wants you to sign in.");
    assert.match(connectivityText("limited"), /not reachable/);
});

test("linkSpeed reads in Gb/s from a gigabit up", () => {
    assert.equal(linkSpeed(100), "100 Mb/s");
    assert.equal(linkSpeed(1000), "1 Gb/s");
    assert.equal(linkSpeed(2500), "2.5 Gb/s");
    assert.equal(linkSpeed(0), "");
    assert.equal(linkSpeed(undefined), "");
});

test("barState shows the cable before Wi-Fi", () => {
    const s = barState({ wired: true, wifiOn: true, wifi: net("home", 0.9, { connected: true }), connectivity: "full" });
    assert.deepEqual(s, { glyph: "wired", level: 0, label: "", tone: "normal", busy: false });
});

test("barState shows the Wi-Fi network and its signal", () => {
    const s = barState({ wired: false, wifiOn: true, wifi: net("home", 0.6, { connected: true }), connectivity: "full" });
    assert.deepEqual(s, { glyph: "wifi", level: 2, label: "home", tone: "normal", busy: false });
});

test("barState warns when connected without internet", () => {
    assert.equal(barState({ wired: false, wifiOn: true, wifi: net("cafe", 0.9, { connected: true }), connectivity: "portal" }).tone, "warn");
    assert.equal(barState({ wired: true, wifiOn: false, wifi: null, connectivity: "limited" }).tone, "warn");
    assert.equal(barState({ wired: true, wifiOn: false, wifi: null, connectivity: "unknown" }).tone, "normal");
});

test("barState: Wi-Fi off, connecting, and nothing", () => {
    assert.equal(barState({ wired: false, wifiOn: false, wifi: null, connectivity: "none" }).glyph, "off");
    assert.deepEqual(
        barState({ wired: false, wifiOn: true, wifi: net("cafe", 0.9, { stateChanging: true }), connectivity: "none" }),
        { glyph: "wifi", level: 0, label: "cafe", tone: "dim", busy: true });
    assert.equal(barState({ wired: false, wifiOn: true, wifi: null, connectivity: "none" }).glyph, "none");
});
