pragma ComponentBehavior: Bound

// The panel Network.qml opens under the bar: Wi-Fi on or off, the cables, and
// the Wi-Fi networks in range, the connected one first. A click on a network
// connects to it, asking for its password first when none is saved; the
// connected one offers Disconnect, a saved one Forget, and a cable Connect or
// Disconnect. From the keyboard, W turns Wi-Fi on or off and 1–9 connect to
// the network listed under that number.
//
// The password is asked for here because nothing else in the session would:
// with no NetworkManager secret agent running (nm-applet, GNOME Shell), a
// network that wants one just fails with NoSecrets.
//
// The card scans only while the panel is open: NetworkManager then rescans
// every 10 s, which a closed panel has no use for.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Networking
import "network.mjs" as Net
import "hints.mjs" as Hints

Item {
    id: panel

    required property var theme
    // Whether the panel is open.
    property bool active: false
    // Network.qml's Wi-Fi card, or null.
    property var wifiDevice: null
    // Network.qml's connectivity, one of network.mjs's names.
    property string connectivity: "unknown"

    // The password field let go of the keyboard.
    signal keysBack()
    // Something else took over, nm-connection-editor or the sign-in page.
    signal closeRequested()

    readonly property bool wifiOn: Networking.wifiEnabled && Networking.wifiHardwareEnabled
    readonly property var wiredDevices: Networking.devices.values
        .filter(d => d.type === DeviceType.Wired && d.nmManaged)
    readonly property var inRange: panel.wifiOn && panel.wifiDevice
        ? Net.listedNetworks(panel.wifiDevice.networks.values)
        : []
    readonly property var networks: panel.inRange.slice(0, Net.MAX_LISTED)

    // The network whose password is being typed, the one a password was last
    // sent to, the one last refused with why (`{ network, text }`), and the
    // one a first click on Forget picked.
    property var prompting: null
    property var pskSent: null
    property var problem: null
    property var forgetting: null

    implicitWidth: 300
    implicitHeight: content.implicitHeight

    // Each opening starts afresh: a failure that came while it was closed has
    // been overtaken by whatever the bar shows now.
    onActiveChanged: {
        if (panel.wifiDevice)
            panel.wifiDevice.scannerEnabled = panel.active;
        panel.prompting = null;
        panel.pskSent = null;
        panel.problem = null;
        panel.forgetting = null;
    }

    // A key pressed while the panel is open, from Network.qml: W turns Wi-Fi
    // on or off, a digit connects to that network. Answers whether it was one
    // of those.
    function keyPressed(event) {
        const digit = Hints.digitKey(event.text, event.nativeScanCode);
        if (event.key === Qt.Key_W) {
            if (Networking.wifiHardwareEnabled)
                Networking.wifiEnabled = !Networking.wifiEnabled;
        } else if (digit > 0) {
            if (digit <= panel.networks.length)
                panel.pick(panel.networks[digit - 1]);
        } else {
            return false;
        }
        return true;
    }

    // network.mjs's name for a network's security.
    function securityOf(network) {
        switch (network.security) {
        case WifiSecurityType.Open:
        case WifiSecurityType.Owe:
            return "open";
        case WifiSecurityType.WpaPsk:
        case WifiSecurityType.Wpa2Psk:
        case WifiSecurityType.Sae:
            return "psk";
        default:
            return "other";
        }
    }

    function pick(network) {
        if (network.connected || network.stateChanging)
            return;
        panel.problem = null;
        const step = Net.connectStep(network.known, panel.securityOf(network));
        if (step === "password") {
            panel.prompting = network;
        } else if (step === "settings") {
            panel.problem = { network: network, text: "This network signs in with an account: set it up in Settings." };
        } else {
            panel.dismissPrompt();
            panel.pskSent = null;
            network.connect();
        }
    }

    function sendPassword(network, psk) {
        if (psk === "")
            return;
        panel.dismissPrompt();
        panel.problem = null;
        panel.pskSent = network;
        network.connectWithPsk(psk);
    }

    function dismissPrompt() {
        if (panel.prompting === null)
            return;
        panel.prompting = null;
        panel.keysBack();
    }

    function failed(network, reason) {
        if (!panel.active)
            return;
        const name = reason === ConnectionFailReason.NoSecrets ? "secrets"
            : reason === ConnectionFailReason.WifiAuthTimeout ? "timeout"
            : reason === ConnectionFailReason.WifiNetworkLost ? "lost"
            : reason === ConnectionFailReason.WifiClientFailed ? "failed"
            : reason === ConnectionFailReason.WifiClientDisconnected ? "disconnected"
            : "unknown";
        const typed = panel.pskSent === network;
        panel.pskSent = null;
        panel.problem = { network: network, text: Net.failureText(name, typed) };
        if (name === "secrets" && panel.securityOf(network) === "psk")
            panel.prompting = network;
    }

    // Forget deletes the saved password: the first click only asks.
    function forget(network) {
        if (panel.forgetting !== network) {
            panel.forgetting = network;
            forgetTimeout.restart();
            return;
        }
        panel.forgetting = null;
        network.forget();
    }

    Timer {
        id: forgetTimeout
        interval: 3000
        onTriggered: panel.forgetting = null
    }

    // NetworkManager's own check URL: a captive portal answers any plain-HTTP
    // page with its sign-in page, and this is the one it already intercepts.
    function openSignIn() {
        Quickshell.execDetached(["sh", "-c",
            "uri=$(busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager"
            + " org.freedesktop.NetworkManager ConnectivityCheckUri | sed -E 's/^s \"(.*)\"$/\\1/');"
            + " exec xdg-open \"${uri:-http://example.com}\""]);
        panel.closeRequested();
    }

    function openSettings() {
        Quickshell.execDetached(["nm-connection-editor"]);
        panel.closeRequested();
    }

    component Heading: Text {
        topPadding: 10
        bottomPadding: 2
        font.pixelSize: 11
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.4
    }

    // A word that does something, as a menu item does.
    component Link: Text {
        id: link
        required property var theme
        property bool warn: false
        signal activated()

        color: link.warn ? link.theme.warnColor
            : linkMouse.containsMouse ? link.theme.accentColor
            : link.theme.dimColor
        font.pixelSize: 11

        MouseArea {
            id: linkMouse
            anchors.fill: parent
            anchors.margins: -3
            hoverEnabled: true
            onClicked: link.activated()
        }
    }

    component Toggle: Rectangle {
        id: toggle
        required property var theme
        property bool on: false
        // False when the hardware switch holds it off.
        property bool available: true
        signal flipped()

        width: 28
        height: 16
        radius: 8
        color: toggle.on && toggle.available ? toggle.theme.accentColor : toggle.theme.trackColor
        border.color: toggle.on && toggle.available ? toggle.theme.accentColor : toggle.theme.lineColor

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: toggle.on ? toggle.width - width - 3 : 3
            width: 10
            height: 10
            radius: 5
            color: toggle.available ? toggle.theme.fgColor : toggle.theme.dimColor
            Behavior on x { NumberAnimation { duration: 120 } }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            enabled: toggle.available
            onClicked: toggle.flipped()
        }
    }

    Column {
        id: content
        width: parent.width
        spacing: 4

        // Wi-Fi on or off.
        Item {
            width: parent.width
            implicitHeight: 22

            NetworkIcon {
                id: headIcon
                anchors.verticalCenter: parent.verticalCenter
                theme: panel.theme
                kind: panel.wifiOn ? "wifi" : "off"
                level: 3
                ink: panel.theme.fgColor
            }
            Text {
                anchors.left: headIcon.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "Wi-Fi"
                color: panel.theme.fgColor
                font.pixelSize: 12
                font.bold: true
            }
            Toggle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                theme: panel.theme
                on: panel.wifiOn
                available: Networking.wifiHardwareEnabled
                onFlipped: Networking.wifiEnabled = !Networking.wifiEnabled
            }
        }

        Text {
            visible: !Networking.wifiHardwareEnabled
            width: parent.width
            wrapMode: Text.Wrap
            text: "Turned off by the hardware switch or airplane mode."
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        // The internet, when it is not reachable.
        Item {
            visible: Net.connectivityText(panel.connectivity) !== ""
            width: parent.width
            implicitHeight: Math.max(note.implicitHeight, signIn.implicitHeight)

            Text {
                id: note
                anchors.left: parent.left
                anchors.right: signIn.visible ? signIn.left : parent.right
                anchors.rightMargin: 8
                wrapMode: Text.Wrap
                text: Net.connectivityText(panel.connectivity)
                color: panel.theme.warnColor
                font.pixelSize: 11
            }
            Link {
                id: signIn
                visible: panel.connectivity === "portal"
                anchors.right: parent.right
                theme: panel.theme
                text: "Sign in"
                onActivated: panel.openSignIn()
            }
        }

        // The cables, when there is a port for one.
        Heading {
            visible: panel.wiredDevices.length > 0
            text: "Wired"
            color: panel.theme.dimColor
        }

        Repeater {
            model: ScriptModel {
                values: panel.wiredDevices
            }

            Item {
                id: wiredRow
                required property var modelData
                readonly property var device: wiredRow.modelData
                readonly property bool changing: wiredRow.device.state === ConnectionState.Connecting
                    || wiredRow.device.state === ConnectionState.Disconnecting

                width: content.width
                implicitHeight: 24

                NetworkIcon {
                    id: wiredIcon
                    anchors.verticalCenter: parent.verticalCenter
                    theme: panel.theme
                    kind: "wired"
                    ink: wiredRow.device.connected ? panel.theme.fgColor : panel.theme.dimColor
                }
                Text {
                    anchors.left: wiredIcon.right
                    anchors.leftMargin: 8
                    anchors.right: wiredState.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: `Ethernet · ${wiredRow.device.name}`
                    color: wiredRow.device.connected ? panel.theme.fgColor : panel.theme.dimColor
                    font.pixelSize: 12
                }
                Row {
                    id: wiredState
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Text {
                        visible: text !== ""
                        text: !wiredRow.device.hasLink ? "Cable unplugged"
                            : wiredRow.changing ? "Connecting…"
                            : wiredRow.device.connected ? Net.linkSpeed(wiredRow.device.linkSpeed)
                            : ""
                        color: panel.theme.dimColor
                        font.pixelSize: 11
                        font.features: { "tnum": 1 }
                    }
                    Link {
                        visible: wiredRow.device.hasLink && !wiredRow.changing
                        theme: panel.theme
                        text: wiredRow.device.connected ? "Disconnect" : "Connect"
                        onActivated: {
                            if (wiredRow.device.connected)
                                wiredRow.device.disconnect();
                            else
                                wiredRow.device.network?.connect();
                        }
                    }
                }
            }
        }

        // The Wi-Fi networks in range.
        Heading {
            visible: panel.wifiOn
            text: "Wi-Fi networks"
            color: panel.theme.dimColor
        }

        Text {
            visible: panel.wifiOn && panel.networks.length === 0
            text: panel.wifiDevice ? "Looking for networks…" : "No Wi-Fi card."
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        Repeater {
            // Keeps each row, and a password half typed in it, while the
            // networks move about with every scan.
            model: ScriptModel {
                values: panel.networks
            }

            Column {
                id: netRow
                required property var modelData
                required property int index
                readonly property var network: netRow.modelData
                readonly property bool asking: panel.prompting === netRow.network
                readonly property string problem: panel.problem?.network === netRow.network ? panel.problem.text : ""

                width: content.width
                spacing: 4

                Connections {
                    target: netRow.network
                    function onConnectionFailed(reason) {
                        panel.failed(netRow.network, reason);
                    }
                }

                Item {
                    width: parent.width
                    implicitHeight: 24

                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: -6
                        anchors.rightMargin: -6
                        radius: 4
                        color: rowMouse.containsMouse && !netRow.network.connected ? panel.theme.hoverColor : "transparent"
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: panel.pick(netRow.network)
                    }
                    NetworkIcon {
                        id: netIcon
                        anchors.verticalCenter: parent.verticalCenter
                        theme: panel.theme
                        kind: "wifi"
                        level: Net.signalLevel(netRow.network.signalStrength)
                        busy: netRow.network.stateChanging
                        ink: netRow.network.connected ? panel.theme.fgColor : panel.theme.dimColor
                    }
                    Text {
                        id: netName
                        anchors.left: netIcon.right
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, netActions.x - netName.x - lock.width - 12)
                        elide: Text.ElideRight
                        // Anyone nearby names their network.
                        textFormat: Text.PlainText
                        text: netRow.network.name
                        color: netRow.network.connected ? panel.theme.fgColor : panel.theme.dimColor
                        font.pixelSize: 12
                        font.bold: netRow.network.connected
                    }
                    // A padlock when the network has a password or a login.
                    Item {
                        id: lock
                        visible: panel.securityOf(netRow.network) !== "open"
                        anchors.left: netName.right
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10
                        height: 10

                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer

                            ShapePath {
                                strokeColor: panel.theme.dimColor
                                strokeWidth: 1.2
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                joinStyle: ShapePath.RoundJoin
                                PathSvg { path: "M2 4.8h6v4.4H2zM3.4 4.8V3.4a1.6 1.6 0 0 1 3.2 0v1.4" }
                            }
                        }
                    }
                    Row {
                        id: netActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Text {
                            visible: netRow.network.stateChanging
                            text: "Connecting…"
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                        }
                        Link {
                            visible: netRow.network.connected
                            theme: panel.theme
                            text: "Disconnect"
                            onActivated: netRow.network.disconnect()
                        }
                        Link {
                            visible: netRow.network.known && !netRow.network.stateChanging
                                && (netRow.network.connected || rowMouse.containsMouse || panel.forgetting === netRow.network)
                            theme: panel.theme
                            warn: panel.forgetting === netRow.network
                            text: panel.forgetting === netRow.network ? "Forget it?" : "Forget"
                            onActivated: panel.forget(netRow.network)
                        }
                        // The digit that connects to it, as a menu shows a shortcut.
                        Text {
                            text: netRow.index < 9 ? String(netRow.index + 1) : ""
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                        }
                    }
                }

                // Its password, when it needs one.
                Rectangle {
                    visible: netRow.asking
                    x: 24
                    width: parent.width - 24
                    height: 26
                    radius: 6
                    color: panel.theme.bgColor
                    border.color: password.activeFocus ? panel.theme.accentColor : panel.theme.lineColor

                    TextInput {
                        id: password
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        color: panel.theme.fgColor
                        selectionColor: panel.theme.accentColor
                        font.pixelSize: 12
                        clip: true
                        onVisibleChanged: {
                            if (password.visible) {
                                password.text = "";
                                password.forceActiveFocus();
                            }
                        }
                        Keys.onReturnPressed: panel.sendPassword(netRow.network, password.text)
                        Keys.onEnterPressed: panel.sendPassword(netRow.network, password.text)
                        Keys.onEscapePressed: panel.dismissPrompt()

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: password.text === ""
                            text: "Password, ↵ · Esc cancel"
                            color: panel.theme.dimColor
                            font.pixelSize: 12
                        }
                    }
                }

                Text {
                    visible: netRow.problem !== ""
                    x: 24
                    width: parent.width - 24
                    wrapMode: Text.Wrap
                    text: netRow.problem
                    color: panel.theme.warnColor
                    font.pixelSize: 11
                }
            }
        }

        Text {
            visible: panel.inRange.length > panel.networks.length
            text: `and ${panel.inRange.length - panel.networks.length} weaker`
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        Item {
            width: parent.width
            implicitHeight: footer.implicitHeight + 10

            Text {
                id: footer
                anchors.bottom: parent.bottom
                text: "W Wi-Fi · 1–9 connect · Esc close"
                color: panel.theme.dimColor
                font.pixelSize: 11
            }
            Link {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                theme: panel.theme
                text: "Settings…"
                onActivated: panel.openSettings()
            }
        }

        Item {
            width: 1
            height: 4
        }
    }
}
