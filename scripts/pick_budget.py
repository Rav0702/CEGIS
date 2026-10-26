#!/usr/bin/env python3
"""
Calibration rule (BENCHMARK_METHODOLOGY.md §5 / §15e) applied mechanically to a pilot run:
the budget in [20 s, cap] at which the pilot arm's solve rate is nearest 50 %, among budgets
whose rate is inside 30-70 %; if none is inside the band, the cap (flagged on stderr).
Trajectories do not depend on the budget, so the rate at budget B is the share of pilot
seeds whose time to solve is <= B. Prints the budget (integer seconds) on stdout.

    python scripts/pick_budget.py <pilot-run> <spec>
"""
import csv
import glob
import os
import sys

run, spec = sys.argv[1], sys.argv[2]
root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
rows = []
for f in glob.glob(os.path.join(root, "results", "runs", run, "runs", f"{spec}.*.csv")):
    rows += list(csv.DictReader(open(f, encoding="utf-8")))
if not rows:
    sys.exit(f"pick_budget: no rows for {spec} in {run}")
cap = int(float(rows[0]["budget_s"]))
n = len(rows)
times = [float(r["time_to_solve_s"]) for r in rows if r["status"] == "solved"]
rate = lambda b: sum(t <= b for t in times) / n
band = [b for b in range(20, cap + 1) if 0.3 <= rate(b) <= 0.7]
if band:
    b = min(band, key=lambda x: (abs(rate(x) - 0.5), x))
    print(f"pick_budget: {spec} {b}s -> {rate(b):.2f} ({n} seeds)", file=sys.stderr)
else:
    b = cap
    print(f"pick_budget: {spec} NO in-band budget <= {cap}s (rate at cap {rate(cap):.2f}); using the cap",
          file=sys.stderr)
print(b)
