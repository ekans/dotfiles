pragma ComponentBehavior: Bound

// Copied images, hung on a line under the bar, after Tendedero
// (https://github.com/alejandrobujan/tendedero).
//
// Each image copied, and nothing copied with text alongside it (a spreadsheet
// copies its cells as both), is saved as `<sha256>.<ext>` in
// $XDG_RUNTIME_DIR/clipboard-line. That folder is the line: oldest file
// first, at most Line.MAX_ITEMS, so a restart hangs the same images and one
// copied again, from the line itself included, hangs once.
//
// The line slides down to show what was hung, and clicks pass through it:
// it came down by itself, under a pointer that was on its way somewhere
// else. `qs -c clipboard ipc call line toggle` brings it down to be used, or
// sends it back; it goes back up once the pointer has left it.
//
// Click a photo to copy it · drag it into an app to give it a copy · its
// cross lets it go. What room the photos leave is hung with underpants.

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "line.mjs" as Line

Scope {
    id: line

    readonly property string dir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/clipboard-line"

    // [{ name, tilt }], oldest first: what hangs, not counting what is falling.
    property var items: []
    property bool revealed: false
    // Brought down to be used, not to show what was hung: only then do the
    // photos take the pointer.
    property bool interactive: false
    property var targetScreen: Quickshell.screens[0]
    property string copiedName: ""
    // The portal's key for the photo pressed last: { name, key }.
    property var lent: ({ name: "", key: "" })
    property bool dragging: false
    // Bumped by the breeze; each photo sways when it changes.
    property int gust: 0
    // Which underpants hang this session, and how they look.
    readonly property int pantsSeed: Math.floor(Math.random() * 4294967296)

    ListModel {
        id: cards
    }

    function indexOf(name) {
        for (let i = 0; i < cards.count; i++) {
            if (cards.get(i).name === name)
                return i;
        }
        return -1;
    }

    function saved(output) {
        const saved = Line.parseSaved(output);
        if (!saved)
            return;
        if (saved.fits)
            line.hangName(saved.name);
        else if (!line.items.some(item => item.name === saved.name))
            Quickshell.execDetached(["rm", "-f", "--", line.dir + "/" + saved.name]);
    }

    function hangName(name) {
        const result = Line.hang(line.items, name, Line.randomTilt());
        if (result.items === line.items) {
            line.nudged(name);
            return;
        }
        line.items = result.items;
        for (const dropped of result.dropped)
            line.letGo(dropped);
        cards.append({ name: name, tilt: result.items[result.items.length - 1].tilt, arriving: true, falling: false });
        line.peek();
    }

    signal nudged(string name)

    function letGo(name) {
        line.items = line.items.filter(item => item.name !== name);
        const i = line.indexOf(name);
        if (i >= 0)
            cards.setProperty(i, "falling", true);
        Quickshell.execDetached(["rm", "-f", "--", line.dir + "/" + name]);
    }

    function forget(name) {
        const i = line.indexOf(name);
        if (i >= 0)
            cards.remove(i);
    }

    // The clipboard history's wipe takes the line down with it.
    function clear() {
        line.items = [];
        cards.clear();
        line.revealed = false;
        Quickshell.execDetached(["rm", "-rf", "--", line.dir]);
    }

    function copy(name) {
        if (copier.running)
            return;
        copier.name = name;
        copier.command = ["sh", "-c", '[ -s "$1" ] || exit 3; wl-copy --type "$2" < "$1" > /dev/null 2>&1',
                          "sh", line.dir + "/" + name, "image/" + name.slice(name.indexOf(".") + 1)];
        copier.running = true;
    }

    // A drag offers the file's path, for apps that can read it, and a key
    // from the document portal for sandboxed ones, which cannot. Qt orders
    // the formats by name, so a Flatpak sees the key first.
    function dragData(name, lent) {
        const data = { "text/uri-list": "file://" + line.dir + "/" + name + "\r\n" };
        if (lent.name === name && lent.key !== "")
            data["application/vnd.portal.filetransfer"] = lent.key;
        return data;
    }

    // On press, so the key is there by the time the pointer has moved far
    // enough to start a drag.
    function lend(name) {
        line.lent = { name: name, key: "" };
        lender.write(line.dir + "/" + name + "\n");
    }

    function dragEnded() {
        line.dragging = false;
        tuckAway.interval = 900;
        tuckAway.restart();
    }

    // portal-transfer.py holds the keys: they last as long as it runs.
    Process {
        id: lender
        running: true
        stdinEnabled: true
        command: ["/usr/bin/python3", String(Qt.resolvedUrl("portal-transfer.py")).replace("file://", "")]
        stdout: SplitParser {
            onRead: data => {
                const tab = data.indexOf("\t");
                const name = data.slice(data.lastIndexOf("/", tab) + 1, tab);
                if (line.lent.name === name)
                    line.lent = { name: name, key: data.slice(tab + 1).trim() };
            }
        }
        onRunningChanged: {
            if (!lender.running)
                restartLender.restart();
        }
    }

    Timer {
        id: restartLender
        interval: 1000
        onTriggered: lender.running = true
    }

    // A photo whose file is gone copies nothing: it falls instead.
    Process {
        id: copier
        property string name: ""
        onExited: code => {
            if (code === 3) {
                line.letGo(copier.name);
            } else if (code === 0) {
                line.copiedName = copier.name;
                copiedReset.restart();
                line.nudged(copier.name);
            }
        }
    }

    Timer {
        id: copiedReset
        interval: 1200
        onTriggered: line.copiedName = ""
    }

    // --- coming down and going back up --------------------------------------

    // To show what was just hung. A line already down stays as it is.
    function peek() {
        if (line.revealed) {
            tuckAway.interval = Math.max(tuckAway.interval, 2500);
            tuckAway.restart();
            return;
        }
        line.comeDown(false, 2500);
    }

    function toggle() {
        if (line.revealed)
            line.revealed = false;
        else
            line.comeDown(true, line.items.length > 0 ? 6000 : 2500);
    }

    // On the output niri has focused: it is asked first, so the line does not
    // come down on the last one and then jump.
    function comeDown(interactive, hold) {
        line.interactive = interactive;
        tuckAway.interval = hold;
        screenProbe.running = true;
    }

    onRevealedChanged: {
        if (line.revealed) {
            tuckAway.restart();
            wind.interval = 1500 + Math.random() * 2500;
            wind.restart();
        } else {
            line.interactive = false;
        }
    }

    Timer {
        id: tuckAway
        onTriggered: {
            if (!(line.interactive && (hover.hovered || line.dragging)))
                line.revealed = false;
        }
    }

    IpcHandler {
        target: "line"

        function toggle(): void {
            line.toggle();
        }
    }

    Process {
        id: screenProbe
        command: ["niri", "msg", "--json", "focused-output"]
        stdout: StdioCollector {
            id: screenOut
            onStreamFinished: {
                try {
                    const name = JSON.parse(screenOut.text).name;
                    line.targetScreen = Quickshell.screens.find(s => s.name === name) ?? line.targetScreen;
                } catch (e) {}
                line.revealed = true;
            }
        }
    }

    // --- hanging what is copied ----------------------------------------------

    // Run by wl-paste for each copy with the image on stdin. It prints
    // `<name>\t<file --brief>` for an image to hang, and nothing otherwise.
    // The bytes are saved before they are named, so a short write never
    // hangs, and a file already there is left alone, so a photo copied from
    // the line keeps its place in `ls -tr` and so after a restart.
    //
    // `.current` holds the hash of the image on the clipboard when the
    // watcher started. wl-paste runs this at once for that image, which is
    // not a copy: it would bring the line down at every start, and hang
    // again an image let go of while it was still on the clipboard.
    readonly property string watchScript: '[ "$CLIPBOARD_STATE" = data ] || exit 0; '
        + 'wl-paste --list-types | grep -qxE "text/plain.*|UTF8_STRING|STRING|TEXT" && exit 0; '
        + 'f=$(mktemp "$1/.in.XXXXXX") || exit 1; '
        + 'trap \'rm -f "$f"\' EXIT; '
        // Anything bigger is not a screenshot, and lives in RAM here.
        + 'head -c 67108865 > "$f" || exit 1; '
        + '[ "$(wc -c < "$f")" -le 67108864 ] || exit 0; '
        + 'case $(file --brief --mime-type "$f") in '
        + 'image/png) e=png ;; image/jpeg) e=jpeg ;; image/gif) e=gif ;; image/bmp) e=bmp ;; *) exit 0 ;; esac; '
        + 's=$(sha256sum < "$f"); s=${s%% *}; '
        + '{ read -r old _ < "$1/.current"; } 2>/dev/null; rm -f "$1/.current"; '
        + '[ "$s" = "${old:-}" ] && exit 0; '
        + '[ -e "$1/$s.$e" ] || mv "$f" "$1/$s.$e" || exit 1; '
        + 'printf "%s\\t%s\\n" "$s.$e" "$(file --brief "$1/$s.$e")"'

    // Restarted when it dies, like the history's recorders.
    Process {
        id: watcher
        running: false
        command: ["sh", "-c", 'umask 077; mkdir -p "$1" || exit 1; '
                  + 'wl-paste --type image 2>/dev/null | sha256sum > "$1/.current"; '
                  + 'exec wl-paste --type image --watch sh -c "$2" sh "$1"',
                  "sh", line.dir, line.watchScript]
        stdout: SplitParser {
            onRead: data => line.saved(data)
        }
        onRunningChanged: {
            if (!watcher.running)
                restartWatcher.restart();
        }
    }

    Timer {
        id: restartWatcher
        interval: 1000
        onTriggered: watcher.running = true
    }

    // What hung before a restart hangs again, quietly, before the watcher
    // starts: the clipboard's current image would otherwise hang twice.
    Process {
        running: true
        command: ["sh", "-c", 'cd "$1" 2>/dev/null && rm -f .in.* && ls -1tr', "sh", line.dir]
        stdout: StdioCollector {
            id: restored
            onStreamFinished: {
                const result = Line.restore(restored.text, () => Line.randomTilt());
                line.items = result.items;
                for (const item of result.items)
                    cards.append({ name: item.name, tilt: item.tilt, arriving: false, falling: false });
                for (const name of result.dropped)
                    Quickshell.execDetached(["rm", "-f", "--", line.dir + "/" + name]);
                watcher.running = true;
            }
        }
    }

    // Every so often a little wind moves the line: soon after it comes
    // down, so a short look still sees it, then every 7 to 16 s.
    Timer {
        id: wind
        running: line.revealed && line.items.length > 0
        repeat: true
        onTriggered: {
            line.gust++;
            wind.interval = 7000 + Math.random() * 9000;
        }
    }

    // --- the line --------------------------------------------------------------

    PanelWindow {
        id: win

        readonly property real hiddenY: -(Line.PANEL_HEIGHT + 12)

        screen: line.targetScreen
        visible: line.revealed || content.y > win.hiddenY + 0.5
        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: Line.PANEL_HEIGHT
        // Below the bar's exclusive zone, and leaving windows where they are.
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "clipboard-line"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        color: "transparent"
        // Clicks go through everywhere but on a photo, and everywhere when
        // the line only came down to show what was hung.
        mask: Region {
            regions: line.interactive ? line.maskRegions : []
        }

        Item {
            id: content
            width: win.width
            height: Line.PANEL_HEIGHT
            y: line.revealed ? 0 : win.hiddenY

            Behavior on y {
                NumberAnimation {
                    duration: line.revealed ? 420 : 220
                    easing.type: line.revealed ? Easing.OutBack : Easing.InCubic
                    easing.overshoot: 0.9
                }
            }

            HoverHandler {
                id: hover
                onHoveredChanged: {
                    if (!hover.hovered && !line.dragging && line.revealed && line.interactive) {
                        tuckAway.interval = 900;
                        tuckAway.restart();
                    }
                }
            }

            Rope {
                width: content.width
            }

            Rectangle {
                visible: line.items.length === 0
                x: Math.round((content.width - width) / 2)
                y: Math.round(Line.ropeY(content.width / 2, content.width) + 18)
                width: hint.implicitWidth + 24
                height: 28
                radius: 14
                color: Qt.rgba(1, 1, 1, 0.88)
                border.color: Qt.rgba(0, 0, 0, 0.10)

                Text {
                    id: hint
                    anchors.centerIn: parent
                    text: "Copy an image and it will hang here"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: "#3d3846"
                }
            }

            Repeater {
                model: Line.pantsSlots(content.width, line.pantsSeed)
                delegate: Underpants {}
            }

            Repeater {
                id: cardRepeater
                model: cards
                onItemAdded: line.updateMask()
                onItemRemoved: line.updateMask()

                delegate: Card {}
            }
        }
    }

    property var maskRegions: []

    function updateMask() {
        const regions = [];
        for (let i = 0; i < cardRepeater.count; i++) {
            const card = cardRepeater.itemAt(i);
            if (card)
                regions.push(card.maskRegion);
        }
        line.maskRegions = regions;
    }

    // A thin neutral line with a soft shadow, fading out at both ends so it
    // seems to come from beyond the screen.
    component Rope: Item {
        id: rope
        height: Line.ROPE_TOP + 2 * Line.sag(rope.width) + 4

        Shape {
            id: strands
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: false
            layer.enabled: true

            ShapePath {
                strokeColor: Qt.rgba(0, 0, 0, 0.22)
                strokeWidth: 1.6
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: -20
                startY: Line.ROPE_TOP
                PathQuad {
                    x: rope.width + 20
                    y: Line.ROPE_TOP
                    controlX: rope.width / 2
                    controlY: Line.ROPE_TOP + 2 * Line.sag(rope.width)
                }
            }
            ShapePath {
                strokeColor: Qt.rgba(0.55, 0.55, 0.55, 1)
                strokeWidth: 1.2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: -20
                startY: Line.ROPE_TOP
                PathQuad {
                    x: rope.width + 20
                    y: Line.ROPE_TOP
                    controlX: rope.width / 2
                    controlY: Line.ROPE_TOP + 2 * Line.sag(rope.width)
                }
            }
        }

        Rectangle {
            id: fade
            anchors.fill: parent
            visible: false
            layer.enabled: true
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 0.08; color: "black" }
                GradientStop { position: 0.92; color: "black" }
                GradientStop { position: 1; color: "transparent" }
            }
        }

        MultiEffect {
            anchors.fill: parent
            source: strands
            maskEnabled: true
            maskSource: fade
        }
    }

    // One photo with its clip. It drops onto the line, swings, sways with
    // the breeze and falls when let go.
    component Card: Item {
        id: card

        required property string name
        required property real tilt
        required property bool arriving
        required property bool falling

        readonly property int live: line.items.findIndex(item => item.name === card.name)
        readonly property real centerX: Line.cardX(Math.max(0, card.live), line.items.length, content.width)
        // Where it hangs; frozen when it falls.
        property real restX: card.centerX
        readonly property real ropeAt: Line.ropeY(card.restX, content.width)
        readonly property var photo: Line.photoSize(image.implicitWidth, image.implicitHeight)
        readonly property bool hovered: mouse.containsMouse && !card.falling
        // In window coordinates, around the photo as drawn: a Region on
        // `item: frame` only follows the frame's own geometry, not the card
        // or the line moving it, nor the tilt and the swing.
        readonly property var bounds: Line.frameBounds(frame.width, frame.height, frame.scale, card.rotation)
        readonly property QtObject maskRegion: Region {
            x: Math.floor(card.x + card.bounds.x)
            y: Math.floor(content.y + card.y + card.bounds.y)
            width: card.falling ? 0 : Math.ceil(card.bounds.width) + 1
            height: card.falling ? 0 : Math.ceil(card.bounds.height) + 1
        }

        property real drop: 0

        width: Line.CARD_WIDTH
        height: Line.PANEL_HEIGHT
        x: card.restX - card.width / 2
        y: card.ropeAt - 9.5 + card.drop
        transformOrigin: Item.Top
        rotation: card.tilt + sway.angle
        opacity: 0

        Swing {
            id: sway
            held: card.falling
        }

        Behavior on restX {
            enabled: !card.falling
            SpringAnimation { spring: 3; damping: 0.3 }
        }

        Component.onCompleted: {
            if (!card.arriving) {
                card.opacity = 1;
                return;
            }
            sway.angle = 16;
            card.drop = -46;
            arrive.start();
        }

        ParallelAnimation {
            id: arrive
            NumberAnimation { target: card; property: "drop"; to: 0; duration: 420; easing.type: Easing.OutBack }
            NumberAnimation { target: card; property: "opacity"; to: 1; duration: 160 }
        }

        onFallingChanged: {
            if (card.falling) {
                card.restX = card.restX;
                arrive.stop();
                fall.start();
            }
        }

        SequentialAnimation {
            id: fall
            ParallelAnimation {
                NumberAnimation { target: card; property: "drop"; to: 320; duration: 450; easing.type: Easing.InQuad }
                NumberAnimation { target: sway; property: "angle"; to: card.tilt >= 0 ? 28 : -28; duration: 450; easing.type: Easing.InQuad }
                NumberAnimation { target: card; property: "opacity"; to: 0; duration: 450; easing.type: Easing.InQuad }
            }
            ScriptAction { script: line.forget(card.name) }
        }

        Connections {
            target: line
            function onNudged(name) {
                if (name === card.name)
                    sway.nudge(3);
            }
        }

        RectangularShadow {
            anchors.fill: frame
            radius: frame.radius
            offset.y: card.hovered ? 8 : 5
            blur: card.hovered ? 28 : 20
            color: Qt.rgba(0, 0, 0, card.hovered ? 0.30 : 0.20)
            scale: frame.scale
            transformOrigin: Item.Top
        }

        Rectangle {
            id: frame
            anchors.horizontalCenter: parent.horizontalCenter
            y: Line.FRAME_TOP
            width: card.photo.width + 2 * Line.INSET
            height: card.photo.height + 2 * Line.INSET
            radius: 16
            color: Qt.rgba(1, 1, 1, 0.82)
            border.color: Qt.rgba(1, 1, 1, 0.9)
            border.width: 1
            transformOrigin: Item.Top
            scale: mouse.pressed ? 0.97 : (card.hovered ? 1.035 : 1)
            opacity: mouse.drag.active ? 0.45 : 1

            Behavior on scale {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }

            ClippingRectangle {
                anchors.fill: parent
                anchors.margins: Line.INSET
                radius: frame.radius - Line.INSET
                color: "transparent"

                Image {
                    id: image
                    anchors.fill: parent
                    source: "file://" + line.dir + "/" + card.name
                    sourceSize.width: 2 * Line.CARD_WIDTH
                    asynchronous: true
                    smooth: true
                    mipmap: true
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                drag.target: dragProxy
                onPressed: line.lend(card.name)
                onClicked: line.copy(card.name)
            }

            // What is dragged: unseen, the platform draws the photo under the
            // pointer. Copied, never moved, so the photo stays on the line.
            Item {
                id: dragProxy
                width: frame.width
                height: frame.height
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction
                Drag.proposedAction: Qt.CopyAction
                Drag.mimeData: line.dragData(card.name, line.lent)
                Drag.imageSource: image.source
                Drag.imageSourceSize: Qt.size(card.photo.width, card.photo.height)
                Drag.hotSpot.x: card.photo.width / 2
                Drag.hotSpot.y: card.photo.height / 2
                Drag.active: mouse.drag.active
                Drag.onActiveChanged: {
                    if (dragProxy.Drag.active)
                        line.dragging = true;
                }
                Drag.onDragFinished: {
                    dragProxy.x = 0;
                    dragProxy.y = 0;
                    line.dragEnded();
                }
            }

            // Lets the photo go: off the line, and its file with it.
            Rectangle {
                x: 4
                y: 4
                width: 20
                height: 20
                radius: 10
                color: closeArea.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.88)
                border.color: Qt.rgba(0, 0, 0, 0.12)
                opacity: card.hovered || closeArea.containsMouse ? 1 : 0
                scale: card.hovered || closeArea.containsMouse ? 1 : 0.6

                Behavior on opacity { NumberAnimation { duration: 180 } }
                Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 10
                    font.bold: true
                    color: "#3d3846"
                }

                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    // Only where it shows: a photo's corner is not a cross.
                    enabled: card.hovered || closeArea.containsMouse
                    hoverEnabled: true
                    onClicked: line.letGo(card.name)
                }
            }
        }

        // The clip, over the top edge of the photo.
        Clip {
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Rectangle {
            anchors.horizontalCenter: frame.horizontalCenter
            y: frame.y + frame.height * frame.scale + 8
            width: copiedLabel.implicitWidth + 20
            height: 24
            radius: 12
            color: Qt.rgba(1, 1, 1, 0.92)
            border.color: Qt.rgba(0, 0, 0, 0.10)
            opacity: line.copiedName === card.name ? 1 : 0

            Behavior on opacity { NumberAnimation { duration: 200 } }

            Text {
                id: copiedLabel
                anchors.centerIn: parent
                text: "✓ Copied"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                color: "#3d3846"
            }
        }
    }

    // A swing about the top edge: pulled aside by `nudge`, let go on the
    // damped spring in line.mjs, and stirred by the breeze. `angle` is in
    // degrees off plumb.
    component Swing: Item {
        id: sway

        property real angle: 0
        property real velocity: 0
        property bool held: false
        // How far the breeze moves it.
        property real give: 1

        function nudge(degrees) {
            if (sway.held)
                return;
            push.to = degrees;
            push.restart();
        }

        NumberAnimation {
            id: push
            target: sway
            property: "angle"
            duration: 300
            easing.type: Easing.OutQuad
            onFinished: sway.velocity = 0
        }

        FrameAnimation {
            running: !sway.held && !push.running && !Line.atRest({ angle: sway.angle, velocity: sway.velocity })
            onTriggered: {
                const next = Line.stepSwing({ angle: sway.angle, velocity: sway.velocity }, frameTime);
                sway.velocity = next.velocity;
                sway.angle = next.angle;
            }
        }

        Connections {
            target: line
            function onGustChanged() {
                breeze.interval = Math.random() * 350;
                breeze.restart();
            }
        }

        Timer {
            id: breeze
            onTriggered: sway.nudge((1.6 + Math.random() * 1.8) * sway.give)
        }
    }

    // A minimal aluminium clip, with the slot the line passes through.
    component Clip: Rectangle {
        y: 0
        width: 9
        height: 26
        radius: 3.5
        border.color: Qt.rgba(1, 1, 1, 0.7)
        border.width: 0.6
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.rgba(0.70, 0.70, 0.70, 1) }
            GradientStop { position: 0.35; color: Qt.rgba(0.93, 0.93, 0.93, 1) }
            GradientStop { position: 0.65; color: Qt.rgba(0.82, 0.82, 0.82, 1) }
            GradientStop { position: 1; color: Qt.rgba(0.62, 0.62, 0.62, 1) }
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 8.5
            width: 5
            height: 1.4
            radius: 0.7
            color: Qt.rgba(0, 0, 0, 0.32)
        }
    }

    // A pair of underpants in a gap the photos left, pegged at both
    // corners. Only to look at: clicks go through them.
    component Underpants: Item {
        id: pants

        required property var modelData

        readonly property real w: Line.PANTS_WIDTH
        readonly property real h: Line.PANTS_HEIGHT
        readonly property bool boxers: pants.modelData.kind === "boxers"
        readonly property color cloth: pants.modelData.color
        readonly property color accent: pants.modelData.color === "#ffffff" ? "#f66151" : Qt.rgba(1, 1, 1, 0.8)
        readonly property bool free: Line.isFree(pants.modelData, content.width, line.items.length)
        readonly property string outline: pants.boxers
            ? "M 4 0 L 52 0 L 56 38 Q 56 42 52 42 L 33 42 L 28 22 L 23 42 L 4 42 Q 0 42 0 38 Z"
            : "M 0 0 L 56 0 L 56 12 C 46 16 37 26 34 40 L 22 40 C 19 26 10 16 0 12 Z"

        width: pants.w
        height: pants.h + 12
        x: pants.modelData.x - pants.w / 2
        y: Line.ropeY(pants.modelData.x, content.width) - 9.5
        transformOrigin: Item.Top
        rotation: pants.modelData.tilt + sway.angle
        opacity: pants.free ? 1 : 0
        visible: pants.opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 260; easing.type: Easing.InOutQuad }
        }

        Swing {
            id: sway
            give: 0.6
        }

        // The cloth: colour, waistband and pattern, cut to shape below.
        Item {
            id: fabric
            y: 12
            width: pants.w
            height: pants.h
            visible: false
            layer.enabled: true

            Rectangle {
                anchors.fill: parent
                color: pants.cloth
            }

            Rectangle {
                width: parent.width
                height: 7
                color: Qt.darker(pants.cloth, 1.18)
            }

            Grid {
                y: 10
                x: 3
                columns: 6
                columnSpacing: 4
                rowSpacing: 4
                visible: pants.modelData.pattern === "dots"
                Repeater {
                    model: 24
                    Rectangle { width: 5; height: 5; radius: 2.5; color: pants.accent }
                }
            }

            Row {
                y: 7
                x: 2
                spacing: 5
                visible: pants.modelData.pattern === "stripes"
                Repeater {
                    model: 7
                    Rectangle { width: 3; height: pants.h; color: pants.accent }
                }
            }

            Grid {
                y: 9
                x: 2
                columns: 5
                columnSpacing: 2
                visible: pants.modelData.pattern === "hearts"
                Repeater {
                    model: 15
                    Text { text: "♥"; font.pixelSize: 9; color: pants.accent }
                }
            }
        }

        Shape {
            id: cut
            y: 12
            width: pants.w
            height: pants.h
            visible: false
            layer.enabled: true
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "black"
                strokeColor: "transparent"
                PathSvg {
                    path: pants.outline
                }
            }
        }

        MultiEffect {
            y: 12
            width: pants.w
            height: pants.h
            source: fabric
            maskEnabled: true
            maskSource: cut
            // A padded effect stretches the mask out of line with the cloth.
            autoPaddingEnabled: false
        }

        Shape {
            y: 12
            width: pants.w
            height: pants.h
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.darker(pants.cloth, 1.35)
                strokeWidth: 1
                PathSvg {
                    path: pants.outline
                }
            }
        }

        Clip {
            x: 8
        }

        Clip {
            x: pants.w - 17
        }
    }
}
