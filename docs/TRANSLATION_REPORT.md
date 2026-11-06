# windDrivenRainFoam: translation to OpenFOAM ESI v2606, packaging and HPC execution

## Outcome

- **Port is exact.** Given the same wind field, the v2606 build of `windDrivenRainFoam` reproduces the upstream v2106 rain results **bit for bit** across 314 field and patch comparisons. Only the file headers differ.
- **End-to-end it works on HPC.** The sealed image ran cubicBuilding through Slurm on 4 MPI ranks over 2 nodes (c1 and c2), and was submitted, monitored and fetched with `wdr`. Results went in and out through S3.
- **End-to-end numbers match closely.** The full v2606 pipeline (wind and rain) is close to the v2106 reference, but not identical:
  - wind fields: within 0.5% relative L2
  - rain fields: within 0.03%
  - catch ratio on the building: within 0.15%
  - rain volume fraction on the building wall: up to 3.8%
- **The gap comes from OpenFOAM itself.** It's in the wind flow, which is computed by OpenFOAM's own `simpleFoam` and wall functions. Those changed between v2106 and v2606. The ported code doesn't touch them.
- **An engineer must set the tolerance.** At a strict 1e-3 relative L2 tolerance, 24 of 340 end-to-end comparisons fail. All 24 are wind turbulence fields or rain values on the building wall. An engineer must decide whether v2606's wind solution is acceptable for this use.

## What changed in the solver (T1)

The physics and numerics are unchanged. Upstream's last ESI release is `of-com_v2106`
(7a38455). The v2606 port changes **5 lines in one file** (`createFields.H`): dictionary reads move to the
v2606 API. The old calls are marked deprecated in v2606.

| upstream (v2106 API) | v2606 | why |
|---|---|---|
| `dict.lookupOrDefault<scalar>("temp", 285.85)` | `dict.getOrDefault<scalar>(...)` | `lookupOrDefault` is `FOAM_DEPRECATED_STRICT(2019-06, "getOrDefault()")` |
| `dict.lookupOrDefault<scalar>("scalingFactor", 1.0)` | `dict.getOrDefault<scalar>(...)` | same |
| `dict.lookupOrDefault("solveTD", false)` | `dict.getOrDefault<bool>(...)` | same |
| `List<scalar> Rh(dict.lookup("Rh"))` | `dict.get<List<scalar>>("Rh")` | constructing from the `lookup()` stream is the old pattern; `get<T>` also checks the entry is fully read |
| `List<scalar> phases(dict.lookup("phases"))` | `dict.get<List<scalar>>("phases")` | same |

Evidence: compiling the unmodified upstream `of-com_v2106` source against v2606 with `wmake -strict` gives exactly
3 deprecation warnings, at the three `lookupOrDefault` calls. The two `lookup()` changes are not forced by v2606.
They are the matching modern API, and they report a clear error if an entry is missing or malformed.

How we know nothing else is needed: the image build compiles the solver with `wmake -strict`
(v2606's `FOAM_COMPILE_STRICT`, which turns every deprecated API into a compiler warning) and fails if there is
**any** warning. The tutorial case dictionaries (`cubicBuilding`, tag `of-com_v2106`) run unmodified on v2606.

## Dependencies and image (T2, T3)

- `hpc/deps/lock.yaml` is the single list of pins:
  - base image by digest (ubuntu 24.04)
  - apt archive frozen at a snapshot date, plus exact `name=version` for each package (`hpc/deps/apt-packages.txt`)
  - OpenFOAM source by URL and sha256
  - solver and tutorial commits
- Two-stage Apptainer build (`hpc/build.sh`):
  1. OpenFOAM v2606 compiled from source with system OpenMPI, Scotch and FFTW. There is no ThirdParty tree, and optional libraries are off.
  2. The solver compiled inside the image, plus the bundled `cubicBuilding` case and the `wdr-case` workflow script.
- Outputs:
  - `windDrivenRainFoam-<version>.sif` + `.sha256`
  - `sbom.spdx.json` (SPDX 2.3, from syft over the image, plus the source-built OpenFOAM, solver and tutorial entries)
  - `manifest.json`
- Nothing is compiled on the cluster. The nodes only need Apptainer and Slurm.

## Validation (T4)

Reference: upstream `of-com_v2106` solver and tutorials on the pinned `opencfd/openfoam-default` v2106 image
(`hpc/reference/run_upstream_reference.sh`). It uses 4 ranks with simple decomposition `(2 1 2)`, the same
decomposition as every v2606 run, so the results can be compared one to one. Comparison tool: `hpc/validation/compare.py`. For each field it reports relative L2 and max absolute difference, over all cells and every patch, at the latest time.

**1. Port check: rain solver only, same input** (`results/port-check.md`).
- Setup: v2606 `windDrivenRainFoam` from the sealed image, run on the reference run's wind fields.
- Result: **PASS at 0.0 difference** in all 314 field/patch comparisons, covering:
  - rain velocity `U1..U17`
  - volume fraction `alpha1..alpha17`
  - catch ratios `scr*` and `gcr*`
- The numerical data in the output files is byte-identical. This isolates the port: the 5 changed lines and the v2606 libraries the solver links against give exactly the upstream answer.

**2. End to end: full pipeline on Slurm, 2 nodes** (`results/comparison.md`).
- Setup: v2606 `simpleFoam`, then the v2606 rain solver, submitted with `wdr submit`.

| | relative L2 vs v2106 |
|---|---|
| wind `U`, `phi`, `nut` (internal) | 3.4e-4, 7.0e-6, 6.0e-5 |
| wind `p`, `k`, `epsilon` (internal) | 1.3e-3, 2.2e-3, 5.1e-3 |
| rain `U1..17`, `alpha1..17` (internal, worst) | 3.1e-4 |
| specific catch ratio `scr*` on the cube (worst) | 1.5e-3 |
| rain `alpha*` on the cube wall (worst) | 3.8e-2 |

Why this is OpenFOAM and not the port:
- The `simpleFoam` residual histories agree to 3–4 significant figures, and both runs stop at exactly the same iteration (2856).
- The largest differences are in cells next to the walls. There, `k` differs by 1.0e-2 relative L2, compared with 1.8e-3 away from the walls. That pattern matches the ESI wall-function rework after v2106 (the `epsilonWallFunction` and `kqRWallFunction` patches in this case), along with compiler differences (gcc 9 to gcc 13).
- Test 1 shows the rain solver adds no difference of its own.
- The same tool comparing the reference with itself reports 0.0 everywhere.

## SLURM and MPI (T5)

- The same image runs on every rank. `srun --mpi=pmix` starts one container per rank, and the image's OpenMPI 4.1.6 connects to Slurm through PMIx. No host MPI and no `mpirun` are needed.
- `hpc/slurm/wdr.sbatch` runs the whole tutorial workflow. Serial steps use one task; the solves use every rank on every node.
- Failure detection: non-zero exit, `FOAM FATAL` in a log, or a solver log without `End`.

## Operator interface (T6)

`wdr submit | status | logs | fetch` and `wdr image push | list`. Cases come in from a local directory or S3, and results go back to S3.
See `docs/OPERATOR_GUIDE.md`.

## Issues found and how they were handled

| issue | where | fix |
|---|---|---|
| OpenMPI aborts with an integer divide-by-zero during startup | AWS vCPUs (hwloc's x86 CPUID backend) | `HWLOC_COMPONENTS=-x86`, set in the batch script and passed into the container. Harmless on bare metal. |
| OpenFOAM's `etc/bashrc` can't find its install dir when sourced from `/bin/sh` | image build | source it under bash (it relies on `BASH_SOURCE`) |
| dl.openfoam.com download is slow and sometimes fails partway | image build | `deps/fetch-sources.sh` downloads once, checks the sha256, and copies the archive into the build |
| Slurm step launch fails (`Could not create scope directory`) | containerised compute nodes, cgroup v2 | compute containers run with an init process (Slurm derives its cgroup root from PID 1). Not needed on real nodes. |
| shared-memory single-copy fails between separate container instances | MPI inside Apptainer | `OMPI_MCA_btl_vader_single_copy_mechanism=none` |
| `decomposePar` refuses to overwrite earlier processor dirs | re-runs | `decomposePar -force` |

None of these needed a change to the solver.

## Effort

- **Agent (Devin):** all of the work in this branch:
  - port
  - image definitions and pinning
  - SBOM
  - local Slurm/Apptainer/S3 cluster
  - batch script
  - operator CLI
  - comparison tool
  - reference and validation runs
  - this report
- **Human:** about 5 minutes. Leonard Tan created the GitHub fork and gave access, and asked for status updates.
  No code was written or edited by a human. Engineer review of this branch is the remaining human step.
- **Wall-clock:** about 3 h from start to validated result, nearly all of it compute:
  - OpenFOAM v2606 compile from source: about 70 min on 8 vCPUs
  - reference run (v2106, 4 ranks): about 75 min, sharing the CPUs with the compile
  - v2606 run on Slurm (4 ranks over 2 nodes): 43 min (35 min wind, 7 min rain)
- **Rebuild:** `hpc/build.sh` reproduces the image from scratch. The compile is cached in the toolchain stage; the solver stage takes about 1 min.
