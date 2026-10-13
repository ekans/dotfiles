// A notification's picture, in a circle: the image it carries (often the
// sender's), else its app's icon, else the app name's first letter.

import QtQuick
import Quickshell
import Quickshell.Widgets
import "notifications.mjs" as Notes

ClippingRectangle {
    id: icon

    required property var theme
    required property var notification
    property int size: 24

    readonly property var picked: Notes.iconSource(icon.notification?.image ?? "", icon.notification?.appIcon ?? "")
    readonly property string themed: icon.picked.icon !== "" ? Quickshell.iconPath(icon.picked.icon, true) : ""
    readonly property string shown: icon.picked.source !== "" ? icon.picked.source : icon.themed

    // A theme name the icon theme does not have still gives a path; it only
    // fails to load. The letter stands in until the picture is there.
    readonly property bool loaded: picture.status === Image.Ready

    implicitWidth: icon.size
    implicitHeight: icon.size
    radius: icon.size / 2
    color: icon.loaded ? "transparent" : icon.theme.trackColor

    Image {
        id: picture
        anchors.fill: parent
        visible: icon.loaded
        source: icon.shown
        sourceSize: Qt.size(icon.size * 2, icon.size * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
    }

    Text {
        anchors.centerIn: parent
        visible: !icon.loaded
        text: (icon.notification?.appName || "?").slice(0, 1).toUpperCase()
        color: icon.theme.fgColor
        font.pixelSize: Math.round(icon.size * 0.45)
        font.bold: true
    }
}
