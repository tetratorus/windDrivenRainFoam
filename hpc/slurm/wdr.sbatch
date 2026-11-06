#!/bin/bash
# Run a cubicBuilding-style windDrivenRainFoam case from the sealed Apptainer image.
# Usage: sbatch [--nodes=N --ntasks-per-node=M] wdr.sbatch SIF CASE_DIR [RESULT_URI]
#   SIF        image on the shared filesystem (verified against SIF.sha256 if present)
#   CASE_DIR   case on the shared filesystem; holds *.simpleFoam and *.windDrivenRainFoam
#   RESULT_URI optional s3://bucket/prefix; results are uploaded there when the job succeeds
# MPI model: Slurm launches one container per rank (srun --mpi=pmix); OpenMPI inside the image
# wires up through PMIx, so no mpirun and no host MPI install is needed.
#SBATCH --job-name=wdr
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --output=%x-%j.out
set -euo pipefail
SIF=${1:?SIF}; CASE=$(realpath "${2:?CASE_DIR}"); RESULT_URI=${3:-}
NP=${SLURM_NTASKS:?run under sbatch}
cd "$CASE"
[ ! -f "$SIF.sha256" ] || (cd "$(dirname "$SIF")" && sha256sum -c --quiet "$(basename "$SIF").sha256")
# Workarounds for virtualised / containerised nodes (harmless on bare metal):
#  - hwloc's x86 CPUID backend divides by zero on some AWS vCPU topologies
#  - no cross-memory-attach between container instances
export HWLOC_COMPONENTS=-x86 OMPI_MCA_btl_vader_single_copy_mechanism=none OMPI_MCA_btl=self,vader,tcp
export APPTAINERENV_HWLOC_COMPONENTS=$HWLOC_COMPONENTS
# no --cleanenv: ranks need the SLURM_*/PMIX_* variables; the image's env file sets PATH/LD_LIBRARY_PATH itself
ax() { local dir=$1; shift; apptainer exec --bind "$CASE" --pwd "$dir" "$SIF" "$@"; }
wind=$(ls -d "$CASE"/*.simpleFoam); rain=$(ls -d "$CASE"/*.windDrivenRainFoam)
step() { echo "[$(date -u +%FT%TZ)] $*"; }
solve() {  # DIR APP : parallel solve over all allocated ranks/nodes
  local dir=$1 app=$2
  step "$app on $NP ranks across $SLURM_JOB_NUM_NODES nodes ($SLURM_JOB_NODELIST)"
  srun --mpi=pmix bash -c "$(declare -f ax); SIF='$SIF' CASE='$CASE' ax '$dir' $app -parallel" > "$dir/log.$app" 2>&1 \
    || { tail -40 "$dir/log.$app"; exit 1; }
  ax "$CASE" wdr-case check-log "$dir/log.$app"
}
serial() { srun -N1 -n1 --mpi=none bash -c "$(declare -f ax); SIF='$SIF' CASE='$CASE' ax '$CASE' wdr-case $*"; }
step "image $(apptainer inspect -l "$SIF" | grep -E 'solver.revision' || true)"
serial version
serial wind-pre "$CASE" "$NP"
solve "$wind" simpleFoam
serial wind-post "$CASE"
serial rain-pre "$CASE" "$NP"
solve "$rain" windDrivenRainFoam
serial rain-post "$CASE"
rm -rf "$wind"/processor* "$rain"/processor*
echo "SUCCESS" > "$CASE/STATUS"
if [ -n "$RESULT_URI" ]; then
  step "uploading results to $RESULT_URI"
  tar -C "$(dirname "$CASE")" -czf "$CASE.results.tar.gz" "$(basename "$CASE")"
  "${WDR_CLI:-/opt/wdr-operator/wdr}" put "$CASE.results.tar.gz" "$RESULT_URI/results.tar.gz"
fi
step done
