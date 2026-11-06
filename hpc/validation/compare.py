#!/usr/bin/env python3
"""Compare a v2606 cubicBuilding result against the upstream v2106 reference, field by field.

usage: compare.py REF_CASE NEW_CASE [--tol 1e-3] [--sub windDrivenRainFoam] [--md report.md] [--json out.json]
REF_CASE/NEW_CASE hold *.simpleFoam and *.windDrivenRainFoam; the latest time of each sub-case is compared.
Every field file present in both is compared over internal cells and every patch (values written
as `uniform` or `nonuniform`). Metric: relative L2 = |new-ref|_2 / |ref|_2 (all components), plus max |new-ref|.
A field passes when relative L2 <= tol. Fields whose reference norm is 0 pass when max |diff| <= tol.
"""
import argparse, gzip, json, math, pathlib, re, sys

NUM = r"[-+0-9.eE]+"


def read(p):
    op = gzip.open if p.suffix == ".gz" else open
    with op(p, "rt") as f:
        return f.read()


def values(block, ncomp_hint=None):
    """Parse `uniform X` / `nonuniform List<T> N ( ... )` after a keyword; return list of floats or None."""
    m = re.match(r"\s*uniform\s+(\([^)]*\)|" + NUM + r")\s*;", block)
    if m:
        return [float(x) for x in re.findall(NUM, m.group(1))], True
    m = re.match(r"\s*nonuniform\s+List<\w+>\s*(\d+)\s*\(", block)
    if m:
        n = int(m.group(1)); start = m.end()
        depth, i = 1, start
        while depth:
            c = block[i]
            depth += (c == "(") - (c == ")"); i += 1
        return [float(x) for x in re.findall(NUM, block[start:i - 1])], False
    m = re.match(r"\s*nonuniform\s+List<\w+>\s*0\s*\(\s*\)", block)
    if m:
        return [], False
    return None, None


def parse_field(p):
    t = read(p)
    out = {}
    m = re.search(r"\binternalField\b", t)
    if m:
        v, _ = values(t[m.end():])
        if v is not None:
            out["internal"] = v
    b = re.search(r"\bboundaryField\s*\{", t)
    if b:
        for pm in re.finditer(r"\n\s{4}(\"?[\w.()|*-]+\"?)\s*\{", t[b.end():]):
            body = t[b.end() + pm.end():]
            end = body.find("\n    }")
            vm = re.search(r"\n\s+value\s", body[:end])
            if vm:
                v, _ = values(body[vm.end():end + 1])
                if v is not None:
                    out["patch:" + pm.group(1)] = v
    return out


def latest(case):
    ts = [d for d in case.iterdir() if d.is_dir() and re.fullmatch(NUM, d.name) and d.name != "0"]
    return max(ts, key=lambda d: float(d.name)) if ts else None


def stats(a, b, uniform_ok=True):
    if len(a) != len(b):
        if len(b) and len(a) and (len(a) % len(b) == 0 or len(b) % len(a) == 0):  # uniform vs nonuniform
            n = max(len(a), len(b)); ka, kb = n // len(a), n // len(b)
            a = (a * ka) if len(a) < n and len(a) <= 3 else a
            b = (b * kb) if len(b) < n and len(b) <= 3 else b
        if len(a) != len(b):
            return None
    d2 = sum((x - y) ** 2 for x, y in zip(a, b)); r2 = sum(y * y for y in b)
    mx = max((abs(x - y) for x, y in zip(a, b)), default=0.0)
    return {"n": len(b), "rel_l2": math.sqrt(d2 / r2) if r2 else (0.0 if d2 == 0 else math.inf),
            "max_abs": mx, "ref_norm": math.sqrt(r2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref"); ap.add_argument("new")
    ap.add_argument("--tol", type=float, default=1e-3)
    ap.add_argument("--md"); ap.add_argument("--json")
    ap.add_argument("--sub", action="append", choices=("simpleFoam", "windDrivenRainFoam"),
                    help="compare only this sub-case (repeatable; default both)")
    a = ap.parse_args()
    ref, new = pathlib.Path(a.ref), pathlib.Path(a.new)
    rows, ok = [], True
    for sub in a.sub or ("simpleFoam", "windDrivenRainFoam"):
        rc = next(ref.glob(f"*.{sub}")); nc = next(new.glob(f"*.{sub}"))
        rt, nt = latest(rc), latest(nc)
        if not rt or not nt:
            print(f"missing results for {sub}: ref={rt} new={nt}"); ok = False; continue
        if rt.name != nt.name:
            print(f"warning: {sub} latest time differs: ref {rt.name} new {nt.name}")
        names = sorted({p.name.removesuffix(".gz") for p in rt.iterdir() if p.is_file()} &
                       {p.name.removesuffix(".gz") for p in nt.iterdir() if p.is_file()})
        for n in names:
            if n in ("phi", "phirain") or n.startswith("phirain"):
                kind = "flux"
            else:
                kind = "field"
            fr = next(rt.glob(n + "*")); fn = next(nt.glob(n + "*"))
            pr, pn = parse_field(fr), parse_field(fn)
            for part in sorted(set(pr) & set(pn)):
                s = stats(pn[part], pr[part])
                if s is None:
                    rows.append({"case": sub, "time": rt.name, "field": n, "part": part, "error": "size mismatch"}); ok = False; continue
                passed = s["rel_l2"] <= a.tol if s["ref_norm"] else s["max_abs"] <= a.tol
                ok &= passed
                rows.append({"case": sub, "time": rt.name, "field": n, "part": part, **s, "pass": passed})
            for part in sorted(set(pr) ^ set(pn)):
                rows.append({"case": sub, "time": rt.name, "field": n, "part": part, "error": "only in one result"})
    worst = sorted([r for r in rows if "rel_l2" in r], key=lambda r: -r["rel_l2"])
    summary = {"tolerance_rel_l2": a.tol, "compared": len([r for r in rows if "rel_l2" in r]),
               "failed": [f"{r['case']}/{r['field']}/{r['part']}" for r in rows if r.get("pass") is False or "error" in r],
               "worst": worst[:10], "pass": ok}
    if a.json:
        json.dump({"summary": summary, "rows": rows}, open(a.json, "w"), indent=1)
    if a.md:
        with open(a.md, "w") as f:
            f.write(f"# cubicBuilding: v2606 vs upstream v2106 reference\n\n")
            f.write(f"Result: **{'PASS' if ok else 'FAIL'}** ({summary['compared']} field/patch comparisons, tolerance relative L2 <= {a.tol:g})\n\n")
            f.write("| case | field | part | values | relative L2 | max abs diff | pass |\n|---|---|---|---|---|---|---|\n")
            for r in rows:
                if r["part"] != "internal" and r.get("pass", False) and r.get("ref_norm", 1) == 0:
                    continue
                if "error" in r:
                    f.write(f"| {r['case']} | {r['field']} | {r['part']} | | | | {r['error']} |\n")
                elif r["part"] == "internal" or not r["pass"]:
                    f.write(f"| {r['case']} | {r['field']} | {r['part']} | {r['n']} | {r['rel_l2']:.3e} | {r['max_abs']:.3e} | {'yes' if r['pass'] else 'NO'} |\n")
            f.write("\nPatch values that pass are omitted from the table (all are in the JSON file).\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "worst"}, indent=1))
    for r in worst[:5]:
        print(f"  worst: {r['case']}/{r['field']}/{r['part']} rel_l2={r['rel_l2']:.3e} max_abs={r['max_abs']:.3e}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
