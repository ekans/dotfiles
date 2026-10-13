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
    property alias dnd: persist.dnd
    // In the panel and arrived since it was last opened.
    readonly property int unread: service.history.filter(n => service.arrivedAt(n) > persist.seenAt).length

    // Newest first, for the panel. A transient one is only ever a popup.
    readonly property var history: server.trackedNotifications.values.filter(n => !n.transient).reverse()

    // The one the island shows, and those waiting behind it.
    property var current: null
    property var queue: []

    // When each one arrived, by id; Notification does not say.
    readonly property var arrivals: JSON.parse(persist.arrivals)

    // The notifications themselves outlive a reload (keepOnReload), so what
    // is known about them does too.
    PersistentProperties {
        id: persist
        reloadableId: "notifications"

        property bool dnd: false
        // `arrivals` as JSON: a JS object does not survive the reload.
        property string arrivals: "{}"
        // When the panel was last opened, as a Date.now().
        property real seenAt: 0
    }

    signal renewed(var n)

    function arrivedAt(n) {
        return service.arrivals[n?.id] ?? null;
    }

    function markRead() {
        persist.seenAt = Date.now();
    }

    function next() {
        const rest = service.queue.slice();
        service.current = rest.shift() ?? null;
        service.queue = rest;
    }

    // The island is done with the current one: it stays in the panel, or
    // expires if it is transient.
    function advance() {
        const done = service.current;
        service.next();
        if (done?.transient)
            done.expire();
    }

    // Takes it off the island and out of the queue, e.g. as it closes.
    function forget(n) {
        if (service.queue.includes(n))
            service.queue = service.queue.filter(q => q !== n);
        if (service.current === n)
            service.next();
    }

    function enqueue(n) {
        if (service.current === null)
            service.current = n;
        else if (n.urgency === Notes.URGENCY.Critical)
            service.queue = [n].concat(service.queue);
        else
            service.queue = service.queue.concat([n]);
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
    }

    function stamp(n) {
        persist.arrivals = JSON.stringify(Object.assign({}, service.arrivals, { [n.id]: Date.now() }));
    }

    // The app sent it again with the same id: new again, and up again.
    function replaced(n) {
        if (!(n?.id in service.arrivals))
            return;
        service.stamp(n);
        if (service.current === n)
            service.renewed(n);
        else if (!service.queue.includes(n) && Notes.popsUp(n.urgency, service.dnd))
            service.enqueue(n);
    }

    function arrived(n) {
        const popsUp = !n.lastGeneration && Notes.popsUp(n.urgency, service.dnd);
        // Untracked, the server drops it once this returns.
        if (n.transient && !popsUp)
            return;
        n.tracked = true;
        if (!(n.lastGeneration && n.id in service.arrivals))
            service.stamp(n);
        // Closed by the app, dismissed, or its action run: the object is
        // destroyed right after, so nothing may keep pointing at it.
        n.closed.connect(() => {
            service.forget(n);
            const rest = Object.assign({}, service.arrivals);
            delete rest[n.id];
            persist.arrivals = JSON.stringify(rest);
        });
        // A replacement changes the text in place, without a new arrival;
        // callLater makes one of the two signals it can send.
        const renew = () => service.replaced(n);
        n.summaryChanged.connect(() => Qt.callLater(renew));
        n.bodyChanged.connect(() => Qt.callLater(renew));
        if (popsUp)
            service.enqueue(n);
    }

    // Do-not-disturb holds back what is waiting too, critical ones aside.
    onDndChanged: {
        if (!service.dnd)
            return;
        const held = service.queue.filter(n => n.urgency !== Notes.URGENCY.Critical);
        service.queue = service.queue.filter(n => n.urgency === Notes.URGENCY.Critical);
        for (const n of held.filter(n => n.transient))
            n.expire();
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
