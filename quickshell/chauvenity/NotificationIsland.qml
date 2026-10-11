pragma ComponentBehavior: Bound

// Notifications as they arrive, one at a time, from the middle of the bar:
// the window title gives way to a pill with who and what, which opens
// downward under the pointer to show the rest and the app's buttons, then
// folds back into the title. Critical ones open straight away, with a red
// edge, and stay until they are dealt with.
//
// Its own window, on the overlay layer above the bar, because it grows past
// the bar's height; it takes clicks only on the pill. A left click runs the
// default action, a right click puts it away (it stays in the bell's panel),
// a middle click dismisses it for good.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "notifications.mjs" as Notes

Scope {
    id: island

    required property var theme
    // NotificationService.
    required property var service
    // The output it shows on: the focused one.
    property string outputName: ""

    readonly property var n: island.service.current
    readonly property bool critical: island.n?.urgency === Notes.URGENCY.Critical
    readonly property int duration: island.n ? Notes.popupDuration(island.n.urgency, island.n.expireTimeout) : 0
    // Out of the title; false while it folds back.
    property bool out: false
    property bool hovered: false
    readonly property bool expanded: island.out && (island.hovered || island.critical)
    // What is left of its time, 1 to 0, for the line under it.
    property real remaining: 1
    // The one folding away; see hide().
    property var leaving: null

    // Whether it covers the bar's title on that output.
    readonly property bool shown: win.visible
    readonly property string screenName: win.screen?.name ?? ""

    // Folds it back into the title, then hands over to the next one. The
    // next one may already be current, if this one closed under it.
    function hide() {
        if (!island.out)
            return;
        island.leaving = island.n;
        island.out = false;
        drain.stop();
        foldTimer.restart();
    }

    function startDrain() {
        island.remaining = 1;
        if (island.duration > 0) {
            drain.duration = island.duration;
            drain.restart();
        } else {
            drain.stop();
        }
    }

    onNChanged: {
        if (!island.n)
            island.out = false;
        else if (island.out)
            island.startDrain();
        else
            openTimer.restart();
    }

    Timer {
        id: openTimer
        // A frame at the title's size first, so it grows out of it.
        interval: 30
        onTriggered: {
            if (!island.n)
                return;
            island.out = true;
            island.startDrain();
        }
    }

    Timer {
        id: foldTimer
        interval: 320
        onTriggered: {
            if (island.service.current === island.leaving)
                island.service.advance();
            island.leaving = null;
        }
    }

    NumberAnimation {
        id: drain
        target: island
        property: "remaining"
        from: 1
        to: 0
        // Hovering holds it.
        paused: drain.running && island.hovered
        onFinished: island.hide()
    }

    // A pill-shaped button under an open notification.
    component Button: Rectangle {
        id: button
        required property var theme
        required property string label
        property bool primary: false
        signal clicked()

        implicitWidth: buttonText.implicitWidth + 18
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

    PanelWindow {
        id: win

        screen: Quickshell.screens.find(s => s.name === island.outputName) ?? Quickshell.screens[0]
        visible: island.n !== null || foldTimer.running
        anchors {
            top: true
        }
        implicitWidth: 460
        implicitHeight: 240
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "chauvenity-notifications"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // Clicks anywhere else go to whatever is under it.
        mask: Region {
            item: pill
        }

        Rectangle {
            id: pill

            readonly property int compactHeight: 24
            readonly property int compactWidth: Math.min(400, Math.max(180, compactRow.width + 20))
            readonly property int openWidth: 400

            width: !island.out ? 120 : island.expanded ? pill.openWidth : pill.compactWidth
            height: island.expanded ? full.implicitHeight + 24 : pill.compactHeight
            x: Math.round((win.width - pill.width) / 2)
            // Level with the bar's own items.
            y: Math.round((island.theme.barHeight - pill.compactHeight) / 2)
            radius: island.expanded ? 18 : pill.compactHeight / 2
            opacity: island.out ? 1 : 0
            color: Qt.darker(island.theme.bgColor, 1.9)
            border.width: island.critical ? 1.5 : 1
            border.color: island.critical ? island.theme.badColor : island.theme.lineColor
            clip: true

            Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
            Behavior on height { NumberAnimation { duration: 380; easing.type: Easing.OutBack; easing.overshoot: 0.9 } }
            Behavior on radius { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 180 } }

            HoverHandler {
                onHoveredChanged: island.hovered = hovered
            }

            // Underneath the buttons: they take their own clicks.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    const n = island.n;
                    if (!n)
                        return;
                    if (mouse.button === Qt.MiddleButton) {
                        n.dismiss();
                        return;
                    }
                    if (mouse.button === Qt.LeftButton)
                        island.service.activate(n);
                    island.hide();
                }
            }

            // Closed: who and what, on one line.
            Row {
                id: compactRow
                x: 3
                y: Math.round((pill.compactHeight - 18) / 2)
                spacing: 8
                opacity: island.expanded ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }

                NotificationIcon {
                    theme: island.theme
                    notification: island.n
                    size: 18
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 160)
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Notes.plainText(island.n?.summary)
                    color: island.theme.fgColor
                    font.pixelSize: 12
                    font.bold: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    width: Math.min(implicitWidth, 180)
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Notes.firstLine(Notes.plainText(island.n?.body))
                    color: Qt.lighter(island.theme.dimColor, 1.3)
                    font.pixelSize: 12
                }
                // More waiting behind it.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: island.service.queue.length > 0
                    text: `+${island.service.queue.length}`
                    color: island.theme.accentColor
                    font.pixelSize: 11
                    font.bold: true
                }
            }

            // How much of its time is left.
            Rectangle {
                visible: !island.expanded && island.duration > 0
                x: 12
                y: pill.compactHeight - 3
                width: Math.max(0, (pill.width - 24) * island.remaining)
                height: 1.5
                radius: 1
                color: island.theme.accentColor
                opacity: 0.7
            }

            // Open: everything, and the buttons.
            Column {
                id: full
                x: 14
                y: 12
                width: pill.openWidth - 28
                spacing: 10
                opacity: island.expanded ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180 } }

                Row {
                    width: parent.width
                    spacing: 10

                    NotificationIcon {
                        theme: island.theme
                        notification: island.n
                        size: 32
                    }
                    Column {
                        width: parent.width - 42
                        spacing: 2

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: island.n?.appName ?? ""
                            color: island.critical ? island.theme.badColor : island.theme.dimColor
                            font.pixelSize: 11
                            font.bold: island.critical
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: Notes.plainText(island.n?.summary)
                            color: island.theme.fgColor
                            font.pixelSize: 13
                            font.bold: true
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            wrapMode: Text.Wrap
                            maximumLineCount: 5
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: Notes.plainText(island.n?.body)
                            color: Qt.lighter(island.theme.dimColor, 1.45)
                            font.pixelSize: 12
                        }
                    }
                }

                Flow {
                    width: parent.width
                    spacing: 6

                    Repeater {
                        model: Notes.buttonActions(island.n?.actions)

                        Button {
                            required property var modelData
                            theme: island.theme
                            label: modelData.text
                            primary: true
                            onClicked: {
                                modelData.invoke();
                                island.hide();
                            }
                        }
                    }
                    Button {
                        theme: island.theme
                        label: "Close"
                        onClicked: island.hide()
                    }
                }
            }
        }
    }
}
