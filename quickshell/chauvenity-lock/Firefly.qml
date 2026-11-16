pragma ComponentBehavior: Bound

// One place on LockScene's ring: a white-hot core in a pulsing warm halo, lit
// while the password is at least index + 1 characters long.
//
// The scene makes all MAX_FIREFLIES of them once and never destroys one, so a
// key costs no object, and a firefly that leaves is a change of state rather
// than a destroy racing its own animation. An unlit one is a transparent item
// with nothing running.
//
// Only a lit firefly is told where to go. One that leaves is no longer told,
// so it stays where it was while it cools and fades. `place` is the count it
// is placed under, computed from the scene's count alone, so that whether it
// is lit and where it goes can never disagree halfway through an update.
// Quickshell 0.3.2 keeps a binding even when it is assigned to while a
// Behavior is on the property, which is why angle and ring are assigned
// from onPlaceChanged and never bound.

import QtQuick
import "lock.mjs" as Logic

Item {
    id: fly

    required property int index
    required property LockScene scene

    readonly property int place: fly.index < fly.scene.count ? fly.scene.count : 0
    property bool placed: false
    property real angle: 0
    property real ring: 0
    property real grow: 1
    property real drop: 0
    // Each firefly's halo pulses out of step with the others'.
    readonly property real pulse: 0.7 + 0.3 * Math.sin(2 * Math.PI * (fly.scene.twinkle + fly.index * 0.38))

    Behavior on angle { id: glideAngle; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
    Behavior on ring { id: glideRing; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

    onPlaceChanged: {
        if (fly.place > 0) {
            // A firefly that arrives starts where it belongs, in the middle,
            // and grows out from there.
            glideAngle.enabled = glideRing.enabled = fly.placed;
            fly.angle = fly.index / fly.place * 2 * Math.PI;
            fly.ring = Logic.ringRadius(fly.place);
            glideAngle.enabled = glideRing.enabled = true;
            if (!fly.placed)
                arrive.restart();
        }
        fly.placed = fly.place > 0;
    }

    NumberAnimation { id: arrive; target: fly; property: "grow"; from: 0; to: 1; duration: 450; easing.type: Easing.OutBack }

    x: Math.cos(fly.angle) * fly.ring * fly.scene.u * fly.grow * fly.scene.spread
    y: Math.sin(fly.angle) * fly.ring * fly.scene.u * fly.grow * fly.scene.spread + fly.drop
    opacity: 0

    Image {
        id: halo
        x: -width / 2
        y: -height / 2
        width: 30 * fly.scene.u
        height: width
        source: "art/halo-ash.png"
        opacity: 0.6 * fly.pulse
    }

    Image {
        id: core
        x: -width / 2
        y: -height / 2
        width: 9 * fly.scene.u
        height: width
        source: "art/glow.png"
    }

    state: fly.place === 0 ? (fly.scene.wrong ? "sink" : "out")
        : fly.scene.unlocked ? "free" : "lit"

    states: [
        State {
            name: "lit"
            PropertyChanges { fly.opacity: 1; halo.source: "art/halo-ember.png" }
        },
        State {
            name: "free"
            PropertyChanges { fly.opacity: 1; halo.source: "art/halo-green.png"; core.source: "art/halo-green.png" }
        },
        State { name: "out" },
        State {
            name: "sink"
            PropertyChanges { fly.drop: 90 * fly.scene.u }
        }
    ]

    transitions: [
        Transition {
            to: "lit"
            NumberAnimation { property: "opacity"; duration: 150 }
        },
        Transition {
            to: "out"
            NumberAnimation { property: "opacity"; duration: 220; easing.type: Easing.InQuad }
        },
        Transition {
            to: "sink"
            NumberAnimation { properties: "opacity,drop"; duration: 800; easing.type: Easing.InQuad }
        }
    ]
}
