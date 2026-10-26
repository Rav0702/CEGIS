#!/usr/bin/env python3
"""
bench/diagnose.py -- reports on stored runs (made by bench/run.jl).

    diagnose.py RUN                         one run   -> results/runs/RUN/report.md
    diagnose.py BASELINE CAND [CAND ...]    compare   -> results/comparisons/BASELINE__vs__CAND/report.md

RUN may be a run name (looked up in results/runs/) or a path.

Options
  --specs a,b            restrict to these specs
  --alternative ALT      two-sided (default) | greater | less, where `greater` means
                         "the candidate is BETTER". Choose it before you look at the
                         results; picking a one-sided test after seeing the direction
                         halves the p-value dishonestly.
  --alpha 0.05
  --no-figures

Statistics (all paired by seed; a seed that crashed or errored in either run is
dropped from both, so pairing survives):
  primary    verified solve within budget   McNemar exact test, odds ratio + exact CI
  pooled     across specs                   McNemar on summed discordant pairs (= the
                                            Mantel-Haenszel test stratified by pair),
                                            plus a chi-square test of whether the effect
                                            differs between specs
  survival   time-to-solve, censored        log-rank test, Peto hazard ratio + CI
  secondary  accuracy, AUC, stall, cost, size   Wilcoxon signed-rank, matched-pairs
                                            rank-biserial correlation, median difference
  multiplicity                              Holm correction across every primary test
"""

import argparse
import csv
import datetime as dt
import glob
import math
import os
import re
import sys
import tomllib

import numpy as np
from scipy import stats

sys.path.insert(0, os.path.dirname(__file__))
import figures  # noqa: E402
from figures import Run, num, acc_on_time_grid  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
RUNS_ROOT = os.path.join(ROOT, "results", "runs")
CMP_ROOT = os.path.join(ROOT, "results", "comparisons")
PAIRABLE = {"solved", "censored", "unverified"}   # crashed / error are dropped from both runs


# ── loading ──────────────────────────────────────────────────────────────────

class StoredRun:
    def __init__(self, arg):
        path = arg if os.path.isdir(arg) else os.path.join(RUNS_ROOT, arg)
        if not os.path.isdir(path):
            sys.exit(f"error: no run `{arg}` (looked in {RUNS_ROOT})")
        self.dir = os.path.normpath(path)
        self.name = os.path.basename(self.dir)
        mpath = os.path.join(self.dir, "manifest.toml")
        if not os.path.isfile(mpath):
            sys.exit(f"error: {self.dir} has no manifest.toml — was it made by bench/run.jl?")
        with open(mpath, "rb") as f:
            self.man = tomllib.load(f)
        self.rows = {}          # spec -> {seed: row}
        self.duplicates = []
        for p in sorted(glob.glob(os.path.join(self.dir, "runs", "*.csv"))):
            with open(p, newline="") as f:
                for r in csv.DictReader(f):
                    d = self.rows.setdefault(r["spec"], {})
                    s = int(r["seed"])
                    if s in d:
                        self.duplicates.append((r["spec"], s))
                        continue
                    d[s] = r
        self._gens = {}

    def specs(self):
        return sorted(self.rows)

    def gens(self, spec):
        if spec not in self._gens:
            g = {}
            for p in glob.glob(os.path.join(self.dir, "generations", f"{glob.escape(spec)}.s*.csv")):
                with open(p, newline="") as f:
                    for r in csv.DictReader(f):
                        if r["spec"] == spec:
                            g.setdefault(int(r["seed"]), []).append(r)
            self._gens[spec] = g
        return self._gens[spec]

    def run(self, spec, seed):
        return Run(self.rows[spec][seed], self.gens(spec).get(seed, []))

    def spec_meta(self, spec):
        return self.man.get("specs", {}).get(spec, {})


# ── statistics ───────────────────────────────────────────────────────────────

def mcnemar(b, c, alt):
    """b = baseline-only solves, c = candidate-only solves. `greater` = candidate better."""
    n = b + c
    return 1.0 if n == 0 else stats.binomtest(c, n, 0.5, alternative=alt).pvalue


def min_achievable_p(d, alt):
    """Smallest McNemar p possible with d discordant pairs, however they split."""
    if d == 0:
        return 1.0
    return stats.binomtest(d, d, 0.5, alternative="greater" if alt != "two-sided" else "two-sided").pvalue


def odds_ratio(b, c):
    """Candidate-vs-baseline odds of solving among discordant pairs, with an exact 95% CI."""
    if b + c == 0:
        return (math.nan, math.nan, math.nan)
    ci = stats.binomtest(c, b + c).proportion_ci(0.95, method="exact")
    f = lambda p: math.inf if p >= 1 else p / (1 - p)
    return (math.inf if b == 0 else c / b, f(ci.low), f(ci.high))


def wilson(k, n, z=1.96):
    if n == 0:
        return (math.nan, math.nan)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (c - h, c + h)


def _surv(runs, axis):
    """(time, event) per run on the given axis, or None if any run lacks it."""
    pts = [r.survival(axis) for r in runs]
    return None if any(p is None for p in pts) else pts


def peto_hazard_ratio(base, cand, axis="time"):
    """HR > 1: the candidate solves at a higher rate. From the log-rank O, E, V."""
    sb, sc = _surv(base, axis), _surv(cand, axis)
    if sb is None or sc is None:
        return (math.nan, math.nan, math.nan)
    ev = [(t, e, 0) for t, e in sb] + [(t, e, 1) for t, e in sc]
    ev.sort(key=lambda e: (e[0], not e[1]))
    n0, n1 = len(sb), len(sc)
    O1 = E1 = V = 0.0
    i = 0
    while i < len(ev):
        t = ev[i][0]
        d0 = d1 = c0 = c1 = 0
        while i < len(ev) and ev[i][0] == t:
            _, e, g = ev[i]
            if e:
                d1 += g; d0 += 1 - g
            else:
                c1 += g; c0 += 1 - g
            i += 1
        n, d = n0 + n1, d0 + d1
        if d > 0 and n > 1 and n0 > 0 and n1 > 0:
            O1 += d1
            E1 += d * n1 / n
            V += d * (n1 / n) * (1 - n1 / n) * ((n - d) / (n - 1))
        n0 -= d0 + c0
        n1 -= d1 + c1
    if V <= 0:
        return (math.nan, math.nan, math.nan)
    k = (O1 - E1) / V
    return (math.exp(k), math.exp(k - 1.96 / math.sqrt(V)), math.exp(k + 1.96 / math.sqrt(V)))


def logrank(base, cand, alt, axis="time"):
    """
    Log-rank p. The event here is a SOLVE, which is good, so "candidate better" means
    the candidate's event (hazard) rate is HIGHER. SciPy phrases alternatives as event
    rates of x relative to y ('greater': x's rate is higher), so with x = candidate the
    mapping is the identity. (Reading it as "survival is lower/higher" inverts it; a
    one-sided test would then report no effect for a real improvement.)
    """
    sb, sc = _surv(base, axis), _surv(cand, axis)
    if sb is None or sc is None:
        return math.nan
    if not any(e for _, e in sb) and not any(e for _, e in sc):
        return 1.0
    cd = lambda pts: stats.CensoredData(uncensored=[t for t, e in pts if e],
                                        right=[t for t, e in pts if not e])
    scipy_alt = alt
    try:
        return float(stats.logrank(x=cd(sc), y=cd(sb), alternative=scipy_alt).pvalue)
    except Exception:
        return math.nan


def paired_test(xb, xc, alt, higher_is_better):
    """Wilcoxon signed-rank on (candidate - baseline); `alt` is in 'candidate better' terms."""
    xb, xc = np.asarray(xb, float), np.asarray(xc, float)
    keep = ~(np.isnan(xb) | np.isnan(xc))
    xb, xc = xb[keep], xc[keep]
    n = len(xb)
    out = {"n": n, "base_med": float(np.median(xb)) if n else math.nan,
           "cand_med": float(np.median(xc)) if n else math.nan,
           "med_diff": float(np.median(xc - xb)) if n else math.nan, "p": math.nan, "r": math.nan}
    if n == 0:
        return out
    d = xc - xb
    nz = d[d != 0]
    if len(nz) == 0:
        out.update(p=1.0, r=0.0)
        return out
    ranks = stats.rankdata(np.abs(nz))
    out["r"] = float((ranks[nz > 0].sum() - ranks[nz < 0].sum()) / ranks.sum())
    w_alt = alt if alt == "two-sided" else (
        ("greater" if alt == "greater" else "less") if higher_is_better else
        ("less" if alt == "greater" else "greater"))
    # Zero differences dropped explicitly (the "wilcox" convention), so the exact
    # distribution is used whenever there are no tied magnitudes.
    try:
        with np.errstate(all="ignore"):
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                out["p"] = float(stats.wilcoxon(nz, alternative=w_alt).pvalue)
    except ValueError:
        out["p"] = 1.0
    return out


def holm(pvals):
    ps = [(p if not math.isnan(p) else 1.0) for p in pvals]
    order = sorted(range(len(ps)), key=lambda i: ps[i])
    adj = [0.0] * len(ps)
    running = 0.0
    m = len(ps)
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (m - rank) * ps[i]))
        adj[i] = running
    return adj


def at_solve(r, field):
    """A cumulative trajectory value at the solve generation, or NaN without a trace."""
    if not (r.solved and r.has_trace and r.solve_gen > 0):
        return math.nan
    i = int(np.searchsorted(r.gen, r.solve_gen, side="right")) - 1
    return float(getattr(r, field)[i]) if i >= 0 else math.nan


def auc_acc(r, budget):
    if not r.has_trace:
        return math.nan
    grid = np.linspace(0, budget, 240)
    return float(np.nanmean(acc_on_time_grid(r, grid)))


def stall_fraction(r):
    if not r.has_trace:
        return math.nan
    done = r.solve_gen if (r.solved and r.solve_gen > 0) else r.last_gen
    v = r.val_eff[r.gen <= done]
    if len(v) < 2:
        return math.nan
    best = np.maximum.accumulate(v)
    return float(np.mean(v[1:] <= best[:-1]))


# ── formatting ───────────────────────────────────────────────────────────────

def fp(p):
    if p is None or (isinstance(p, float) and math.isnan(p)):
        return "—"
    return "<0.0001" if p < 1e-4 else f"{p:.4f}" if p < 0.01 else f"{p:.3f}"


def pe(p):
    """p as a phrase: 'p = 0.0007', or 'p < 0.0001' rather than 'p = <0.0001'."""
    t = fp(p)
    return f"p < {t[1:]}" if t.startswith("<") else f"p = {t}"


def fx(x, d=2):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "—"
    if isinstance(x, float) and math.isinf(x):
        return "∞"
    return f"{x:.{d}f}" if isinstance(x, float) else str(x)


def fci(est, lo, hi, d=2):
    return "—" if math.isnan(est) else f"{fx(est, d)} [{fx(lo, d)}, {fx(hi, d)}]"


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def med(xs):
    xs = [x for x in xs if not math.isnan(x)]
    return float(np.median(xs)) if xs else math.nan


# ── single-run report ────────────────────────────────────────────────────────

def single_report(run, specs, make_figs):
    m = run.man
    lines = [f"# Run `{run.name}`", "",
             f"arm **{m['arm']}** (`{m['arm_hash']}`) · code `{m['code_sha256']}` · "
             f"git `{m['git_sha'][:10]}`{' +dirty' if m.get('git_dirty') else ''} · "
             f"{m.get('host', '?')} · {m.get('jobs', '?')} jobs · created {m.get('created_utc', '?')}", "",
             "arm configuration: " + ", ".join(f"`{k}={v}`" for k, v in sorted(m["arm_config"].items())), ""]
    if m.get("code_changed_during_run"):
        lines += ["> ⚠ The source code changed while this run was being filled in (`--allow-code-change`). "
                  "Its seeds do not all come from the same algorithm.", ""]
    if m.get("mixed_jobs"):
        lines += ["> ⚠ This run was resumed with a different `--jobs`, so seeds ran under different load.", ""]

    rows = []
    fails, examples, spend = [], [], []
    for s in specs:
        d = run.rows[s]
        meta = run.spec_meta(s)
        st = [r["status"] for r in d.values()]
        n = len(st)
        k = st.count("solved")
        lo, hi = wilson(k, n)
        solved = [r for r in d.values() if r["status"] == "solved"]
        cens = [r for r in d.values() if r["status"] != "solved"]
        rows.append([f"`{s}`", meta.get("tier", "?"), f"{fx(num(meta.get('budget')), 0)} s", n,
                     f"**{k}** ({100 * k / n:.0f}%, CI {100 * lo:.0f}–{100 * hi:.0f})" if n else "—",
                     st.count("crashed"), st.count("error"), st.count("unverified"),
                     fx(med([num(r["time_to_solve_s"]) for r in solved]), 1),
                     fx(med([num(r["generations"]) for r in solved]), 0),
                     fx(med([num(r["z3_total"]) for r in solved]), 0),
                     fx(med([num(r["program_size"]) for r in solved]), 0),
                     fx(med([num(r["val_acc_final"]) for r in cens]), 3)])
        bad = sorted((int(r["seed"]), r["status"], num(r["val_acc_final"])) for r in cens)
        if bad:
            fails.append(f"- `{s}`: " + ", ".join(f"{sd} ({stt}{'' if math.isnan(v) else f', acc {v:.2f}'})"
                                                 for sd, stt, v in bad))
        if solved:
            best = min(solved, key=lambda r: num(r["program_size"]))
            examples.append(f"- `{s}` seed {best['seed']}, {best['program_size']} nodes: `{best['program_expr']}`")
        spend.append([f"`{s}`"] + [fx(med([num(r.get(c)) for r in d.values()]), 0) for c in
                                   ("z3_constraint_checks", "z3_cex_queries", "z3_complete_output",
                                    "z3_output_unique", "z3_subprocess", "z3_total")])
    health = health_notes(run)
    if health:
        lines += ["## Run health", ""] + [f"> ⚠ {h}" for h in health] + [""]
    lines += ["## Outcomes", "",
              md_table(["spec", "tier", "budget", "seeds", "solved (95% CI)", "crashed", "error", "unverified",
                        "median time", "median gens", "median Z3", "median size", "median acc (unsolved)"],
                       rows),
              "", "Medians of time, generations, Z3 and size are over solved seeds; accuracy over unsolved ones "
                  "(how close the failures got).", ""]
    if any(r[7] for r in rows):
        lines += ["> ⚠ `unverified` means the search claimed a solution the independent Z3 check rejected — "
                  "a soundness bug, not a near miss.", ""]
    lines += ["## Solver spend per seed (medians, all seeds)", "",
              md_table(["spec", "constraint checks", "counterexample", "output completion",
                        "output uniqueness", "subprocess", "total"], spend), ""]
    lines += completion_section([(run.name, run)], specs)
    lines += harvest_section([(run.name, run)], specs)
    lines += guided_section([(run.name, run)], specs)
    lines += ["## Seeds not solved", ""] + (fails or ["none"]) + [""]
    lines += ["## Smallest verified program per spec", ""] + (examples or ["none"]) + [""]
    if make_figs:
        lines += ["## Figures", ""]
        for s in specs:
            series = {run.name: [run.run(s, sd) for sd in sorted(run.rows[s])
                                 if run.rows[s][sd]["status"] in PAIRABLE]}
            if not series[run.name]:
                continue
            budget = num(run.spec_meta(s).get("budget"))
            if math.isnan(budget):
                budget = max(r.budget for r in series[run.name])
            outdir = os.path.join(run.dir, "figures", s)
            figures.all_figures(s, series, budget, len(series[run.name]), outdir)
            lines += [f"### `{s}`", "", f"![](figures/{s}/overview.png)", "",
                      f"Every metric against wall-clock (`*_time`) and generations (`*_gen`); "
                      f"PDFs for print in `figures/{s}/`.", ""]
    path = os.path.join(run.dir, "report.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nrun {run.name}  (arm {m['arm']}, code {m['code_sha256']})")
    print(f"{'spec':<16}{'seeds':>6}{'solved':>8}{'rate':>7}{'crash':>7}{'median t':>10}")
    for s, r in zip(specs, rows):
        d = run.rows[s]
        k = sum(1 for x in d.values() if x["status"] == "solved")
        print(f"{s:<16}{len(d):>6}{k:>8}{100 * k / max(len(d), 1):>6.0f}%{r[5]:>7}{r[8]:>10}")
    for h in health:
        print(f"  warning: {h}")
    print(f"\nreport: {os.path.relpath(path, ROOT)}")


def completion_section(named_runs, specs):
    """How counterexamples became tests — the evidence the incomplete-test path ran.

    Omitted when no run stored the columns (runs made before incomplete tests existed)."""
    rows = []
    for s in specs:
        for nm, run in named_runs:
            d = run.rows.get(s, {})
            recs = [r for r in d.values() if r.get("incomplete_final", "") != ""]
            if not recs:
                continue
            sa = sorted({r.get("single_answer", "") for r in recs})
            sa_txt = {"1": "yes", "0": "no", "": "not checked"}
            inc = [num(r["incomplete_final"]) for r in recs]
            rows.append([f"`{s}`", f"`{nm}`", " / ".join(sa_txt.get(x, x) for x in sa),
                         fx(med([num(r["tests_final"]) - num(r["incomplete_final"]) for r in recs]), 0),
                         fx(med(inc), 0),
                         f"{sum(1 for x in inc if x > 0)}/{len(recs)}",
                         fx(med([num(r.get("unique_checks")) for r in recs]), 0),
                         fx(med([num(r.get("tests_unchecked")) for r in recs]), 0)])
    if not rows:
        return []
    return ["### Test completion" if len(named_runs) > 1 else "## Test completion", "",
            "How counterexamples became tests. *Single-answer* is Z3's verdict on the whole spec: when "
            "yes, every counterexample is a sound complete test and no per-test query runs. Otherwise "
            "each counterexample costs one uniqueness query and becomes an *incomplete* test (input "
            "only, judged by the constraints) when another output is also valid. *Unchecked* tests "
            "were made complete without that guarantee: the legacy ablation, or a spec outside the "
            "in-process scope. Medians per seed.", "",
            md_table(["spec", "run", "single-answer", "complete tests", "incomplete tests",
                      "seeds with incomplete", "uniqueness queries", "unchecked"], rows), ""]


def harvest_section(named_runs, specs):
    """What the counterexample path did — the evidence a counterexample mode ran.

    One *event* is a verification that found the candidate wrong. `:single` returns one
    witness per event; `:per_constraint` one per violated constraint. Omitted for runs
    stored before the columns existed and for runs without test-based verification."""
    rows = []
    for s in specs:
        for nm, run in named_runs:
            d = run.rows.get(s, {})
            recs = [r for r in d.values() if r.get("cex_mode", "") in ("single", "per_constraint")]
            if not recs:
                continue
            ev = [num(r["cex_events"]) for r in recs]
            added = [num(r["cex_tests_added"]) for r in recs]
            per_ev = [a / e for a, e in zip(added, ev) if e > 0]
            multi = [num(r["cex_multi_events"]) / e for r, e in zip(recs, ev) if e > 0]
            modes = sorted({r["cex_mode"] for r in recs})
            fb = sum(1 for r in recs if r.get("cex_fallback") == "1")
            rows.append([f"`{s}`", f"`{nm}`", "/".join(modes) + (f" ({fb} fell back)" if fb else ""),
                         fx(med(ev), 0), fx(med([num(r["cex_witnesses"]) for r in recs]), 0),
                         fx(med(added), 0), fx(med(per_ev), 2), fx(med(multi), 2),
                         fx(med([num(r["cex_dup"]) for r in recs]), 0),
                         fx(med([num(r["cex_no_output"]) for r in recs]), 0),
                         fx(med([num(r["cex_capped"]) for r in recs]), 0),
                         fx(med([num(r["z3_constraint_checks"]) for r in recs]), 0)])
    if not rows:
        return []
    return ["### Counterexample harvest" if len(named_runs) > 1 else "## Counterexample harvest", "",
            "What each verification that found a candidate wrong turned into. *Events*: such "
            "verifications. *Witnesses*: violation inputs they returned (one per event in `single` "
            "mode, one per violated constraint in `per_constraint`). *Tests/event*: tests added per "
            "event; above 1 only if the per-constraint path adds tests. *Multi share*: fraction of "
            "events adding two or more. *Dup*: witness inputs already tests or repeated within the "
            "event. *No output*: completion failed (kept as incomplete tests). Medians per seed.", "",
            md_table(["spec", "run", "mode", "events", "witnesses", "tests added", "tests/event",
                      "multi share", "dup", "no output", "capped", "constraint checks"], rows), ""]


def guided_section(named_runs, specs):
    """What the guided mutation path did (GuidedPatchMutation) — the evidence it ran.

    Omitted for runs without the path (mode `none`) and runs stored before the columns."""
    rows = []
    for s in specs:
        for nm, run in named_runs:
            d = run.rows.get(s, {})
            recs = [r for r in d.values() if r.get("guided_mode", "none") not in ("none", "")]
            if not recs:
                continue
            g = lambda k: [num(r[k]) for r in recs]
            share = [num(r["guided_time_s"]) / num(r["elapsed_s"]) for r in recs if num(r["elapsed_s"]) > 0]
            rows.append([f"`{s}`", f"`{nm}`", "/".join(sorted({r["guided_mode"] for r in recs})),
                         fx(med(g("guided_attempts")), 0), fx(med(g("guided_applied")), 0),
                         fx(med(g("guided_analyses")), 0), fx(med(g("guided_site_builds")), 0),
                         fx(med(g("guided_cache_hits")), 0), fx(med(g("guided_ineligible")), 0),
                         fx(med(g("guided_budget_skip")), 0),
                         fx(med(g("guided_no_site")), 0) + " / " + fx(med(g("guided_no_patch")), 0),
                         fx(med(g("guided_depth_reject")), 0), fx(med(share), 2),
                         " / ".join(fx(med([num(r.get(k, "")) for r in recs if r.get(k, "") != ""]), 1)
                                    for k in ("guided_t_localize", "guided_t_build", "guided_t_validate"))])
    if not rows:
        return []
    return ["### Guided mutation" if len(named_runs) > 1 else "## Guided mutation", "",
            "What the guided path did per seed (medians). *Attempts*: mutations that tried it "
            "(probability `guided_rate`); *applied*: children it wrote (a guarded patch, or a random "
            "subtree at the same site for the placebo); every other attempt fell back to subtree "
            "mutation. *Analyses* / *site builds*: localizations and patch lists computed (one budget "
            "token each); *cache hits*: attempts served from the per-program cache; *ineligible*: "
            "parent test-perfect or passing too few tests; *budget skips*: out of tokens this "
            "generation. *Time share*: guided time / elapsed time. *Phases*: seconds per seed in "
            "localization / patch building / validation (runs from 2026-09-28 on).", "",
            md_table(["spec", "run", "mode", "attempts", "applied", "analyses", "site builds", "cache hits",
                      "ineligible", "budget skips", "no site / no patch", "depth rejects", "time share",
                      "phases (s)"],
                     rows), ""]


# ── comparison ───────────────────────────────────────────────────────────────

SECONDARY = [
    # key, label, higher_is_better, subset ("all" matched pairs | "both" = both solved)
    ("val_acc_final", "final champion accuracy", True, "all"),
    ("auc_acc", "AUC of accuracy over time", True, "all"),
    ("stall_fraction", "stall fraction", False, "all"),
    ("time_to_solve_s", "time to solve (s)", False, "both"),
    ("generations", "generations to solve", False, "both"),
    ("z3_total", "Z3 calls to solve", False, "both"),
    ("program_size", "program size", False, "both"),
    ("z3_total_all", "Z3 calls per run (all seeds)", False, "all"),
]


def _problem_forms(path):
    """The spec's declarations and constraints (everything but the grammar), whitespace-normalized."""
    text = re.sub(r";[^\n]*", "", open(os.path.join(ROOT, path), encoding="utf-8").read())
    forms, depth, start = [], 0, None
    for i, c in enumerate(text):
        if c == "(":
            depth, start = depth + 1, (i if depth == 0 else start)
        elif c == ")":
            depth -= 1
            if depth == 0:
                f = " ".join(text[start:i + 1].replace("(", " ( ").replace(")", " ) ").split())
                if f.split()[1] in ("set-logic", "declare-var", "define-fun", "constraint"):
                    forms.append(f)
    return forms


def compatibility(base, cand, spec):
    """Problems that exclude pairing this spec across two runs. A grammar variant (`run.jl --variant`)
    pairs with the plain spec when only the grammar differs: same declarations and constraints."""
    mb, mc = base.spec_meta(spec), cand.spec_meta(spec)
    excl = []
    for k, what in (("sha256", "spec file"), ("budget", "budget"), ("pop_size", "population size"),
                    ("max_depth", "initial depth"), ("depth_cap", "depth cap")):
        if mb.get(k) != mc.get(k):
            if (k == "sha256" and (mb.get("variant") or mc.get("variant"))
                    and _problem_forms(mb["path"]) == _problem_forms(mc["path"])):
                continue
            excl.append(f"{what} differs ({mb.get(k)} vs {mc.get(k)})")
    return excl


MIN_FREE_MB = 1500   # bench/common.jl: a seed started below this ran under memory pressure
CPU_EXCESS_CORES = 3.0   # bench/common.jl: load beyond the run's own workers, in cores


def health_notes(run):
    """Seeds whose conditions make their timing or status suspect. Empty for runs
    stored before the columns existed (they cannot be checked, not known to be clean)."""
    notes = []
    rows = [r for d in run.rows.values() for r in d.values()]
    low = [r for r in rows if r.get("sys_free_mb", "") != "" and num(r["sys_free_mb"]) < MIN_FREE_MB]
    waited = [r for r in rows if num(r.get("mem_wait_s")) > 1]
    refail = [r for r in rows if r["status"] == "error" and r.get("error", "").startswith("re-verification failed")]
    threads = num(run.man.get("cpu_threads"))
    jobs = num(run.man.get("jobs"))
    busy = [num(r.get("cpu_busy")) for r in rows if r.get("cpu_busy", "") != ""]
    if busy and threads > 0 and jobs > 0:
        own = jobs / threads
        hot = [b for b in busy if (b - own) * threads > CPU_EXCESS_CORES]
        if hot:
            notes.append(f"`{run.name}`: {len(hot)} of {len(busy)} seed(s) ran while the machine was busier "
                         f"than its {int(jobs)} workers explain (more than {CPU_EXCESS_CORES:.0f} extra cores; "
                         f"median load {np.median(busy):.2f} vs {own:.2f} expected) — another process "
                         f"competed for the CPU, so their wall-clock timing is suspect.")
    if low:
        notes.append(f"`{run.name}`: {len(low)} seed(s) started with under {MIN_FREE_MB} MB free "
                     f"(minimum {min(num(r['sys_free_mb']) for r in low):.0f} MB) — their wall-clock "
                     f"timing may be depressed by memory pressure.")
    if waited:
        notes.append(f"`{run.name}`: {len(waited)} seed(s) waited for memory before starting "
                     f"(up to {max(num(r['mem_wait_s']) for r in waited):.0f} s; outside the timed region).")
    if refail:
        notes.append(f"`{run.name}`: {len(refail)} claimed solution(s) could not be re-verified (z3 failed "
                     f"to run) — recorded as `error` and dropped from comparisons, not as `unverified`.")
    return notes


def run_warnings(base, cand):
    w = []
    b, c = base.man, cand.man
    if b.get("jobs") != c.get("jobs"):
        w.append(f"different parallelism (`--jobs` {b.get('jobs')} vs {c.get('jobs')}). Budgets are wall-clock, "
                 f"so the busier run had less compute per seed — rerun one of them with matching `--jobs`.")
    if b.get("host") != c.get("host"):
        w.append(f"different machines ({b.get('host')} vs {c.get('host')}); wall-clock budgets are not comparable.")
    if b.get("val_n") != c.get("val_n"):
        w.append(f"different validation battery sizes ({b.get('val_n')} vs {c.get('val_n')}).")
    for r in (base, cand):
        if r.man.get("code_changed_during_run"):
            w.append(f"`{r.name}` mixes seeds from different source code (`--allow-code-change`).")
        if r.man.get("mixed_jobs"):
            w.append(f"`{r.name}` was resumed with a different `--jobs`.")
        if r.duplicates:
            w.append(f"`{r.name}` has duplicate seed rows (kept the first): {r.duplicates[:5]}")
        w += health_notes(r)
    return w


def compare(base, cands, specs_filter, alt, alpha, make_figs):
    tag = f"{base.name}__vs__{'+'.join(c.name for c in cands)}"
    outdir = os.path.join(CMP_ROOT, tag)
    os.makedirs(outdir, exist_ok=True)

    results = []        # one per (candidate, spec)
    notes = []
    for cand in cands:
        shared = sorted(set(base.specs()) & set(cand.specs()))
        if specs_filter:
            shared = [s for s in shared if s in specs_filter]
        only = sorted(set(base.specs()) ^ set(cand.specs()))
        if only:
            notes.append(f"specs in only one of `{base.name}` / `{cand.name}` (not compared): {', '.join(only)}")
        for s in shared:
            excl = compatibility(base, cand, s)
            if excl:
                notes.append(f"`{s}` excluded for `{cand.name}`: " + "; ".join(excl))
                continue
            rb, rc = base.rows[s], cand.rows[s]
            seeds_all = set(rb) | set(rc)
            matched = sorted(sd for sd in set(rb) & set(rc)
                             if rb[sd]["status"] in PAIRABLE and rc[sd]["status"] in PAIRABLE)
            dropped = sorted(seeds_all - set(matched))
            B = [base.run(s, sd) for sd in matched]
            C = [cand.run(s, sd) for sd in matched]
            b = sum(1 for x, y in zip(B, C) if x.solved and not y.solved)
            c = sum(1 for x, y in zip(B, C) if y.solved and not x.solved)
            both = sum(1 for x, y in zip(B, C) if x.solved and y.solved)
            budget = num(base.spec_meta(s).get("budget"))
            res = {
                "fallback": False,
                "cand": cand, "spec": s, "n": len(matched), "matched": matched, "dropped": dropped,
                "base_solved": sum(r.solved for r in B), "cand_solved": sum(r.solved for r in C),
                "b": b, "c": c, "both": both, "budget": budget, "B": B, "C": C,
                "p_mc": mcnemar(b, c, alt), "min_p": min_achievable_p(b + c, alt),
                "or": odds_ratio(b, c), "p_lr": logrank(B, C, alt), "hr": peto_hazard_ratio(B, C),
                "p_lr_gen": logrank(B, C, alt, "gen"), "hr_gen": peto_hazard_ratio(B, C, "gen"),
                "b_only_seeds": [sd for sd, x, y in zip(matched, B, C) if x.solved and not y.solved],
                "c_only_seeds": [sd for sd, x, y in zip(matched, B, C) if y.solved and not x.solved],
                "unverified": [(nm, sd) for nm, rr in ((base.name, rb), (cand.name, rc))
                               for sd in matched if rr[sd]["status"] == "unverified"],
            }
            # secondary measures
            sec = {}
            both_idx = [i for i, (x, y) in enumerate(zip(B, C)) if x.solved and y.solved]
            for key, label, hib, subset in SECONDARY:
                idx = both_idx if subset == "both" else range(len(matched))
                if key == "auc_acc":
                    xb = [auc_acc(B[i], budget) for i in idx]; xc = [auc_acc(C[i], budget) for i in idx]
                elif key == "stall_fraction":
                    xb = [stall_fraction(B[i]) for i in idx]; xc = [stall_fraction(C[i]) for i in idx]
                elif key in ("generations", "z3_total"):
                    # Measured AT the solve. The run's own totals also include the rest of
                    # the round in which it solved -- the search only notices a solve at
                    # round end and keeps checking (and harvesting from) other candidates
                    # until then -- which overstates cost, unevenly across arms. Runs
                    # imported without trajectories fall back to run totals.
                    def pick(R, rows, i):
                        r = R[i]
                        if key == "generations" and r.solved and r.solve_gen > 0:
                            return float(r.solve_gen)
                        v = at_solve(r, "z3") if key == "z3_total" else math.nan
                        if math.isnan(v):
                            res["fallback"] = True
                            return num(rows[matched[i]][key])
                        return v
                    xb = [pick(B, rb, i) for i in idx]; xc = [pick(C, rc, i) for i in idx]
                elif key == "z3_total_all":
                    xb = [num(rb[matched[i]]["z3_total"]) for i in idx]
                    xc = [num(rc[matched[i]]["z3_total"]) for i in idx]
                else:
                    xb = [num(rb[matched[i]][key]) for i in idx]; xc = [num(rc[matched[i]][key]) for i in idx]
                sec[key] = paired_test(xb, xc, alt, hib)
            res["sec"] = sec
            results.append(res)

    if not results:
        sys.exit("error: nothing to compare — no spec is shared and compatible between these runs.\n  " +
                 "\n  ".join(notes))

    adj = holm([r["p_mc"] for r in results])
    for r, a in zip(results, adj):
        r["p_holm"] = a

    # pooled per candidate
    pooled = {}
    for cand in cands:
        rs = [r for r in results if r["cand"] is cand]
        B_, C_ = sum(r["b"] for r in rs), sum(r["c"] for r in rs)
        het = [[r["b"], r["c"]] for r in rs if r["b"] + r["c"] > 0]
        p_het = math.nan
        small = False
        if len(het) >= 2:
            try:
                chi = stats.chi2_contingency(np.array(het))
                p_het = float(chi.pvalue)
                small = bool((chi.expected_freq < 5).any())
            except ValueError:
                # every discordant pair points the same way in every spec: no heterogeneity to test
                p_het = 1.0
        pooled[cand.name] = {"b": B_, "c": C_, "n": sum(r["n"] for r in rs), "p": mcnemar(B_, C_, alt),
                             "or": odds_ratio(B_, C_), "p_het": p_het, "het_small": small, "k": len(rs)}

    ledger_n = update_ledger(base, cands, results, pooled, alt)
    write_comparison(base, cands, results, pooled, notes, alt, alpha, outdir, ledger_n, make_figs)
    print_comparison(base, cands, results, pooled, notes, alt, alpha, outdir, ledger_n)


def verdict(r, alpha, alt):
    d = r["b"] + r["c"]
    if r["n"] and (r["base_solved"] in (0, r["n"])) and (r["cand_solved"] in (0, r["n"])) \
            and r["base_solved"] == r["cand_solved"]:
        v = "solve rate cannot discriminate: both runs at " + ("100%" if r["base_solved"] else "0%")
        if r["base_solved"] and not math.isnan(r["p_lr"]) and r["p_lr"] < alpha:
            hr = r["hr"][0]
            faster = "candidate" if hr > 1 else "baseline"
            return v + (f"; but time-to-solve does — {faster} faster (log-rank {pe(r['p_lr'])}, "
                        f"hazard ratio {fx(hr)}; secondary, not Holm-corrected)")
        return v + " — change the budget"
    if r["p_holm"] < alpha:
        better = r["c"] > r["b"]
        return f"**candidate {'better' if better else 'worse'}** ({r['c']} vs {r['b']} discordant seeds, significant after Holm)"
    if r["min_p"] > alpha:
        return (f"underpowered: only {d} discordant seed{'s' if d != 1 else ''} — even a clean sweep "
                f"could not reach p < {alpha} (best possible {pe(r['min_p'])}); add seeds")
    if r["p_mc"] < alpha:
        return f"nominal p < {alpha} but not after Holm correction — treat as unconfirmed"
    return "no significant difference"


def write_comparison(base, cands, results, pooled, notes, alt, alpha, outdir, ledger_n, make_figs):
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    L = [f"# `{base.name}` vs {', '.join(f'`{c.name}`' for c in cands)}", "",
         f"generated {now} · alternative **{alt}** (`greater` = candidate better) · α = {alpha} · "
         f"Holm correction across {len(results)} primary test{'s' if len(results) != 1 else ''}", ""]

    for cand in cands:
        rs = [r for r in results if r["cand"] is cand]
        L += [f"## `{cand.name}` against baseline `{base.name}`", "", "### Verdict", ""]
        L += [md_table(["spec", "pairs", "baseline solved", "candidate solved", "cand-only", "base-only",
                        "McNemar p", "Holm p", "odds ratio [95% CI]", "log-rank p", "hazard ratio [95% CI]"],
                       [[f"`{r['spec']}`", r["n"], f"{r['base_solved']} ({100 * r['base_solved'] / max(r['n'], 1):.0f}%)",
                         f"{r['cand_solved']} ({100 * r['cand_solved'] / max(r['n'], 1):.0f}%)", r["c"], r["b"],
                         fp(r["p_mc"]), fp(r["p_holm"]), fci(*r["or"]), fp(r["p_lr"]), fci(*r["hr"])]
                        for r in rs]), ""]
        L += [f"- `{r['spec']}` — {verdict(r, alpha, alt)}" for r in rs] + [""]
        gen_lines = [f"`{r['spec']}` log-rank {pe(r['p_lr_gen'])}, hazard ratio {fci(*r['hr_gen'])}"
                     for r in rs if not math.isnan(r["p_lr_gen"])]
        if gen_lines:
            L += ["**Solve speed in generations** (log-rank on the generation scale; unsolved runs "
                  "censored at the generation they reached; secondary, not Holm-corrected): "
                  + "; ".join(gen_lines) + ". The table's log-rank is on wall-clock time. An arm can "
                  "need fewer generations yet not be faster, if each generation costs more. "
                  "**Indicative only:** budgets are wall-clock, so the censoring here is informative "
                  "(struggling runs grow larger test sets, slow down and reach fewer generations). "
                  "The unbiased per-generation comparison is *generations to solve* over seeds both "
                  "arms solved, in the secondary table.", ""]
        pc = pooled[cand.name]
        het = ("—" if math.isnan(pc["p_het"]) else fp(pc["p_het"]) +
               (" (small counts: approximate)" if pc["het_small"] else ""))
        L += [f"**Pooled over {pc['k']} spec{'s' if pc['k'] != 1 else ''}:** {pc['n']} pairs, "
              f"{pc['c']} candidate-only vs {pc['b']} baseline-only, McNemar {pe(pc['p'])}, "
              f"odds ratio {fci(*pc['or'])}. Heterogeneity across specs p = {het}.", ""]
        if not math.isnan(pc["p_het"]) and pc["p_het"] < 0.1:
            L += ["> ⚠ The effect differs between specs. Read the per-spec rows; the pooled figure averages "
                  "opposing effects.", ""]
        L += ["### Secondary measures", "",
              "Paired Wilcoxon signed-rank tests. *r* is the matched-pairs rank-biserial correlation, "
              "positive when the candidate's value is higher. Rows marked *both solved* use only seeds "
              "both runs solved; generations and Z3 calls to solve are counted up to the solve itself, "
              "not the end of the round in which it happened.", ""]
        if any(r["fallback"] for r in rs):
            L += ["> Some runs have no trajectories (imported), so their Z3 calls to solve are run "
                  "totals, which include the rest of the solving round.", ""]
        sec_rows = []
        for r in rs:
            for key, label, hib, subset in SECONDARY:
                t = r["sec"][key]
                if t["n"] == 0:
                    continue
                sec_rows.append([f"`{r['spec']}`", label + (" · *both solved*" if subset == "both" else ""),
                                 t["n"], fx(t["base_med"], 3), fx(t["cand_med"], 3), fx(t["med_diff"], 3),
                                 "higher" if hib else "lower", fp(t["p"]), fx(t["r"], 2)])
        L += [md_table(["spec", "measure", "n", "baseline median", "candidate median", "median Δ",
                        "better is", "p", "r"], sec_rows), ""]
        L += ["### Solver spend per seed (medians, all matched seeds)", ""]
        sp_rows = []
        for r in rs:
            for nm, run_, R in ((base.name, base, r["B"]), (cand.name, cand, r["C"])):
                rows = run_.rows[r["spec"]]
                sp_rows.append([f"`{r['spec']}`", f"`{nm}`"] +
                               [fx(med([num(rows[sd].get(c)) for sd in r["matched"]]), 0) for c in
                                ("z3_constraint_checks", "z3_cex_queries", "z3_complete_output",
                                 "z3_output_unique", "z3_subprocess", "z3_total")])
        L += [md_table(["spec", "run", "constraint checks", "counterexample", "output completion",
                        "output uniqueness", "subprocess", "total"], sp_rows), ""]
        L += completion_section([(base.name, base)] + [(c.name, c) for c in cands],
                                sorted({r["spec"] for r in rs}))
        L += harvest_section([(base.name, base)] + [(c.name, c) for c in cands],
                             sorted({r["spec"] for r in rs}))
        L += guided_section([(base.name, base)] + [(c.name, c) for c in cands],
                            sorted({r["spec"] for r in rs}))
        L += ["### Seeds that disagree", ""]
        for r in rs:
            L += [f"- `{r['spec']}` — solved only by the candidate: {r['c_only_seeds'] or 'none'}; "
                  f"only by the baseline: {r['b_only_seeds'] or 'none'}"]
        L += [""]

    L += ["## Compatibility", ""]
    comp = [["", f"`{base.name}`"] + [f"`{c.name}`" for c in cands]]
    for key, lab in (("arm", "arm"), ("arm_hash", "arm config"), ("code_sha256", "source code"),
                     ("git_sha", "git commit"), ("git_dirty", "uncommitted changes"), ("host", "host"),
                     ("jobs", "parallel jobs"), ("val_n", "validation battery"), ("created_utc", "created")):
        vals = [str(base.man.get(key, "?"))[:16]] + [str(c.man.get(key, "?"))[:16] for c in cands]
        comp.append([lab] + vals)
    L += [md_table(comp[0], comp[1:]), ""]
    speed = []
    for r in results:
        for nm, run_ in ((base.name, base), (r["cand"].name, r["cand"])):
            rows = run_.rows[r["spec"]]
            v = [num(rows[sd]["elapsed_s"]) / max(num(rows[sd]["generations"]), 1) for sd in r["matched"]]
            speed.append([f"`{r['spec']}`", f"`{nm}`", fx(1000 * med(v), 1)])
    L += ["Median milliseconds per generation — a load or machine difference shows up here as well as "
          "an algorithmic one:", "", md_table(["spec", "run", "ms / generation"], speed), ""]
    warns = []
    for c in cands:
        warns += run_warnings(base, c)
    for r in results:
        if r["unverified"]:
            warns.append(f"`{r['spec']}`: {len(r['unverified'])} `unverified` seed(s) {r['unverified'][:5]} — the "
                         f"search claimed a solution the independent Z3 check rejected (soundness bug).")
        if r["dropped"]:
            warns.append(f"`{r['spec']}` / `{r['cand'].name}`: seeds dropped from both runs (crashed, errored, or "
                         f"present in only one): {r['dropped'][:20]}{' …' if len(r['dropped']) > 20 else ''}")
    L += (["### Warnings", ""] + [f"- ⚠ {w}" for w in warns] + [""]) if warns else ["No compatibility warnings.", ""]
    if notes:
        L += ["### Notes", ""] + [f"- {n}" for n in notes] + [""]

    L += ["## Multiple comparisons", "",
          f"This is comparison **#{ledger_n}** recorded against baseline `{base.name}` "
          f"(code `{base.man['code_sha256']}`). Every idea tested against the same baseline is another draw: "
          f"at α = {alpha}, one false positive is expected in roughly every {round(1 / alpha)} comparisons "
          f"of ideas that do nothing. Across {ledger_n} comparison{'s' if ledger_n != 1 else ''}, a family-wise "
          f"α = {alpha} needs p < {alpha / ledger_n:.4f} (Bonferroni) on the pooled test. Full list: "
          f"`results/comparisons/ledger.csv`.", ""]

    if make_figs:
        L += ["## Figures", ""]
        runs_all = [base] + cands
        for s in sorted({r["spec"] for r in results}):
            seeds = set.intersection(*[{sd for sd, row in rr.rows[s].items() if row["status"] in PAIRABLE}
                                       for rr in runs_all if s in rr.rows])
            if not seeds:
                continue
            series = {rr.name: [rr.run(s, sd) for sd in sorted(seeds)] for rr in runs_all if s in rr.rows}
            budget = num(base.spec_meta(s).get("budget"))
            r0 = next(r for r in results if r["spec"] == s)
            note = (f"McNemar {cands[0].name}-only {r0['c']} vs {base.name}-only {r0['b']}, {pe(r0['p_mc'])} · "
                    f"log-rank {pe(r0['p_lr'])} ({alt})") if len(cands) == 1 else ""
            note_gen = (f"log-rank on generations {pe(r0['p_lr_gen'])} ({alt})"
                        if len(cands) == 1 and not math.isnan(r0["p_lr_gen"]) else "")
            figures.all_figures(s, series, budget, len(seeds), os.path.join(outdir, "figures", s),
                                note=note, note_gen=note_gen)
            L += [f"### `{s}`", "", f"![](figures/{s}/overview.png)", "",
                  f"Left column wall-clock, right column generations. Individual figures, each in a "
                  f"`*_time` and a `*_gen` version (PDF for print, PNG preview), in `figures/{s}/`.", ""]

    with open(os.path.join(outdir, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    with open(os.path.join(outdir, "stats.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["baseline", "candidate", "spec", "pairs", "base_solved", "cand_solved", "cand_only",
                    "base_only", "p_mcnemar", "p_holm", "odds_ratio", "or_lo", "or_hi", "p_logrank", "hazard_ratio",
                    "hr_lo", "hr_hi", "p_logrank_gen", "hazard_ratio_gen", "hr_gen_lo", "hr_gen_hi",
                    "alternative"] + [f"{k}_{x}" for k, *_ in SECONDARY for x in
                                                       ("n", "base_med", "cand_med", "med_diff", "p", "r")])
        for r in results:
            w.writerow([base.name, r["cand"].name, r["spec"], r["n"], r["base_solved"], r["cand_solved"], r["c"],
                        r["b"], r["p_mc"], r["p_holm"], *r["or"], r["p_lr"], *r["hr"], r["p_lr_gen"],
                        *r["hr_gen"], alt] +
                       [r["sec"][k][x] for k, *_ in SECONDARY for x in ("n", "base_med", "cand_med", "med_diff",
                                                                       "p", "r")])


def print_comparison(base, cands, results, pooled, notes, alt, alpha, outdir, ledger_n):
    print(f"\n{base.name} (baseline)  vs  {', '.join(c.name for c in cands)}   [{alt}, alpha {alpha}, "
          f"Holm over {len(results)}]")
    for cand in cands:
        print(f"\n  {cand.name}")
        print(f"  {'spec':<16}{'pairs':>6}{'base':>6}{'cand':>6}{'c-only':>8}{'b-only':>8}"
              f"{'McNemar':>10}{'Holm':>9}{'log-rank':>10}   verdict")
        for r in (x for x in results if x["cand"] is cand):
            v = verdict(r, alpha, alt).replace("**", "")
            print(f"  {r['spec']:<16}{r['n']:>6}{r['base_solved']:>6}{r['cand_solved']:>6}{r['c']:>8}{r['b']:>8}"
                  f"{fp(r['p_mc']):>10}{fp(r['p_holm']):>9}{fp(r['p_lr']):>10}   {v}")
        pc = pooled[cand.name]
        print(f"  {'pooled':<16}{pc['n']:>6}{'':>12}{pc['c']:>8}{pc['b']:>8}{fp(pc['p']):>10}"
              f"   heterogeneity p {fp(pc['p_het'])}")
    for c in cands:
        for w in run_warnings(base, c):
            print(f"  ! {w}")
    for n in notes:
        print(f"  note: {n}")
    print(f"\n  comparison #{ledger_n} against {base.name}")
    print(f"  report: {os.path.relpath(os.path.join(outdir, 'report.md'), ROOT)}")


def update_ledger(base, cands, results, pooled, alt):
    """Record this comparison; return how many distinct comparisons exist against this baseline + code."""
    path = os.path.join(CMP_ROOT, "ledger.csv")
    os.makedirs(CMP_ROOT, exist_ok=True)
    rows = []
    if os.path.isfile(path):
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for cand in cands:
        key = (base.name, base.man["code_sha256"], cand.name, cand.man["code_sha256"], alt)
        rs = [r for r in results if r["cand"] is cand]
        entry = {"utc": now, "baseline": base.name, "baseline_code": base.man["code_sha256"],
                 "candidate": cand.name, "candidate_code": cand.man["code_sha256"], "alternative": alt,
                 "specs": ";".join(r["spec"] for r in rs), "pooled_p": pooled[cand.name]["p"],
                 "min_holm_p": min(r["p_holm"] for r in rs)}
        rows = [r for r in rows if (r["baseline"], r["baseline_code"], r["candidate"], r["candidate_code"],
                                    r["alternative"]) != key]
        rows.append(entry)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["utc", "baseline", "baseline_code", "candidate", "candidate_code",
                                          "alternative", "specs", "pooled_p", "min_holm_p"])
        w.writeheader()
        w.writerows(rows)
    return sum(1 for r in rows if r["baseline"] == base.name and r["baseline_code"] == base.man["code_sha256"])


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Report on one stored run, or compare a baseline with candidates.")
    ap.add_argument("runs", nargs="+", help="RUN, or BASELINE CANDIDATE [CANDIDATE ...]")
    ap.add_argument("--specs", default="")
    ap.add_argument("--alternative", default="two-sided", choices=["two-sided", "greater", "less"])
    ap.add_argument("--alpha", type=float, default=0.05)
    ap.add_argument("--no-figures", action="store_true")
    a = ap.parse_args()
    runs = [StoredRun(x) for x in a.runs]
    names = [r.name for r in runs]
    if len(set(names)) != len(names):
        sys.exit("error: the same run was given twice")
    sf = set(a.specs.split(",")) if a.specs else None
    if len(runs) == 1:
        specs = [s for s in runs[0].specs() if not sf or s in sf]
        single_report(runs[0], specs, not a.no_figures)
    else:
        compare(runs[0], runs[1:], sf, a.alternative, a.alpha, not a.no_figures)


if __name__ == "__main__":
    main()
