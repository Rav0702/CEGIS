#!/usr/bin/env python3
"""
E5 analysis (spec_knowledge/EXPERIMENTS.md, registered 2026-10-24): solve counts, exact McNemar paired by seed
(two-sided), Holm within each registered family, the decision rules, the generation-matched check, machine load
per arm, speed, and the replication of the reference arms against E5a.

    PYTHONIOENCODING=utf-8 bench/.venv/Scripts/python scripts/e5_analysis.py > results/e5_analysis.md
"""
import csv
import glob
import os
import statistics

from scipy.stats import binomtest

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
SPECS = ["above4", "array_search4", "max6.sygus"]
ARMS = ["orig", "atomsinert", "atoms", "blocksinert", "blocks", "guard", "case"]
PAIRABLE = {"solved", "censored", "unverified"}


def load(run):
    rows = {}
    for f in glob.glob(os.path.join(ROOT, "results", "runs", run, "runs", "*.csv")):
        with open(f, newline="") as fh:
            for r in csv.DictReader(fh):
                rows[(r["spec"], int(r["seed"]))] = r
    return rows


def solved_set(rows, spec, gen=None):
    """Seeds solved (within `gen` generations when given)."""
    return {s for (sp, s), r in rows.items() if sp == spec and r["status"] == "solved"
            and (gen is None or (r["solve_gen"] != "" and int(r["solve_gen"]) <= gen))}


def mcnemar(a, b, spec, gen=None):
    """(b-only, a-only, p): exact two-sided McNemar over seeds pairable in both runs."""
    seeds = {s for (sp, s) in a if sp == spec and (sp, s) in b
             and a[(sp, s)]["status"] in PAIRABLE and b[(sp, s)]["status"] in PAIRABLE}
    sa, sb = solved_set(a, spec, gen) & seeds, solved_set(b, spec, gen) & seeds
    n10, n01 = len(sb - sa), len(sa - sb)
    return n10, n01, (binomtest(n10, n10 + n01, 0.5).pvalue if n10 + n01 else 1.0)


def holm(ps):
    order = sorted(range(len(ps)), key=lambda i: ps[i])
    adj, run = [0.0] * len(ps), 0.0
    for rank, i in enumerate(order):
        run = max(run, min(1.0, (len(ps) - rank) * ps[i]))
        adj[i] = run
    return adj


def nsolved(rows, spec):
    return len(solved_set(rows, spec))


def family(title, pairs, runs=None, correct=True):
    runs = runs or R
    res = [(b, a, sp, *mcnemar(runs[a], runs[b], sp)) for (b, a, sp) in pairs]
    adj = holm([r[5] for r in res]) if correct else [r[5] for r in res]
    print(f"\n### {title}" + (f" (Holm over {len(res)})" if correct else " (uncorrected)") + "\n")
    print("| contrast | spec | solved | only first | only second | p |" + (" p Holm |" if correct else ""))
    print("|---|---|---|---|---|---|" + ("---|" if correct else ""))
    out = {}
    for (b, a, sp, n10, n01, p), ph in zip(res, adj):
        print(f"| {b} vs {a} | {sp} | {nsolved(runs[b], sp)} vs {nsolved(runs[a], sp)} | {n10} | {n01} | {p:.2g} |"
              + (f" {ph:.2g} |" if correct else ""))
        out[(b, a, sp)] = (n10 - n01, ph)
    return out


def med(xs):
    return statistics.median(xs) if xs else float("nan")


R = {a: load(f"e5-{a}") for a in ARMS}

print("## E5 solve counts (of 66; crashed / error in brackets when any)\n")
print("| spec | " + " | ".join(ARMS) + " |")
print("|---|" + "---|" * len(ARMS))
for sp in SPECS:
    cells = []
    for a in ARMS:
        rows = [r for (s, _), r in R[a].items() if s == sp]
        bad = sum(r["status"] in ("crashed", "error") for r in rows)
        cells.append(f"{nsolved(R[a], sp)}" + (f" ({bad})" if bad else "") + ("" if len(rows) == 66 else f" /{len(rows)}"))
    print(f"| {sp} | " + " | ".join(cells) + " |")

prim = family("Primary: each level vs its inert placebo",
              [("atoms", "atomsinert", sp) for sp in SPECS] + [("blocks", "blocksinert", sp) for sp in SPECS])
family("Secondary: atoms vs orig", [("atoms", "orig", sp) for sp in SPECS])
family("Secondary: blocks vs orig", [("blocks", "orig", sp) for sp in SPECS])
family("Secondary: atomsinert vs orig (cost of the atom productions)", [("atomsinert", "orig", sp) for sp in SPECS])
family("Secondary: blocksinert vs orig (cost of the block productions)", [("blocksinert", "orig", sp) for sp in SPECS])
family("Secondary: blocks vs atoms (whole guards vs their atoms)", [("blocks", "atoms", sp) for sp in SPECS])
family("Secondary: case vs blocks (guard and answer joined in one production)", [("case", "blocks", sp) for sp in SPECS])
family("Secondary: guard vs blocks (the guard inside an ite production vs as a Bool block)", [("guard", "blocks", sp) for sp in SPECS])

print("\n### Decision rules\n")
for lvl in ("atoms", "blocks"):
    w = sum(prim[(lvl, lvl + "inert", sp)][0] > 0 and prim[(lvl, lvl + "inert", sp)][1] < 0.05 for sp in SPECS)
    print(f"- {lvl} carry knowledge GP can use: {lvl} > {lvl}inert after Holm on {w} of 3 specs: "
          f"{'supported' if w >= 2 else 'not supported'} (needs >= 2)")

print("\n### Generation-matched check (seeds solved within G generations; G = the smallest, over arms, of the median "
      "generations reached by unsolved seeds)\n")
print("| spec | G | " + " | ".join(ARMS) + " | atoms vs atomsinert | blocks vs blocksinert |")
print("|---|---|" + "---|" * (len(ARMS) + 2))
for sp in SPECS:
    reach = [med([int(r["generations"]) for (s, _), r in R[a].items() if s == sp and r["status"] != "solved"])
             for a in ARMS]
    G = int(min(x for x in reach if x == x)) if any(x == x for x in reach) else 0
    cells = [str(len(solved_set(R[a], sp, G))) for a in ARMS]
    c = []
    for lvl in ("atoms", "blocks"):
        n10, n01, p = mcnemar(R[lvl + "inert"], R[lvl], sp, G)
        c.append(f"{n10} : {n01}, p {p:.2g}")
    print(f"| {sp} | {G} | " + " | ".join(cells) + " | " + " | ".join(c) + " |")

print("\n### Machine load (median cpu_busy) and generations per second of unsolved seeds\n")
print("| spec | " + " | ".join(ARMS) + " |")
print("|---|" + "---|" * len(ARMS))
for sp in SPECS:
    cells = []
    for a in ARMS:
        rows = [r for (s, _), r in R[a].items() if s == sp]
        cpu = med([float(r["cpu_busy"]) for r in rows if r["cpu_busy"] not in ("", "NaN")])
        gps = med([float(r["generations"]) / float(r["elapsed_s"]) for r in rows
                   if r["status"] != "solved" and float(r["elapsed_s"]) > 0])
        cells.append(f"{cpu:.2f} / {gps:.1f}")
    print(f"| {sp} | " + " | ".join(cells) + " |")

print("\n### Speed: medians over solved seeds (generation to solve / seconds to solve)\n")
print("| spec | " + " | ".join(ARMS) + " |")
print("|---|" + "---|" * len(ARMS))
for sp in SPECS:
    cells = []
    for a in ARMS:
        rows = [r for (s, _), r in R[a].items() if s == sp and r["status"] == "solved"]
        cells.append(f"{med([float(r['solve_gen']) for r in rows if r['solve_gen'] != '']):.0f} / "
                     f"{med([float(r['time_to_solve_s']) for r in rows]):.1f} s" if rows else "—")
    print(f"| {sp} | " + " | ".join(cells) + " |")

print("\n### Reference arms against E5a (same seeds, earlier session; same outcome seed by seed)\n")
for a, ref in (("orig", "e5a-orig"), ("guard", "e5a-guard"), ("case", "e5a-case")):
    X = load(ref)
    for sp in SPECS:
        same = sum(1 for (s, seed), r in R[a].items() if s == sp and (s, seed) in X
                   and (r["status"] == "solved") == (X[(s, seed)]["status"] == "solved"))
        print(f"- {a} {sp}: {nsolved(R[a], sp)} vs {ref} {nsolved(X, sp)}; same outcome on {same} of 66")
