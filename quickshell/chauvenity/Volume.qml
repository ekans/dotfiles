pragma ComponentBehavior: Bound

// The bar's volume indicator: a glyph for the default sink's kind, a meter of
// what it plays (PeakMeter), then the level in a fixed width, so the items to
// its left do not move as it changes.
// Muted keeps the level, struck out; above 100 % it turns the warn colour.
// The wheel steps it 5 % at a time, a middle click mutes, and a click opens
// VolumePanel, where the keyboard steps, mutes, tests and picks the output too,
// and the microphone with Shift (Super+Space h then V opens it).

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "audio.mjs" as Audio

Item {
    id: vol

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // Its hint, as shell.qml's `keyboard` section describes: the name
    // `ipc call bar toggle` takes, and the letter it asks for.
    property string hintName: "volume"
    property string hintKey: "v"
    // Icon only.
    property bool compact: false

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool ready: !!(vol.sink && vol.sink.audio)
    readonly property real level: vol.ready ? vol.sink.audio.volume : 0
    readonly property bool muted: vol.ready && vol.sink.audio.muted
    readonly property string tone: Audio.volumeTone(vol.level, vol.muted)

    visible: vol.ready
    implicitWidth: indicator.implicitWidth + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? vol.theme.hoverColor : "transparent"
    }

    Row {
        id: indicator
        anchors.centerIn: parent
        spacing: 4

        AudioIcon {
            anchors.verticalCenter: parent.verticalCenter
            theme: vol.theme
            kind: vol.ready ? Audio.nodeKind(vol.sink.name, vol.sink.properties) : "speaker"
            level: vol.level
            muted: vol.muted
            ink: vol.tone === "over" ? vol.theme.warnColor : vol.theme.dimColor
        }

        PeakMeter {
            visible: !vol.compact
            anchors.verticalCenter: parent.verticalCenter
            theme: vol.theme
            sink: vol.sink
            muted: vol.muted
        }

        Text {
            id: levelText
            visible: !vol.compact
            anchors.verticalCenter: parent.verticalCenter
            // As wide as "100%", whatever the level.
            width: widest.advanceWidth
            text: Audio.percent(vol.level)
            color: vol.tone === "muted" ? vol.theme.dimColor
                : vol.tone === "over" ? vol.theme.warnColor
                : vol.theme.fgColor
            font.pixelSize: 12
            font.strikeout: vol.muted
            font.features: { "tnum": 1 }
        }
    }

    TextMetrics {
        id: widest
        font: levelText.font
        text: "100%"
    }

    // Opens or closes VolumePanel, closing any other panel. A click, the bar's
    // hints and `qs -c chauvenity ipc call bar toggle volume` all come here.
    function toggle() {
        vol.panels.toggle(panel);
    }

    MouseArea {
        id: mouse

        // Wheel travel not yet turned into a 5 % step: a touchpad sends it a
        // few units at a time, a mouse 120 per notch.
        property real pendingWheel: 0

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: event => {
            if (event.button === Qt.MiddleButton) {
                if (vol.ready)
                    vol.sink.audio.muted = !vol.sink.audio.muted;
            } else {
                vol.toggle();
            }
        }
        onWheel: event => {
            mouse.pendingWheel += event.angleDelta.y;
            const notches = Math.trunc(mouse.pendingWheel / 120);
            if (notches === 0 || !vol.ready)
                return;
            mouse.pendingWheel -= notches * 120;
            vol.sink.audio.volume = Audio.stepVolume(vol.level, notches);
        }
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
        anchor.item: vol
        anchor.rect.x: vol.width - panel.implicitWidth
        anchor.rect.y: vol.height + 6

        // Translucent over niri's blur.
        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(vol.theme.panelColor, 0.75)
            border.color: vol.theme.lineColor
        }

        // Escape closes it, and VolumePanel takes the rest. Qt hands the
        // panel the bar's keys while it is open, but focus has to be asked
        // for each time it opens.
        Item {
            id: panelKeys
            Keys.onEscapePressed: vol.panels.close()
            Keys.onPressed: event => event.accepted = content.keyPressed(event)
        }

        VolumePanel {
            id: content
            x: 14
            y: 8
            theme: vol.theme
            active: panel.visible
        }
    }
}
