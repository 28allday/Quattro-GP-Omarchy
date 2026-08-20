#!/bin/bash
# Bake the fragment shaders into the .qsb files Qt Quick actually loads.
#
# The baked files are committed. A plugin is installed by `omarchy plugin add`,
# which is a git clone and nothing else -- there is no build step on the user's
# machine, so anything the shell needs at runtime has to already be in the repo.
#
# Needs qt6-shadertools. qsb is not on PATH on Arch.
set -euo pipefail

QSB=${QSB:-/usr/lib/qt6/bin/qsb}
cd "$(dirname "$0")"

[ -x "$QSB" ] || { echo "qsb not found at $QSB -- install qt6-shadertools" >&2; exit 1; }

for f in road tint; do
    "$QSB" --qt6 -o "$f.frag.qsb" "$f.frag"
    echo "baked $f.frag.qsb"
done
