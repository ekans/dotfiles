import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Which open overlay gets the keyboard. When two overlays ask for it
// exclusively, niri draws the one opened last on top but sends the keys to the
// one opened first, so Super+Space v v over bb-new showed the clipboard and typed
// into bb-new. The open overlays keep a stack of their names in
// $XDG_RUNTIME_DIR/quickshell-overlays, newest last, and only the newest asks
// for the keyboard. The ones below keep their state and get it back in turn.
//
// To take part, copy this file next to a config's shell.qml, add
// `OverlayFocus { id: overlayFocus; name: "…"; open: root.open }` and give the
// window `WlrLayershell.keyboardFocus: overlayFocus.keyboardFocus`.
Scope {
    id: focus

    required property string name
    property bool open

    readonly property bool held: focus.open && focus.stack[focus.stack.length - 1] === focus.name
    readonly property int keyboardFocus: focus.held ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    property list<string> stack: []

    onOpenChanged: focus.write(focus.open)
    // A restart while open would leave the name on the stack, above the others.
    Component.onCompleted: focus.write(false)

    function write(present) {
        file.reload();
        const names = file.text().split("\n").filter(n => n !== "" && n !== focus.name);
        file.setText(names.concat(present ? [focus.name] : []).map(n => n + "\n").join(""));
    }

    FileView {
        id: file

        path: `${Quickshell.env("XDG_RUNTIME_DIR")}/quickshell-overlays`
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: file.reload()
        onLoaded: focus.stack = file.text().split("\n").filter(n => n !== "")
        onSaved: focus.stack = file.text().split("\n").filter(n => n !== "")
    }
}
