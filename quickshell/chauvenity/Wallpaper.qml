pragma ComponentBehavior: Bound

// The picture behind the windows, one per output. No wallpaper daemon is
// installed, so the bar's own shell draws it, on niri's background layer.
// niri/config.kdl moves that layer into the backdrop, so it stays still while
// workspaces slide and shows in the overview.

import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
    id: wallpaper

    // The picture; the one place to change it. chezmoi downloads this one
    // (.chezmoiexternal.toml).
    property string source: `${Quickshell.env("HOME")}/.local/share/wallpapers/mr-goatee.jpg`

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: window
            required property var modelData

            screen: window.modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "wallpaper"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // niri's old background, which a missing or unreadable file shows.
            color: "#241f31"

            Image {
                anchors.fill: parent
                source: "file://" + wallpaper.source
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                // Decoded at the output's pixel size, not the file's 4096px.
                // From the screen rather than the window, which is 0 wide
                // until the compositor has configured it.
                sourceSize: Qt.size(
                    window.modelData.width * window.modelData.devicePixelRatio,
                    window.modelData.height * window.modelData.devicePixelRatio)
                opacity: status === Image.Ready ? 1 : 0

                Behavior on opacity { NumberAnimation { duration: 400 } }
            }
        }
    }
}
