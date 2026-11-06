import QtQuick
import Quickshell
import Quickshell.Io

// Lets pick-to-bb (~/.config/quickshell/pick-to-bb) describe the element under
// a point of this shell. Quickshell windows are invisible to AT-SPI, so the
// shell answers for itself over `qs ipc`:
//
//     qs ipc --pid <pid> call pickToBb inspect <output> <x> <y>
//
// To make a Quickshell config inspectable, copy this file next to its
// shell.qml and add `PickInspector { roots: [bars] }` inside its ShellRoot,
// listing the windows, or the Variants / loaders holding them, by id. Popups
// inside those windows are found on their own. (The ShellRoot itself cannot be
// listed: its children are not readable from JS.)
//
// Window positions are worked out from anchors and margins, as the compositor
// does not tell clients where it put them: other surfaces' exclusive zones and
// popups slid back on screen can make them a little off.
Scope {
    id: inspector

    // Where the search for windows starts.
    property list<QtObject> roots

    IpcHandler {
        target: "pickToBb"

        function inspect(output: string, x: real, y: real): string {
            return JSON.stringify(inspector.inspectAt(output, x, y));
        }
    }

    function typeName(object) {
        // "QQuickText(0x55…)", "ClaudeUsage_QMLTYPE_23(0x55…)", "QQuickRectangle_QML_7(0x55…, "name")"
        let name = String(object).replace(/\(0x[0-9a-f]+.*$/, "");
        name = name.replace(/_QML(TYPE)?_\d+$/, "");
        return name.replace(/^QQuick/, "");
    }

    function isPanel(object) {
        return object.exclusionMode !== undefined && object.anchors !== undefined && object.anchors.top !== undefined;
    }

    function isPopup(object) {
        return object.anchor !== undefined && object.anchor !== null && object.anchor.rect !== undefined;
    }

    function listOf(value) {
        if (!value || typeof value !== "object")
            return [];
        let length;
        try {
            length = value.length;
        } catch (e) {
            // Some Quickshell list properties cannot be counted from JS.
            return [];
        }
        if (typeof length === "number") {
            const items = [];
            for (let i = 0; i < length; i++)
                items.push(value[i]);
            return items;
        }
        return [value];
    }

    // Every panel and popup reachable from the root, each with the window it
    // sits in (a popup is placed relative to its parent window).
    function collectWindows(object, owner, found, seen, depth) {
        if (!object || typeof object !== "object" || depth > 60 || seen.includes(object))
            return;
        seen.push(object);
        if (isPanel(object) || isPopup(object)) {
            found.push({
                "window": object,
                "owner": owner
            });
            owner = object;
        }
        for (const property of ["data", "instances", "contentItem", "item"]) {
            let value;
            try {
                value = object[property];
            } catch (e) {
                continue;
            }
            for (const child of listOf(value))
                collectWindows(child, owner, found, seen, depth + 1);
        }
    }

    function windowRect(entry, entries) {
        const window = entry.window;
        const width = window.width || window.implicitWidth || 0;
        const height = window.height || window.implicitHeight || 0;
        if (isPanel(window)) {
            const screen = window.screen;
            const margins = window.margins;
            const anchors = window.anchors;
            const x = anchors.left ? margins.left : anchors.right ? screen.width - width - margins.right : (screen.width - width) / 2;
            const y = anchors.top ? margins.top : anchors.bottom ? screen.height - height - margins.bottom : (screen.height - height) / 2;
            return Qt.rect(x, y, width, height);
        }
        // Popups: anchor rect inside the parent window, top-left aligned,
        // which is Quickshell's default edges and gravity.
        const parentEntry = parentOf(entry, entries);
        if (!parentEntry)
            return null;
        const parentWindow = parentEntry.window;
        const parentRect = windowRect(parentEntry, entries);
        if (!parentRect)
            return null;
        let x = window.anchor.rect.x;
        let y = window.anchor.rect.y;
        if (window.anchor.item && parentWindow.contentItem) {
            const mapped = window.anchor.item.mapToItem(parentWindow.contentItem, x, y);
            x = mapped.x;
            y = mapped.y;
        }
        return Qt.rect(parentRect.x + x, parentRect.y + y, width, height);
    }

    function screenOf(entry, entries) {
        if (entry.window.screen)
            return entry.window.screen;
        const parentEntry = isPopup(entry.window) ? parentOf(entry, entries) : null;
        return parentEntry ? screenOf(parentEntry, entries) : null;
    }

    // `anchor.window` is Quickshell's backing window object rather than the
    // PanelWindow the walk found, so the window the popup was declared in is
    // the fallback.
    function parentOf(entry, entries) {
        return entries.find(e => e.window === entry.window.anchor.window) || entries.find(e => e.window === entry.owner) || null;
    }

    // Items that only arrange or catch input: the hit test looks through them
    // to what is drawn underneath.
    function isTransparent(item) {
        const type = typeName(item);
        if (["Item", "MouseArea", "Row", "Column", "Grid", "Flow", "Repeater", "RowLayout", "ColumnLayout", "GridLayout", "Loader", "ProxyWindowContentItem"].includes(type))
            return true;
        if (type === "Rectangle" && item.color.a === 0 && (!item.border || item.border.width === 0 || item.border.color.a === 0))
            return true;
        return false;
    }

    function inside(item, x, y) {
        return x >= 0 && y >= 0 && x < item.width && y < item.height;
    }

    // Deepest drawn item at (x, y), as the chain from `item` down to it.
    function hit(item, x, y, handlers, depth) {
        if (depth > 80)
            return null;
        if (typeName(item) === "MouseArea" && item.enabled)
            handlers.push(item);
        const children = listOf(item.children);
        const order = children.map((child, index) => index);
        order.sort((a, b) => (children[b].z - children[a].z) || (b - a));
        for (const index of order) {
            const child = children[index];
            if (!child.visible || child.opacity === 0)
                continue;
            const point = item.mapToItem(child, x, y);
            if (!inside(child, point.x, point.y))
                continue;
            const below = hit(child, point.x, point.y, handlers, depth + 1);
            if (below)
                return [item].concat(below);
        }
        return isTransparent(item) ? null : [item];
    }

    function textOf(item, budget) {
        const parts = [];
        const walk = (node, depth) => {
            if (budget.left <= 0 || depth > 40 || !node.visible)
                return;
            if (typeof node.text === "string" && node.text.length > 0) {
                parts.push(node.text);
                budget.left -= node.text.length;
            }
            for (const child of listOf(node.children))
                walk(child, depth + 1);
        };
        walk(item, 0);
        return parts.join("\n");
    }

    function describe(item) {
        const info = {
            "type": typeName(item)
        };
        if (item.objectName)
            info.objectName = item.objectName;
        if (typeof item.text === "string" && item.text)
            info.text = item.text.slice(0, 200);
        return info;
    }

    function inspectAt(output, x, y) {
        const entries = [];
        for (const root of listOf(inspector.roots))
            collectWindows(root, null, entries, [], 0);
        // Popups open over their parents, so they are tried first.
        const ordered = entries.filter(e => isPopup(e.window)).concat(entries.filter(e => isPanel(e.window)));
        for (const entry of ordered) {
            const window = entry.window;
            if (!window.visible || !window.contentItem)
                continue;
            const screen = screenOf(entry, entries);
            if (!screen || screen.name !== output)
                continue;
            const rect = windowRect(entry, entries);
            if (!rect || x < rect.x || y < rect.y || x >= rect.x + rect.width || y >= rect.y + rect.height)
                continue;

            const handlers = [];
            const chain = hit(window.contentItem, x - rect.x, y - rect.y, handlers, 0) || [window.contentItem];
            const element = chain[chain.length - 1];
            const origin = element.mapToItem(window.contentItem, 0, 0);
            const budget = {
                "left": 4000
            };
            // Each MouseArea under the point, with the component it belongs to.
            const clickable = handlers.filter(h => {
                const p = h.mapFromItem(window.contentItem, x - rect.x, y - rect.y);
                return inside(h, p.x, p.y);
            }).map(h => h.parent ? typeName(h.parent) : "?");
            return {
                "hit": true,
                "config": Quickshell.shellDir,
                "surface": {
                    "type": isPanel(window) ? "PanelWindow" : "PopupWindow",
                    "rect": [rect.x, rect.y, rect.width, rect.height]
                },
                "element": Object.assign(describe(element), {
                    "rect": [rect.x + origin.x, rect.y + origin.y, element.width, element.height],
                    "subtreeText": textOf(element, budget)
                }),
                "path": chain.slice(0, -1).filter(item => item !== window.contentItem).map(describe),
                "clickable": clickable
            };
        }
        return {
            "hit": false
        };
    }
}
