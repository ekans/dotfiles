pragma ComponentBehavior: Bound

// The bar's line to the walkpad helper (walkpad/, the systemd user service
// walkpad.service), one per shell like NotificationService: every bar's
// Walkpad item reads `model` from here and asks for things through it.
//
// The helper is the walkpad. It keeps recording while the bar reloads,
// crashes or is being edited, and this only shows what it says. On a reload
// the socket closes, a new one opens, and `watch` brings the whole state back
// at once. If the helper is not there, the model says so and the socket is
// tried again every 3 s. The walks already on screen stay.
//
//     systemctl --user status walkpad        journalctl --user -u walkpad

import QtQuick
import Quickshell
import Quickshell.Io
import "walkpad.mjs" as Pad

Scope {
    id: service

    // walkpad.mjs's model: what the panel and the bar item draw. Written only
    // here, and only through Pad.apply, Pad.serviceConnecting and
    // Pad.serviceDown.
    property var model: Pad.emptyModel()

    // As walkpad/config.py's socket_path. walkpad/tests/test_server.py reads
    // this file to check it.
    readonly property string socketPath: Quickshell.env("WALKPAD_SOCKET")
        || `${Quickshell.env("XDG_RUNTIME_DIR")}/walkpad.sock`

    // What the verbs answer when there is no helper to ask.
    readonly property string notRunning: "the walkpad service is not running"

    // --- what the panel and the leader can ask ----------------------------------
    // One line each, as walkpad/server.py reads them. Every verb answers ""
    // once the line is sent, or why it could not be. The result of the command
    // comes back as a new status (or a `samples` line), never as a return value.

    function finish(): string { return service.send("finish"); }
    function deleteWalk(id: int): string { return service.send(`delete ${id}`); }
    function setConnect(on: bool): string { return service.send(on ? "connect on" : "connect off"); }
    function toggleConnect(): string { return service.send("connect toggle"); }
    // Skips the rest of the backoff while Waiting: Try now, and the panel opening.
    function retry(): string { return service.send("connect on"); }
    function forget(): string { return service.send("forget"); }
    function fetchSamples(id: int): string { return service.send(`samples ${id}`); }

    // Nothing is queued for later: the panel greys its buttons while the
    // helper is not up, and a command meant for a helper that was down is not
    // one to run when it comes back.
    function send(command: string): string {
        if (!socket.connected)
            return service.notRunning;
        socket.write(command + "\n");
        socket.flush();
        return "";
    }

    function lost() {
        if (service.model.service !== "down")
            service.model = Pad.serviceDown(service.model);
        reconnect.restart();
    }

    Socket {
        id: socket
        path: service.socketPath
        connected: true

        parser: SplitParser {
            onRead: line => service.model = Pad.apply(service.model, line)
        }

        onConnectedChanged: {
            if (socket.connected) {
                service.model = Pad.serviceConnecting(service.model);
                socket.write("watch\n");
                socket.flush();
            } else {
                service.lost();
            }
        }
        // A refused connection never sets `connected`, so it does not reach
        // onConnectedChanged. The error does.
        onError: service.lost()
    }

    Timer {
        id: reconnect
        interval: 3000
        onTriggered: socket.connected = true
    }
}
