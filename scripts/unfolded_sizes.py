#!/usr/bin/env python3
"""
Program sizes of solved seeds, in grammar nodes (the harness's `program_size`) and unfolded into the original
grammar (count of operators + leaves in `program_expr`, the expanded Julia expression). For plain grammars the
two agree; for enriched grammars a case production counts as one grammar node but unfolds to its full term.

    bench/.venv/Scripts/python scripts/unfolded_sizes.py main-enrich-orig main-enrich-case main-enrich-decoy
"""
import csv, glob, os, re, statistics as st, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))


def unfolded(e):
    leaves = [t for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+", e) if t != "ifelse"]
    ops = (e.count("ifelse") + e.count("&&") + e.count("||") + len(re.findall(r">=|<=|==", e))
           + len(re.findall(r"(?<![<>=!])[<>](?!=)", e))
           + len(re.findall(r"(?<![<>=!])[+\-](?!=)", e)) + len(re.findall(r"!(?!=)", e)))
    return len(leaves) + ops


def main(runs):
    specs = sorted({re.sub(r"\.s\d+\.csv$", "", os.path.basename(f)) for r in runs
                    for f in glob.glob(os.path.join(ROOT, "results", "runs", r, "runs", "*.csv"))})
    print(f"{'spec':18s}" + "".join(f"{r:>34s}" for r in runs))
    for spec in specs:
        cells = []
        for r in runs:
            rows = [x for f in glob.glob(os.path.join(ROOT, "results", "runs", r, "runs", f"{spec}.s*.csv"))
                    if re.fullmatch(re.escape(spec) + r"\.s\d+\.csv", os.path.basename(f))
                    for x in csv.DictReader(open(f)) if x["status"] == "solved"]
            if not rows:
                cells.append("-")
                continue
            g = st.median(int(x["program_size"]) for x in rows)
            u = st.median(unfolded(x["program_expr"]) for x in rows)
            cells.append(f"n={len(rows)} grammar {g:g} unfolded {u:g}")
        print(f"{spec:18s}" + "".join(f"{c:>34s}" for c in cells))


if __name__ == "__main__":
    main(sys.argv[1:])
