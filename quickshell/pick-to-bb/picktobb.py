#!/usr/bin/python3
"""Helper for the pick-to-bb Quickshell overlay.

  picktobb.py start RUN_DIR                          the focused output, which the overlay freezes
  picktobb.py windows RUN_DIR                        capture the windows that can be on it
  picktobb.py locate RUN_DIR X Y                     the UI element at output-local point (X, Y)
  picktobb.py window-at RUN_DIR X Y                  the window at that point, for a screenshot
  picktobb.py send RUN_DIR PROMPT                    start a bb thread with the prompt and the element
  picktobb.py send-shot RUN_DIR MODE PROMPT X Y W H  start a bb thread with a screenshot

`start` keeps the output in RUN_DIR/output.json; the overlay then writes
RUN_DIR/screen.png (the frozen output) and, on the first element or window
click, runs `windows`, which keeps niri's windows and their captures in
RUN_DIR/windows.json. `locate` prints its result as JSON and keeps it in
RUN_DIR/located.json, which `send` reads.

The screenshot skips the element: MODE is `region` (X Y W H framed on the
frozen output), `window` (the last `window-at`) or `screen`.

Runs on the system python on purpose: it needs the distro's PyGObject (AT-SPI)
and Pillow, which the mise/brew pythons on PATH do not have.
"""

import json
import multiprocessing
import os
import shutil
import signal
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageDraw

# Claude Code's alias: the newest Opus, whichever version that is.
BB_MODEL = "opus"
BB_REASONING = "high"
BB_PROVIDER = "claude-code"
# bb's own projectless home: threads there get a scratch workspace, no repo.
BB_PROJECT = "proj_personal"
BB_ENVIRONMENT_PROVIDER = "personal-workspace"

# A pixel "matches" when its grey levels differ by less than this.
MATCH_THRESHOLD = 12
# Below this share of matching pixels a window is not taken to be there. The
# window that is there scores ~0.95; one that is not can still pass for it in
# part (a dark terminal over a dark app scores ~0.6).
MIN_MATCH_SHARE = 0.75
# Crop drawn around the click when there is no element to frame (logical px).
FALLBACK_BOX = (320, 200)
CROP_PADDING = 48


# --- window position ---------------------------------------------------------
#
# niri's IPC has no on-screen position for tiled windows (and floating ones are
# placed in niri's own floating-space coordinates), so the window under a click
# is found by sliding niri's own capture of each window over the frozen output,
# coarse to fine, keeping the click point inside the window. The best match
# wins.


def capture_window(window_id, path):
    """niri's capture of a whole window, parts off screen included. niri also
    puts it on the clipboard: callers put the clipboard back."""
    if os.path.exists(path):
        os.remove(path)
    subprocess.run(
        ["niri", "msg", "action", "screenshot-window", "--id", str(window_id),
         "--write-to-disk", "true", "--path", path],
        check=True, capture_output=True, timeout=5,
    )
    return wait_for_png(path)


def wait_for_png(path, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            image = Image.open(path)
            image.load()
            return image
        except (FileNotFoundError, OSError, SyntaxError):
            time.sleep(0.05)
    raise RuntimeError("niri did not write the window screenshot")


CLIPBOARD_PREFERENCE = [
    "image/png", "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT",
]


def save_clipboard():
    try:
        listed = subprocess.run(["wl-paste", "--list-types"], capture_output=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return None
    types = listed.stdout.decode(errors="replace").split()
    if listed.returncode != 0 or not types:
        return ("empty", None)
    mime = next((t for t in CLIPBOARD_PREFERENCE if t in types), types[0])
    try:
        data = subprocess.run(
            ["wl-paste", "--no-newline", "--type", mime], capture_output=True, timeout=3
        ).stdout
    except subprocess.TimeoutExpired:
        return None
    return (mime, data)


def restore_clipboard(saved):
    if saved is None:
        return
    mime, data = saved
    try:
        if mime == "empty":
            subprocess.run(["wl-copy", "--clear"], timeout=2)
        else:
            subprocess.run(["wl-copy", "--type", mime], input=data, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        pass


def match_count(screen, window, ox, oy, box=None):
    """Matching pixels and compared pixels with the window's top-left at (ox, oy)."""
    left, top = max(ox, 0), max(oy, 0)
    right = min(ox + window.width, screen.width)
    bottom = min(oy + window.height, screen.height)
    if box:
        left, top = max(left, box[0]), max(top, box[1])
        right, bottom = min(right, box[2]), min(bottom, box[3])
    if right <= left or bottom <= top:
        return 0, 0
    a = screen.crop((left, top, right, bottom))
    b = window.crop((left - ox, top - oy, right - ox, bottom - oy))
    histogram = ImageChops.difference(a, b).histogram()
    return sum(histogram[:MATCH_THRESHOLD]), (right - left) * (bottom - top)


def best_offset(screen, window, candidates, box=None):
    best = None
    for ox, oy in candidates:
        matched, _ = match_count(screen, window, ox, oy, box)
        if best is None or matched > best[0]:
            best = (matched, ox, oy)
    return best


def locate_window(screen_png, window_png, point=None):
    """Window top-left in screen pixels, and the share of pixels that agree.

    With a point, only positions that keep it inside the window are tried;
    without, every position that leaves some of the window on screen.
    """
    screen = Image.open(screen_png).convert("L")
    window = Image.open(window_png).convert("L")

    def scaled(factor):
        return (
            screen.reduce(factor) if factor > 1 else screen,
            window.reduce(factor) if factor > 1 else window,
        )

    factor = 32
    s, w = scaled(factor)
    if point is None:
        xs, ys = range(1 - w.width, s.width), range(1 - w.height, s.height)
    else:
        cx, cy = point[0] // factor, point[1] // factor
        xs, ys = range(cx - w.width + 1, cx + 1), range(cy - w.height + 1, cy + 1)
    coarse = []
    for oy in ys:
        for ox in xs:
            matched, _ = match_count(s, w, ox, oy)
            coarse.append((matched, ox, oy))
    coarse.sort(reverse=True)
    seeds = [(ox * factor, oy * factor) for _, ox, oy in coarse[:4]]

    # Fine: search around each seed at growing resolution. The full-resolution
    # steps only compare a box around the click, or around the middle of the
    # window's part on screen, to stay fast.
    best = None
    for seed in seeds:
        x, y = seed
        px, py = point or (
            (max(x, 0) + min(x + window.width, screen.width)) // 2,
            (max(y, 0) + min(y + window.height, screen.height)) // 2,
        )
        for factor, radius in ((8, 6), (2, 6), (1, 2)):
            s, w = scaled(factor)
            box = None
            if factor <= 2:
                half = 400 // factor
                box = (px // factor - half, py // factor - half, px // factor + half, py // factor + half)
            candidates = [
                (x // factor + dx, y // factor + dy)
                for dy in range(-radius, radius + 1)
                for dx in range(-radius, radius + 1)
            ]
            _, bx, by = best_offset(s, w, candidates, box)
            x, y = bx * factor, by * factor
        matched, compared = match_count(screen, window, x, y)
        share = matched / compared if compared else 0.0
        if best is None or share > best[0]:
            best = (share, x, y)
    return (best[1], best[2]), best[0]


# --- AT-SPI ------------------------------------------------------------------


def atspi():
    import gi

    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    return Atspi


def cgroup_of(pid):
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            return f.read().strip()
    except OSError:
        return None


def pid_ancestors(pid):
    seen = []
    while pid and pid > 1 and len(seen) < 32:
        seen.append(pid)
        try:
            with open(f"/proc/{pid}/stat") as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return seen


def find_frame(Atspi, window):
    """The AT-SPI top-level that is niri's window, or None.

    Flatpak apps talk to AT-SPI through a proxy with another pid, so pid, cgroup
    scope, title and size are all weighed rather than relying on the pid alone.
    """
    win_pid = window.get("pid")
    win_ancestors = set(pid_ancestors(win_pid)) if win_pid else set()
    win_cgroup = cgroup_of(win_pid) if win_pid else None
    title = (window.get("title") or "").strip()
    width, height = window["layout"]["window_size"]

    best = None
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None:
            continue
        try:
            app_pid = app.get_process_id()
        except Exception:
            app_pid = None
        app_score = 0
        if app_pid and win_pid:
            if app_pid == win_pid or app_pid in win_ancestors:
                app_score = 4
            elif win_cgroup and cgroup_of(app_pid) == win_cgroup:
                app_score = 3
        try:
            count = app.get_child_count()
        except Exception:
            continue
        for j in range(count):
            frame = app.get_child_at_index(j)
            if frame is None:
                continue
            try:
                name = (frame.get_name() or "").strip()
                extents = frame.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
                active = frame.get_state_set().contains(Atspi.StateType.ACTIVE)
            except Exception:
                continue
            score = app_score
            if name and title:
                if name == title:
                    score += 3
                elif name in title or title in name:
                    score += 2
            if abs(extents.width - width) <= 2 and abs(extents.height - height) <= 2:
                score += 1
            if active and window.get("is_focused"):
                score += 1
            if score >= 4 and (best is None or score > best[0]):
                best = (score, app, frame, extents)
    return best


def extents_of(Atspi, element):
    component = element.get_component_iface()
    if component is None:
        return None
    try:
        return component.get_extents(Atspi.CoordType.WINDOW)
    except Exception:
        return None


def contains(extents, x, y):
    return (
        extents is not None
        and extents.width > 0
        and extents.height > 0
        and extents.x <= x < extents.x + extents.width
        and extents.y <= y < extents.y + extents.height
    )


def deepest_at(Atspi, frame, x, y):
    current = frame
    for _ in range(64):
        component = current.get_component_iface()
        if component is None:
            break
        child = component.get_accessible_at_point(x, y, Atspi.CoordType.WINDOW)
        if child is None or child == current:
            break
        current = child
    return current


def descend_by_extents(Atspi, frame, x, y):
    """Hit test by hand, for toolkits whose own one misses."""
    current = frame
    for _ in range(64):
        best = None
        try:
            count = min(current.get_child_count(), 500)
        except Exception:
            break
        for i in range(count):
            child = current.get_child_at_index(i)
            if child is None:
                continue
            extents = extents_of(Atspi, child)
            if contains(extents, x, y):
                area = extents.width * extents.height
                if best is None or area < best[0]:
                    best = (area, child)
        if best is None:
            break
        current = best[1]
    return current


def hit_test(Atspi, frame, x, y, scale):
    """Deepest element whose extents contain (x, y), in the frame's coordinates.

    Gecko answers hit tests in device pixels while reporting extents in logical
    ones, so each scale is tried and only an answer that contains the point
    counts.
    """
    best = None
    for factor in dict.fromkeys([1.0, scale]):
        try:
            element = deepest_at(Atspi, frame, round(x * factor), round(y * factor))
        except Exception:
            continue
        if element is None or element == frame:
            continue
        extents = extents_of(Atspi, element)
        if contains(extents, x, y):
            area = extents.width * extents.height
            if best is None or area < best[0]:
                best = (area, element)
    if best is not None:
        return best[1]
    return descend_by_extents(Atspi, frame, x, y)


def describe(Atspi, element):
    info = {"role": element.get_role_name(), "name": element.get_name() or ""}
    try:
        info["description"] = element.get_description() or ""
    except Exception:
        pass
    try:
        info["states"] = sorted(
            Atspi.StateType(s).value_nick for s in element.get_state_set().get_states()
        )
    except Exception:
        pass
    try:
        info["attributes"] = dict(element.get_attributes() or {})
    except Exception:
        pass
    parts = []
    collect_text(Atspi, element, parts, [TEXT_LIMIT])
    text = "".join(parts).strip()
    if text.strip():
        info["text"] = text[:TEXT_LIMIT]
        info["text_truncated"] = len(text) >= TEXT_LIMIT
    return info


TEXT_LIMIT = 4000
EMBEDDED_OBJECT = "￼"


def collect_text(Atspi, element, parts, budget, depth=0):
    """The element's text, children included.

    Containers in Gecko and GTK hold a placeholder character where each child
    sits rather than the child's text, so children are read in order instead.
    """
    if budget[0] <= 0 or depth > 24:
        return
    own = ""
    if element.get_text_iface() is not None:
        try:
            # Accessible.get_text shadows the Text interface's, hence the
            # unbound call.
            count = Atspi.Text.get_character_count(element)
            own = Atspi.Text.get_text(element, 0, min(count, budget[0]))
        except Exception:
            own = ""
    try:
        count = element.get_child_count()
    except Exception:
        count = 0
    if own and EMBEDDED_OBJECT not in own:
        parts.append(own)
        budget[0] -= len(own)
        return
    if own:
        # Interleave the container's own text with its children's.
        chunks = own.split(EMBEDDED_OBJECT)
        for index, chunk in enumerate(chunks):
            if chunk:
                parts.append(chunk)
                budget[0] -= len(chunk)
            elif index > 0 and parts and not parts[-1].endswith(("\n", " ")):
                # Two children with nothing between them are blocks, not inline.
                parts.append("\n")
            if index < len(chunks) - 1 and index < count:
                child = element.get_child_at_index(index)
                if child is not None:
                    collect_text(Atspi, child, parts, budget, depth + 1)
        return
    for index in range(min(count, 200)):
        child = element.get_child_at_index(index)
        if child is not None:
            collect_text(Atspi, child, parts, budget, depth + 1)
            if parts and not parts[-1].endswith(("\n", " ")):
                parts.append("\n")
        if budget[0] <= 0:
            break


def ancestors(Atspi, element, frame):
    path, url = [], None
    current = element
    for _ in range(64):
        try:
            current = current.get_parent()
        except Exception:
            break
        if current is None:
            break
        role = current.get_role_name()
        path.append({"role": role, "name": (current.get_name() or "")[:120]})
        if url is None and current.get_document_iface() is not None:
            try:
                url = current.get_document_iface().get_document_attribute_value("DocURL")
            except Exception:
                pass
        if current == frame:
            break
    path.reverse()
    return path, url


def element_at(window, local_point, scale):
    """Element under a point given relative to the window's top-left (logical px)."""
    Atspi = atspi()
    found = find_frame(Atspi, window)
    if found is None:
        return None, "the app exposes no accessibility tree for this window"
    _, app, frame, frame_extents = found
    # Toolkits disagree on where their own window origin is (Gecko puts its
    # frame at 20,20); the frame's extents line up with niri's window geometry.
    x = frame_extents.x + round(local_point[0])
    y = frame_extents.y + round(local_point[1])
    element = hit_test(Atspi, frame, x, y, scale)
    if element is None or element == frame:
        return None, "the accessibility tree has nothing under that point"
    info = describe(Atspi, element)
    info["app"] = app.get_name() or ""
    try:
        info["toolkit"] = app.get_toolkit_name() or ""
    except Exception:
        pass
    info["path"], info["document_url"] = ancestors(Atspi, element, frame)
    extents = element.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    info["rect_in_window"] = [
        extents.x - frame_extents.x, extents.y - frame_extents.y, extents.width, extents.height,
    ]
    return info, None


# --- commands ----------------------------------------------------------------


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def niri_json(*args):
    answer = subprocess.run(["niri", "msg", "--json", *args], capture_output=True, text=True, check=True)
    return json.loads(answer.stdout)


def output_info(name, outputs):
    logical = outputs[name]["logical"]
    return {"name": name, "width": logical["width"], "height": logical["height"]}


def start(run_dir):
    """The focused output: the overlay freezes it."""
    output = output_info(niri_json("focused-output")["name"], niri_json("outputs"))
    with open(os.path.join(run_dir, "output.json"), "w") as f:
        json.dump(output, f)
    print(json.dumps(output))


def windows(run_dir):
    """Capture every window that can be on the frozen output (its active
    workspace's) and find where each one is on it.

    Done once, on the first click that needs it, so later clicks only look
    the window up. Not sooner: each capture is a niri screenshot, with its
    notification and its clipboard history entry.
    """
    output = load_json(os.path.join(run_dir, "output.json"))
    active = {w["id"] for w in niri_json("workspaces") if w["output"] == output["name"] and w["is_active"]}
    found = [w for w in niri_json("windows") if w.get("workspace_id") in active]
    saved = save_clipboard()
    try:
        for window in found:
            window.update(kind="window", output=output, png=None, rect=None, share=0.0)
            path = os.path.join(run_dir, f"window-{window['id']}.png")
            try:
                capture_window(window["id"], path)
                window["png"] = path
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass
    finally:
        restore_clipboard(saved)

    captured = [w for w in found if w["png"]]
    screen_png = os.path.join(run_dir, "screen.png")
    if captured:
        with multiprocessing.get_context("fork").Pool(len(captured)) as pool:
            matches = pool.starmap(locate_window, [(screen_png, w["png"]) for w in captured])
        scale = Image.open(screen_png).width / output["width"]
        for window, ((ox, oy), share) in zip(captured, matches):
            place_window(window, ox, oy, share, scale)

    # Tiled windows never overlap: of two that seem to, the weaker match is a
    # window that is not on screen passing for the one that is.
    tiled = []
    for window in sorted(found, key=lambda w: w["share"], reverse=True):
        if window["rect"] and not window.get("is_floating"):
            if any(overlap(window["rect"], other["rect"]) for other in tiled):
                window["rect"] = None
            else:
                tiled.append(window)

    with open(os.path.join(run_dir, "windows.json"), "w") as f:
        json.dump(found, f)
    print(json.dumps({w["id"]: w["rect"] for w in found}))


def place_window(window, ox, oy, share, scale):
    """Keep where the window is, if its capture matched. The capture can be
    larger than the window: it holds the shadows a client draws around itself,
    which the window's own coordinates (and AT-SPI's) leave out."""
    window["share"] = share
    if share < MIN_MATCH_SHARE:
        return
    width, height = window["layout"]["window_size"]
    captured = Image.open(window["png"]).size
    margin_x = max(captured[0] / scale - width, 0) / 2
    margin_y = max(captured[1] / scale - height, 0) / 2
    window["rect"] = [ox / scale + margin_x, oy / scale + margin_y, width, height]


def overlap(a, b):
    """Whether two rects share more than a sliver."""
    width = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    height = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return width > 8 and height > 8


def window_at(run_dir, x, y):
    """The window under output-local point (x, y), or None. Floating windows
    are above the tiled ones."""
    under = [
        w for w in load_json(os.path.join(run_dir, "windows.json"), [])
        if w.get("rect") and w["rect"][0] <= x < w["rect"][0] + w["rect"][2]
        and w["rect"][1] <= y < w["rect"][1] + w["rect"][3]
    ]
    return max(under, key=lambda w: (bool(w.get("is_floating")), w["share"]), default=None)


def locate(run_dir, x, y):
    """Quickshell surfaces sit above every window, so they are asked first."""
    output = load_json(os.path.join(run_dir, "output.json"))
    result = locate_in_quickshell(output, x, y)
    if result["element"] is None:
        result = locate_in_window(run_dir, output, x, y)
    with open(os.path.join(run_dir, "located.json"), "w") as f:
        json.dump(result, f)
    print(json.dumps(result))


def locate_in_window(run_dir, output, x, y):
    result = {
        "point": [x, y], "window": {"kind": "none", "output": output}, "window_png": None,
        "origin": None, "window_rect": None, "element": None, "note": None,
    }
    window = window_at(run_dir, x, y)
    if window is None:
        result["note"] = "no window found under the click"
        return result

    scale = Image.open(os.path.join(run_dir, "screen.png")).width / output["width"]
    wx, wy, width, height = window["rect"]
    result["window"], result["window_png"] = window, window["png"]
    result["origin"], result["window_rect"] = [wx, wy], window["rect"]
    try:
        element, note = element_at(window, (x - wx, y - wy), scale)
    except Exception as error:
        element, note = None, f"accessibility lookup failed: {error}"
    if element is not None:
        ex, ey, ew, eh = element["rect_in_window"]
        # Clip to the window: some toolkits report whole scrolled documents.
        left, top = max(wx + ex, wx), max(wy + ey, wy)
        right = min(wx + ex + ew, wx + width)
        bottom = min(wy + ey + eh, wy + height)
        if right > left and bottom > top:
            element["rect"] = [left, top, right - left, bottom - top]
        else:
            note, element = "the element reported a position outside the window", None
    result["element"], result["note"] = element, note
    return result


# --- Quickshell ---------------------------------------------------------------
#
# Quickshell windows are not in the AT-SPI tree, so shells that include
# PickInspector.qml answer over `qs ipc` instead.


def quickshell_instances():
    try:
        listed = subprocess.run(["qs", "list", "--all", "--json"], capture_output=True, text=True, timeout=5)
        instances = json.loads(listed.stdout or "[]")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []
    # Not this overlay's own instance.
    return [i for i in instances if i.get("pid") != os.getppid()]


def locate_in_quickshell(output, x, y):
    result = {
        "point": [x, y], "window": {"kind": "none", "output": output}, "window_png": None,
        "origin": None, "window_rect": None, "element": None, "note": None,
    }
    for instance in quickshell_instances():
        try:
            answer = subprocess.run(
                ["qs", "ipc", "--pid", str(instance["pid"]), "call", "pickToBb", "inspect", output["name"], str(x), str(y)],
                capture_output=True, text=True, timeout=5,
            )
            found = json.loads(answer.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            # No PickInspector in that shell, or it is busy.
            continue
        if not isinstance(found, dict) or not found.get("hit"):
            continue
        config = found.get("config") or os.path.dirname(instance.get("config_path", ""))
        raw = found["element"]
        types = [p["type"] for p in found.get("path", [])] + [raw["type"]]
        files = [t + ".qml" for t in dict.fromkeys(types) if os.path.exists(os.path.join(config, t + ".qml"))]
        files.append("shell.qml")
        if raw["type"] == "ProxyWindowContentItem":
            # Empty space: the window's own content item.
            raw["type"] = found["surface"]["type"]
        result["element"] = {
            "source": "quickshell",
            "role": raw["type"],
            "name": raw.get("text") or raw.get("objectName") or "",
            "text": raw.get("subtreeText") or "",
            "rect": raw["rect"],
            "path": [{"role": p["type"], "name": p.get("text") or p.get("objectName") or ""} for p in found.get("path", [])],
            "quickshell": {
                "config": config,
                "pid": instance["pid"],
                "surface": found["surface"],
                "clickable": found.get("clickable", []),
                "qml_files": files,
            },
        }
        result["origin"] = found["surface"]["rect"][:2]
        result["window_rect"] = found["surface"]["rect"]
        return result
    result["note"] = "no inspectable Quickshell element under the click"
    return result


def selection_rect(located, output):
    element = located.get("element")
    if element and element.get("rect"):
        return element["rect"]
    x, y = located["point"]
    w, h = FALLBACK_BOX
    left = min(max(x - w / 2, 0), max(output["width"] - w, 0))
    top = min(max(y - h / 2, 0), max(output["height"] - h, 0))
    return [left, top, w, h]


def crop_element(run_dir, located, output):
    """The selection outlined on the frozen output, with some surroundings."""
    screen = Image.open(os.path.join(run_dir, "screen.png")).convert("RGB")
    scale = screen.width / output["width"]
    x, y, w, h = selection_rect(located, output)
    pad = CROP_PADDING
    box = (
        max(round((x - pad) * scale), 0),
        max(round((y - pad) * scale), 0),
        min(round((x + w + pad) * scale), screen.width),
        min(round((y + h + pad) * scale), screen.height),
    )
    crop = screen.crop(box)
    draw = ImageDraw.Draw(crop)
    draw.rectangle(
        (round(x * scale) - box[0], round(y * scale) - box[1],
         round((x + w) * scale) - box[0], round((y + h) * scale) - box[1]),
        outline=(237, 51, 59), width=max(2, round(2 * scale)),
    )
    path = os.path.join(run_dir, "element.png")
    crop.save(path)
    return path


def fence(text):
    ticks = 3
    while "`" * ticks in text:
        ticks += 1
    return "`" * ticks


def compose_prompt(prompt, window, located, images):
    lines = [prompt.strip(), "", "---", "", "## Selected UI element", ""]
    lines.append(
        "Before writing the request above, the user clicked this element on their "
        "screen (Linux, niri Wayland compositor). Attached: "
        + ", ".join(f"`{name}` ({what})" for name, what in images)
        + "."
    )
    lines.append("")
    element = located.get("element")
    if element is not None and element.get("source") == "quickshell":
        return "\n".join(lines + quickshell_lines(element, window)) + "\n"
    if window.get("kind") == "window":
        lines.append(f"- **App:** `{window.get('app_id')}` (pid {window.get('pid')})")
        lines.append(f"- **Window title:** {window.get('title')}")
    if element is None:
        lines.append(
            f"- **Element:** no accessibility information ({located.get('note')}); "
            "rely on the screenshot. The click was at "
            f"{round(located['point'][0])},{round(located['point'][1])} on the screen."
        )
        return "\n".join(lines) + "\n"

    label = element["role"] + (f' "{element["name"]}"' if element.get("name") else "")
    lines.append(f"- **Element:** {label}")
    if element.get("description"):
        lines.append(f"- **Description:** {element['description']}")
    if element.get("document_url"):
        lines.append(f"- **Page URL:** {element['document_url']}")
    if element.get("path"):
        lines.append("- **Path:** " + path_line(element, label))
    if element.get("attributes"):
        attributes = ", ".join(f"{k}={v}" for k, v in sorted(element["attributes"].items()))
        lines.append(f"- **Attributes:** {attributes}")
    if element.get("states"):
        lines.append(f"- **States:** {', '.join(element['states'])}")
    ex, ey, ew, eh = element["rect_in_window"]
    lines.append(f"- **Bounds in window:** x={ex} y={ey} {ew}×{eh} (logical px)")
    if element.get("app"):
        lines.append(f"- **Accessibility app name:** {element['app']} ({element.get('toolkit', '')})")
    lines += text_lines(element)
    return "\n".join(lines) + "\n"


def path_line(element, label):
    crumbs = []
    for crumb in (p["role"] + (f' "{p["name"]}"' if p["name"] else "") for p in element["path"]):
        # Collapse runs of the same unnamed wrapper: "section ×7".
        if crumbs and crumbs[-1][0] == crumb and '"' not in crumb:
            crumbs[-1][1] += 1
        else:
            crumbs.append([crumb, 1])
    crumbs = [crumb if count == 1 else f"{crumb} ×{count}" for crumb, count in crumbs]
    return " › ".join(crumbs + [label])


def text_lines(element):
    text = (element.get("text") or "").strip()
    if not text or text == element.get("name"):
        return []
    marker = fence(text)
    suffix = " (truncated)" if element.get("text_truncated") else ""
    return ["", f"Element text{suffix}:", "", marker, text, marker]


def quickshell_lines(element, window):
    shell = element["quickshell"]
    surface = shell["surface"]
    sx, sy, sw, sh = (round(v) for v in surface["rect"])
    label = element["role"] + (f' "{element["name"]}"' if element.get("name") else "")
    lines = [
        f"- **Quickshell config:** `{shell['config']}` (pid {shell['pid']}). The element is QML from "
        "this shell, not an app window.",
        f"- **Surface:** {surface['type']} at x={sx} y={sy} {sw}×{sh} on output {window['output']['name']}",
        f"- **Element:** {label} (QML type)",
    ]
    if element.get("path"):
        lines.append("- **Path:** " + path_line(element, label))
    if shell.get("clickable"):
        owners = ", ".join(f"`{owner}`" for owner in dict.fromkeys(shell["clickable"]))
        lines.append(f"- **Handles clicks:** a MouseArea in {owners}")
    lines.append("- **QML files to start from:** " + ", ".join(f"`{f}`" for f in shell["qml_files"]))
    ex, ey, ew, eh = (round(v) for v in element["rect"])
    lines.append(f"- **Bounds on screen:** x={ex} y={ey} {ew}×{eh} (logical px)")
    return lines + text_lines(element)


def bb_binary():
    for candidate in (
        os.environ.get("BB_CLI"),
        os.path.expanduser("~/.npm-global/bin/bb"),
        "/usr/local/bin/bb",
        "/usr/bin/bb",
    ):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return "bb"


def send(run_dir, prompt):
    output = load_json(os.path.join(run_dir, "output.json"))
    located = load_json(os.path.join(run_dir, "located.json")) or {
        "point": [0, 0], "element": None, "note": "the element was never located",
    }
    window = located.get("window") or {"kind": "none", "output": output}

    images = [("element.png", "the selection outlined in red, with its surroundings")]
    paths = [crop_element(run_dir, located, output)]
    if located.get("window_png") and os.path.exists(located["window_png"]):
        images.append((os.path.basename(located["window_png"]), "the whole window"))
        paths.append(located["window_png"])

    prompt_path = os.path.join(run_dir, "prompt.md")
    with open(prompt_path, "w") as f:
        f.write(compose_prompt(prompt, window, located, images))
    spawn_thread(prompt_path, paths)


def spawn_thread(prompt_path, paths):
    """Start the bb thread, open it, and print the answer the overlay reads."""
    bb = bb_binary()
    command = [
        bb, "thread", "spawn",
        "--project", BB_PROJECT,
        "--environment-provider", BB_ENVIRONMENT_PROVIDER,
        "--provider", BB_PROVIDER,
        "--model", BB_MODEL,
        "--reasoning-level", BB_REASONING,
        "--prompt-file", prompt_path,
        "--json",
    ]
    for path in paths:
        command += ["--image", path]
    spawned = subprocess.run(command, capture_output=True, text=True, timeout=60)
    try:
        answer = json.loads(spawned.stdout)
    except ValueError:
        answer = {}
    thread_id = answer.get("id") or (answer.get("thread") or {}).get("id")
    if spawned.returncode != 0 or not thread_id:
        error = (answer.get("error") or {}).get("message") or spawned.stderr.strip() or spawned.stdout.strip()
        print(json.dumps({"ok": False, "error": error or f"bb exited with {spawned.returncode}"}))
        sys.exit(1)
    subprocess.run([bb, "thread", "open", thread_id], capture_output=True, timeout=15)
    print(json.dumps({"ok": True, "thread": thread_id}))


# --- screenshots ---------------------------------------------------------------
#
# A screenshot has no element: the user frames a region of the frozen output,
# clicks a window, or takes the whole output, and that image is the context.


def shot_window_at(run_dir, x, y):
    """The window to screenshot, kept in RUN_DIR/shot.json. Its image is niri's
    capture: the whole window, parts scrolled off screen included."""
    window = window_at(run_dir, x, y)
    if window is not None:
        with open(os.path.join(run_dir, "shot.json"), "w") as f:
            json.dump(window, f)
    print(json.dumps({"window": window}))


SHOT_SUBJECTS = {
    "region": "a region of their screen",
    "window": "one window",
    "screen": "their whole screen",
}


def send_shot(run_dir, mode, prompt, rect):
    output = load_json(os.path.join(run_dir, "output.json"))
    window = load_json(os.path.join(run_dir, "shot.json")) if mode == "window" else None
    path = os.path.join(run_dir, "screenshot.png")
    if mode == "window":
        shutil.copyfile(window["png"], path)
    elif mode == "screen":
        shutil.copyfile(os.path.join(run_dir, "screen.png"), path)
    else:
        screen = Image.open(os.path.join(run_dir, "screen.png"))
        scale = screen.width / output["width"]
        x, y, w, h = rect
        screen.crop((
            max(round(x * scale), 0),
            max(round(y * scale), 0),
            min(round((x + w) * scale), screen.width),
            min(round((y + h) * scale), screen.height),
        )).save(path)

    prompt_path = os.path.join(run_dir, "prompt.md")
    with open(prompt_path, "w") as f:
        f.write(compose_shot_prompt(prompt, mode, output, window, rect))
    spawn_thread(prompt_path, [path])


def compose_shot_prompt(prompt, mode, output, window, rect):
    lines = [prompt.strip(), "", "---", "", "## Screenshot", ""]
    lines.append(
        f"Before writing the request above, the user took a screenshot of {SHOT_SUBJECTS[mode]} "
        "(Linux, niri Wayland compositor). Attached: `screenshot.png`."
    )
    lines.append("")
    if mode == "window":
        width, height = window["layout"]["window_size"]
        lines.append(f"- **App:** `{window.get('app_id')}` (pid {window.get('pid')})")
        lines.append(f"- **Window title:** {window.get('title')}")
        lines.append(
            f"- **Window size:** {width}×{height} (logical px); the capture is the whole window, "
            "parts scrolled off screen included"
        )
    elif mode == "region":
        x, y, w, h = (round(v) for v in rect)
        lines.append(f"- **Region:** x={x} y={y} {w}×{h} on output {output['name']} (logical px)")
    else:
        lines.append(f"- **Output:** {output['name']}, {output['width']}×{output['height']} (logical px)")
    return "\n".join(lines) + "\n"


def main():
    command, run_dir = sys.argv[1], sys.argv[2]
    # A hung app can block AT-SPI calls; never leave the overlay waiting forever.
    signal.alarm(45)
    if command == "start":
        start(run_dir)
    elif command == "windows":
        windows(run_dir)
    elif command == "locate":
        locate(run_dir, float(sys.argv[3]), float(sys.argv[4]))
    elif command == "window-at":
        shot_window_at(run_dir, float(sys.argv[3]), float(sys.argv[4]))
    elif command == "send":
        send(run_dir, sys.argv[3])
    elif command == "send-shot":
        send_shot(run_dir, sys.argv[3], sys.argv[4], [float(v) for v in sys.argv[5:9]])
    else:
        sys.exit(f"unknown command {command}")


if __name__ == "__main__":
    main()
