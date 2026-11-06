# Operating windDrivenRainFoam on the HPC cluster

Everything runs from the login node with one command, `wdr`. Cases go in and results come out through S3
(object storage), so you don't need shell access to the compute nodes or any OpenFOAM install.

## 1. Publish an image (engineers, once per release)

```bash
hpc/build.sh                                   # pinned build -> hpc/build/windDrivenRainFoam-<version>.sif (+ .sha256, SBOM, manifest)
wdr image push hpc/build/windDrivenRainFoam-<version>.sif <version>
wdr image list
```

Each version is stored in `s3://wdr-images/windDrivenRainFoam/<version>/` with its checksum, SBOM
(`sbom.spdx.json`) and build manifest. Jobs copy an image to the shared filesystem once and check its checksum before every run.

## 2. Run a case (researchers)

A case is a directory with two sub-cases, the same layout as the upstream tutorial:
`<name>.simpleFoam/` (wind flow) and `<name>.windDrivenRainFoam/` (rain). You can submit it from a local directory or from a `.tar.gz` in S3:

```bash
apptainer run windDrivenRainFoam.sif init-tutorial mycase   # optional: start from the bundled cubicBuilding case
wdr submit mycase --nodes 2 --ntasks-per-node 2              # or: wdr submit s3://wdr-cases/mycase.tar.gz
wdr status <job>                                             # Slurm state; result location
wdr logs <job>                                               # step-by-step progress
wdr fetch <job> ./results                                    # download + unpack results
```

The job runs the tutorial workflow with no manual steps:

1. mesh
2. decompose
3. `simpleFoam` across all ranks and nodes
4. reconstruct
5. map the wind fields into the rain case
6. decompose
7. `windDrivenRainFoam` across all ranks and nodes
8. reconstruct
9. upload `results.tar.gz` to `s3://wdr-results/<job-dir>/`

A job fails if any step returns non-zero, if a log contains `FOAM FATAL`, or if a solver log doesn't reach `End`. Results are uploaded only when the job succeeds.

## 3. Without the CLI

```bash
sbatch --nodes=2 --ntasks-per-node=2 hpc/slurm/wdr.sbatch /shared/images/<v>/windDrivenRainFoam.sif /shared/jobs/mycase [s3://bucket/prefix]
```

## Configuration

| variable | default | meaning |
|---|---|---|
| `S3_ENDPOINT` | AWS | S3 endpoint URL (leave unset on AWS) |
| `WDR_IMAGE_BUCKET` / `WDR_CASE_BUCKET` / `WDR_RESULT_BUCKET` | `wdr-images` / `wdr-cases` / `wdr-results` | buckets |
| `WDR_SHARED` | `/shared` | shared filesystem visible to all nodes (FSx for Lustre / EFS on AWS) |

## Local test cluster

`hpc/cluster/up.sh` starts a Docker stand-in for the AWS environment:

- a Slurm head/login node
- two 4-core compute nodes with Apptainer
- SeaweedFS as the S3 store

Run commands on it with `docker compose exec -u operator1 head wdr ...`.

## Web console

The same flow is available in a browser. `hpc/operator/wdr-web` (Python standard library only) runs on
the login node next to the `wdr` CLI and calls it for every action; `hpc/operator/wdr-web.html` is the page.
In the local cluster it starts with the head container and is published on `http://127.0.0.1:8080`.

- **Submit:** bundled cubicBuilding tutorial, an uploaded `.tar.gz` case, or an `s3://` case; pick image, nodes and ranks per node.
- **Watch:** Slurm node load, job stage, which hosts the MPI ranks landed on, residual plots for both solvers, live log.
- **Results:** download `results.tar.gz` from object storage.
- **Validate:** compare against the v2106 reference in `/shared/reference/cubicBuilding` with `hpc/validation/compare.py`; summary plus full Markdown report.
