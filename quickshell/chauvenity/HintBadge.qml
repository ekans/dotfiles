// A bar item's hint: the key that picks it, drawn over it while the bar shows
// its hints (`qs -c chauvenity ipc call bar hints`).

import QtQuick

Rectangle {
    id: badge

    required property var theme
    required property bool shown
    // The key, or "" when the item has none.
    required property string label

    visible: badge.shown && badge.label !== ""
    width: Math.max(18, keyText.implicitWidth + 8)
    height: 18
    radius: 4
    color: badge.theme.accentColor

    Text {
        id: keyText
        anchors.centerIn: parent
        text: badge.label
        color: badge.theme.bgColor
        font.pixelSize: 12
        font.bold: true
    }
}
