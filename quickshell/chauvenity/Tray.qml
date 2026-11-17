// The bar's system tray: one button per StatusNotifierItem an app publishes
// (Tailscale, 1Password, …), with the app's own icon and menu. Unlike the
// bar's other items it is not drawn, as the icons are the apps'.
//
// The tray's D-Bus watcher may belong to another process (vicinae takes it
// when it starts first); Quickshell then registers as a host on that watcher,
// so the items show either way.

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets

Row {
    id: tray

    required property var theme

    spacing: 2

    Repeater {
        model: SystemTray.items

        Item {
            id: button

            required property SystemTrayItem modelData

            // A Passive item asks the host to hide it until it has news.
            visible: button.modelData.status !== Status.Passive
            implicitWidth: 22
            implicitHeight: 22

            Rectangle {
                anchors.fill: parent
                radius: 4
                color: mouse.containsMouse ? tray.theme.hoverColor : "transparent"
            }

            IconImage {
                anchors.centerIn: parent
                implicitSize: 16
                source: button.modelData.icon
            }

            function openMenu() {
                const below = button.mapToItem(null, 0, button.height);
                button.modelData.display(button.QsWindow.window, below.x, below.y);
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onClicked: event => {
                    if (event.button === Qt.MiddleButton)
                        button.modelData.secondaryActivate();
                    else if (event.button === Qt.RightButton || button.modelData.onlyMenu)
                        button.openMenu();
                    else
                        button.modelData.activate();
                }
                onWheel: event => button.modelData.scroll(event.angleDelta.y, false)
            }
        }
    }
}
