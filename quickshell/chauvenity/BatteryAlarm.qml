pragma ComponentBehavior: Bound

// The low-battery alarm, one for the whole shell: at 10 % or below on battery
// every bar turns red and its battery glyph lights up twice a beat, a
// heartbeat. One beat drives them all, so the bars on every output and the
// glyphs in them flash together.
//
// `glow` runs 0 → 1 → 0 twice in a beat and holds 0 between beats; the bar
// scales it by `pulse.peak`. battery.mjs alertPulse() sets the pace and the
// peak from the level. The Timer starts each beat, so between beats nothing
// animates and nothing is redrawn: the alarm runs on an almost empty battery.

import QtQuick
import Quickshell.Services.UPower
import "battery.mjs" as Battery

Item {
    id: alarm

    readonly property var device: UPower.displayDevice
    readonly property bool ready: !!(alarm.device && alarm.device.isLaptopBattery)
    readonly property real level: alarm.ready ? alarm.device.percentage : 0
    readonly property bool active: alarm.ready && Battery.batteryTone(alarm.level, alarm.device.state) === "alert"
    readonly property var pulse: Battery.alertPulse(alarm.level)
    property real glow: 0

    onActiveChanged: {
        if (!alarm.active) {
            beat.stop();
            alarm.glow = 0;
        }
    }

    Timer {
        interval: alarm.pulse.period
        repeat: true
        triggeredOnStart: true
        running: alarm.active
        onTriggered: beat.restart()
    }

    // Two flashes, the second longer, then still: 37.5 % of the period, the
    // shape the glyph's own beat had at 2 s.
    SequentialAnimation {
        id: beat

        NumberAnimation { target: alarm; property: "glow"; from: 0; to: 1; duration: alarm.pulse.period * 0.045; easing.type: Easing.OutQuad }
        NumberAnimation { target: alarm; property: "glow"; from: 1; to: 0; duration: alarm.pulse.period * 0.09; easing.type: Easing.InQuad }
        PauseAnimation { duration: alarm.pulse.period * 0.035 }
        NumberAnimation { target: alarm; property: "glow"; from: 0; to: 1; duration: alarm.pulse.period * 0.045; easing.type: Easing.OutQuad }
        NumberAnimation { target: alarm; property: "glow"; from: 1; to: 0; duration: alarm.pulse.period * 0.16; easing.type: Easing.InQuad }
    }
}
