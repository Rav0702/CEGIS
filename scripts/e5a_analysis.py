#!/usr/bin/env python3
"""
E5a analysis (spec_knowledge/EXPERIMENTS.md, registered 2026-10-17): solve counts, exact McNemar paired by seed
(two-sided), Holm within each registered family, the decision rule, the d / h / c estimates, and medians of the
generation and time to solve.

    bench/.venv/Scripts/python scripts/e5a_analysis.py            -> stdout (markdown)
"""
import csv
import glob
import os
import statistics

from scipy.stats import binomtest

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
SPECS = ["above4", "array_search4", "max6.sygus"]
ARMS = ["orig", "inert", "scrambled", "guard", "case"]
PAIRABLE = {"solved", "censored", "unverified"}


def load(run):
    rows = {}
    for f in glob.glob(os.path.join(ROOT, "results", "runs", run, "runs", "*.csv")):
        with open(f, newline="") as fh:
            for r in csv.DictReader(fh):
                rows[(r["spec"], int(r["seed"]))] = r
    return rows


def mcnemar(a, b, spec):
    """(b-only, a-only, p): seeds solved by b and not a, by a and not b; exact two-sided McNemar."""
    seeds = sorted(s for (sp, s) in a if sp == spec and (sp, s) in b
                   and a[(sp, s)]["status"] in PAIRABLE and b[(sp, s)]["status"] in PAIRABLE)
    sa = {s for s in seeds if a[(spec, s)]["status"] == "solved"}
    sb = {s for s in seeds if b[(spec, s)]["status"] == "solved"}
    n10, n01 = len(sb - sa), len(sa - sb)
    p = binomtest(n10, n10 + n01, 0.5).pvalue if n10 + n01 else 1.0
    return n10, n01, p, len(seeds)


def holm(ps):
    order = sorted(range(len(ps)), key=lambda i: ps[i])
    adj, run = [0.0] * len(ps), 0.0
    for rank, i in enumerate(order):
        run = max(run, min(1.0, (len(ps) - rank) * ps[i]))
        adj[i] = run
    return adj


def family(title, pairs):
    """pairs: (better-hypothesis arm, other arm, spec). Prints a table, returns {(b, a, spec): (diff, p_holm)}."""
    res = [(b, a, sp, *mcnemar(R[a], R[b], sp)) for (b, a, sp) in pairs]
    adj = holm([r[5] for r in res])
    print(f"\n### {title} (Holm over {len(res)})\n")
    print("| contrast | spec | solved | only first | only second | p | p Holm |")
    print("|---|---|---|---|---|---|---|")
    out = {}
    for (b, a, sp, n10, n01, p, n), ph in zip(res, adj):
        print(f"| {b} vs {a} | {sp} | {solved(b, sp)} vs {solved(a, sp)} | {n10} | {n01} | {p:.2g} | {ph:.2g} |")
        out[(b, a, sp)] = (n10 - n01, ph)
    return out


def solved(arm, spec):
    return sum(1 for (sp, _), r in R[arm].items() if sp == spec and r["status"] == "solved")


def med(arm, spec, col):
    v = [float(r[col]) for (sp, _), r in R[arm].items() if sp == spec and r["status"] == "solved" and r[col] != ""]
    return statistics.median(v) if v else float("nan")


R = {a: load(f"e5a-{a}") for a in ARMS}

print("## E5a solve counts (of 66; crashed / error in brackets when any)\n")
print("| spec | " + " | ".join(ARMS) + " |")
print("|---|" + "---|" * len(ARMS))
for sp in SPECS:
    cells = []
    for a in ARMS:
        rows = [r for (s, _), r in R[a].items() if s == sp]
        if not rows:
            cells.append("—")
            continue
        bad = sum(r["status"] in ("crashed", "error") for r in rows)
        cells.append(f"{solved(a, sp)}" + (f" ({bad})" if bad else "") + ("" if len(rows) == 66 else f" /{len(rows)}"))
    print(f"| {sp} | " + " | ".join(cells) + " |")

scr = [sp for sp in SPECS if any(s == sp for (s, _) in R["scrambled"])]
prim = family("Primary: guard vs every placebo",
              [("guard", "inert", sp) for sp in SPECS] + [("guard", "scrambled", sp) for sp in scr])
family("Secondary: inert vs orig (draw cost)", [("inert", "orig", sp) for sp in SPECS])
family("Secondary: scrambled vs inert (wrong splits)", [("scrambled", "inert", sp) for sp in scr])
family("Secondary: case vs guard (the answer, once the guard is known)", [("case", "guard", sp) for sp in SPECS])
family("Secondary: case vs orig (E1 replication)", [("case", "orig", sp) for sp in SPECS])

print("\n### Decision rule\n")
wins = []
for sp in SPECS:
    placebos = ["inert"] + (["scrambled"] if sp in scr else [])
    ok = all(prim[("guard", p, sp)][0] > 0 and prim[("guard", p, sp)][1] < 0.05 for p in placebos)
    wins.append(ok)
    print(f"- {sp}: guard beats {' and '.join(placebos)} after Holm: {'yes' if ok else 'no'}")
print(f"- **{sum(wins)} of 3 specs**: claim {'supported' if sum(wins) >= 2 else 'not supported'} (needs >= 2)")

print("\n### Estimates (solve counts; design §4)\n")
print("| spec | draw cost d = orig − inert | harm h = inert − scrambled | value c = guard − inert | guard − orig | case − guard |")
print("|---|---|---|---|---|---|")
for sp in SPECS:
    s = {a: solved(a, sp) for a in ARMS}
    h = f"{s['inert'] - s['scrambled']:+d}" if sp in scr else "—"
    print(f"| {sp} | {s['orig'] - s['inert']:+d} | {h} | {s['guard'] - s['inert']:+d} | {s['guard'] - s['orig']:+d} | {s['case'] - s['guard']:+d} |")

print("\n### Speed: medians over solved seeds (generation to solve / seconds to solve)\n")
print("| spec | " + " | ".join(ARMS) + " |")
print("|---|" + "---|" * len(ARMS))
for sp in SPECS:
    cells = []
    for a in ARMS:
        if not any(s == sp for (s, _) in R[a]):
            cells.append("—")
            continue
        cells.append(f"{med(a, sp, 'solve_gen'):.0f} / {med(a, sp, 'time_to_solve_s'):.1f} s")
    print(f"| {sp} | " + " | ".join(cells) + " |")

cp = {a: load(f"e5a-cp-{a}-cap19") for a in ("orig", "guard", "case")}
if any(cp.values()):
    print("\n### Exploratory: countpos4.split at depth cap 19 (seeds 1001–1020)\n")
    print("| arm | solved | median generation |")
    print("|---|---|---|")
    for a, rows in cp.items():
        sol = [r for r in rows.values() if r["status"] == "solved"]
        g = statistics.median(float(r["solve_gen"]) for r in sol) if sol else float("nan")
        print(f"| {a} | {len(sol)} of {len(rows)} | {g:.0f} |")
