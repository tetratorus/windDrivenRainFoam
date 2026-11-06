#!/usr/bin/env bash
# Upstream reference: unmodified windDrivenRainFoam (tag of-com_v2106) + cubicBuilding tutorial
# (tag of-com_v2106) on the upstream-supported OpenFOAM v2106 (official OpenCFD image).
# Same steps as the tutorial Allrun; parallel block enabled (NP ranks, simple decomposition).
# HWLOC_COMPONENTS=-x86: hwloc in the OpenMPI of this image divides by zero on some virtual CPUs (seen on AWS).
set -euo pipefail
OUT=${1:?usage: $0 OUTDIR [NP]}
NP=${2:-4}
IMAGE=opencfd/openfoam-default@sha256:56be58e72f8bd89a6db7ca37ac4124f64a66db5909b79034176cbc9a0bb1f819
SOLVER_REPO=https://github.com/OpenFOAM-BuildingPhysics/windDrivenRainFoam
TUT_REPO=https://github.com/OpenFOAM-BuildingPhysics/windDrivenRainFoam-tutorials
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
[ -d "$OUT/solver" ] || git clone -q --branch of-com_v2106 --depth 1 "$SOLVER_REPO" "$OUT/solver"
[ -d "$OUT/tutorials" ] || git clone -q --branch of-com_v2106 --depth 1 "$TUT_REPO" "$OUT/tutorials"
docker run --rm -e HWLOC_COMPONENTS=-x86 --user "$(id -u):$(id -g)" -e HOME=/tmp -e NP="$NP" -v "$OUT":/work -w /work \
  --entrypoint bash "$IMAGE" -c '
set -euo pipefail
set +eu; . /usr/lib/openfoam/openfoam2106/etc/bashrc; set -eu
export FOAM_USER_APPBIN=/work/bin FOAM_USER_LIBBIN=/work/lib; mkdir -p bin lib
(cd solver && wmake) > log.wmake 2>&1
export PATH=/work/bin:$PATH
setNP() { foamDictionary -entry numberOfSubdomains -set $NP system/decomposeParDict >/dev/null
          foamDictionary -entry method -set simple system/decomposeParDict >/dev/null
          foamDictionary -entry simpleCoeffs/n -set "(2 1 $((NP/2)))" system/decomposeParDict >/dev/null; }
cd tutorials/cubicBuilding/cubicBuilding.simpleFoam
blockMesh > log.blockMesh 2>&1
setNP; decomposePar -force > log.decomposePar 2>&1
mpirun -np $NP simpleFoam -parallel > log.simpleFoam 2>&1
reconstructPar -latestTime > log.reconstructPar 2>&1
cd ../cubicBuilding.windDrivenRainFoam
cp -r ../cubicBuilding.simpleFoam/constant/polyMesh constant/
t=$(foamListTimes -latestTime -case ../cubicBuilding.simpleFoam)
for f in U k epsilon nut; do cp ../cubicBuilding.simpleFoam/$t/$f.gz 0/$f.gz; done
changeDictionary > log.changeDictionary 2>&1
setNP; decomposePar -force > log.decomposePar 2>&1
mpirun -np $NP windDrivenRainFoam -parallel > log.windDrivenRainFoam 2>&1
reconstructPar -latestTime > log.reconstructPar 2>&1
echo REFERENCE_DONE
'
