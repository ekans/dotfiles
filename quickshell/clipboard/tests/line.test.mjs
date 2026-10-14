// Unit tests for the clothesline's logic.
//
//   node --test ~/.config/quickshell/clipboard/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    MAX_ITEMS,
    isName,
    ropeY,
    cardX,
    photoSize,
    hang,
    restore,
    stepSwing,
    atRest,
} from "../line.mjs";

const SHA_A = "a".repeat(64);
const SHA_B = "b".repeat(64);

const names = n => Array.from({ length: n }, (_, i) => i.toString(16).padStart(64, "0") + ".png");

test("only the watcher's file names are line items", () => {
    assert.equal(isName(SHA_A + ".png"), true);
    assert.equal(isName(SHA_A + ".webp"), true);
    assert.equal(isName(SHA_A + ".svg+xml"), false);
    assert.equal(isName(".in.Xy12ab"), false);
    assert.equal(isName("A".repeat(64) + ".png"), false);
});

test("the rope sags to its lowest in the middle", () => {
    assert.equal(ropeY(0, 1920), 10);
    assert.equal(ropeY(960, 1920), 40);
    assert.equal(ropeY(1920, 1920), 10);
    assert.equal(ropeY(500, 1000), 10 + 18);
});

test("cards hang 174 apart, centred", () => {
    assert.deepEqual([0, 1, 2].map(i => cardX(i, 3, 1920)), [786, 960, 1134]);
    assert.equal(cardX(0, 1, 1920), 960);
});

test("a narrow screen brings the cards closer", () => {
    assert.equal(Math.round(cardX(0, 8, 1000)), 100);
    assert.equal(Math.round(cardX(7, 8, 1000)), 900);
});

test("the photo fits the card keeping its proportions", () => {
    assert.deepEqual(photoSize(1920, 1080), { width: 136, height: 77 });
    assert.deepEqual(photoSize(1000, 2000), { width: 52, height: 104 });
    assert.deepEqual(photoSize(0, 0), { width: 136, height: 104 });
});

test("a new image hangs at the newest end", () => {
    const { items, dropped } = hang([{ name: SHA_A + ".png", tilt: 1 }], SHA_B + ".png", -2);
    assert.deepEqual(items, [{ name: SHA_A + ".png", tilt: 1 }, { name: SHA_B + ".png", tilt: -2 }]);
    assert.deepEqual(dropped, []);
});

test("an image already on the line hangs once", () => {
    const line = [{ name: SHA_A + ".png", tilt: 1 }, { name: SHA_B + ".png", tilt: 2 }];
    assert.deepEqual(hang(line, SHA_A + ".png", 0), { items: line, dropped: [] });
});

test("a full line lets its oldest fall", () => {
    const all = names(MAX_ITEMS + 1);
    const full = all.slice(0, MAX_ITEMS).map(name => ({ name: name, tilt: 0 }));
    const { items, dropped } = hang(full, all[MAX_ITEMS], 0);
    assert.deepEqual(items.map(item => item.name), all.slice(1));
    assert.deepEqual(dropped, [all[0]]);
});

test("the line comes back from its folder, oldest first", () => {
    const all = names(MAX_ITEMS + 2);
    const listing = [".in.Xy12ab", "notes.txt"].concat(all).join("\n") + "\n";
    const { items, dropped } = restore(listing, () => 0.5);
    assert.deepEqual(items.map(item => item.name), all.slice(2));
    assert.equal(items[0].tilt, 0.5);
    assert.deepEqual(dropped, all.slice(0, 2));
    assert.deepEqual(restore("", () => 0), { items: [], dropped: [] });
});

test("a swing from 16° is back at −8.7° half a period later", () => {
    // θ(t) = 16·e^(−1.3t)·(cos ωt + 1.3/ω·sin ωt), ω = √(46 − 1.3²).
    const omega = Math.sqrt(46 - 1.3 * 1.3);
    const half = Math.PI / omega;
    let state = { angle: 16, velocity: 0 };
    let t = 0;
    while (t + 1 / 60 <= half) {
        state = stepSwing(state, 1 / 60);
        t += 1 / 60;
    }
    state = stepSwing(state, half - t);
    assert.ok(Math.abs(state.angle - -8.662) < 0.1, `angle ${state.angle}`);
});

test("a swing comes to rest", () => {
    let state = { angle: 16, velocity: 0 };
    let frames = 0;
    while (!atRest(state) && frames < 60 * 20) {
        state = stepSwing(state, 1 / 60);
        frames++;
    }
    assert.ok(frames > 60 * 3 && frames < 60 * 8, `rested after ${frames} frames`);
});
