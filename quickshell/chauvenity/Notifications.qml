pragma ComponentBehavior: Bound

// The bar's notifications indicator: a bell, crossed out while do-not-disturb
// is on, and the number that arrived since the panel was last opened. A click
// opens NotificationsPanel: everything not yet dismissed, newest first.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "notifications.mjs" as Notes

Item {
    id: bell

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // NotificationService.
    required property var service
    property var now: new Date()
    // Its hint, as shell.qml's `keyboard` section describes; hints.mjs picks
    // the letter.
    property string hintName: "notifications"

    readonly property string count: Notes.countLabel(bell.service.unread)

    implicitWidth: indicator.implicitWidth + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? bell.theme.hoverColor : "transparent"
    }

    Row {
        id: indicator
        anchors.centerIn: parent
        spacing: 4

        BellIcon {
            anchors.verticalCenter: parent.verticalCenter
            theme: bell.theme
            muted: bell.service.dnd
            ink: bell.count !== "" ? bell.theme.fgColor : bell.theme.dimColor
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: bell.count !== ""
            width: Math.max(16, countText.implicitWidth + 8)
            height: 16
            radius: 8
            color: bell.theme.accentColor

            Text {
                id: countText
                anchors.centerIn: parent
                text: bell.count
                color: bell.theme.bgColor
                font.pixelSize: 11
                font.bold: true
                font.features: { "tnum": 1 }
            }
        }
    }

    // Opens or closes the panel, closing any other. A click, the bar's hints
    // and `qs -c chauvenity ipc call bar toggle notifications` all come here.
    function toggle() {
        bell.panels.toggle(panel);
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: bell.toggle()
    }

    PopupWindow {
        id: panel
        visible: false
        onVisibleChanged: {
            if (panel.visible)
                panelKeys.forceActiveFocus();
            // Read once it has been looked at, not when it opens: what came
            // in while it was open is read too.
            else
                bell.service.markRead();
        }
        // Closes it on a click in another client; a click on the bar goes
        // through barPanels in shell.qml.
        grabFocus: true
        color: "transparent"
        // niri blurs the windows behind a popup (popups are not "xray").
        BackgroundEffect.blurRegion: Region {
            item: sheet
            radius: sheet.radius
        }
        implicitWidth: content.implicitWidth + 28
        implicitHeight: content.implicitHeight + 16

        // Right-aligned under the indicator, as Battery places its panel.
        anchor.item: bell
        anchor.rect.x: bell.width - panel.implicitWidth
        anchor.rect.y: bell.height + 6

        // Translucent over niri's blur.
        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(bell.theme.panelColor, 0.75)
            border.color: bell.theme.lineColor
        }

        // Escape closes it. Qt hands the panel the bar's keys while it is
        // open, but focus has to be asked for each time it opens.
        Item {
            id: panelKeys
            Keys.onEscapePressed: bell.panels.close()
        }

        NotificationsPanel {
            id: content
            x: 14
            y: 8
            theme: bell.theme
            service: bell.service
            now: bell.now
        }
    }
}
