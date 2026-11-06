#!/usr/bin/env bash
# SBOM (SPDX 2.3 JSON) + build manifest for a built image.
#  - OS packages: syft scan of the SIF (dpkg database inside the image)
#  - source-built components (OpenFOAM, the solver, the bundled tutorial case) added from deps/lock.yaml + build args
set -euo pipefail
cd "$(dirname "$0")/.."
SIF=${1:?SIF}; VERSION=${2:?VERSION}
OUT=$(dirname "$SIF")
syft scan "singularity:$SIF" -q -o spdx-json="$OUT/sbom.syft.spdx.json"
python3 - "$SIF" "$VERSION" "$OUT" <<'PY'
import json, subprocess, sys, hashlib, pathlib, re
sif, version, out = sys.argv[1:]
out = pathlib.Path(out)
lock = pathlib.Path("deps/lock.yaml").read_text()
def pin(key):
    m = re.search(rf"^\s*{key}:\s*(\S+)", lock, re.M); return m.group(1) if m else None
labels = json.loads(subprocess.check_output(["apptainer", "inspect", "--json", "-l", sif]))
labels = labels["data"]["attributes"]["labels"]
digest = hashlib.sha256(open(sif, "rb").read()).hexdigest()
doc = json.load(open(out / "sbom.syft.spdx.json"))
doc["name"] = f"windDrivenRainFoam-{version}"
extra = [
  ("OpenFOAM", "v2606", pin("openfoam_url"), pin("openfoam_sha256"), "GPL-3.0-or-later"),
  ("windDrivenRainFoam", labels.get("solver.revision"), "https://github.com/OpenFOAM-BuildingPhysics/windDrivenRainFoam", None, "GPL-3.0-or-later"),
  ("windDrivenRainFoam-tutorials/cubicBuilding", labels.get("tutorials.revision"), "https://github.com/OpenFOAM-BuildingPhysics/windDrivenRainFoam-tutorials", None, "GPL-3.0-or-later"),
]
for i, (name, ver, url, sha, lic) in enumerate(extra):
    p = {"name": name, "SPDXID": f"SPDXRef-Package-source-{i}", "versionInfo": ver, "downloadLocation": url or "NOASSERTION",
         "filesAnalyzed": False, "licenseConcluded": lic, "licenseDeclared": lic, "copyrightText": "NOASSERTION",
         "comment": "built from source inside the image"}
    if sha: p["checksums"] = [{"algorithm": "SHA256", "checksumValue": sha}]
    doc["packages"].append(p)
json.dump(doc, open(out / "sbom.spdx.json", "w"), indent=1)
pk = [p for p in doc["packages"] if p.get("versionInfo")]
manifest = {"image": pathlib.Path(sif).name, "version": version, "sha256": digest, "labels": labels,
            "base_image": pin("base_image"), "apt_snapshot": pin("apt_snapshot"),
            "openfoam": {"version": "v2606", "url": pin("openfoam_url"), "sha256": pin("openfoam_sha256")},
            "packages": len(pk)}
for want in ("g++-13", "openmpi-bin", "libscotch-dev", "libpmix2t64", "libc6"):
    for p in pk:
        if p["name"] == want: manifest.setdefault("key_packages", {})[want] = p["versionInfo"]
json.dump(manifest, open(out / "manifest.json", "w"), indent=1)
print(f"SBOM: {len(doc['packages'])} packages -> {out/'sbom.spdx.json'}")
PY
rm -f "$OUT/sbom.syft.spdx.json"
