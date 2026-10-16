# Where the helper reads its pad, keeps its database and listens, chosen by
# the environment and nothing else (no flags, so there is one way):
#
#     WALKPAD_PAD     "bluez" (default) or "replay:/path/to/script"
#     WALKPAD_DB      default $XDG_DATA_HOME/walkpad/walkpad.db
#     WALKPAD_SOCKET  default $XDG_RUNTIME_DIR/walkpad.sock
#     WALKPAD_IMPORT  the BB plugin's database to import into a new store;
#                     default ~/.bb/plugins/walkpad/data.db, "" for none
#
# An empty variable counts as unset, but for WALKPAD_IMPORT, where "" means
# no import.
#
# Inside niri-sandbox (NIRI_SANDBOX set, or XDG_RUNTIME_DIR under
# /run/user/UID/niri-sandbox/), which shares $HOME and the system bus with the
# real session, the helper refuses to start unless the pad is a replay and
# WALKPAD_DB and WALKPAD_IMPORT are given explicitly, the database not being
# the default one. A sandboxed bar can then never reach the real pad or write
# the real walks.

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

_SANDBOX_RUNTIME = re.compile(r"/run/user/[0-9]+/niri-sandbox(/|$)")


@dataclass(frozen=True)
class Bluez:
    pass


@dataclass(frozen=True)
class Replay:
    script: Path


@dataclass(frozen=True)
class Config:
    pad: Bluez | Replay
    db: Path
    socket: Path
    import_from: Path | None


def _get(env: Mapping[str, str], name: str) -> str:
    return env.get(name) or ""


def _data_home(env: Mapping[str, str]) -> Path | None:
    if data := _get(env, "XDG_DATA_HOME"):
        return Path(data)
    return Path(env["HOME"], ".local/share") if _get(env, "HOME") else None


def default_db(env: Mapping[str, str]) -> Path | None:
    data = _data_home(env)
    return data / "walkpad" / "walkpad.db" if data else None


def socket_path(env: Mapping[str, str]) -> Path | None:
    """WALKPAD_SOCKET, else $XDG_RUNTIME_DIR/walkpad.sock. WalkpadService.qml
    computes the same path from the same two variables."""
    if socket := _get(env, "WALKPAD_SOCKET"):
        return Path(socket)
    runtime = _get(env, "XDG_RUNTIME_DIR")
    return Path(runtime, "walkpad.sock") if runtime else None


def in_sandbox(env: Mapping[str, str]) -> bool:
    return bool(_get(env, "NIRI_SANDBOX")) or bool(_SANDBOX_RUNTIME.match(_get(env, "XDG_RUNTIME_DIR")))


def resolve(env: Mapping[str, str]) -> Config | str:
    """The configuration, or why the helper must not start."""
    pad_spec = _get(env, "WALKPAD_PAD") or "bluez"
    if pad_spec == "bluez":
        pad: Bluez | Replay = Bluez()
    elif pad_spec.startswith("replay:"):
        script = Path(pad_spec.removeprefix("replay:"))
        if not script.is_file():
            return f"WALKPAD_PAD: no replay script at {script}"
        pad = Replay(script)
    else:
        return f'WALKPAD_PAD is "bluez" or "replay:PATH", not "{pad_spec}"'

    db = Path(env["WALKPAD_DB"]) if _get(env, "WALKPAD_DB") else default_db(env)
    if db is None:
        return "set HOME, XDG_DATA_HOME or WALKPAD_DB"
    socket = socket_path(env)
    if socket is None:
        return "set XDG_RUNTIME_DIR or WALKPAD_SOCKET"
    if "WALKPAD_IMPORT" not in env:
        import_from = Path(env["HOME"], ".bb/plugins/walkpad/data.db") if _get(env, "HOME") else None
    else:
        import_from = Path(env["WALKPAD_IMPORT"]) if env["WALKPAD_IMPORT"] else None

    if in_sandbox(env):
        if not isinstance(pad, Replay):
            return "in niri-sandbox the pad must be WALKPAD_PAD=replay:…, not the real one"
        # The sandbox may set XDG_DATA_HOME apart from the session's, so the
        # database under $HOME counts as the real one too.
        real = {path.resolve() for path in (default_db(env), default_db({"HOME": _get(env, "HOME")})) if path}
        if not _get(env, "WALKPAD_DB") or db.resolve() in real:
            return "in niri-sandbox set WALKPAD_DB to a scratch file, not the real database"
        if "WALKPAD_IMPORT" not in env:
            return 'in niri-sandbox set WALKPAD_IMPORT ("" for none)'
    return Config(pad, db, socket, import_from)
