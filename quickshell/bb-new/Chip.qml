import QtQuick

// One setting under the prompt: its name, its value, and a dot while it is not
// the default. A change of value pulses it.
Rectangle {
    id: chip

    required property string label
    required property string value
    required property bool changed
    // shell.qml's palette and font: a file of its own cannot see `root`.
    required property var theme

    implicitWidth: content.implicitWidth + 18
    implicitHeight: 26
    radius: 6
    color: chip.theme.panel
    border.width: 1
    border.color: chip.changed ? chip.theme.accent : chip.theme.line

    onValueChanged: pulse.restart()

    NumberAnimation {
        id: pulse
        target: chip
        property: "scale"
        from: 1.12
        to: 1
        duration: 240
        easing.type: Easing.OutCubic
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 7

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.label
            color: chip.theme.dim
            font.family: chip.theme.font
            font.pixelSize: 11
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.value
            color: chip.changed ? chip.theme.accent : chip.theme.fg
            font.family: chip.theme.font
            font.pixelSize: 13
        }
    }

    Rectangle {
        visible: chip.changed
        x: chip.width - 5
        y: -3
        width: 8
        height: 8
        radius: 4
        color: chip.theme.accent
    }
}
