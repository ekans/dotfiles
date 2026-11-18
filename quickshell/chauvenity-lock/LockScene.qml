pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Particles
import "lock.mjs" as Logic

Item {
    id: scene

    enum Sleep { Awake, Dimming, Asleep }

    required property var lock
    property real u: 1

    readonly property string passwordState: scene.lock.passwordState
    readonly property bool checking: scene.passwordState === "checking"
    readonly property bool unlocked: scene.passwordState === "unlocked"
    readonly property bool wrong: scene.passwordState === "wrong" || scene.passwordState === "error"
    readonly property int count: Logic.fireflyCount(scene.lock.buffer.length)

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

    property int sleep: LockScene.Awake
    readonly property bool awake: scene.sleep === LockScene.Awake
    readonly property bool asleep: scene.sleep === LockScene.Asleep
    property real dimmedAt: 0

    function wake() {
        if (!scene.awake) {
            const dimmed = Date.now() - scene.dimmedAt;
            scene.sleep = LockScene.Awake;
            prefill.burst(Logic.wakeBurst(dimmed));
        }
        doze.restart();
    }

    Timer {
        id: doze
        interval: Logic.SLEEP_MS
        running: !scene.checking
        onTriggered: {
            scene.sleep = LockScene.Dimming;
            scene.dimmedAt = Date.now();
        }
    }

    Timer {
        interval: Logic.BURNOUT_MS
        running: scene.sleep === LockScene.Dimming
        onTriggered: scene.sleep = LockScene.Asleep
    }

    Connections {
        target: scene.lock
        function onKeyPressesChanged() { scene.wake(); }
        function onPasswordStateChanged() { scene.wake(); }
        function onFingerStateChanged() { scene.wake(); }
    }

    ParticleSystem {
        id: system
        paused: scene.asleep
    }

    // The embers are tinted by their sprite rather than by ImageParticle.color:
    // a particle keeps the colour of the first painter that drew it, so a colour
    // change never reaches the embers already alive. On success a second painter
    // draws the same embers with the green sprite and fades in over the first.
    // (A GroupGoal moving them to a green group instead crashed Qt 6.)
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

    // Off until success: Qt's particle cost follows the live particles and the
    // affectors, so until then the embers drift on their emitters' own
    // velocity and acceleration.
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

    Image {
        anchors.centerIn: parent
        width: 24 * scene.u
        height: width
        source: "art/halo-ember.png"
        opacity: scene.count === 0 && !scene.unlocked ? 0.35 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }

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
                    count: scene.count
                    u: scene.u
                    twinkle: scene.twinkle
                    spread: scene.spread
                    wrong: scene.wrong
                    unlocked: scene.unlocked
                }
            }
        }
    }
}
