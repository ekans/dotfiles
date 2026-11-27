// Unit tests for the light/dark switch's reading of GNOME's colour scheme.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import { readScheme, setScheme } from "../appearance.mjs";

test("readScheme reads `gsettings get` and `gsettings monitor` lines", () => {
    assert.equal(readScheme("'prefer-dark'"), "dark");
    assert.equal(readScheme("color-scheme: 'prefer-dark'"), "dark");
    assert.equal(readScheme("'default'"), "light");
    assert.equal(readScheme("color-scheme: 'prefer-light'"), "light");
});

test("readScheme has no answer for a line that is not a scheme", () => {
    assert.equal(readScheme(""), null);
    assert.equal(readScheme("No such key “color-scheme”"), null);
});

test("setScheme writes what readScheme reads back", () => {
    for (const mode of ["light", "dark"]) {
        const argv = setScheme(mode);
        assert.deepEqual(argv.slice(0, 4), ["gsettings", "set", "org.gnome.desktop.interface", "color-scheme"]);
        assert.equal(readScheme(`'${argv[4]}'`), mode);
    }
});
