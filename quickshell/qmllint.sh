#!/usr/bin/env bash
# Runs chauvenity-os's QML check (.github/workflows/niri-session-config-check.yml)
# on this repo, in the same Fedora container with the same qmllint, so a lint
# failure shows up here before the greeter is synced into the image.
#
#   quickshell/qmllint.sh [DIR...]   default: the lock and the greeter, the
#                                    directories chauvenity-os ships from here
#
# The image is built once and cached. After the COPR updates quickshell, run
# `podman rmi localhost/dotfiles-qmllint` to lint against the new one.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
image=localhost/dotfiles-qmllint

build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT
podman build -t "$image" - >"$build_log" 2>&1 <<'EOF' || { cat "$build_log" >&2; exit 1; }
FROM registry.fedoraproject.org/fedora:44@sha256:278ccc1c8af3d618b64accbba691bb14f82d371b2e13c86fa2ac7a447d1e03bb
RUN dnf install -y dnf5-plugins \
 && dnf copr enable -y errornointernet/quickshell \
 && dnf install -y --setopt=install_weak_deps=False niri quickshell qt6-qtdeclarative-devel \
 && dnf clean all
EOF

if [ $# -eq 0 ]; then
    set -- "$repo"/quickshell/chauvenity-lock "$repo"/quickshell/chauvenity-greeter
fi
dirs=()
for d in "$@"; do
    dirs+=("quickshell/$(basename "$(realpath "$d")")")
done

podman run --rm -v "$repo:/src:ro,z" -w /src "$image" bash -c '
status=0
for dir in "$@"; do
    for f in "$dir"/*.qml; do
        [ -e "$f" ] || continue
        out=$(cd "$dir" && qmllint-qt6 -I /usr/lib64/qt6/qml -I . "${f##*/}" 2>&1 \
              | grep -E "^(Error|Warning)" \
              | grep -v "PanelWindow is not creatable") || true
        if [ -n "$out" ]; then
            echo "FAIL $f"
            echo "$out" | sed "s/^/     /"
            status=1
        else
            echo "ok   $f"
        fi
    done
done
exit $status
' lint "${dirs[@]}"
