---
name: ship
description: Ship the current branch's work.
disable-model-invocation: true
---

1. commit the change.
2. FF merge.
3. push if a remote exists.
   If there is no remote, skip this step and say so.
4. Reload from main. `main` is checked out in this repo's main checkout, not in this worktree. Find it with `git worktree list` (the primary clone, not a worktree entry). In that checkout:
   - `git pull --ff-only`
   - `chezmoi update`
   - The bar reloads a `.qml` change by itself, not a `.mjs` one. If a `.mjs` file under `quickshell/` changed, tell the user which instance needs a restart. Don't restart it.
