#!/usr/bin/env bash
# Build the sealed image: stage 1 (pinned OpenFOAM v2606 toolchain) then stage 2 (solver compiled inside).
# Outputs build/windDrivenRainFoam-<version>.sif + .sha256, build/sbom.spdx.json, build/manifest.json
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-v2606-$(git rev-parse --short HEAD)}
TUT_REPO=${TUT_REPO:-https://github.com/OpenFOAM-BuildingPhysics/windDrivenRainFoam-tutorials}
TUT_REF=${TUT_REF:-of-com_v2106}
mkdir -p build/ctx
# root build (or set APPTAINER_BUILD="apptainer build --fakeroot" where subuid mapping is configured)
APPTAINER_BUILD=${APPTAINER_BUILD:-sudo apptainer build}
deps/fetch-sources.sh
[ -f build/openfoam-v2606.sif ] || $APPTAINER_BUILD build/openfoam-v2606.sif apptainer/openfoam-v2606.def
# solver: git-tracked sources only (no hpc/, no build products)
rm -rf build/ctx/solver && mkdir -p build/ctx/solver
(cd .. && git ls-files -- ':!hpc' ':!docs' ':!*.md' ':!.gitignore' | tar -cf - -T -) | tar -xf - -C build/ctx/solver
[ -d build/ctx/tutorials ] || git clone -q --depth 1 --branch "$TUT_REF" "$TUT_REPO" build/ctx/tutorials
SOLVER_REV=$(git rev-parse HEAD)$(git diff --quiet HEAD -- .. ':!hpc' || echo -dirty)
TUTORIALS_REV=$(git -C build/ctx/tutorials rev-parse HEAD)
OUT=build/windDrivenRainFoam-$VERSION.sif
$APPTAINER_BUILD --force \
  --build-arg SOLVER_REV="$SOLVER_REV" --build-arg TUTORIALS_REV="$TUTORIALS_REV" \
  "$OUT" apptainer/windDrivenRainFoam.def
sudo chown "$(id -u):$(id -g)" "$OUT"
(cd build && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
deps/make-sbom.sh "$OUT" "$VERSION"
echo "built $OUT"
