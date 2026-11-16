#!/usr/bin/env bash
# Draws the lock screen's sprites (../LockScene.qml, ../Firefly.qml) into this
# directory. Each is a 64 px soft round glow: opaque in the middle, fading
# to nothing at the rim.
#
#   glow.png         white, for every particle, tinted there by
#                    ImageParticle.color, and for the fireflies' white-hot core
#   halo-ember.png   a firefly's halo, warm
#   halo-green.png   the same on success
#   halo-ash.png     the same, cooled, as a firefly leaves
#
# An Image cannot be tinted without an offscreen pass per item, so each halo
# colour is a file of its own.
#
#   art/sprites.sh      rerun after changing a colour; needs ImageMagick 7
set -euo pipefail
cd "$(dirname "$0")"

glow() {
    magick -size 64x64 xc:"$1" -alpha set -channel A \
        -fx 'max(0, 1 - hypot(i - 31.5, j - 31.5) / 32) ^ 2' +channel \
        -define png:exclude-chunks=date,time -strip "$2"
}

glow white glow.png
glow '#ffa348' halo-ember.png
glow '#57e389' halo-green.png
glow '#8a8890' halo-ash.png
