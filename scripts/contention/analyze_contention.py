#!/usr/bin/env python3
"""
Contention slowdown per arm (results/contention/raw.csv from run_contention.sh): for each
arm, spec and seed, time under 4 concurrent processes / time alone, for identical work
(same seed, same generation count — checked). If one arm's slowdown differs from the
baseline's, --jobs 4 budgets favour or penalise that arm.

    bench/.venv/Scripts/python scripts/contention/analyze_contention.py
"""
import csv
import os
import statistics as st
from collections import defaultdict

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
rows = list(csv.DictReader(open(os.path.join(ROOT, "results", "contention", "raw.csv"), encoding="utf-8")))
t = defaultdict(dict)   # (arm, spec, seed) -> mode -> (gens, elapsed)
for r in rows:
    t[(r["arm"], r["spec"], int(r["seed"]))][r["mode"]] = (int(r["gens"]), float(r["elapsed_s"]))

out = defaultdict(list)
mismatch = []
for (arm, spec, seed), m in sorted(t.items()):
    if "solo" in m and "conc" in m:
        if m["solo"][0] != m["conc"][0]:
            mismatch.append((arm, spec, seed, m["solo"][0], m["conc"][0]))
            continue
        out[(arm, spec)].append((m["conc"][1] / m["solo"][1], m["solo"][1] / m["solo"][0] * 1000,
                                 m["conc"][1] / m["conc"][0] * 1000))

print("| spec | arm | seeds | ms/gen alone | ms/gen with 4 | slowdown (median) | range | vs baseline |")
print("|---|---|---|---|---|---|---|---|")
for spec in ("array_search4", "max6"):
    base = out.get(("baseline-lex", spec))
    bmed = st.median(x[0] for x in base) if base else None
    for arm in ("baseline-lex", "lex-guided", "lex-percon", "hybrid-ratio"):
        v = out.get((arm, spec))
        if not v:
            continue
        med = st.median(x[0] for x in v)
        rel = f"{med / bmed:.2f}×" if bmed else ""
        print(f"| `{spec}` | `{arm}` | {len(v)} | {st.median(x[1] for x in v):.0f} | {st.median(x[2] for x in v):.0f} | "
              f"{med:.2f}× | {min(x[0] for x in v):.2f}–{max(x[0] for x in v):.2f} | {rel} |")
if mismatch:
    print("\ngeneration counts differ (excluded — should not happen):", mismatch)
