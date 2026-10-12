pragma ComponentBehavior: Bound

// Mod+E's translator, all of it, in a panel on the right of the output Mod+E
// was pressed on (Translator.qml has the whole story). Its header names the
// mode and the text it works on; under it, what the stage needs: what each
// mode would do with the selection, the word being typed, a word's senses,
// the paragraph's translation, the fix's changes with why, or how it went.
// The keys it takes are at the bottom.
//
// It holds the keyboard while it waits on one (Translator.wantsKeys), and
// lets go while the LLM works and while a result is pasted.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "translate.mjs" as Tr

PanelWindow {
    id: panel

    required property var theme
    required property var translator

    readonly property string stage: panel.translator.stage
    readonly property string mode: panel.translator.mode
    readonly property var colors: ({ good: String(panel.theme.goodColor), bad: String(panel.theme.badColor) })
    // Waiting on something it says.
    readonly property bool busy: ["probing", "looking", "working"].indexOf(panel.stage) !== -1

    visible: panel.stage !== ""
    screen: Quickshell.screens.find(s => s.name === panel.translator.output) ?? Quickshell.screens[0]
    anchors {
        top: true
        bottom: true
        right: true
    }
    margins {
        top: 8
        bottom: 8
        right: 8
    }
    implicitWidth: 460
    // Under the bar, over the windows, and without pushing them aside.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "chauvenity-translate"
    WlrLayershell.keyboardFocus: overlayFocus.keyboardFocus
    color: "transparent"
    // niri blurs the wallpaper behind the panel ("xray"); a layer-rule
    // with `background-effect { xray false; }` blurs the windows instead.
    BackgroundEffect.blurRegion: Region {
        item: sheet
        radius: sheet.radius
    }

    readonly property string title: {
        switch (panel.mode) {
        case "w":
            return "Word · Wiktionary";
        case "p":
            return "Paragraph · into English";
        case "f":
            return "Fix · simple English";
        default:
            return "Translate";
        }
    }

    readonly property string subtitle: {
        const tr = panel.translator;
        if (panel.stage === "probing")
            return "";
        if (panel.stage === "fix") {
            const count = tr.changes.length;
            return `${count} ${count === 1 ? "change" : "changes"} · ${tr.answerTime}`;
        }
        if (panel.stage === "paragraph")
            return tr.answerTime;
        const words = Tr.countWords(tr.text);
        if (words === 0)
            return panel.stage === "choosing" ? "nothing selected" : "";
        return `${words === 1 ? "1 word" : `${words} words`}${tr.selected ? " selected" : " typed"}`;
    }

    // What the modes work on, but where the stage shows it itself: the
    // headword, the changes.
    readonly property bool showsSource: panel.translator.text.trim() !== ""
        && ["choosing", "looking", "working", "paragraph"].indexOf(panel.stage) !== -1

    readonly property string keysHelp: {
        const tr = panel.translator;
        const others = Tr.MODES.filter(m => m.key !== panel.mode).map(m => m.key).join(" ");
        switch (panel.stage) {
        case "choosing":
            return "w p f pick · any other key closes";
        case "typing":
            return "↵ look it up · Esc close";
        case "looking":
            return "Esc close";
        case "word":
            if (tr.glosses.length === 0)
                return `${others} the other modes · Esc close`;
            return tr.selected
                ? `←→ pick · ↵ replace the selection · c copy · ${others} · Esc`
                : `←→ pick · ↵ copy · ${others} · Esc`;
        case "paragraph":
            return tr.selected
                ? `↵ replace the selection · c copy · ${others} the other modes · Esc`
                : `↵ copy · ${others} the other modes · Esc`;
        case "fix":
            return `Tab ↓ j next · ⇧Tab ↑ k back · Space keep yours · ↵ apply · ${others} · Esc drop`;
        default:
            return "Mod+E closes";
        }
    }

    function takeKeys() {
        if (panel.translator.stage === "typing") {
            input.text = "";
            input.forceActiveFocus();
        } else {
            keys.forceActiveFocus();
        }
    }

    onVisibleChanged: {
        if (panel.visible)
            Qt.callLater(panel.takeKeys);
    }

    // Lets an overlay opened over this one take the keyboard (OverlayFocus.qml).
    OverlayFocus {
        id: overlayFocus
        name: "chauvenity-translate"
        open: panel.visible && panel.translator.wantsKeys
    }

    Connections {
        target: panel.translator

        function onStageChanged() {
            // Once the views' bindings have seen the change.
            Qt.callLater(panel.takeKeys);
            const stage = panel.translator.stage;
            if (stage === "fix") {
                diff.contentY = 0;
                list.positionViewAtBeginning();
            } else if (stage === "paragraph") {
                translationView.contentY = 0;
            } else if (stage === "word") {
                sensesView.contentY = 0;
            }
        }
    }

    Item {
        id: keys
        Keys.onPressed: event => event.accepted = panel.translator.panelKey(event)
    }

    // Translucent over niri's blur.
    Rectangle {
        id: sheet
        anchors.fill: parent
        radius: 10
        color: Qt.alpha(panel.theme.panelColor, 0.75)
        border.color: panel.theme.lineColor
    }

    Column {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 14
        spacing: 10

        Row {
            width: head.width
            spacing: 8

            Text {
                id: titleIcon
                text: "文A"
                color: panel.theme.accentColor
                font.pixelSize: 13
                font.bold: true
            }
            Text {
                anchors.baseline: titleIcon.baseline
                text: panel.title
                color: panel.theme.fgColor
                font.pixelSize: 13
                font.bold: true
            }
            Text {
                anchors.baseline: titleIcon.baseline
                textFormat: Text.PlainText
                text: panel.subtitle
                color: panel.theme.dimColor
                font.pixelSize: 11
            }
        }

        // The modes, the one picked lit, once one is: while choosing, the
        // body has them.
        Row {
            visible: panel.mode !== "" && panel.stage !== "done"
            spacing: 14

            Repeater {
                model: Tr.MODES

                Row {
                    id: modeTab
                    required property var modelData
                    readonly property bool picked: modeTab.modelData.key === panel.mode
                    spacing: 5
                    opacity: modeTab.picked ? 1 : 0.5

                    HintBadge {
                        anchors.verticalCenter: parent.verticalCenter
                        theme: panel.theme
                        shown: true
                        label: modeTab.modelData.key
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modeTab.modelData.name
                        color: modeTab.picked ? panel.theme.fgColor : panel.theme.dimColor
                        font.pixelSize: 12
                        font.bold: modeTab.picked
                    }
                }
            }
        }

        // What the modes work on: the selection, or the word typed.
        Rectangle {
            visible: panel.showsSource
            width: head.width
            height: source.height + 16
            radius: 7
            color: panel.theme.hoverColor

            Flickable {
                id: source
                x: 10
                y: 8
                width: parent.width - 20
                height: Math.min(sourceText.implicitHeight, panel.height * 0.25)
                contentHeight: sourceText.implicitHeight
                clip: true
                interactive: source.contentHeight > source.height

                Text {
                    id: sourceText
                    width: source.width
                    textFormat: Text.PlainText
                    text: panel.translator.text
                    color: panel.stage === "paragraph" ? panel.theme.dimColor : panel.theme.fgColor
                    font.pixelSize: 12
                    lineHeight: 1.2
                    wrapMode: Text.Wrap
                }
            }
        }

        Rectangle {
            width: head.width
            height: 1
            color: panel.theme.lineColor
        }
    }

    Item {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: head.bottom
        anchors.bottom: footer.top
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        anchors.topMargin: 10
        anchors.bottomMargin: 10

        // probing, looking, working: waiting on something.
        Row {
            visible: panel.busy
            spacing: 8

            Text {
                text: spinner.frames[spinner.frame]
                color: panel.theme.accentColor
                font.pixelSize: 13
            }
            Text {
                width: body.width - 24
                textFormat: Text.PlainText
                text: panel.stage === "probing" ? "reading the selection…"
                    : panel.stage === "looking" ? `looking up “${Tr.preview(panel.translator.term, 40)}”…`
                    : panel.translator.message
                color: panel.theme.fgColor
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
        }

        // choosing: the three modes, each with what it would do.
        Column {
            visible: panel.stage === "choosing"
            width: body.width
            spacing: 14

            Repeater {
                model: panel.stage === "choosing" ? Tr.MODES : []

                Row {
                    id: choice
                    required property var modelData
                    spacing: 10

                    HintBadge {
                        theme: panel.theme
                        shown: true
                        label: choice.modelData.key
                    }
                    Column {
                        width: body.width - 28
                        spacing: 2

                        Text {
                            text: choice.modelData.name
                            color: panel.theme.fgColor
                            font.pixelSize: 13
                            font.bold: true
                        }
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: Tr.modeHint(choice.modelData.key, panel.translator)
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }

        // typing
        Rectangle {
            visible: panel.stage === "typing"
            width: body.width
            height: 30
            radius: 6
            color: panel.theme.hoverColor
            border.color: panel.theme.accentColor

            TextInput {
                id: input
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                width: parent.width - 20
                color: panel.theme.fgColor
                selectionColor: panel.theme.accentColor
                font.pixelSize: 13
                clip: true
                Keys.onReturnPressed: panel.translator.typed(input.text)
                Keys.onEnterPressed: panel.translator.typed(input.text)
                Keys.onEscapePressed: panel.translator.close()

                Text {
                    visible: input.text === ""
                    text: "a French word or set phrase"
                    color: panel.theme.dimColor
                    font.pixelSize: 13
                }
            }
        }

        // word: its senses, or why there are none.
        Item {
            id: word
            visible: panel.stage === "word"
            anchors.fill: parent

            // Where each sense's glosses start in Translator's flat list.
            readonly property var offsets: {
                const starts = [];
                let at = 0;
                for (const sense of panel.translator.senses) {
                    starts.push(at);
                    at += sense.glosses.length;
                }
                return starts;
            }
            readonly property int currentSense: panel.translator.glosses[panel.translator.gloss]?.sense ?? 0

            Column {
                id: wordHead
                width: word.width
                spacing: 4

                Text {
                    width: wordHead.width
                    textFormat: Text.PlainText
                    text: panel.translator.term || panel.translator.text
                    color: panel.theme.fgColor
                    font.pixelSize: 17
                    font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    visible: panel.translator.formNote !== ""
                    width: wordHead.width
                    textFormat: Text.PlainText
                    text: `from “${Tr.preview(panel.translator.text, 30)}”, ${panel.translator.formNote}`
                    color: panel.theme.dimColor
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                Text {
                    visible: panel.translator.glosses.length === 0
                    width: wordHead.width
                    topPadding: 6
                    textFormat: Text.PlainText
                    text: Tr.wordMissing(panel.translator.lookup, panel.translator.text)
                        + (panel.translator.lookup === "unreachable" ? "" : " p translates it.")
                    color: panel.theme.dimColor
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            Flickable {
                id: sensesView
                anchors.top: wordHead.bottom
                anchors.topMargin: 10
                anchors.bottom: wordFoot.top
                anchors.bottomMargin: 8
                width: word.width
                contentHeight: senses.implicitHeight
                clip: true
                interactive: sensesView.contentHeight > sensesView.height

                Column {
                    id: senses
                    width: sensesView.width
                    spacing: 8

                    Repeater {
                        model: panel.translator.senses

                        Row {
                            id: senseRow
                            required property var modelData
                            required property int index
                            spacing: 8

                            Text {
                                width: 52
                                topPadding: 3
                                textFormat: Text.PlainText
                                text: senseRow.modelData.pos
                                color: panel.theme.dimColor
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }

                            Flow {
                                width: senses.width - 60
                                spacing: 4

                                Repeater {
                                    model: senseRow.modelData.glosses

                                    Rectangle {
                                        id: glossChip
                                        required property string modelData
                                        required property int index
                                        readonly property bool isCurrent:
                                            word.offsets[senseRow.index] + glossChip.index === panel.translator.gloss

                                        width: Math.min(glossText.implicitWidth, senses.width - 80) + 14
                                        height: glossText.implicitHeight + 6
                                        radius: 5
                                        color: glossChip.isCurrent
                                            ? Qt.rgba(panel.theme.accentColor.r, panel.theme.accentColor.g, panel.theme.accentColor.b, 0.18)
                                            : panel.theme.hoverColor
                                        border.color: glossChip.isCurrent ? panel.theme.accentColor : panel.theme.lineColor

                                        Text {
                                            id: glossText
                                            x: 7
                                            y: 3
                                            width: Math.min(implicitWidth, senses.width - 80)
                                            textFormat: Text.PlainText
                                            text: glossChip.modelData
                                            color: glossChip.isCurrent ? panel.theme.fgColor : panel.theme.dimColor
                                            font.pixelSize: 12
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // The current sense's example, if Wiktionary has one.
                    Text {
                        readonly property var example: panel.translator.senses[word.currentSense]?.example ?? null
                        visible: example !== null
                        width: senses.width
                        topPadding: 4
                        textFormat: Text.PlainText
                        text: example ? `${example.fr} → ${example.en}` : ""
                        color: panel.theme.dimColor
                        font.pixelSize: 11
                        font.italic: true
                        wrapMode: Text.Wrap
                    }
                }
            }

            Text {
                id: wordFoot
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                visible: panel.translator.glosses.length > 0
                text: "wiktionary"
                color: panel.theme.dimColor
                font.pixelSize: 10
                font.family: "JetBrains Mono"
            }
        }

        // paragraph: the translation.
        Flickable {
            id: translationView
            visible: panel.stage === "paragraph"
            anchors.fill: parent
            contentHeight: translationText.implicitHeight
            clip: true
            interactive: translationView.contentHeight > translationView.height

            Text {
                id: translationText
                width: translationView.width
                textFormat: Text.PlainText
                text: panel.translator.translation
                color: panel.theme.fgColor
                font.pixelSize: 13
                lineHeight: 1.25
                wrapMode: Text.Wrap
            }
        }

        // fix: the whole text, every change in place, then a card per change.
        Item {
            id: fix
            visible: panel.stage === "fix"
            anchors.fill: parent

            Flickable {
                id: diff
                width: fix.width
                height: Math.min(diffText.implicitHeight, fix.height * 0.4)
                contentHeight: diffText.implicitHeight
                clip: true
                interactive: diff.contentHeight > diff.height

                Text {
                    id: diffText
                    width: diff.width
                    // Escaped by Tr.diffMarkup: the selection cannot add markup.
                    textFormat: Text.StyledText
                    text: Tr.diffMarkup(panel.translator.parts, panel.translator.changes[panel.translator.current]?.index ?? -1,
                                        panel.translator.kept, panel.colors)
                    color: panel.theme.fgColor
                    font.pixelSize: 13
                    lineHeight: 1.25
                    wrapMode: Text.Wrap
                }
            }

            Rectangle {
                id: fixLine
                anchors.top: diff.bottom
                anchors.topMargin: 10
                width: fix.width
                height: 1
                color: panel.theme.lineColor
            }

            ListView {
                id: list
                anchors.top: fixLine.bottom
                anchors.topMargin: 10
                anchors.bottom: parent.bottom
                width: fix.width
                clip: true
                spacing: 6
                model: panel.translator.changes
                currentIndex: panel.translator.current
                onCurrentIndexChanged: list.positionViewAtIndex(list.currentIndex, ListView.Contain)

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property bool isCurrent: card.index === panel.translator.current
                    readonly property bool isKept: panel.translator.kept.indexOf(card.modelData.index) !== -1

                    width: list.width
                    height: cardColumn.implicitHeight + 14
                    radius: 7
                    color: card.isCurrent ? Qt.rgba(panel.theme.accentColor.r, panel.theme.accentColor.g, panel.theme.accentColor.b, 0.1) : "transparent"
                    border.color: card.isCurrent ? panel.theme.accentColor : panel.theme.lineColor
                    opacity: card.isKept ? 0.55 : 1

                    Column {
                        id: cardColumn
                        x: 10
                        y: 7
                        width: card.width - 20
                        spacing: 3

                        Row {
                            width: cardColumn.width
                            spacing: 8

                            Text {
                                width: Math.min(implicitWidth, cardColumn.width - kindTag.width - keptText.width - 16)
                                // Escaped by Tr.changeMarkup.
                                textFormat: Text.StyledText
                                text: Tr.changeMarkup(card.modelData, card.isKept, panel.colors)
                                color: panel.theme.fgColor
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                            }
                            Rectangle {
                                id: kindTag
                                visible: card.modelData.kind !== ""
                                width: visible ? kindText.implicitWidth + 10 : 0
                                height: 16
                                radius: 3
                                color: panel.theme.hoverColor

                                Text {
                                    id: kindText
                                    anchors.centerIn: parent
                                    textFormat: Text.PlainText
                                    text: card.modelData.kind
                                    color: card.modelData.kind === "style" ? panel.theme.warnColor : panel.theme.dimColor
                                    font.pixelSize: 10
                                }
                            }
                            Text {
                                id: keptText
                                visible: card.isKept
                                width: visible ? implicitWidth : 0
                                text: "kept yours"
                                color: panel.theme.accentColor
                                font.pixelSize: 10
                            }
                        }
                        Text {
                            visible: card.modelData.why !== ""
                            width: cardColumn.width
                            textFormat: Text.PlainText
                            text: card.modelData.why
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }

        // done: how it went.
        Text {
            visible: panel.stage === "done"
            width: body.width
            textFormat: Text.PlainText
            text: (panel.translator.tone === "good" ? "✓ " : "✗ ") + panel.translator.message
            color: panel.translator.tone === "good" ? panel.theme.goodColor : panel.theme.badColor
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }
    }

    Text {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        textFormat: Text.PlainText
        text: panel.keysHelp
        color: panel.theme.dimColor
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    QtObject {
        id: spinner
        readonly property var frames: ["◐", "◓", "◑", "◒"]
        property int frame: 0
    }

    Timer {
        interval: 120
        repeat: true
        running: panel.busy
        onTriggered: spinner.frame = (spinner.frame + 1) % spinner.frames.length
    }
}
