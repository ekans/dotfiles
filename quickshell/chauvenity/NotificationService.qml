pragma ComponentBehavior: Bound

// The desktop's notification server, in place of mako: every notification an
// app sends lands here. It keeps them for the bell's panel (Notifications.qml)
// until they are dismissed, and lines them up for the island
// (NotificationIsland.qml), which shows one at a time.
//
// mako has to be off for this to get the D-Bus name:
//
//     systemctl --user mask --now mako.service      # undo: unmask, start

import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import "notifications.mjs" as Notes

Scope {
    id: service

    // Only critical notifications pop up while it is on; the rest go
    // straight to the panel.
    property bool dnd: false
    // Arrived since the panel was last opened.
    property int unread: 0

    // Newest first, for the panel.
    readonly property var history: server.trackedNotifications.values.slice().reverse()

    // The one the island shows, and those waiting behind it.
    property var current: null
    property var queue: []

    // When each one arrived, by id; Notification does not say.
    property var arrivals: ({})

    function arrivedAt(n) {
        return service.arrivals[n?.id] ?? null;
    }

    function markRead() {
        service.unread = 0;
    }

    // The island is done with the current one: it stays in the panel.
    function advance() {
        const next = service.queue.slice();
        service.current = next.shift() ?? null;
        service.queue = next;
    }

    // Takes it off the island and out of the queue, e.g. as it closes.
    function forget(n) {
        if (service.queue.includes(n))
            service.queue = service.queue.filter(q => q !== n);
        if (service.current === n)
            service.advance();
    }

    // A click on it, or its default action from the panel.
    function activate(n) {
        const action = Notes.defaultAction(n.actions);
        if (action)
            action.invoke();
        else
            service.forget(n);
    }

    function clearAll() {
        for (const n of server.trackedNotifications.values.slice())
            n.dismiss();
        service.unread = 0;
    }

    function arrived(n) {
        n.tracked = true;
        if (!n.lastGeneration)
            service.unread += 1;
        service.arrivals = Object.assign({}, service.arrivals, { [n.id]: Date.now() });
        // Closed by the app, dismissed, or its action run: the object is
        // destroyed right after, so nothing may keep pointing at it.
        n.closed.connect(() => {
            service.forget(n);
            const rest = Object.assign({}, service.arrivals);
            delete rest[n.id];
            service.arrivals = rest;
        });
        if (n.lastGeneration || !Notes.popsUp(n.urgency, service.dnd))
            return;
        if (service.current === null)
            service.current = n;
        else if (n.urgency === Notes.URGENCY.Critical)
            service.queue = [n].concat(service.queue);
        else
            service.queue = service.queue.concat([n]);
    }

    // Do-not-disturb holds back what is waiting too, critical ones aside.
    onDndChanged: {
        if (!service.dnd)
            return;
        service.queue = service.queue.filter(n => n.urgency === Notes.URGENCY.Critical);
    }

    NotificationServer {
        id: server
        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        // Bodies are shown as plain text: see notifications.mjs plainText().
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        bodyImagesSupported: false
        actionsSupported: true
        imageSupported: true
        onNotification: n => service.arrived(n)
    }
}
