#!/usr/bin/env python3
"""
E4 analysis (spec_knowledge/EXPERIMENTS.md, registered 2026-10-23): solve counts, exact McNemar paired by seed
(two-sided), Holm within each registered family, the decision rules, speed, what happened to the seeds
(`seed_guards_kept`), the cross-session contrasts with E5a and E6a, and the exploratory no-parsimony block.

    PYTHONIOENCODING=utf-8 bench/.venv/Scripts/python scripts/e4_analysis.py > results/e4_analysis.md
"""
import csv
import glob
import json
import os
import statistics

from scipy.stats import binomtest

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
SPECS = ["above4", "array_search4", "max6.sygus", "tiered3"]
COMPLETE = ["above4", "array_search4", "max6.sygus"]
ARMS = ["none", "inert", "guard", "partial", "full"]
PAIRABLE = {"solved", "censored", "unverified"}


def load(run):
    rows = {}
    for f in glob.glob(os.path.join(ROOT, "results", "runs", run, "runs", "*.csv")):
        with open(f, newline="") as fh:
            for r in csv.DictReader(fh):
                rows[(r["spec"], int(r["seed"]))] = r
    return rows


def load_art(run):
    out = {}
    for f in glob.glob(os.path.join(ROOT, "results", "runs", run, "artifacts", "*.jsonl")):
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                a = json.loads(line)
                out[(a["spec"], int(a["seed"]))] = a
    return out


def mcnemar(a, b, spec):
    """(b-only, a-only, p, n): seeds solved by b and not a, by a and not b; exact two-sided McNemar."""
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


def nsolved(rows, spec):
    return sum(1 for (sp, _), r in rows.items() if sp == spec and r["status"] == "solved")


def family(title, pairs, runs, correct=True):
    """pairs: (first, second, spec), keys of `runs`. Prints a table; returns {(first, second, spec): (diff, p)}."""
    res = [(b, a, sp, *mcnemar(runs[a], runs[b], sp)) for (b, a, sp) in pairs]
    adj = holm([r[5] for r in res]) if correct else [r[5] for r in res]
    print(f"\n### {title}" + (f" (Holm over {len(res)})" if correct else " (uncorrected)") + "\n")
    print("| contrast | spec | solved | only first | only second | p | " + ("p Holm |" if correct else "|"))
    print("|---|---|---|---|---|---|" + ("---|" if correct else ""))
    out = {}
    for (b, a, sp, n10, n01, p, n), ph in zip(res, adj):
        tail = f" {ph:.2g} |" if correct else ""
        print(f"| {b} vs {a} | {sp} | {nsolved(runs[b], sp)} vs {nsolved(runs[a], sp)} | {n10} | {n01} | {p:.2g} |" + tail)
        out[(b, a, sp)] = (n10 - n01, ph)
    return out


def med(rows, spec, col):
    v = [float(r[col]) for (sp, _), r in rows.items() if sp == spec and r["status"] == "solved" and r[col] != ""]
    return statistics.median(v) if v else float("nan")


R = {a: load(f"e4-{a}") for a in ARMS}
A = {a: load_art(f"e4-{a}") for a in ARMS}

print("## E4 solve counts (of 66; crashed / error in brackets when any)\n")
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
        cells.append(f"{nsolved(R[a], sp)}" + (f" ({bad})" if bad else "") + ("" if len(rows) == 66 else f" /{len(rows)}"))
    print(f"| {sp} | " + " | ".join(cells) + " |")

prim = family("Primary: guard vs inert", [("guard", "inert", sp) for sp in SPECS], R)
cost = family("Secondary: inert vs none (cost of seeding)", [("inert", "none", sp) for sp in SPECS], R)
family("Secondary: guard vs none", [("guard", "none", sp) for sp in SPECS], R)
part = family("Secondary: partial vs none", [("partial", "none", sp) for sp in SPECS], R)
full = family("Secondary: full vs none on tiered3", [("full", "none", "tiered3")], R)

print("\n### Decision rules\n")
w = sum(prim[("guard", "inert", sp)][0] > 0 and prim[("guard", "inert", sp)][1] < 0.05 for sp in SPECS)
print(f"- seeds carry knowledge GP can use: guard > inert after Holm on {w} of 4 specs: "
      f"{'supported' if w >= 2 else 'not supported'} (needs >= 2)")
c = [sp for sp in SPECS if cost[("inert", "none", sp)][1] < 0.05]
print(f"- seeding costs nothing: inert vs none significant on {c if c else 'no spec'}: "
      f"{'supported' if not c else 'not supported'}")
w = sum(part[("partial", "none", sp)][0] > 0 and part[("partial", "none", sp)][1] < 0.05 for sp in SPECS)
print(f"- partial chains help: partial > none after Holm on {w} of 4 specs: {'supported' if w >= 2 else 'not supported'}")
d, p = full[("full", "none", "tiered3")]
print(f"- all the knowledge as seeds helps under partial knowledge: full vs none on tiered3, diff {d:+d}, p {p:.2g}: "
      f"{'supported' if d > 0 and p < 0.05 else 'not supported'}")
print("- sanity, full on the complete specs: " +
      ", ".join(f"{sp} {nsolved(R['full'], sp)}/66 (max solve generation "
                f"{max((int(r['solve_gen']) for (s, _), r in R['full'].items() if s == sp and r['status'] == 'solved' and r['solve_gen'] != ''), default='-')})"
                for sp in COMPLETE))

print("\n### Speed: medians over solved seeds (generation to solve / seconds to solve)\n")
print("| spec | " + " | ".join(ARMS) + " |")
print("|---|" + "---|" * len(ARMS))
for sp in SPECS:
    print(f"| {sp} | " + " | ".join(f"{med(R[a], sp, 'solve_gen'):.0f} / {med(R[a], sp, 'time_to_solve_s'):.1f} s"
                                    if nsolved(R[a], sp) else "—" for a in ARMS) + " |")

print("\n### The seeds: mean size, and knowledge guards found verbatim in the final best program\n")
print("| arm | spec | seed size (mean) | solved runs keeping ≥ 1 guard | unsolved runs keeping ≥ 1 guard |")
print("|---|---|---|---|---|")
for a in ARMS[1:]:
    for sp in SPECS:
        arts = [x for (s, _), x in A[a].items() if s == sp]
        if not arts:
            continue
        size = statistics.mean(x["completion"].get("seed_size_mean", 0) for x in arts)
        sol = [x for x in arts if x["status"] == "solved"]
        uns = [x for x in arts if x["status"] != "solved"]
        k = lambda xs: f"{sum(x['completion'].get('seed_guards_kept', 0) > 0 for x in xs)} of {len(xs)}"
        print(f"| {a} | {sp} | {size:.0f} | {k(sol)} | {k(uns)} |")

print("\n### Cross-session contrasts (same seeds, earlier code; descriptive)\n")
X = {"e5a-guard": load("e5a-guard"), "e5a-orig": load("e5a-orig"),
     "main-e6a-caseguard": load("main-e6a-caseguard"), "main-e6a-orig": load("main-e6a-orig"),
     "e4-guard": R["guard"], "e4-full": R["full"], "e4-none": R["none"]}
family("Init vs grammar: guard seeds vs E5a's guard grammar", [("e4-guard", "e5a-guard", sp) for sp in COMPLETE], X, False)
family("Init vs grammar: full seeds vs E6a's recipes + region-guard grammar", [("e4-full", "main-e6a-caseguard", "tiered3")], X, False)
print("\n**Replication of the unseeded arm** (identical outcomes, seed by seed):\n")
for ref, sps in (("e5a-orig", COMPLETE), ("main-e6a-orig", ["tiered3"])):
    for sp in sps:
        same = sum(1 for (s, seed), r in R["none"].items() if s == sp and (s, seed) in X[ref]
                   and (r["status"] == "solved") == (X[ref][(s, seed)]["status"] == "solved"))
        print(f"- {sp}: e4-none {nsolved(R['none'], sp)} vs {ref} {nsolved(X[ref], sp)}; same outcome on {same} of 66 seeds")

E = {a: load(f"e4x-{a}-nopars") for a in ("none", "guard", "full")}
if any(E.values()):
    print("\n## Exploratory: no parsimony case (seeds 1001–1020)\n")
    print("| spec | none | guard | full |")
    print("|---|---|---|---|")
    for sp in SPECS:
        print(f"| {sp} | " + " | ".join(str(nsolved(E[a], sp)) if any(s == sp for (s, _) in E[a]) else "—"
                                        for a in ("none", "guard", "full")) + " |")
    family("guard vs none without parsimony", [("guard", "none", sp) for sp in SPECS], E, False)
    family("full vs none without parsimony", [("full", "none", "tiered3")], E, False)
