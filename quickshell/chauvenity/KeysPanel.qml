pragma ComponentBehavior: Bound

// The keyboard shortcuts panel: niri's binds, grouped by what they act on and
// laid out in columns, in place of niri's own one-column list.
//
//     qs -c chauvenity ipc call keys toggle     # Mod+Shift+/ in ~/.config/niri
//
// The binds are read from niri's config files each time the panel opens, the
// way niri reads them (includes, and later binds overriding earlier ones), so
// it shows what niri does now. keys.mjs does the reading and the wording.
//
// Keys: type to filter · Esc clears the filter, then closes · a click outside
// closes.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "keys.mjs" as Binds

Scope {
    id: panel

    required property var theme
    // The output niri has focused, by name; the panel opens there.
    required property string outputName

    readonly property alias window: overlay
    property bool open: false

    property var groups: []
    property var files: []
    property var problems: []
    property string query: ""
    readonly property var shown: Binds.filterGroups(panel.groups, panel.query)

    // A cleared filter can leave the height as it was, so the height alone
    // does not say when the full list is back.
    onQueryChanged: frame.keepTop()

    function toggle() {
        if (panel.open)
            panel.close();
        else
            panel.summon();
    }

    function close() {
        panel.open = false;
    }

    // --- reading niri's config ------------------------------------------------
    // A file at a time, as resolveBinds asks for it: a handful of small files,
    // read in well under a frame.

    FileView {
        id: reader
        blockAllReads: true
        printErrors: false
    }

    function readFile(path) {
        // Cleared first, so a file read on the last opening is read again.
        reader.path = "";
        reader.path = path;
        reader.waitForJob();
        return reader.loaded ? reader.text() : null;
    }

    function summon() {
        const env = {
            HOME: Quickshell.env("HOME") ?? "",
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME") ?? "",
            NIRI_CONFIG: Quickshell.env("NIRI_CONFIG") ?? "",
        };
        const texts = {};
        let result = Binds.resolveBinds(texts, env);
        while (result.need) {
            texts[result.need] = panel.readFile(result.need);
            result = Binds.resolveBinds(texts, env);
        }
        for (const problem of result.problems)
            console.warn(`keys: ${problem}`);
        panel.groups = Binds.groupBinds(result.binds);
        panel.files = result.files;
        panel.problems = result.problems;
        search.text = "";
        body.contentY = 0;
        panel.open = true;
    }

    function homePath(path) {
        const home = Quickshell.env("HOME") ?? "";
        return home !== "" && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
    }

    // --- pieces ------------------------------------------------------------------

    // One key, as a key cap. Modifiers are drawn dimmer than the key they
    // change, so the key itself is what the eye lands on.
    component KeyCap: Rectangle {
        id: cap
        required property string label
        property bool modifier: false

        width: Math.max(22, capText.implicitWidth + 12)
        height: 22
        radius: 5
        color: panel.theme.trackColor
        border.color: panel.theme.lineColor

        Text {
            id: capText
            anchors.centerIn: parent
            text: cap.label
            textFormat: Text.PlainText
            color: cap.modifier ? panel.theme.dimColor : panel.theme.fgColor
            font.pixelSize: 11
            font.bold: !cap.modifier
            // A pair's two keys ("K J") read as two, not as one word.
            font.wordSpacing: 4
        }
    }

    component Separator: Text {
        height: 22
        verticalAlignment: Text.AlignVCenter
        color: panel.theme.dimColor
        font.pixelSize: 11
    }

    // The keys of a row: its chords, "or" between them; within a chord the
    // modifiers once, then each key they go with, "/" between them.
    component Chords: Row {
        id: chords
        required property var chordList
        spacing: 6

        Repeater {
            model: chords.chordList

            Row {
                id: chordRow
                required property var modelData
                required property int index
                spacing: 3

                Separator {
                    visible: chordRow.index > 0
                    text: "or"
                    rightPadding: 3
                }
                Repeater {
                    model: chordRow.modelData.mods
                    KeyCap {
                        required property string modelData
                        label: modelData
                        modifier: true
                    }
                }
                Repeater {
                    model: chordRow.modelData.keys

                    Row {
                        id: keyRow
                        required property string modelData
                        required property int index
                        spacing: 3

                        Separator {
                            visible: keyRow.index > 0
                            text: "/"
                        }
                        KeyCap {
                            label: keyRow.modelData
                        }
                    }
                }
            }
        }
    }

    // --- the overlay -----------------------------------------------------------

    PanelWindow {
        id: overlay

        visible: panel.open
        screen: Quickshell.screens.find(s => s.name === panel.outputName) ?? Quickshell.screens[0]
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "chauvenity-keys"
        WlrLayershell.keyboardFocus: panel.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        color: "transparent"
        // niri blurs the wallpaper behind the card ("xray"); a layer-rule
        // with `background-effect { xray false; }` blurs the windows instead.
        BackgroundEffect.blurRegion: Region {
            item: card
            radius: card.radius
        }

        onVisibleChanged: {
            if (overlay.visible) {
                search.forceActiveFocus();
                openAnimation.restart();
            }
        }

        ParallelAnimation {
            id: openAnimation
            NumberAnimation { target: backdrop; property: "opacity"; from: 0; to: 1; duration: 140 }
            NumberAnimation { target: frame; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { target: frame; property: "scale"; from: 0.97; to: 1; duration: 180; easing.type: Easing.OutCubic }
        }

        // Dims the screen; a click outside the card closes.
        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.35)

            MouseArea {
                anchors.fill: parent
                onClicked: panel.close()
            }
        }

        Item {
            id: frame

            readonly property int margin: 24
            readonly property int gap: 32
            readonly property int minColumnWidth: 320
            width: Math.round(Math.min(1260, overlay.width - 80))
            readonly property int innerWidth: frame.width - 2 * frame.margin
            readonly property int columnCount: Math.max(1, Math.min(4,
                Math.floor((frame.innerWidth + frame.gap) / (frame.minColumnWidth + frame.gap))))
            readonly property var columns: Binds.packColumns(panel.shown, frame.columnCount)
            readonly property int columnWidth: Math.floor(
                (frame.innerWidth - frame.gap * (frame.columnCount - 1)) / frame.columnCount)

            height: Math.round(Math.min(header.height + columnsRow.implicitHeight + 3 * frame.margin,
                                        overlay.height - 80))
            x: Math.round((overlay.width - frame.width) / 2)
            // Centred as the whole list is, then kept there: a filter shrinks
            // the card from the bottom rather than moving the search box away
            // from under the eyes.
            y: Math.round((overlay.height - frame.fullHeight) / 2)

            // The card's height with nothing filtered.
            property real fullHeight: 0

            function keepTop() {
                if (panel.query === "")
                    frame.fullHeight = frame.height;
            }

            onHeightChanged: frame.keepTop()

            // Translucent over niri's blur (BackgroundEffect on the overlay),
            // and without a drop shadow: a shadow is dark under the card too,
            // and would hide the blur.
            Rectangle {
                id: card
                anchors.fill: parent
                radius: 14
                color: Qt.alpha(panel.theme.bgColor, 0.75)
                border.color: panel.theme.lineColor
                clip: true

                // Swallows clicks, so only the backdrop closes.
                MouseArea {
                    anchors.fill: parent
                }

                Item {
                    id: header
                    x: frame.margin
                    y: frame.margin
                    width: frame.innerWidth
                    height: 52

                    Text {
                        id: title
                        anchors.left: parent.left
                        anchors.top: parent.top
                        text: "Keyboard shortcuts"
                        color: panel.theme.fgColor
                        font.pixelSize: 17
                        font.bold: true
                    }

                    // Where the binds came from, and what could not be read.
                    Text {
                        anchors.left: parent.left
                        anchors.right: searchBox.left
                        anchors.rightMargin: 16
                        anchors.top: title.bottom
                        anchors.topMargin: 6
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: panel.problems.length > 0
                            ? panel.problems.join(" · ")
                            : "From " + panel.files.map(f => panel.homePath(f)).join(" + ")
                        color: panel.problems.length > 0 ? panel.theme.warnColor : panel.theme.dimColor
                        font.pixelSize: 11
                    }

                    Rectangle {
                        id: searchBox
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 280
                        height: 32
                        radius: 8
                        color: panel.theme.panelColor
                        border.color: search.activeFocus ? panel.theme.accentColor : panel.theme.lineColor

                        TextInput {
                            id: search
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            verticalAlignment: TextInput.AlignVCenter
                            color: panel.theme.fgColor
                            selectionColor: panel.theme.accentColor
                            font.pixelSize: 13
                            clip: true
                            onTextChanged: {
                                panel.query = search.text;
                                body.contentY = 0;
                            }

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    if (search.text !== "")
                                        search.text = "";
                                    else
                                        panel.close();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_Down) {
                                    body.scrollBy(event.key === Qt.Key_Down ? 60 : body.height * 0.9);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_PageUp || event.key === Qt.Key_Up) {
                                    body.scrollBy(event.key === Qt.Key_Up ? -60 : -body.height * 0.9);
                                    event.accepted = true;
                                }
                            }

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                visible: search.text === ""
                                text: "Type to filter · Esc to close"
                                color: panel.theme.dimColor
                                font.pixelSize: 13
                            }
                        }
                    }
                }

                Rectangle {
                    x: frame.margin
                    y: header.y + header.height + frame.margin / 2
                    width: frame.innerWidth
                    height: 1
                    color: panel.theme.lineColor
                }

                Flickable {
                    id: body
                    x: frame.margin
                    y: header.y + header.height + frame.margin
                    width: frame.innerWidth
                    height: card.height - body.y - frame.margin / 2
                    contentWidth: columnsRow.implicitWidth
                    contentHeight: columnsRow.implicitHeight + frame.margin / 2
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    function scrollBy(dy) {
                        const most = Math.max(0, body.contentHeight - body.height);
                        body.contentY = Math.max(0, Math.min(most, body.contentY + dy));
                    }

                    Row {
                        id: columnsRow
                        spacing: frame.gap

                        Repeater {
                            model: frame.columns

                            Column {
                                id: column
                                required property var modelData
                                width: frame.columnWidth
                                spacing: 22

                                Repeater {
                                    model: column.modelData

                                    Column {
                                        id: group
                                        required property var modelData
                                        width: column.width
                                        spacing: 2

                                        Text {
                                            text: group.modelData.name.toUpperCase()
                                            color: panel.theme.accentColor
                                            font.pixelSize: 11
                                            font.bold: true
                                            font.letterSpacing: 1.2
                                            bottomPadding: 6
                                        }

                                        Repeater {
                                            model: group.modelData.rows

                                            // Text left, keys right; the keys go
                                            // under the text when both do not fit.
                                            Item {
                                                id: row
                                                required property var modelData
                                                required property int index
                                                readonly property bool stacked:
                                                    label.implicitWidth + keys.implicitWidth + 16 > row.width

                                                width: group.width
                                                height: row.stacked ? label.implicitHeight + keys.height + 12 : 30

                                                Rectangle {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: -6
                                                    anchors.rightMargin: -6
                                                    radius: 6
                                                    color: row.index % 2 === 1 ? panel.theme.panelColor : "transparent"
                                                }

                                                Text {
                                                    id: label
                                                    anchors.left: parent.left
                                                    anchors.right: row.stacked ? parent.right : keys.left
                                                    anchors.rightMargin: row.stacked ? 0 : 16
                                                    y: row.stacked ? 4 : Math.round((row.height - label.height) / 2)
                                                    elide: Text.ElideRight
                                                    // A title is the user's own text, not markup.
                                                    textFormat: Text.PlainText
                                                    text: row.modelData.text
                                                    color: panel.theme.fgColor
                                                    font.pixelSize: 13
                                                }

                                                Chords {
                                                    id: keys
                                                    anchors.right: parent.right
                                                    y: row.stacked ? label.y + label.implicitHeight + 4
                                                                   : Math.round((row.height - keys.height) / 2)
                                                    chordList: row.modelData.chords
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: body.y + 24
                    visible: panel.shown.length === 0
                    textFormat: Text.PlainText
                    text: panel.groups.length === 0 ? "No binds found in niri's config"
                                                    : `No shortcut matches “${panel.query}”`
                    color: panel.theme.dimColor
                    font.pixelSize: 13
                }
            }
        }
    }
}
