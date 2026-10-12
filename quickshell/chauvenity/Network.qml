pragma ComponentBehavior: Bound

// The bar's network indicator: an Ethernet jack while a cable is connected,
// else the Wi-Fi arcs lit to the signal and the network's name. Wi-Fi off is
// the fan struck through. Connected without reaching the internet (a café's
// sign-in page) turns it the warn colour. A middle click turns Wi-Fi on or
// off, and a click opens NetworkPanel, where the networks are picked (Mod+B
// then N opens it).
//
// All of it comes from Quickshell.Networking, which talks to NetworkManager
// over D-Bus: no nmcli, nothing polled.

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Networking
import "network.mjs" as Net

Item {
    id: net

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // Its hint, as shell.qml's `keyboard` section describes: the name
    // `ipc call bar toggle` takes, and the letter it asks for.
    property string hintName: "network"
    property string hintKey: "n"
    // Icon only.
    property bool compact: false

    readonly property var devices: Networking.devices.values
    // The first Wi-Fi card; a laptop has one.
    readonly property var wifiDevice: net.devices.find(d => d.type === DeviceType.Wifi) ?? null
    readonly property var wifiNetworks: net.wifiDevice ? net.wifiDevice.networks.values : []
    readonly property var wifiNetwork: net.wifiNetworks.find(n => n.connected)
        ?? net.wifiNetworks.find(n => n.stateChanging)
        ?? null
    readonly property bool wifiOn: Networking.wifiEnabled && Networking.wifiHardwareEnabled
    readonly property string connectivity: {
        switch (Networking.connectivity) {
        case NetworkConnectivity.Full: return "full";
        case NetworkConnectivity.Limited: return "limited";
        case NetworkConnectivity.Portal: return "portal";
        case NetworkConnectivity.None: return "none";
        default: return "unknown";
        }
    }
    readonly property var look: Net.barState({
        wired: net.devices.some(d => d.type === DeviceType.Wired && d.connected),
        wifiOn: net.wifiOn,
        wifi: net.wifiNetwork,
        connectivity: net.connectivity
    })

    // Without NetworkManager there is nothing to show or change.
    visible: Networking.backend !== NetworkBackendType.None
    implicitWidth: indicator.implicitWidth + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? net.theme.hoverColor : "transparent"
    }

    Row {
        id: indicator
        anchors.centerIn: parent
        spacing: 5

        NetworkIcon {
            anchors.verticalCenter: parent.verticalCenter
            theme: net.theme
            kind: net.look.glyph
            level: net.look.level
            busy: net.look.busy
            ink: net.look.tone === "warn" ? net.theme.warnColor : net.theme.dimColor
        }

        Text {
            visible: !net.compact && net.look.label !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, 110)
            elide: Text.ElideRight
            // Anyone nearby names their network; AutoText would render markup
            // in an SSID.
            textFormat: Text.PlainText
            text: net.look.label
            color: net.look.tone === "warn" ? net.theme.warnColor
                : net.look.tone === "dim" ? net.theme.dimColor
                : net.theme.fgColor
            font.pixelSize: 12
        }
    }

    // Opens or closes NetworkPanel, closing any other panel. A click, the bar's
    // hints and `qs -c chauvenity ipc call bar toggle network` all come here.
    function toggle() {
        net.panels.toggle(panel);
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: event => {
            if (event.button === Qt.MiddleButton)
                Networking.wifiEnabled = !Networking.wifiEnabled;
            else
                net.toggle();
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
        anchor.item: net
        anchor.rect.x: net.width - panel.implicitWidth
        anchor.rect.y: net.height + 6

        // Translucent over niri's blur.
        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(net.theme.panelColor, 0.75)
            border.color: net.theme.lineColor
        }

        // Escape closes it, and NetworkPanel takes the rest. Qt hands the
        // panel the bar's keys while it is open, but focus has to be asked
        // for each time it opens, and again when the password field lets go.
        Item {
            id: panelKeys
            Keys.onEscapePressed: net.panels.close()
            Keys.onPressed: event => event.accepted = content.keyPressed(event)
        }

        NetworkPanel {
            id: content
            x: 14
            y: 8
            theme: net.theme
            active: panel.visible
            wifiDevice: net.wifiDevice
            connectivity: net.connectivity
            onKeysBack: panelKeys.forceActiveFocus()
            onCloseRequested: net.panels.close()
        }
    }
}
