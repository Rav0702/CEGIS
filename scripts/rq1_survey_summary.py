#!/usr/bin/env python3
"""
Summarise the RQ1 coverage survey (scripts/rq1_coverage_survey.jl): per population, the class counts in the general
LIA grammar and in the file's own grammar, and per benchmark family (file name without its size suffix) the
classes, with the reasons for `none`, `out of scope` and `error`.

    PYTHONIOENCODING=utf-8 python scripts/rq1_survey_summary.py > results/rq1_survey/summary.md
"""
import collections
import csv
import glob
import os
import re

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
CLASSES = ["stated", "complete", "partial", "unproven", "none", "out of scope", "error", "skipped", "-"]


def family(path):
    f = re.split(r"[\\/]", path)[-1]
    f = re.sub(r"\.sl$", "", f)
    f = re.sub(r"[_-]?\d+$", "", f)
    return f


for tsv in sorted(glob.glob(os.path.join(ROOT, "results", "rq1_survey", "*.tsv"))):
    name = os.path.basename(tsv)[:-4]
    rows = list(csv.DictReader(open(tsv, newline="", encoding="utf-8"), delimiter="\t"))
    lia = collections.Counter(r["class_lia"] for r in rows)
    own = collections.Counter(r["class_own"] for r in rows)
    ren = sum(r["renamed"] == "true" for r in rows)
    print(f"## {name}: {len(rows)} LIA files ({ren} with parameters renamed positionally)\n")
    print("| grammar | " + " | ".join(c for c in CLASSES if lia[c] or own[c]) + " |")
    print("|---|" + "---|" * sum(1 for c in CLASSES if lia[c] or own[c]))
    print("| general LIA | " + " | ".join(str(lia[c]) for c in CLASSES if lia[c] or own[c]) + " |")
    print("| file's own | " + " | ".join(str(own[c]) for c in CLASSES if lia[c] or own[c]) + " |\n")
    fam = collections.defaultdict(collections.Counter)
    why = collections.defaultdict(collections.Counter)
    for r in rows:
        key = family(r["file"])
        fam[key][(r["class_lia"], r["class_own"])] += 1
        if r["class_lia"] in ("none", "out of scope", "error", "partial", "unproven"):
            why[key][r["class_lia"] + ": " + r["detail_lia"][:70]] += 1
    print("| family | files | classes (general LIA / own grammar) |")
    print("|---|---|---|")
    for k in sorted(fam):
        n = sum(fam[k].values())
        cls = ", ".join(f"{a} / {b} x{c}" for (a, b), c in sorted(fam[k].items()))
        print(f"| {k} | {n} | {cls} |")
    print()
    if why:
        print("Reasons (general LIA grammar):\n")
        for k in sorted(why):
            for w, c in why[k].most_common():
                print(f"- {k}: {w} (x{c})")
        print()
