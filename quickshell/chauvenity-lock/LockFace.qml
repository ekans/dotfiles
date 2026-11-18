pragma ComponentBehavior: Bound

// What one output shows while the session is locked: the time at the top,
// a firefly per character typed circling the middle (LockScene.qml), the
// fingerprint under them. Every output shows the same, from shell.qml's
// state; the one niri gives the keyboard to types into it.
//
// Prototype "14 · Fireflies".
//
// The login greeter (../chauvenity-greeter) draws this same face, with its own
// state object as `lock`: one that never has a fingerprint ("unavailable").

import QtQuick
import QtQuick.Shapes
import "lock.mjs" as Logic

Item {
    id: face

    // shell.qml's root: the palette and the state below.
    required property var lock
    // Off for the greeter, which has no desktop to fade to.
    property bool fadeOnUnlock: true
    // Off while something else, such as the greeter's power menu, takes the keys.
    property bool inputEnabled: true

    // Sizes are the prototype's, drawn at 1280 × 800 and scaled with the
    // output.
    readonly property real u: Math.max(0.75, Math.min(face.width / 1280, face.height / 800))
    readonly property string passwordState: face.lock.passwordState
    readonly property string fingerState: face.lock.fingerState
    readonly property bool checking: face.passwordState === "checking"
    readonly property bool unlocked: face.passwordState === "unlocked"

    // Typing goes to this, unseen, so that dead keys, compose and the layout
    // are Qt's business; the fireflies follow its length.
    TextInput {
        id: input
        opacity: 0
        focus: true
        echoMode: TextInput.Password
        // Qt's own cursor blinks, which redraws the window twice a second
        // for as long as the lock is up; a delegate cursor does not.
        cursorDelegate: Item {}
        readOnly: face.checking || face.unlocked || !face.inputEnabled
        onTextEdited: face.lock.edit(input.text)
        onAccepted: face.lock.submit()
        Keys.onPressed: event => {
            face.lock.noteKeyPress();
            event.accepted = false;
        }
        Keys.onEscapePressed: {
            face.lock.noteKeyPress();
            face.lock.edit("");
        }
    }

    // The buffer is the lock's, shared with the other outputs; it is emptied
    // after a wrong password.
    Connections {
        target: face.lock
        function onBufferChanged() {
            if (input.text !== face.lock.buffer)
                input.text = face.lock.buffer;
        }
    }

    // The keyboard comes back here whenever this output's surface has it.
    Component.onCompleted: input.forceActiveFocus()

    LockScene {
        anchors.fill: parent
        lock: face.lock
        u: face.u
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: face.unlocked && face.fadeOnUnlock ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InQuad } }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.07
            text: face.lock.clockText
            color: face.lock.dimColor
            font.family: "JetBrains Mono"
            font.pixelSize: Math.round(16 * face.u)
            font.letterSpacing: 2.4 * face.u
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.58
            text: Logic.passwordText(face.passwordState)
            color: face.passwordState === "wrong" || face.passwordState === "error"
                ? face.lock.badColor : face.lock.dimColor
            font.pixelSize: Math.round(14 * face.u)
        }

        // --- fingerprint ----------------------------------------------------

        Column {
            id: finger
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.68
            spacing: 12 * face.u
            visible: face.fingerState !== "unavailable"

            property real shake: 0
            transform: Translate { x: finger.shake }

            readonly property color tone: face.fingerState === "match" ? face.lock.goodColor
                : face.fingerState === "nomatch" ? face.lock.badColor
                : face.lock.dimColor

            // Lucide's "fingerprint" (ISC licence), a 24 × 24 drawing.
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 41 * face.u
                height: width
                opacity: face.fingerState === "off" ? 0.3 : 1

                Shape {
                    width: 24
                    height: 24
                    scale: parent.width / 24
                    transformOrigin: Item.TopLeft
                    preferredRendererType: Shape.CurveRenderer

                    ShapePath {
                        strokeColor: finger.tone
                        strokeWidth: 1.6
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        PathSvg {
                            path: "M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4 M14 13.12c0 2.38 0 6.38-1 8.88 "
                                + "M17.29 21.02c.12-.6.43-2.3.5-3.02 M2 12a10 10 0 0 1 18-6 M2 16h.01 "
                                + "M21.8 16c.2-2 .131-5.354 0-6 M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2 "
                                + "M8.65 22c.21-.66.45-1.32.57-2 M9 6.8a6 6 0 0 1 9 5.2v2"
                        }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Logic.fingerText(face.fingerState, face.lock.fingerTriesLeft)
                color: face.fingerState === "off" ? face.lock.badColor : finger.tone
                font.pixelSize: Math.round(13 * face.u)
            }

            SequentialAnimation {
                id: fingerShake
                NumberAnimation { target: finger; property: "shake"; to: -8 * face.u; duration: 50 }
                NumberAnimation { target: finger; property: "shake"; to: 8 * face.u; duration: 80 }
                NumberAnimation { target: finger; property: "shake"; to: -6 * face.u; duration: 80 }
                NumberAnimation { target: finger; property: "shake"; to: 4 * face.u; duration: 80 }
                NumberAnimation { target: finger; property: "shake"; to: 0; duration: 60 }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: parent.height * 0.07
            text: "Caps Lock is on"
            color: face.lock.warnColor
            font.pixelSize: Math.round(13 * face.u)
            opacity: face.lock.capsLock ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
    }

    onFingerStateChanged: {
        if (face.fingerState === "nomatch")
            fingerShake.restart();
    }
}
