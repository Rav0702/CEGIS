#!/usr/bin/env python3
"""
bench/scaling.py -- the pre-registered scaling analysis (BENCHMARK_METHODOLOGY.md §15e).

Pairs `baseline-lex` with `lex-percon` per spec across the stored runs that hold each
spec, and asks whether the effect grows with n for the separable family (above_n) and
stays flat for the coupled family (max_n).

    bench/.venv/Scripts/python bench/scaling.py

Writes results/comparisons/scaling/{report.md, scaling.csv, effect_vs_n.{png,pdf}}.
Primary family (Holm): above4, above5, above6, max5, max6, max7. above7 is exploratory
(10 seeds at 900 s) and reported descriptively only.
"""
import csv
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import diagnose as D  # noqa: E402
import figures as F   # noqa: E402

ROOT = D.ROOT
OUT = os.path.join(ROOT, "results", "comparisons", "scaling")

# spec -> (family, n, baseline run, candidate run, primary?)
PLAN = [
    ("above4", "above_n", 4, "lex-multi-v2", "percon-multi-v2", True),
    ("above5", "above_n", 5, "scale-lex", "scale-percon", True),
    ("above6", "above_n", 6, "scale-lex", "scale-percon", True),
    ("above7", "above_n", 7, "scale-lex", "scale-percon", False),
    ("max5", "max_n", 5, "lex-core-v2", "percon-core-v2", True),
    ("max6", "max_n", 6, "scale-lex", "scale-percon", True),
    ("max7", "max_n", 7, "scale-lex", "scale-percon", True),
]


def log_or(b, c):
    """Log conditional odds ratio with the 0.5 continuity correction, and its 95% CI
    (so a clean sweep still has a finite point for the trend figure)."""
    lo = math.log((c + 0.5) / (b + 0.5))
    se = math.sqrt(1 / (c + 0.5) + 1 / (b + 0.5))
    return lo, lo - 1.96 * se, lo + 1.96 * se


def main():
    runs = {}
    rows = []
    for spec, fam, n, bname, cname, primary in PLAN:
        for nm in (bname, cname):
            if nm not in runs and os.path.isdir(os.path.join(D.RUNS_ROOT, nm)):
                runs[nm] = D.StoredRun(nm)
        if bname not in runs or cname not in runs:
            print(f"  skip {spec}: run missing")
            continue
        B_, C_ = runs[bname], runs[cname]
        if spec not in B_.rows or spec not in C_.rows:
            print(f"  skip {spec}: not in both runs")
            continue
        excl = D.compatibility(B_, C_, spec)
        if excl:
            print(f"  skip {spec}: " + "; ".join(excl))
            continue
        rb, rc = B_.rows[spec], C_.rows[spec]
        matched = sorted(s for s in set(rb) & set(rc)
                         if rb[s]["status"] in D.PAIRABLE and rc[s]["status"] in D.PAIRABLE)
        B = [B_.run(spec, s) for s in matched]
        C = [C_.run(spec, s) for s in matched]
        b = sum(1 for x, y in zip(B, C) if x.solved and not y.solved)
        c = sum(1 for x, y in zip(B, C) if y.solved and not x.solved)
        both = [i for i, (x, y) in enumerate(zip(B, C)) if x.solved and y.solved]
        gens = D.paired_test([B[i].solve_gen for i in both], [C[i].solve_gen for i in both],
                             "two-sided", False)
        ev = [D.num(rc[s].get("cex_events")) for s in matched]
        ad = [D.num(rc[s].get("cex_tests_added")) for s in matched]
        tpe = [a / e for a, e in zip(ad, ev) if e and e > 0]
        lor = log_or(b, c)
        hr = D.peto_hazard_ratio(B, C)
        rows.append(dict(
            spec=spec, family=fam, n=n, primary=primary, pairs=len(matched),
            budget=D.num(B_.spec_meta(spec).get("budget")),
            base_solved=sum(r.solved for r in B), cand_solved=sum(r.solved for r in C),
            b=b, c=c, p_mc=D.mcnemar(b, c, "two-sided"),
            log_or=lor[0], log_or_lo=lor[1], log_or_hi=lor[2],
            p_lr=D.logrank(B, C, "two-sided"), hr=hr[0], hr_lo=hr[1], hr_hi=hr[2],
            gens_base=gens["base_med"], gens_cand=gens["cand_med"], p_gens=gens["p"],
            tests_per_event=float(np.median(tpe)) if tpe else math.nan,
            runs=f"{bname} vs {cname}"))

    prim = [r for r in rows if r["primary"]]
    for r, a in zip(prim, D.holm([r["p_mc"] for r in prim])):
        r["p_holm"] = a
    for r in rows:
        r.setdefault("p_holm", math.nan)

    os.makedirs(OUT, exist_ok=True)
    keys = list(rows[0].keys()) if rows else []
    with open(os.path.join(OUT, "scaling.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)

    # ── trend figure: log OR and wall-clock HR against n, per family ──
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
    styles = {"above_n": (F.SLOTS[1][0], "o", "above_n (separable)"),
              "max_n": (F.SLOTS[0][0], "s", "max_n (coupled)")}
    for fam, (col, mk, lab) in styles.items():
        fr = sorted([r for r in rows if r["family"] == fam], key=lambda r: r["n"])
        if not fr:
            continue
        off = -0.06 if fam == "above_n" else 0.06
        for ax, (y, lo, hi) in zip(axes, (("log_or", "log_or_lo", "log_or_hi"), ("hr", "hr_lo", "hr_hi"))):
            xs = [r["n"] + off for r in fr]
            ys = [r[y] for r in fr]
            ax.plot(xs, ys, color=col, lw=1.4, alpha=0.6)
            for r, x in zip(fr, xs):
                filled = r["primary"]
                ax.errorbar([x], [r[y]], yerr=[[r[y] - r[lo]], [r[hi] - r[y]]], fmt=mk, color=col,
                            mfc=col if filled else "white", ms=6, capsize=3, lw=1.2,
                            label=lab if r is fr[0] else None)
    axes[0].axhline(0, color=F.INK_3, lw=0.8, ls=":")
    axes[1].axhline(1, color=F.INK_3, lw=0.8, ls=":")
    axes[1].set_yscale("log")
    axes[0].set_ylabel("log odds ratio of solving (percon vs lex)")
    axes[1].set_ylabel("wall-clock hazard ratio (percon vs lex)")
    for ax, t in zip(axes, ("solve-rate effect vs n", "time-to-solve effect vs n")):
        ax.set_xlabel("n (inputs = constraints of that kind)")
        ax.set_xticks([4, 5, 6, 7])
        ax.set_title(t, loc="left")
        ax.legend(loc="upper left")
    fig.text(0.01, -0.02, "95% CIs · hollow marker = exploratory (above7: 10 seeds, 900 s) · "
             "log OR with 0.5 continuity correction · above4, max5 from the v2 runs",
             fontsize=8, color=F.INK_3)
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(OUT, f"effect_vs_n.{ext}"), dpi=140, bbox_inches="tight")
    plt.close(fig)

    # ── report ──
    fmt = D.fx
    table = [[f"`{r['spec']}`", r["family"], r["n"], "primary" if r["primary"] else "exploratory",
              f"{r['budget']:.0f} s", r["pairs"], r["base_solved"], r["cand_solved"],
              f"{r['c']} : {r['b']}", D.fp(r["p_mc"]), D.fp(r["p_holm"]),
              f"{fmt(math.exp(r['log_or']))} [{fmt(math.exp(r['log_or_lo']))}, {fmt(math.exp(r['log_or_hi']))}]",
              f"{fmt(r['hr'])} [{fmt(r['hr_lo'])}, {fmt(r['hr_hi'])}]", D.fp(r["p_lr"]),
              f"{fmt(r['gens_base'], 0)} → {fmt(r['gens_cand'], 0)}", fmt(r["tests_per_event"])]
             for r in sorted(rows, key=lambda r: (r["family"], r["n"]))]
    L = ["# Scaling study: `lex-percon` vs `baseline-lex`", "",
         "Pre-registered in `BENCHMARK_METHODOLOGY.md` §15e. Hypothesis: the advantage grows with n for "
         "the separable family (`above_n`) and not for the coupled family (`max_n`). Primary test: per-spec "
         "exact McNemar, Holm across the six primary specs; the trend is read from the per-spec effects.", "",
         D.md_table(["spec", "family", "n", "role", "budget", "pairs", "lex", "percon", "percon-only : lex-only",
                     "McNemar p", "Holm p", "odds ratio [95% CI]", "wall-clock HR [95% CI]", "log-rank p",
                     "generations to solve (both solved)", "tests / verification"], table), "",
         "![](effect_vs_n.png)", "",
         "Odds ratio: conditional, from discordant seeds, with a 0.5 continuity correction for the CI "
         "(figure and table). HR > 1: `lex-percon` solves at a higher rate. Generations to solve: medians over "
         "seeds both arms solved (unbiased per-generation measure). Tests / verification: median over seeds, "
         "`lex-percon` only (1.0 would mean the per-constraint path adds nothing).", ""]
    with open(os.path.join(OUT, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L[:6]))
    print(f"\nreport: {os.path.relpath(os.path.join(OUT, 'report.md'), ROOT)}")


if __name__ == "__main__":
    main()
