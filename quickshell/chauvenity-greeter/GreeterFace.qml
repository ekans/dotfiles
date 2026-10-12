pragma ComponentBehavior: Bound

// What one output shows at login: the lock screen's face, with `ducatore ·
// niri` where the lock has the fingerprint, and the hint at the bottom.
// Prototype "01 · same face".

import QtQuick
import "lock"
import "greeter.mjs" as Logic

Item {
    id: scene

    // shell.qml's root: the palette and the login state.
    required property var greeter

    readonly property real u: Math.max(0.75, Math.min(scene.width / 1280, scene.height / 800))

    LockFace {
        anchors.fill: parent
        lock: scene.greeter
        fadeOnUnlock: false
        inputEnabled: !scene.greeter.powerOpen
    }

    // Tab and Ctrl+Alt+Del are not typing, so the face's text input hands them
    // up to here.
    Keys.onTabPressed: scene.greeter.nextSession(1)
    Keys.onBacktabPressed: scene.greeter.nextSession(-1)
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Delete && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.AltModifier)) {
            scene.greeter.togglePower();
            event.accepted = true;
        } else if (scene.greeter.powerOpen && scene.greeter.choosePower(event.text)) {
            event.accepted = true;
        }
    }

    Row {
        id: who
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.68
        spacing: 0
        opacity: scene.greeter.powerOpen ? 0.4 : 1
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Text {
            text: `${scene.greeter.user} · `
            color: scene.greeter.dimColor
            font.pixelSize: Math.round(14 * scene.u)
        }

        Item {
            width: Math.max(name.implicitWidth, 52 * scene.u)
            height: name.implicitHeight

            Text {
                id: name
                text: scene.greeter.session.label
                color: scene.greeter.accentColor
                font.pixelSize: Math.round(14 * scene.u)
                transform: Translate { id: lift }
            }

            // The session name drops in when Tab changes it.
            ParallelAnimation {
                id: flash
                NumberAnimation { target: name; property: "opacity"; from: 0; to: 1; duration: 350 }
                NumberAnimation { target: lift; property: "y"; from: -4 * scene.u; to: 0; duration: 350 }
            }

            Connections {
                target: scene.greeter
                function onSessionIndexChanged() { flash.restart(); }
            }
        }
    }

    // Where the lock says "Caps Lock is on"; that wins.
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: parent.height * 0.07
        text: Logic.hintText(scene.greeter.powerOpen)
        color: scene.greeter.dimColor
        font.pixelSize: Math.round(12 * scene.u)
        opacity: scene.greeter.capsLock ? 0 : (scene.greeter.powerOpen ? 0.9 : 0.6)
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }
}
