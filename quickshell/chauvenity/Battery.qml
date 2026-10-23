pragma ComponentBehavior: Bound

// The bar's battery indicator: a glyph filled to the level, then the level in
// a fixed width, so the items to its left do not move as it changes. Low and
// alert (10 % or below) turn the warn and bad colours, charging the good one.
// A click opens BatteryPanel and its history.

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import "battery.mjs" as Battery

Item {
    id: bat

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // shell.qml's BatteryAlarm, whose beat the glyph flashes with.
    required property var alarm
    // Its hint, as shell.qml's `keyboard` section describes: the name
    // `ipc call bar toggle` takes, and the letter it asks for.
    property string hintName: "battery"
    property string hintKey: "b"

    readonly property var device: UPower.displayDevice
    readonly property bool ready: !!(bat.device && bat.device.isLaptopBattery)
    readonly property real level: bat.ready ? bat.device.percentage : 0
    readonly property string tone: Battery.batteryTone(bat.level, bat.ready ? bat.device.state : 0)

    visible: bat.ready
    implicitWidth: indicator.implicitWidth + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? bat.theme.hoverColor : "transparent"
    }

    Row {
        id: indicator
        anchors.centerIn: parent
        spacing: 4

        BatteryIcon {
            anchors.verticalCenter: parent.verticalCenter
            theme: bat.theme
            level: bat.level
            tone: bat.tone
            glow: bat.alarm.glow
        }

        Text {
            id: levelText
            anchors.verticalCenter: parent.verticalCenter
            // As wide as "100%", whatever the level.
            width: widest.advanceWidth
            text: Battery.percent(bat.level)
            color: bat.tone === "charging" ? bat.theme.goodColor
                : bat.tone === "alert" ? bat.theme.badColor
                : bat.tone === "low" ? bat.theme.warnColor
                : bat.theme.fgColor
            font.pixelSize: 12
            font.features: { "tnum": 1 }
        }
    }

    TextMetrics {
        id: widest
        font: levelText.font
        text: "100%"
    }

    // Opens or closes BatteryPanel, closing any other panel. A click, the bar's
    // hints and `qs -c chauvenity ipc call bar toggle battery` all come here.
    function toggle() {
        bat.panels.toggle(panel);
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: bat.toggle()
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

        // Right-aligned under the indicator, as ClaudeUsage places its panel.
        anchor.item: bat
        anchor.rect.x: bat.width - panel.implicitWidth
        anchor.rect.y: bat.height + 6

        // Translucent over niri's blur.
        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(bat.theme.panelColor, 0.75)
            border.color: bat.theme.lineColor
        }

        // Escape closes it. Qt hands the panel the bar's keys while it is
        // open, but focus has to be asked for each time it opens.
        Item {
            id: panelKeys
            Keys.onEscapePressed: bat.panels.close()
        }

        BatteryPanel {
            id: content
            x: 14
            y: 8
            theme: bat.theme
            device: bat.device
            tone: bat.tone
            glow: bat.alarm.glow
            active: panel.visible
        }
    }
}
