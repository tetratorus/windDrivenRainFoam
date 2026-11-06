#!/usr/bin/env bash
# Fetch pinned upstream source archives into deps/sources/ and verify sha256.
# Point OPENFOAM_MIRROR at an approved internal mirror to avoid direct internet egress.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p sources
OPENFOAM_MIRROR=${OPENFOAM_MIRROR:-https://dl.openfoam.com/source}
f=sources/OpenFOAM-v2606.tgz
[ -f "$f" ] || curl -fL --retry 5 -C - -o "$f" "$OPENFOAM_MIRROR/v2606/OpenFOAM-v2606.tgz"
echo "2a1310e3ed192cc4c521e1d22dcc176f57bec61160c878dc4348f21d6672294d  $f" | sha256sum -c -
