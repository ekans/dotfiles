pragma ComponentBehavior: Bound

// The bar's walking pad: a walker, dim while the pad is not connected and lit
// while it is. While a walk is open it also shows the speed and the walk's
// time in fixed widths (the compact bar, the time only), so the items to its
// left do not move. A click opens WalkpadPanel: Live, Walks, Days, Settings.
//
// Everything comes from WalkpadService (`service.model`). This file decides
// nothing about walks.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "walkpad.mjs" as Pad

Item {
    id: pad

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // shell.qml's WalkpadService, one for every bar.
    required property var service
    required property var now
    property bool compact: false
    // Its hint: `qs -c chauvenity ipc call bar toggle walkpad`, Super+Space o w.
    property string hintName: "walkpad"
    property string hintKey: "w"

    readonly property var model: pad.service.model
    readonly property bool walking: pad.model.open !== null

    implicitWidth: indicator.implicitWidth + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? pad.theme.hoverColor : "transparent"
    }

    Row {
        id: indicator
        anchors.centerIn: parent
        spacing: 4

        WalkerIcon {
            anchors.verticalCenter: parent.verticalCenter
            theme: pad.theme
            lit: Pad.lit(pad.model)
        }

        // The speed, as wide as "10.0" whatever it reads. Hidden when compact.
        Text {
            id: speedText
            anchors.verticalCenter: parent.verticalCenter
            visible: pad.walking && !pad.compact
            width: widestSpeed.advanceWidth
            horizontalAlignment: Text.AlignRight
            text: Pad.speed(pad.model.speedKmh)
            color: pad.theme.fgColor
            font.pixelSize: 12
            font.features: { "tnum": 1 }
        }

        // The walk's time, as wide as "0:00:00".
        Text {
            id: timeText
            anchors.verticalCenter: parent.verticalCenter
            visible: pad.walking
            width: widestTime.advanceWidth
            text: pad.walking ? Pad.clock(pad.model.open.elapsedS) : ""
            color: pad.theme.fgColor
            font.pixelSize: 12
            font.features: { "tnum": 1 }
        }
    }

    TextMetrics {
        id: widestSpeed
        font: speedText.font
        text: "10.0"
    }

    TextMetrics {
        id: widestTime
        font: timeText.font
        text: "0:00:00"
    }

    // Opens or closes WalkpadPanel, closing any other panel. A click, the
    // bar's hints and `qs -c chauvenity ipc call bar toggle walkpad` all come
    // here.
    function toggle() {
        pad.panels.toggle(panel);
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: pad.toggle()
    }

    // The same popup recipe as Battery.qml: grab, blur, Escape, right-aligned
    // under the item, its anchor inside the bar so the bar hands it the keys.
    PopupWindow {
        id: panel
        visible: false
        onVisibleChanged: {
            if (panel.visible)
                panelKeys.forceActiveFocus();
        }
        grabFocus: true
        color: "transparent"
        BackgroundEffect.blurRegion: Region {
            item: sheet
            radius: sheet.radius
        }
        implicitWidth: content.implicitWidth + 28
        implicitHeight: content.implicitHeight + 16

        anchor.item: pad
        anchor.rect.x: pad.width - panel.implicitWidth
        anchor.rect.y: pad.height + 6

        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(pad.theme.panelColor, 0.75)
            border.color: pad.theme.lineColor
        }

        // Escape closes it, and WalkpadPanel takes the rest. Qt hands the
        // panel the bar's keys while it is open, but focus has to be asked
        // for each time it opens.
        Item {
            id: panelKeys
            Keys.onEscapePressed: pad.panels.close()
            Keys.onPressed: event => event.accepted = content.keyPressed(event)
        }

        WalkpadPanel {
            id: content
            x: 14
            y: 8
            theme: pad.theme
            service: pad.service
            now: pad.now
            active: panel.visible
        }
    }
}
