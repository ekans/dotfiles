// The clothesline's logic for Clothesline.qml: which images hang, where each
// one hangs, and how it swings. After Tendedero
// (https://github.com/alejandrobujan/tendedero), whose sizes and springs these
// are.
//
// Plain ECMAScript, no QML: tests/line.test.mjs runs it under node. Keep to
// what Qt's JavaScript engine parses — no object spread.

export const MAX_ITEMS = 8;

export const CARD_WIDTH = 150;
export const PHOTO_MAX_HEIGHT = 104;
export const SPACING = CARD_WIDTH + 24;
export const INSET = 4;
export const ROPE_TOP = 10;
export const PANEL_HEIGHT = PHOTO_MAX_HEIGHT + 106;

// What the watcher saves: `<sha256>.<ext>`, in a format Qt decodes without
// qt6-qtimageformats, which this system does not have: no webp.
const NAME = /^[0-9a-f]{64}\.(png|jpeg|gif|bmp)$/;

export function isName(name) {
    return NAME.test(name);
}

// Qt refuses to decode an image over 256 MB, 4 bytes a pixel, and decodes a
// PNG in full before scaling it: anything bigger would hang as a blank card.
export const MAX_PIXELS = 60000000;

// `file --brief` of a saved image → its size, or null if it does not say.
const DIMENSIONS = [
    /^PNG image data, (\d+) x (\d+)/,
    /^GIF image data, version \w+, (\d+) x (\d+)/,
    /bitmap.*?, (\d+) x -?(\d+)/,
    /, (\d+)x(\d+), components/,
];

export function dimensions(description) {
    for (const pattern of DIMENSIONS) {
        const match = pattern.exec(String(description || ""));
        if (match)
            return { width: Number(match[1]), height: Number(match[2]) };
    }
    return null;
}

// A watcher line, `<name>\t<file --brief>` → { name, fits }, or null if it
// names nothing the line can hang.
export function parseSaved(output) {
    const text = String(output || "").trim();
    const tab = text.indexOf("\t");
    const name = tab < 0 ? text : text.slice(0, tab);
    if (!isName(name))
        return null;
    const size = dimensions(tab < 0 ? "" : text.slice(tab + 1));
    return { name: name, fits: !size || size.width * size.height <= MAX_PIXELS };
}

// The rope hangs as a parabola from edge to edge.
export function sag(width) {
    return Math.min(30, width * 0.018);
}

export function ropeY(x, width) {
    if (width <= 0)
        return ROPE_TOP;
    const f = x / width;
    return ROPE_TOP + 4 * sag(width) * f * (1 - f);
}

// Centre of the card at `index`, the line centred on the screen. On a screen
// too narrow for them all, the cards move closer together.
export function cardX(index, count, width) {
    const gaps = Math.max(count - 1, 0);
    const step = gaps > 0 ? Math.min(SPACING, Math.max(0, width - 200) / gaps) : SPACING;
    return width / 2 - gaps * step / 2 + index * step;
}

// The photo fits the card keeping its proportions, so the frame hugs it
// whether the image is wide or tall.
export function photoSize(width, height) {
    const maxW = CARD_WIDTH - 14;
    const maxH = PHOTO_MAX_HEIGHT;
    if (!(width > 0) || !(height > 0))
        return { width: maxW, height: maxH };
    const scale = Math.min(maxW / width, maxH / height);
    return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

// The box around a card's frame as drawn, in the card's coordinates: the
// frame (w × h, `FRAME_TOP` below the clip's top) scaled from its top edge,
// then the card turned `degrees` about the clip. The line's input mask uses
// it, so a click on a tilted or swinging photo lands on it.
export const FRAME_TOP = 14;

export function frameBounds(w, h, scale, degrees) {
    const a = degrees * Math.PI / 180;
    const cos = Math.cos(a);
    const sin = Math.sin(a);
    const half = w * scale / 2;
    const corners = [[-half, FRAME_TOP], [half, FRAME_TOP], [-half, FRAME_TOP + h * scale], [half, FRAME_TOP + h * scale]];
    const xs = corners.map(c => c[0] * cos - c[1] * sin);
    const ys = corners.map(c => c[0] * sin + c[1] * cos);
    const left = Math.min.apply(null, xs);
    const top = Math.min.apply(null, ys);
    return {
        x: CARD_WIDTH / 2 + left,
        y: top,
        width: Math.max.apply(null, xs) - left,
        height: Math.max.apply(null, ys) - top,
    };
}

// --- underpants -------------------------------------------------------------
// The room the photos leave on the line is hung with underpants. Slots are
// measured in from each edge, so the ones nearest the photos come and go as
// the line fills while the outer ones never move. A seed, drawn once a
// session, decides which slots hold a pair and what each one looks like.

export const PANTS_WIDTH = 56;
export const PANTS_HEIGHT = 44;
const PANTS_GAP = 34;
const EDGE = 40;
// Clear of the photos, and of the hint an empty line shows.
const CLEARANCE = 18;
const HINT_HALF_WIDTH = 170;

export const PANTS_COLORS = ["#f66151", "#62a0ea", "#f6d32d", "#57e389", "#c061cb", "#ffa348", "#ffffff", "#99c1f1"];
export const PANTS_KINDS = ["briefs", "boxers"];
export const PANTS_PATTERNS = ["plain", "dots", "stripes", "hearts"];

// mulberry32: a small seeded generator, so a slot looks the same all session.
export function random(seed) {
    let a = seed >>> 0;
    return function () {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function pick(next, list) {
    return list[Math.floor(next() * list.length)];
}

// Every slot that holds a pair on a line `width` wide, left then right. A
// slot's look depends on its side and its place from the edge only.
export function pantsSlots(width, seed) {
    const slots = [];
    const step = PANTS_WIDTH + PANTS_GAP;
    const perSide = Math.floor((width / 2 - EDGE) / step);
    for (const side of [-1, 1]) {
        for (let i = 0; i < perSide; i++) {
            const next = random(seed ^ ((i + 1) * 2654435761) ^ (side > 0 ? 0x9e3779b9 : 0));
            if (next() < 0.4)
                continue;
            const fromEdge = EDGE + i * step + PANTS_WIDTH / 2;
            slots.push({
                key: (side > 0 ? "r" : "l") + i,
                x: side > 0 ? width - fromEdge : fromEdge,
                kind: pick(next, PANTS_KINDS),
                color: pick(next, PANTS_COLORS),
                pattern: pick(next, PANTS_PATTERNS),
                tilt: next() * 6 - 3,
            });
        }
    }
    return slots;
}

// The stretch of line the photos take, or the hint when there are none.
export function occupied(width, count) {
    if (count === 0)
        return { from: width / 2 - HINT_HALF_WIDTH, to: width / 2 + HINT_HALF_WIDTH };
    return {
        from: cardX(0, count, width) - CARD_WIDTH / 2 - CLEARANCE,
        to: cardX(count - 1, count, width) + CARD_WIDTH / 2 + CLEARANCE,
    };
}

export function isFree(slot, width, count) {
    const taken = occupied(width, count);
    return slot.x + PANTS_WIDTH / 2 <= taken.from || slot.x - PANTS_WIDTH / 2 >= taken.to;
}

// Every image hangs a little crooked, like on a real line.
export function randomTilt() {
    return Math.random() * 5 - 2.5;
}

// Hangs `name` at the newest end. An image already on the line stays where it
// is. A full line lets its oldest fall: `dropped` lists what fell.
export function hang(items, name, tilt) {
    if (items.some(item => item.name === name))
        return { items: items, dropped: [] };
    const next = items.concat([{ name: name, tilt: tilt }]);
    const over = Math.max(0, next.length - MAX_ITEMS);
    return { items: next.slice(over), dropped: next.slice(0, over).map(item => item.name) };
}

// `ls -1tr` of the line's folder → the line as it was, oldest first. Anything
// past MAX_ITEMS is in `dropped`, for deleting.
export function restore(listing, tiltOf) {
    let items = [];
    let dropped = [];
    for (const name of String(listing || "").split("\n").map(line => line.trim())) {
        if (!isName(name))
            continue;
        const result = hang(items, name, tiltOf(name));
        items = result.items;
        dropped = dropped.concat(result.dropped);
    }
    return { items: items, dropped: dropped };
}

// The swing is a damped spring, θ'' = −k·θ − c·θ', with Tendedero's
// stiffness and damping for a unit mass. Fixed sub-steps keep it stable
// whatever the frame time.
export const STIFFNESS = 46;
export const DAMPING = 2.6;
const SUBSTEP = 1 / 240;

export function stepSwing(state, dt) {
    let angle = state.angle;
    let velocity = state.velocity;
    let left = Math.min(dt, 0.1);
    while (left > 0) {
        const h = Math.min(SUBSTEP, left);
        velocity += (-STIFFNESS * angle - DAMPING * velocity) * h;
        angle += velocity * h;
        left -= h;
    }
    return { angle: angle, velocity: velocity };
}

export function atRest(state) {
    return Math.abs(state.angle) < 0.02 && Math.abs(state.velocity) < 0.05;
}
