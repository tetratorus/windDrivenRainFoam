# windDrivenRainFoam: translation to OpenFOAM ESI v2606, packaging and HPC execution

## Outcome

<!-- RESULT -->

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

<!-- VALIDATION -->

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
- **Wall-clock:** about 4 h, nearly all of it compute:
  - OpenFOAM v2606 compile from source: about 70 min on 8 vCPUs
  - reference run (v2106, 4 ranks): about 75 min, sharing the CPUs with the compile
  - v2606 run on Slurm (4 ranks over 2 nodes): see Validation
- **Rebuild:** `hpc/build.sh` reproduces the image from scratch. The compile is cached in the toolchain stage; the solver stage takes about 1 min.
