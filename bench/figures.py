"""
bench/figures.py -- trajectory figures for stored runs. A library; bench/diagnose.py calls it.

Every metric is drawn twice: against WALL-CLOCK time and against GENERATIONS.
The two answer different questions. Budgets are wall-clock, so the time axis is
the fair comparison of what a run achieves; the generation axis shows what an
arm does with each generation, independent of how expensive a generation is.
An arm can win per generation and lose per second (max5: hybrid-ratio is ahead
per generation from ~50, but its generations are ~18% slower).

Every function takes `series`: an ordered dict {label: [Run, ...]}. Colour and
line style follow the series' POSITION (the baseline is always first, always
slot 1) rather than an arm name, because two stored runs can share an arm.

What is plotted, and why
------------------------
Accuracy = validation accuracy of the algorithm's CURRENT CHAMPION (the genome
it would return if stopped now), on a fixed battery shared by every run and
seed. Training fitness is measured against an evidence set that grows during a
run, so its curve is a sawtooth that is not comparable across runs; it gets
per-run diagnostic panels only.

Carry-forward, not survivors-only: a verified solve holds exactly 1.0, and a
finished run's test set, Z3 spend or champion holds its final value.
Aggregating only the runs still going drags late points towards the failures
and makes cumulative counts appear to fall.

Solve-rate curves are Kaplan-Meier estimates. On the time axis every unsolved
run is censored at the same budget, so the estimate equals the plain cumulative
fraction solved. On the generation axis unsolved runs are censored at whatever
generation they reached when time ran out -- different for every run -- and
only the product-limit estimator handles that without bias.

Median with an interquartile band; faint lines are single runs.
"""

import math
import os
import warnings

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

# Categorical slots from the validated reference palette (light mode). The first
# three validate all-pairs for colour-vision deficiency; line style is the
# redundant encoding that keeps series apart in greyscale print.
SLOTS = [
    ("#2a78d6", "-"),
    ("#eb6834", "--"),
    ("#1baf7a", "-."),
    ("#eda100", ":"),
    ("#e87ba4", (0, (5, 1, 1, 1))),
    ("#008300", (0, (3, 1))),
    ("#4a3aa7", (0, (1, 1))),
    ("#e34948", (0, (8, 2))),
]

INK, INK_2, INK_3, GRID = "#0b0b0b", "#52514e", "#8a8a86", "#e6e6e3"

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white", "savefig.facecolor": "white",
    "font.size": 9, "axes.titlesize": 10, "axes.labelsize": 9,
    "axes.edgecolor": INK_3, "axes.labelcolor": INK_2, "axes.titlecolor": INK,
    "xtick.color": INK_2, "ytick.color": INK_2, "text.color": INK,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
    "legend.frameon": False, "legend.fontsize": 8.5,
    "pdf.fonttype": 42, "ps.fonttype": 42,
})

AXIS_LABEL = {"time": "wall-clock (s)", "gen": "generation"}
AXIS_WORD = {"time": "time", "gen": "generation"}

# metric -> (Run attribute, y label, title, higher is better, cumulative)
SERIES_METRICS = {
    "tests":     ("tests", "accumulated tests", "test set growth"),
    "incomplete": ("inc", "incomplete tests", "incomplete tests (inputs with several valid outputs)"),
    "witnesses": ("wit", "banked witnesses", "witness bank size"),
    "z3":        ("z3", "Z3 calls (cumulative)", "solver spend"),
    "size":      ("size", "nodes", "champion size"),
}


def styles(series):
    return {label: SLOTS[i % len(SLOTS)] for i, label in enumerate(series)}


def num(s):
    if s is None or s == "":
        return math.nan
    if s in ("inf", "-inf"):
        return float(s)
    try:
        return float(s)
    except ValueError:
        return math.nan


class Run:
    """One seed: its run-level outcome and (if recorded) its per-generation trajectory."""

    def __init__(self, row, grows):
        grows = sorted(grows, key=lambda r: int(r["gen"]))
        self.seed = int(row["seed"])
        self.status = row["status"]
        self.solved = row["solved"] == "1"
        self.budget = num(row.get("budget_s"))
        self.tts = num(row.get("time_to_solve_s"))
        self.solve_gen = num(row.get("solve_gen"))
        col = lambda k: np.array([num(r.get(k)) for r in grows], dtype=float)
        self.gen = col("gen")
        self.t = col("elapsed_s")
        self.val = col("val_acc")
        self.train = col("best_fitness")
        self.size = col("best_size")
        self.tests = col("tests")
        self.inc = col("incomplete_tests")   # all-NaN for runs stored before the column existed
        self.wit = col("witnesses")
        self.z3 = col("z3_total")
        # Once a run holds a verified program it returns that program, which
        # satisfies every constraint on every input: exactly 1.0.
        self.val_eff = self.val.copy()
        if self.solved and self.solve_gen > 0:
            self.val_eff[self.gen >= self.solve_gen] = 1.0

    @property
    def has_trace(self):
        return len(self.gen) > 0

    @property
    def last_gen(self):
        return self.gen[-1] if len(self.gen) else 0

    def x(self, axis):
        return self.t if axis == "time" else self.gen

    def end(self, axis):
        """Where this run stopped on the given axis."""
        if axis == "time":
            return self.tts if self.solved else (self.t[-1] if len(self.t) else 0.0)
        return self.solve_gen if (self.solved and self.solve_gen > 0) else self.last_gen

    def survival(self, axis):
        """(time, event) for survival analysis on either axis; None if unusable."""
        if axis == "time":
            return (self.tts, self.solved)
        if not self.has_trace:
            return None
        return (self.end("gen"), self.solved)


def step_on_grid(x_obs, y_obs, grid):
    """Last observed value at or before each grid point; NaN before the first."""
    if len(x_obs) == 0:
        return np.full(len(grid), np.nan)
    idx = np.searchsorted(x_obs, grid, side="right") - 1
    out = y_obs[np.clip(idx, 0, None)].astype(float)
    out[idx < 0] = np.nan
    return out


def acc_on_grid(r, grid, axis):
    """Champion accuracy on a grid of either axis, carried forward past the run's end."""
    v = step_on_grid(r.x(axis), r.val_eff, grid)
    after = grid > r.end(axis) if axis == "gen" else grid >= r.end(axis)
    v[after] = 1.0 if r.solved else (r.val_eff[-1] if len(r.val_eff) else np.nan)
    return v


def acc_on_time_grid(r, grid):
    """Back-compatible alias used by diagnose.py's AUC measure."""
    return acc_on_grid(r, grid, "time")


def kaplan_meier(times, events, grid):
    """Fraction solved by each grid point: 1 - the product-limit survival estimate."""
    times = np.asarray(times, float)
    events = np.asarray(events, bool)
    n = len(times)
    if n == 0:
        return np.full(len(grid), np.nan)
    uniq = np.unique(times[events])
    surv, s, at_risk_times = [], 1.0, []
    for t in uniq:
        at_risk = np.sum(times >= t)
        d = np.sum((times == t) & events)
        if at_risk > 0:
            s *= 1.0 - d / at_risk
        surv.append(s)
        at_risk_times.append(t)
    out = np.zeros(len(grid))
    if uniq.size:
        idx = np.searchsorted(np.array(at_risk_times), grid, side="right") - 1
        vals = 1.0 - np.array(surv)
        out = np.where(idx >= 0, vals[np.clip(idx, 0, None)], 0.0)
    return out


def at_risk_on_grid(times, grid):
    """Runs still observed (neither solved nor censored earlier) at each grid point."""
    times = np.asarray(times, float)
    return np.array([np.sum(times >= g) for g in grid])


# On the generation axis a curve stops once fewer runs than this remain at risk.
def min_at_risk(n):
    return max(5, int(np.ceil(0.10 * n)))


# Spread shown around every median: the middle 95% of runs, i.e. the 2.5th-97.5th
# percentiles. That is the coverage of mean +/- 2 sigma under normality, without its
# failures here: these quantities are bounded (accuracy in [0, 1], counts >= 0, times
# <= budget) and skewed, so mean +/- 2 sigma would leave the range of possible values
# and follow outliers. Percentiles stay inside the data by construction.
BAND_LO, BAND_HI = 2.5, 97.5
BAND_TEXT = "95% of runs (2.5th-97.5th percentile, the counterpart of ±2σ)"


def band(mat):
    """Median and the middle-95% band across runs (rows), ignoring NaN."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return (np.nanmedian(mat, axis=0), np.nanpercentile(mat, BAND_LO, axis=0),
                np.nanpercentile(mat, BAND_HI, axis=0))


def _spread(v):
    """(median, low, high) of a 1-D sample with the band's percentiles."""
    v = np.asarray(v, float)
    v = v[~np.isnan(v)]
    if v.size == 0:
        return (np.nan, np.nan, np.nan)
    return (float(np.median(v)), float(np.percentile(v, BAND_LO)), float(np.percentile(v, BAND_HI)))


def _grid(series, axis, budget, full=False):
    """Time: [0, budget]. Generations: up to the 95th percentile of run length
    (the full length for survival curves, so no late solve is hidden)."""
    if axis == "time":
        return np.linspace(0, budget, 240)
    lasts = [r.last_gen for runs in series.values() for r in runs if r.has_trace]
    if not lasts:
        return np.arange(1, 3)
    G = int(max(lasts)) if full else int(np.percentile(lasts, 95))
    return np.arange(1, max(G, 2) + 1)


def _run_ends(runs, axis, grid):
    """Where each traced run stopped on this axis (time clipped to the budget: a
    censored run's last observation can fall in the round overrun)."""
    e = np.array([r.end(axis) for r in runs if r.has_trace], float)
    return np.minimum(e, grid[-1]) if axis == "time" else e


def _arm_end(runs, axis):
    """Where an arm actually finished: the point its last run stopped."""
    ends = [r.end(axis) for r in runs if r.has_trace]
    return max(ends) if ends else None


def _finish_marks(ax, ends, col, slot):
    """Where an arm's runs finished, as points on the x-axis: the 2.5th percentile and
    97.5th percentile (`|`) and the median (triangle), labelled, in a row of their own just
    above the axis (one row per arm, so arms do not overlap)."""
    (ex, ex_lo, ex_hi) = _spread(ends)
    if np.isnan(ex):
        return
    tr = ax.get_xaxis_transform()          # x in data, y in axes fraction
    y = 0.035 + 0.075 * slot
    ax.plot([ex_lo, ex_hi], [y, y], ls="none", marker="|", ms=7, mew=1.4, color=col,
            transform=tr, clip_on=False, zorder=6)
    ax.plot([ex], [y], ls="none", marker="^", ms=5.5, color=col, transform=tr,
            clip_on=False, zorder=6)
    for xv, txt in ((ex_lo, "2.5%"), (ex, "median"), (ex_hi, "97.5%")):
        ax.text(xv, y + 0.022, txt, transform=tr, fontsize=5.8, color=col, ha="center",
                va="bottom", zorder=6)


def _draw_band(ax, x, mat, style, label, traces=True, ends=None, slot=0):
    """Median line and middle-95% band across runs, drawn until the arm's last run ends
    (nothing is extrapolated past it), with the arm's finish points marked on the x-axis.

    `ends`: where each run stopped on this axis. The line and band stop at the last of
    them; `_finish_marks` shows the median finish and the 2.5th/97.5th percentile
    finishes. Faint single-run traces (when drawn) run to each run's own end. Returns the
    median line, the x where it stops, and the same (the axis extent)."""
    col, ls = style
    mat = np.array(mat, dtype=float)
    stop = None
    if ends is not None and len(ends) and not np.all(np.isnan(ends)):
        stop = float(np.nanmax(ends))
    if traces:
        for row in mat:
            ax.plot(x, row, color=col, lw=0.5, alpha=0.10, solid_capstyle="round")
    med, lo, hi = band(mat)
    if stop is not None:
        after = x > stop
        med, lo, hi = (np.where(after, np.nan, v) for v in (med, lo, hi))
    ax.fill_between(x, lo, hi, color=col, alpha=0.16, lw=0)
    ax.plot(x, med, color=col, ls=ls, lw=1.8, label=label, solid_capstyle="round")
    if ends is not None:
        _finish_marks(ax, ends, col, slot)
    end = stop if stop is not None else x[-1]
    return med, end, end


def _last(v):
    """Last non-NaN value (the end of a cut line)."""
    v = np.asarray(v, float)
    ok = ~np.isnan(v)
    return v[ok][-1] if ok.any() else np.nan


def _direct_labels(ax, items, xpos, st, min_gap_frac=0.06):
    """Ink-coloured end labels, nudged apart so they never collide."""
    if not items:
        return
    lo, hi = ax.get_ylim()
    gap = (hi - lo) * min_gap_frac
    items = sorted(items, key=lambda it: it[1])
    ys = [it[1] for it in items]
    for i in range(1, len(ys)):
        ys[i] = max(ys[i], ys[i - 1] + gap)
    over = ys[-1] - (hi - gap * 0.3)
    if over > 0:
        ys = [y - over for y in ys]
    for (text, _y, label), y in zip(items, ys):
        ax.annotate(text, xy=(xpos, y), xytext=(6, 0), textcoords="offset points",
                    va="center", ha="left", fontsize=8, color=INK_2, annotation_clip=False)
        ax.plot([xpos], [y], marker="o", ms=3.5, color=st[label][0], clip_on=False, zorder=5)


def _caption(ax, text, y=-0.25, width=115):
    # Wrapped: one long line widens the saved figure (bbox_inches="tight").
    import textwrap
    ax.text(0, y, "\n".join(textwrap.wrap(text, width)), transform=ax.transAxes,
            fontsize=7.5, color=INK_3, va="top")


def _save(fig, outdir, name):
    os.makedirs(outdir, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(outdir, f"{name}.{ext}"), dpi=200, bbox_inches="tight")
    plt.close(fig)


def _traced(series):
    return {k: [r for r in v if r.has_trace] for k, v in series.items() if any(r.has_trace for r in v)}


# --- the figures ---------------------------------------------------------------

def val_acc(spec, series, axis, budget, n, outdir=None, ax=None, strip_ax=None):
    """Champion accuracy against time or generations; the generation version has a
    'still searching' strip showing how much of each curve is carried forward."""
    series = _traced(series)
    if not series:
        return False
    own = ax is None
    if own:
        if axis == "gen":
            fig, (ax, strip_ax) = plt.subplots(2, 1, figsize=(6.4, 4.2), sharex=True,
                                               gridspec_kw={"height_ratios": [4, 1], "hspace": 0.08})
        else:
            fig, ax = plt.subplots(figsize=(6.4, 3.4))
    st = styles(series)
    grid = _grid(series, axis, budget, full=True)
    ends = []
    x_hi = grid[0] + 1
    for slot, (label, runs) in enumerate(series.items()):
        mat = np.array([acc_on_grid(r, grid, axis) for r in runs])
        run_ends = _run_ends(runs, axis, grid)
        finals = [1.0 if r.solved else _last(r.val_eff) for r in runs]
        med, stop, reach = _draw_band(ax, grid, mat, st[label], label, ends=run_ends, slot=slot)
        final = np.nanmedian(finals)
        ends.append((f"{label}  {final:.2f}", _last(med), label))
        x_hi = max(x_hi, reach)
        if strip_ax is not None:
            col, ls = st[label]
            active = np.array([grid <= r.end(axis) for r in runs]).mean(axis=0)
            strip_ax.plot(grid, np.where(grid <= reach, active, np.nan), color=col, ls=ls, lw=1.4)
    if axis == "time":
        # A censored run's last observation can fall in the round overrun past the
        # budget; the time axis never extends beyond the budget.
        x_hi = min(x_hi, grid[-1])
    ax.set_xlim(grid[0], x_hi)
    ax.set_ylim(-0.02, 1.04)
    ax.set_ylabel("validation accuracy")
    ax.set_title(f"{spec} — champion accuracy vs {AXIS_WORD[axis]}", loc="left")
    ax.legend(loc="lower right", handlelength=2.6)
    if strip_ax is not None:
        strip_ax.set_ylim(0, 1.05)
        strip_ax.set_yticks([0, 1])
        strip_ax.set_ylabel("searching", fontsize=8)
        strip_ax.set_xlabel(AXIS_LABEL[axis])
    else:
        ax.set_xlabel(AXIS_LABEL[axis])
    if own:
        _direct_labels(ax, ends, x_hi, st)
        target = strip_ax if strip_ax is not None else ax
        _caption(target, f"median, faint = single runs · {n} matched seeds · solved runs hold 1.0, "
                         f"censored runs their last value · band: {BAND_TEXT} · lines run until the "
                         f"arm's last run ends; marks above the x-axis: each arm's median finish (▲) "
                         f"and 2.5th/97.5th percentile finishes (|)",
                 y=-0.9 if strip_ax is not None else -0.25)
        _save(fig, outdir, f"val_acc_{axis}")
    return True


def solved(spec, series, axis, budget, n, outdir=None, ax=None, note=""):
    """Kaplan-Meier cumulative solve rate against time or generations."""
    usable = {}
    for label, runs in series.items():
        pts = [r.survival(axis) for r in runs]
        if all(p is not None for p in pts):
            usable[label] = pts
    if not usable:
        return False
    own = ax is None
    if own:
        fig, ax = plt.subplots(figsize=(6.4, 3.4))
    st = styles(series)
    grid = np.linspace(0, budget, 400) if axis == "time" else _grid(series, "gen", budget, full=True)
    ends = []
    k_min = None
    x_hi = grid[0] + 1
    for label, pts in usable.items():
        col, ls = st[label]
        times = [p[0] for p in pts]
        frac = kaplan_meier(times, [p[1] for p in pts], grid)
        solved_share = sum(1 for p in pts if p[1]) / len(pts)
        if axis == "time":
            # The curve ends when the arm's last run ended: the budget, unless every
            # run solved earlier.
            keep = grid <= max(times)
            frac = np.where(keep, frac, np.nan)
            last = np.flatnonzero(keep)
            if last.size and last[-1] < len(grid) - 1:
                ax.plot(grid[last[-1]], frac[last[-1]], marker="|", ms=9, mew=1.6, color=col)
            x_hi = max(x_hi, grid[last[-1]] if last.size else grid[0])
        if axis == "gen":
            # Budgets are wall-clock, so on this axis a run is censored at whatever
            # generation it reached — and struggling runs, whose growing test sets
            # make each generation slower, reach fewer. That censoring is
            # informative, and with a handful of runs left one late solve sends the
            # estimate to 100%. Stop the curve while the risk set is still sizeable.
            k_min = min_at_risk(len(pts))
            risk = at_risk_on_grid(times, grid)
            keep = (risk >= k_min) & (grid <= max(times))
            frac = np.where(keep, frac, np.nan)
            last = np.flatnonzero(keep)
            if last.size and last[-1] < len(grid) - 1:
                ax.plot(grid[last[-1]], frac[last[-1]], marker="|", ms=9, mew=1.6, color=col)
            x_hi = max(x_hi, grid[last[-1]] if last.size else grid[0])
        ax.step(grid, frac, where="post", color=col, ls=ls, lw=1.8, label=label)
        # The end label is the observed solve rate, never an extrapolated tail.
        y_end = frac[~np.isnan(frac)][-1] if np.any(~np.isnan(frac)) else solved_share
        ends.append((f"{label}  {solved_share:.0%} solved", y_end, label))
    x_hi = grid[-1] if axis == "time" and x_hi >= grid[-1] else (
        x_hi if axis == "time" else 1.05 * x_hi)
    ax.set_xlim(grid[0], x_hi)
    ax.set_ylim(-0.02, 1.04)
    ax.set_xlabel(AXIS_LABEL[axis])
    ax.set_ylabel("fraction solved")
    ax.set_title(f"{spec} — cumulative solve rate vs {AXIS_WORD[axis]} (Kaplan–Meier)", loc="left")
    ax.legend(loc="lower right", handlelength=2.6)
    if own:
        _direct_labels(ax, ends, x_hi, st)
        cens = ("unsolved runs censored at the budget; a curve ends (|) where the arm's last run ended"
                if axis == "time" else
                "unsolved runs censored at the generation they reached when time ran out — "
                f"informative censoring, so read as sample efficiency among runs still searching; "
                f"each curve stops when fewer than {k_min} runs remain at risk (|); "
                "labels give the observed solve rate")
        _caption(ax, f"{n} matched seeds · verified solves within budget · {cens}" + (f" · {note}" if note else ""))
        _save(fig, outdir, f"solved_{axis}")
    return True


def series_metric(spec, series, metric, axis, budget, outdir=None, ax=None):
    """Tests, witnesses, Z3 calls or champion size against time or generations."""
    field, ylabel, title = SERIES_METRICS[metric]
    series = _traced(series)
    if not series:
        return False
    if metric == "incomplete" and not has_incomplete(series):
        return False
    own = ax is None
    if own:
        fig, ax = plt.subplots(figsize=(6.4, 3.4))
    st = styles(series)
    grid = _grid(series, axis, budget, full=True)
    x_hi = grid[0] + 1
    for slot, (label, runs) in enumerate(series.items()):
        # A finished run's test set, bank, spend and champion no longer change:
        # hold the value at the run's end — the solve, for a solved run — until
        # the arm's LAST run ends; there the line and band stop (no extrapolation).
        # Observations after the solve (runs made before run_cdgp stopped at the
        # solve kept evaluating to the end of the round) are dropped, so they
        # read the same as runs that stop at the solve.
        rows = []
        for r in runs:
            x, y = r.x(axis), getattr(r, field)
            keep = x <= r.end(axis)
            rows.append(step_on_grid(x[keep], y[keep], grid))
        mat = np.array(rows)
        _, stop, reach = _draw_band(ax, grid, mat, st[label], label, traces=False,
                                    ends=_run_ends(runs, axis, grid), slot=slot)
        x_hi = max(x_hi, reach)
    ax.set_xlim(grid[0], min(x_hi, grid[-1]) if axis == "time" else x_hi)
    ax.set_ylim(bottom=0)
    ax.set_xlabel(AXIS_LABEL[axis])
    ax.set_ylabel(ylabel)
    ax.set_title(f"{spec} — {title} vs {AXIS_WORD[axis]}", loc="left")
    ax.legend(loc="upper left", handlelength=2.6)
    if own:
        extra = (" · all call kinds: constraint checks, counterexample, output-completion and "
                 "output-uniqueness queries, subprocess" if metric == "z3" else
                 " · complete and incomplete tests together" if metric == "tests" else "")
        _caption(ax, f"median and band of {BAND_TEXT} over all matched runs; finished runs hold their "
                     f"final value until the arm's last run ends · marks above the x-axis: each arm's "
                     f"median finish (▲) and 2.5th/97.5th percentile finishes (|)" + extra)
        _save(fig, outdir, f"{metric}_{axis}")
    return True


def train_fitness(spec, series, axis, outdir):
    series = _traced(series)
    if not series:
        return False
    st = styles(series)
    labels = list(series)
    fig, axes = plt.subplots(1, len(labels), figsize=(3.3 * len(labels), 3.0), squeeze=False)
    for ax, label in zip(axes[0], labels):
        for r in series[label]:
            ax.plot(r.x(axis), r.train, color=st[label][0], lw=0.6, alpha=0.25)
        ax.set_title(label, loc="left", fontsize=9)
        ax.set_xlabel(AXIS_LABEL[axis])
        ax.set_yscale("symlog", linthresh=1.0)
    axes[0][0].set_ylabel("training fitness (moving target)")
    fig.suptitle(f"{spec} — training fitness per run vs {AXIS_WORD[axis]} "
                 f"(diagnostic, not comparable across runs)", x=0.01, ha="left", fontsize=10)
    fig.tight_layout()
    _save(fig, outdir, f"train_fitness_{axis}")
    return True


ROWS = [("accuracy", None), ("solved", None), ("tests", "tests"), ("incomplete", "incomplete"),
        ("witnesses", "witnesses"), ("z3", "z3"), ("size", "size")]


def has_incomplete(series):
    """Did any run create an incomplete test? (Never on a single-answer spec.)"""
    return any(np.any(np.nan_to_num(r.inc) > 0) for runs in series.values() for r in runs)


def overview(spec, series, budget, n, outdir, note=""):
    """Every metric, wall-clock on the left and generations on the right."""
    rows_ = [r for r in ROWS if r[0] != "incomplete" or has_incomplete(_traced(series))]
    fig, axes = plt.subplots(len(rows_), 2, figsize=(13.0, 3.1 * len(rows_)),
                             gridspec_kw={"hspace": 0.55, "wspace": 0.22})
    for row, (kind, metric) in enumerate(rows_):
        for col, axis in enumerate(("time", "gen")):
            ax = axes[row][col]
            if kind == "accuracy":
                ok = val_acc(spec, series, axis, budget, n, ax=ax)
            elif kind == "solved":
                ok = solved(spec, series, axis, budget, n, ax=ax)
            else:
                ok = series_metric(spec, series, metric, axis, budget, ax=ax)
            if ok:
                ax.title.set_fontsize(9.5)
            else:
                ax.set_visible(False)
    # Default margins are fractions of figure height, which on a tall grid leave
    # wide empty bands above the first row and below the last.
    fig.subplots_adjust(top=1 - 0.55 / fig.get_figheight(), bottom=0.55 / fig.get_figheight())
    fig.text(0.01, 1 - 0.12 / fig.get_figheight(), f"{spec} — left: wall-clock · right: generations",
             fontsize=11, va="top")
    fig.text(0.01, 0.05 / fig.get_figheight(), f"{n} matched seeds" + (f" · {note}" if note else ""),
             fontsize=8, color=INK_3)
    os.makedirs(outdir, exist_ok=True)
    fig.savefig(os.path.join(outdir, "overview.png"), dpi=130, bbox_inches="tight")
    plt.close(fig)


def all_figures(spec, series, budget, n, outdir, note="", note_gen=""):
    """Every figure for one spec, in both axes; returns the file stems written."""
    made = []
    for axis in ("time", "gen"):
        if val_acc(spec, series, axis, budget, n, outdir):
            made.append(f"val_acc_{axis}")
        if solved(spec, series, axis, budget, n, outdir, note=note if axis == "time" else note_gen):
            made.append(f"solved_{axis}")
        for metric in SERIES_METRICS:
            if series_metric(spec, series, metric, axis, budget, outdir):
                made.append(f"{metric}_{axis}")
        if train_fitness(spec, series, axis, outdir):
            made.append(f"train_fitness_{axis}")
    overview(spec, series, budget, n, outdir, note=note)
    made.append("overview")
    return made
