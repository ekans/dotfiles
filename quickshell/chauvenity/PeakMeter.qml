pragma ComponentBehavior: Bound

// The bar's level meter: two thin bars, left and right, for what the sink
// plays, each with a tick that holds its last high; audio.mjs sets how they
// move. Empty tracks when nothing plays, so the bar does not shift. Muted
// still shows what plays, in the dim colour.
//
// The peaks come from a capture of the sink's monitor, which keeps the sink
// awake, so it runs only while a stream is linked to the sink. That capture
// is a monitor link itself, which PwNodeLinkTracker leaves out.

import QtQuick
import Quickshell.Services.Pipewire
import "audio.mjs" as Audio

Row {
    id: meter

    required property var theme
    required property var sink
    property bool muted: false

    readonly property bool playing: links.linkGroups.length > 0
    property var leftBar: Audio.METER_IDLE
    property var rightBar: Audio.METER_IDLE

    spacing: 1

    PwNodeLinkTracker {
        id: links
        node: meter.sink
    }

    PwNodePeakMonitor {
        id: monitor
        node: meter.sink
        enabled: meter.playing
    }

    // Peaks arrive about 20 times a second; this smooths the fall between
    // them, and stops once both bars are back to idle and nothing sounds.
    FrameAnimation {
        running: monitor.peak > 0 || !Audio.meterIdle(meter.leftBar) || !Audio.meterIdle(meter.rightBar)
        onTriggered: {
            const peaks = Audio.stereoPeaks(monitor.enabled ? monitor.peaks : []);
            const dt = Math.min(frameTime, 0.1);
            meter.leftBar = Audio.meterStep(meter.leftBar, peaks[0], dt);
            meter.rightBar = Audio.meterStep(meter.rightBar, peaks[1], dt);
        }
    }

    component Channel: Rectangle {
        id: channel
        required property var theme
        required property var bar
        required property bool muted

        width: 3
        height: 14
        radius: 1
        color: channel.theme.trackColor

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Math.round(channel.bar.level * parent.height)
            radius: 1
            color: channel.muted ? channel.theme.dimColor
                : channel.bar.level >= Audio.METER_WARN ? channel.theme.warnColor
                : channel.theme.accentColor
        }

        Rectangle {
            visible: channel.bar.hold > 0.02
            y: Math.round((1 - channel.bar.hold) * (parent.height - 1))
            width: parent.width
            height: 1
            color: channel.muted ? channel.theme.dimColor : channel.theme.fgColor
        }
    }

    Channel {
        anchors.verticalCenter: parent.verticalCenter
        theme: meter.theme
        bar: meter.leftBar
        muted: meter.muted
    }
    Channel {
        anchors.verticalCenter: parent.verticalCenter
        theme: meter.theme
        bar: meter.rightBar
        muted: meter.muted
    }
}
