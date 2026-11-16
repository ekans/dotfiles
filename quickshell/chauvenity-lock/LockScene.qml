pragma ComponentBehavior: Bound

// What moves behind LockFace's words, prototype "14 · Fireflies": warm embers
// rising from the bottom of the screen, and a firefly (Firefly.qml) per
// character typed, circling the middle on a ring that widens as they come.
//
//   nothing typed   one faint ember glows in the middle
//   backspace       the last firefly cools and fades where it is
//   checking        the ring spins fast
//   wrong           the fireflies sink and fade
//   unlocked        everything turns green and flies outward, and green
//                   embers rush up from the bottom, for EXIT_MS
//
// The embers are tinted by their sprite rather than by ImageParticle.color:
// a particle keeps the colour of the first painter that drew it, so a colour
// change never reaches the embers already alive. On success a second painter
// draws the same embers with the green sprite and fades in over the first.
// (A GroupGoal moving them to a green group instead crashed Qt 6.)
//
// The push outward is off until then: Qt's particle cost follows the live
// particles and the affectors, so the embers drift on their emitters' own
// velocity and acceleration.

import QtQuick
import QtQuick.Particles
import "lock.mjs" as Logic

Item {
    id: scene

    // shell.qml's root, or the greeter's: the state LockFace shows.
    required property var lock
    property real u: 1

    readonly property string passwordState: scene.lock.passwordState
    readonly property bool checking: scene.passwordState === "checking"
    readonly property bool unlocked: scene.passwordState === "unlocked"
    readonly property bool wrong: scene.passwordState === "wrong" || scene.passwordState === "error"
    readonly property int count: Logic.fireflyCount(scene.lock.buffer.length)

    // 0 until success, then 1 over EXIT_MS: the ring flies apart and fades.
    property real flight: 0
    readonly property real spread: 1 + 6 * scene.flight

    states: State {
        name: "free"
        when: scene.unlocked
        PropertyChanges { scene.flight: 1 }
    }
    transitions: Transition {
        to: "free"
        NumberAnimation { property: "flight"; duration: Logic.EXIT_MS; easing.type: Easing.InCubic }
    }

    // --- embers -------------------------------------------------------------

    ParticleSystem { id: system }

    ImageParticle {
        system: system
        groups: ["dust"]
        source: "art/halo-ember.png"
        color: "white"
        alpha: 0.55
        alphaVariation: 0.3
        entryEffect: ImageParticle.Fade
        opacity: 1 - scene.flight
    }

    ImageParticle {
        system: system
        groups: ["dust"]
        source: "art/halo-green.png"
        color: "white"
        alpha: 0.55
        alphaVariation: 0.3
        entryEffect: ImageParticle.Fade
        visible: scene.unlocked
        opacity: scene.flight
    }

    ImageParticle {
        system: system
        groups: ["rush"]
        source: "art/halo-green.png"
        color: "white"
        alpha: 0.8
        entryEffect: ImageParticle.Fade
    }

    Emitter {
        system: system
        group: "dust"
        anchors.bottom: parent.bottom
        width: parent.width
        height: parent.height * 0.3
        enabled: !scene.unlocked
        emitRate: 7
        lifeSpan: Logic.EMBER_LIFE_MS
        lifeSpanVariation: Logic.EMBER_LIFE_VARIATION_MS
        size: 9 * scene.u
        sizeVariation: 6 * scene.u
        endSize: 2 * scene.u
        velocity: AngleDirection { angle: 270; angleVariation: 15; magnitude: 30 * scene.u; magnitudeVariation: 14 * scene.u }
        acceleration: AngleDirection { angle: 0; angleVariation: 180; magnitude: 3 * scene.u }
    }

    Emitter {
        id: prefill
        system: system
        group: "dust"
        anchors.fill: parent
        enabled: false
        lifeSpan: Logic.EMBER_LIFE_MS - 2000
        lifeSpanVariation: Logic.EMBER_LIFE_VARIATION_MS
        size: 9 * scene.u
        sizeVariation: 6 * scene.u
        endSize: 2 * scene.u
        velocity: AngleDirection { angle: 270; angleVariation: 15; magnitude: 30 * scene.u; magnitudeVariation: 14 * scene.u }
        acceleration: AngleDirection { angle: 0; angleVariation: 180; magnitude: 3 * scene.u }
    }

    Emitter {
        id: rush
        system: system
        group: "rush"
        anchors.bottom: parent.bottom
        width: parent.width
        height: parent.height * 0.6
        enabled: false
        lifeSpan: 900
        size: 10 * scene.u
        sizeVariation: 6 * scene.u
        endSize: 2 * scene.u
        velocity: AngleDirection { angle: 270; angleVariation: 8; magnitude: 700 * scene.u; magnitudeVariation: 200 * scene.u }
    }

    Attractor {
        system: system
        groups: ["dust"]
        anchors.fill: parent
        pointX: width / 2
        pointY: height / 2
        strength: -400 * scene.u
        affectedParameter: Attractor.Acceleration
        proportionalToDistance: Attractor.Constant
        enabled: scene.unlocked
    }

    onUnlockedChanged: if (scene.unlocked) rush.burst(140)
    Component.onCompleted: prefill.burst(Logic.PREFILL_EMBERS)

    // --- fireflies ----------------------------------------------------------

    Image {
        anchors.centerIn: parent
        width: 24 * scene.u
        height: width
        source: "art/halo-ember.png"
        opacity: scene.count === 0 && !scene.unlocked ? 0.35 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }

    Item {
        id: orbit
        x: scene.width / 2
        y: scene.height / 2
        opacity: Math.min(1, 2 - scene.spread / 3.5)

        NumberAnimation on rotation { from: 0; to: 360; duration: 14000; loops: Animation.Infinite }

        Item {
            id: spin

            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: 700
                loops: Animation.Infinite
                paused: !scene.checking
            }

            Repeater {
                model: Logic.MAX_FIREFLIES

                Firefly {
                    scene: scene
                }
            }
        }
    }
}
