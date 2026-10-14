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

// What the watcher saves: `<sha256>.<ext>`, the formats Qt decodes.
const NAME = /^[0-9a-f]{64}\.(png|jpeg|gif|bmp|webp)$/;

export function isName(name) {
    return NAME.test(name);
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
