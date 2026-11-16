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
// It falls asleep after SLEEP_MS (lock.mjs) with nothing happening:
//
//   awake     the embers rise, the ring turns
//   dimming   no new embers; the live ones rise until they burn out
//   asleep    BURNOUT_MS later: the particles are paused, the ring stopped,
//             and nothing on screen moves, so Qt stops redrawing the window
//
// A key on any output, the fingerprint and a PAM verdict wake it at once,
// with embers scattered back over the screen. They reach it through the
// shell's root, which every output's scene reads, so all of them wake
// together.
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

    // --- sleep --------------------------------------------------------------

    // "awake", "dimming" or "asleep".
    property string sleep: "awake"
    readonly property bool awake: scene.sleep === "awake"
    readonly property bool asleep: scene.sleep === "asleep"
    property real dimmedAt: 0

    function wake() {
        if (!scene.awake) {
            const dimmed = Date.now() - scene.dimmedAt;
            scene.sleep = "awake";
            prefill.burst(Logic.wakeBurst(dimmed));
        }
        doze.restart();
    }

    Timer {
        id: doze
        interval: Logic.SLEEP_MS
        running: true
        // While PAM checks, the ring keeps spinning; its verdict wakes the
        // scene and starts the count again.
        onTriggered: {
            if (scene.checking)
                return;
            scene.sleep = "dimming";
            scene.dimmedAt = Date.now();
        }
    }

    Timer {
        interval: Logic.BURNOUT_MS
        running: scene.sleep === "dimming"
        onTriggered: scene.sleep = "asleep"
    }

    Connections {
        target: scene.lock
        function onActivityChanged() { scene.wake(); }
        function onPasswordStateChanged() { scene.wake(); }
        function onFingerStateChanged() { scene.wake(); }
    }

    // --- embers -------------------------------------------------------------

    ParticleSystem {
        id: system
        paused: scene.asleep
    }

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
        enabled: scene.awake && !scene.unlocked
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

    // The fireflies' halos pulse on this, each a step apart: one animation
    // for all of them, stopped while none is lit.
    property real twinkle: 0
    NumberAnimation on twinkle {
        from: 0
        to: 1
        duration: 1500
        loops: Animation.Infinite
        running: scene.count > 0
        paused: running && scene.asleep
    }

    Item {
        id: orbit
        x: scene.width / 2
        y: scene.height / 2
        opacity: Math.min(1, 2 - scene.spread / 3.5)

        NumberAnimation on rotation {
            from: 0
            to: 360
            duration: 14000
            loops: Animation.Infinite
            paused: scene.asleep
        }

        Item {
            id: spin

            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: 700
                loops: Animation.Infinite
                paused: !scene.checking || scene.asleep
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
