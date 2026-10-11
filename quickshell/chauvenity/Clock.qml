pragma ComponentBehavior: Bound

// The bar's clock: the time over a dimmed date and ISO week, e.g. `09:29`
// over `Wed 7 Oct · W41`, in tabular digits so the bar does not shift as the
// minutes change. A click opens ClockPanel: its month calendar, and the
// events of the calendars shell.qml reads; so do the bar's hints and
// `qs -c chauvenity ipc call bar toggle clock`, and from there the panel
// works from the keyboard.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "clock.mjs" as Clock

Item {
    id: clk

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // Its hint, as shell.qml's `keyboard` section describes: the name
    // `ipc call bar toggle` takes, and the letter it asks for.
    property string hintName: "clock"
    property string hintKey: "t"
    required property date now
    // shell.qml's calendar feed.
    required property var calendar

    implicitWidth: stack.implicitWidth + 12
    implicitHeight: 28

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? clk.theme.hoverColor : "transparent"
    }

    Column {
        id: stack
        anchors.centerIn: parent
        spacing: 0

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(clk.now, "HH:mm")
            color: clk.theme.fgColor
            font.pixelSize: 13
            font.bold: true
            font.features: { "tnum": 1 }
            lineHeight: 0.95
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(clk.now, "ddd d MMM") + " · W" + Clock.isoWeek(clk.now).week
            color: clk.theme.dimColor
            font.pixelSize: 9
            font.features: { "tnum": 1 }
        }
    }

    // Opens or closes ClockPanel, closing any other panel. A click, the bar's
    // hints and `qs -c chauvenity ipc call bar toggle clock` all come here.
    function toggle() {
        clk.panels.toggle(panel);
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: clk.toggle()
    }

    PopupWindow {
        id: panel
        visible: false
        onVisibleChanged: {
            if (panel.visible)
                panelKeys.forceActiveFocus();
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

        // Right-aligned under the clock, as ClaudeUsage places its panel.
        anchor.item: clk
        anchor.rect.x: clk.width - panel.implicitWidth
        anchor.rect.y: clk.height + 4

        // Translucent over niri's blur.
        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(clk.theme.panelColor, 0.75)
            border.color: clk.theme.lineColor
        }

        // Escape closes it, and ClockPanel takes the rest. Qt hands the
        // panel the bar's keys while it is open, but focus has to be asked
        // for each time it opens.
        Item {
            id: panelKeys
            Keys.onEscapePressed: clk.panels.close()
            Keys.onPressed: event => event.accepted = content.keyPressed(event)
        }

        ClockPanel {
            id: content
            x: 14
            y: 8
            theme: clk.theme
            now: clk.now
            calendar: clk.calendar
            active: panel.visible
            onLinkOpened: clk.panels.close()
        }
    }
}
