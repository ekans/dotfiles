pragma ComponentBehavior: Bound

// The panel Notifications.qml opens under the bar: do-not-disturb, and every
// notification not yet dismissed, newest first. A click on one runs its
// default action; its buttons run the others; × dismisses it, and the app
// hears it was closed.

import QtQuick
import Quickshell
import "notifications.mjs" as Notes

Item {
    id: panel

    required property var theme
    // NotificationService.
    required property var service
    property var now: new Date()

    implicitWidth: 340
    implicitHeight: content.implicitHeight

    // A small text button, as in the header and under a notification.
    component Button: Rectangle {
        id: button
        required property var theme
        required property string label
        property bool primary: false
        signal clicked()

        implicitWidth: buttonText.implicitWidth + 16
        implicitHeight: 22
        radius: 11
        color: button.primary
            ? (buttonMouse.containsMouse ? Qt.lighter(button.theme.accentColor, 1.1) : button.theme.accentColor)
            : (buttonMouse.containsMouse ? button.theme.lineColor : button.theme.trackColor)

        Text {
            id: buttonText
            anchors.centerIn: parent
            text: button.label
            color: button.primary ? button.theme.bgColor : button.theme.fgColor
            font.pixelSize: 11
            font.bold: button.primary
        }
        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: button.clicked()
        }
    }

    Column {
        id: content
        width: parent.width
        spacing: 8

        // Title, do-not-disturb, clear all.
        Item {
            width: parent.width
            implicitHeight: 24

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Notifications"
                color: panel.theme.dimColor
                font.pixelSize: 11
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.4
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                // Do-not-disturb: a label and a switch, one click target.
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: dndRow.implicitWidth
                    implicitHeight: 22

                    Row {
                        id: dndRow
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Do not disturb"
                            color: panel.theme.fgColor
                            font.pixelSize: 11
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26
                            height: 14
                            radius: 7
                            color: panel.service.dnd ? panel.theme.accentColor : panel.theme.lineColor
                            Behavior on color { ColorAnimation { duration: 150 } }

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                y: 2
                                x: panel.service.dnd ? 14 : 2
                                color: panel.theme.fgColor
                                Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: panel.service.dnd = !panel.service.dnd
                    }
                }

                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: panel.theme
                    visible: panel.service.history.length > 0
                    label: "Clear all"
                    onClicked: panel.service.clearAll()
                }
            }
        }

        Text {
            width: parent.width
            visible: panel.service.history.length === 0
            topPadding: 6
            bottomPadding: 10
            horizontalAlignment: Text.AlignHCenter
            text: panel.service.dnd ? "Nothing here. Do not disturb is on." : "Nothing here."
            color: panel.theme.dimColor
            font.pixelSize: 12
        }

        Flickable {
            id: list
            width: parent.width
            visible: panel.service.history.length > 0
            height: Math.min(entries.implicitHeight, 440)
            contentHeight: entries.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: entries
                width: list.width
                spacing: 4

                Repeater {
                    model: panel.service.history

                    Rectangle {
                        id: entry
                        required property var modelData
                        readonly property var n: entry.modelData
                        readonly property bool critical: entry.n?.urgency === Notes.URGENCY.Critical

                        width: entries.width
                        implicitHeight: row.implicitHeight + 16
                        radius: 6
                        color: entryMouse.containsMouse ? panel.theme.hoverColor : Qt.alpha(panel.theme.trackColor, 0.6)
                        border.width: entry.critical ? 1 : 0
                        border.color: panel.theme.badColor

                        // Underneath the buttons: they take their own clicks.
                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Notes.defaultAction(entry.n?.actions) ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: panel.service.activate(entry.n)
                        }

                        Row {
                            id: row
                            x: 8
                            y: 8
                            width: parent.width - 16
                            spacing: 10

                            NotificationIcon {
                                theme: panel.theme
                                notification: entry.n
                                size: 28
                            }

                            Column {
                                width: row.width - 38
                                spacing: 2

                                Text {
                                    width: parent.width - 18
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: [entry.n?.appName ?? "", Notes.ageLabel(panel.service.arrivedAt(entry.n), panel.now)]
                                        .filter(s => s !== "").join(" · ")
                                    color: entry.critical ? panel.theme.badColor : panel.theme.dimColor
                                    font.pixelSize: 11
                                }
                                Text {
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: Notes.plainText(entry.n?.summary)
                                    color: panel.theme.fgColor
                                    font.pixelSize: 12
                                    font.bold: true
                                }
                                Text {
                                    width: parent.width
                                    visible: text !== ""
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: Notes.plainText(entry.n?.body)
                                    color: Qt.lighter(panel.theme.dimColor, 1.45)
                                    font.pixelSize: 12
                                }
                                Flow {
                                    width: parent.width
                                    visible: actionsRepeater.count > 0
                                    topPadding: 4
                                    spacing: 6

                                    Repeater {
                                        id: actionsRepeater
                                        model: Notes.buttonActions(entry.n?.actions)

                                        Button {
                                            required property var modelData
                                            theme: panel.theme
                                            label: modelData.text
                                            onClicked: modelData.invoke()
                                        }
                                    }
                                }
                            }
                        }

                        // Dismiss: the app hears the user closed it.
                        Text {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 6
                            visible: entryMouse.containsMouse || closeMouse.containsMouse
                            text: "✕"
                            color: closeMouse.containsMouse ? panel.theme.fgColor : panel.theme.dimColor
                            font.pixelSize: 11

                            MouseArea {
                                id: closeMouse
                                anchors.fill: parent
                                anchors.margins: -4
                                hoverEnabled: true
                                onClicked: entry.n?.dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}
