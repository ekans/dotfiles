pragma ComponentBehavior: Bound

// Quickshell 0.3.2 keeps a binding even when it is assigned to while a
// Behavior is on the property, which is why angle and ring are assigned
// from onRingSizeChanged and never bound.

import QtQuick
import "lock.mjs" as Logic

Item {
    id: fly

    required property int index
    required property int count
    required property real u
    required property real twinkle
    required property real spread
    required property bool wrong
    required property bool unlocked

    readonly property int ringSize: fly.index < fly.count ? fly.count : 0
    property bool placed: false
    property real angle: 0
    property real ring: 0
    property real grow: 1
    property real drop: 0
    readonly property real pulse: 0.7 + 0.3 * Math.sin(2 * Math.PI * (fly.twinkle + fly.index * 0.38))

    Behavior on angle { id: glideAngle; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
    Behavior on ring { id: glideRing; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

    function takeSlot() {
        fly.angle = fly.index / fly.ringSize * 2 * Math.PI;
        fly.ring = Logic.ringRadius(fly.ringSize);
    }

    function jumpToSlot() {
        glideAngle.enabled = glideRing.enabled = false;
        fly.takeSlot();
        glideAngle.enabled = glideRing.enabled = true;
    }

    onRingSizeChanged: {
        if (fly.ringSize > 0 && fly.placed) {
            fly.takeSlot();
        } else if (fly.ringSize > 0) {
            fly.jumpToSlot();
            arrive.restart();
        }
        fly.placed = fly.ringSize > 0;
    }

    NumberAnimation { id: arrive; target: fly; property: "grow"; from: 0; to: 1; duration: 450; easing.type: Easing.OutBack }

    x: Math.cos(fly.angle) * fly.ring * fly.u * fly.grow * fly.spread
    y: Math.sin(fly.angle) * fly.ring * fly.u * fly.grow * fly.spread + fly.drop
    opacity: 0

    Image {
        id: halo
        x: -width / 2
        y: -height / 2
        width: 30 * fly.u
        height: width
        source: "art/halo-ash.png"
        opacity: 0.6 * fly.pulse
    }

    Image {
        id: core
        x: -width / 2
        y: -height / 2
        width: 9 * fly.u
        height: width
        source: "art/glow.png"
    }

    state: fly.ringSize === 0 ? (fly.wrong ? "sink" : "out")
        : fly.unlocked ? "free" : "lit"

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
            PropertyChanges { fly.drop: 90 * fly.u }
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
