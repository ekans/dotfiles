pragma ComponentBehavior: Bound

// Quickshell 0.3.2 keeps a binding even when it is assigned to while a
// Behavior is on the property, which is why angle and ring are assigned
// from onRingSizeChanged and never bound.

import QtQuick
import "lock.mjs" as Logic

Item {
    id: fly

    required property int index
    required property LockScene scene

    readonly property int ringSize: fly.index < fly.scene.count ? fly.scene.count : 0
    property bool placed: false
    property real angle: 0
    property real ring: 0
    property real grow: 1
    property real drop: 0
    readonly property real pulse: 0.7 + 0.3 * Math.sin(2 * Math.PI * (fly.scene.twinkle + fly.index * 0.38))

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

    state: fly.ringSize === 0 ? (fly.scene.wrong ? "sink" : "out")
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
