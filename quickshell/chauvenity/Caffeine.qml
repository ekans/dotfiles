// The bar's caffeine toggle: a cup, steaming and lit while the session is
// kept awake. No panel; a click flips it. The idle inhibitor it drives lives
// in each bar in shell.qml, so that every output's bar holds one.

import QtQuick

Item {
    id: cup

    required property var theme
    required property bool on
    // Its hint, as shell.qml's `keyboard` section describes; hints.mjs picks
    // the letter.
    property string hintName: "caffeine"

    signal flipped()

    implicitWidth: icon.implicitWidth + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse ? cup.theme.hoverColor : "transparent"
    }

    CaffeineIcon {
        id: icon
        anchors.centerIn: parent
        theme: cup.theme
        on: cup.on
        ink: cup.on ? cup.theme.accentColor : cup.theme.dimColor
    }

    // A click, the bar's hints and `qs -c chauvenity ipc call bar toggle
    // caffeine` all come here.
    function toggle() {
        cup.flipped();
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: cup.toggle()
    }
}
