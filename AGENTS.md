# dotfiles

The chezmoi source for the user's home. The chauvenity-os image applies it
with `chezmoi update --force` once a day. This repo is public, so keep secrets,
tokens and work data out of it.

## Layout

- `dot_config/…` are ordinary chezmoi entries.
- `quickshell/` and `niri/` are the live configs. `~/.config/quickshell` and
  `~/.config/niri` are symlinks to them in the chezmoi checkout
  (`~/.local/share/chezmoi`), created by `dot_config/symlink_*.tmpl`. The
  running bar and niri reload when a file there changes.
- A worktree's `quickshell/` and `niri/` are not live. Edit them, never the
  files under `~/.config`, which are the user's main checkout.

## Testing

- Unit tests: `node --test quickshell/<name>/tests/`.
- niri config: `niri validate -c niri/config.kdl`.
- Quickshell reloads on a `.qml` edit, not on a `.mjs` edit. After changing a
  `.mjs` file, restart the instance.

The user works in a live niri session on this machine. Never start niri, qs or
any GUI app on their `WAYLAND_DISPLAY`, because the window takes their focus.
Never `pkill -f` a pattern such as `qs -c chauvenity`, which also matches their
real bar. To look at a change, use `niri-sandbox`. It runs niri inside
`mutter --headless`, so nothing appears on screen:

```bash
export NIRI_SANDBOX=$BB_THREAD_ID                     # one sandbox per thread
niri-sandbox up -c "$PWD/niri/config.kdl"             # this worktree's niri config
niri-sandbox spawn qs -p "$PWD/quickshell/chauvenity" # this worktree's bar
niri-sandbox run qs -p "$PWD/quickshell/chauvenity" ipc call leader toggle
niri-sandbox shot                                     # prints a PNG path to read
niri-sandbox down
```

The sandbox is not sealed. It has its own `XDG_RUNTIME_DIR` but shares
`$HOME` and the session bus. So `xdg-open` there opens in the user's real
browser, and a clipboard instance that finds `cliphist` on its PATH writes to
the real history (`~/.cache/cliphist/db`). Before you spawn
`quickshell/clipboard`, put a stub `xdg-open` first on its PATH and set
`CLIPHIST_DB_PATH` to a scratch file.

`run` also takes `niri msg`, `wtype` and `wl-copy`. `qs log -p DIR` (through
`run`) shows a sandboxed instance's log. If `niri-sandbox` is not on PATH, use
`~/src/ekans/chauvenity-os/files/system/usr/bin/niri-sandbox`.
