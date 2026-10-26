# bench/ — validating ideas with stored runs

Run an arm once and store it. Run your idea and store that. Then diagnose the
pair: p-values, effect sizes, trajectories, and a plain-language verdict per spec.
Design and statistical protocol: [`../docs/BENCHMARKING_STRATEGY.md`](../docs/BENCHMARKING_STRATEGY.md).

## The loop

```bash
# 1. a baseline, stored once and reused against every idea
julia bench/run.jl --arm baseline-cdgp --suite core --seeds 1:66

# 2. an idea — a registered arm, a one-off keyword change, or a code change
julia bench/run.jl --arm hybrid-nowit --suite core --seeds 1:66
julia bench/run.jl --arm hybrid-ratio --set witness_test_ratio=0.3 --name ratio-0.3 --suite core --seeds 1:66

# 3. diagnosis
bench/.venv/Scripts/python bench/diagnose.py baseline-cdgp hybrid-nowit            # one comparison
bench/.venv/Scripts/python bench/diagnose.py baseline-cdgp hybrid-nowit ratio-0.3  # several, Holm-corrected
bench/.venv/Scripts/python bench/diagnose.py hybrid-nowit                          # report on one run
```

`diagnose.py` prints a verdict table and writes a full report:

```
  hybrid-ratio
  spec             pairs  base  cand  c-only  b-only   McNemar     Holm  log-rank   verdict
  max5                65    48    63      17       2    0.0007   0.0007   <0.0001   candidate better (17 vs 2 discordant seeds, significant after Holm)
```

**Keep these identical across runs you intend to compare:** the seed list, the
suite or specs, `--jobs`, and the machine. Budgets are wall-clock, so a run with
more parallel workers gets less compute per seed. `diagnose.py` checks all of
these and warns.

**Changed the code behind an arm?** Give the new run its own `--name`. Re-running
under the old name is refused, because the manifest records a hash of `src/` and
one run must never mix two versions of the algorithm.

## One-time setup

```bash
python -m venv bench/.venv
bench/.venv/Scripts/python -m pip install -r bench/requirements.txt
#   behind an SSL-inspecting proxy, verify against the Windows trusted roots instead:
#   bench/.venv/Scripts/python -m pip install --cert bench/.venv/os-roots.pem -r bench/requirements.txt
```

## `run.jl` options

| option | meaning |
|---|---|
| `--arm NAME` | an entry of `ARMS` in `common.jl` (required) |
| `--name NAME` | run directory name; default is the arm name |
| `--suite NAME` | `quick` (tier A), `core` (calibrated tier B), `b` (all tier B), `multi` (tier M, multi-answer specs), `full` — or `--specs a,b` |
| `--seeds 1:66` | seed list |
| `--jobs 4` | parallel workers; keep it the same across compared runs. 4 is the sweet spot on the dev machine: 6 runs each seed ~50% slower (same throughput, different solve rates) |
| `--shards auto` | workers per spec; `auto` fills `--jobs` |
| `--set k=v,…` | override arm keywords for a one-off idea (requires `--name`) |
| `--budget S` | override every spec's registry budget |
| `--allow-code-change true` | continue a run after editing `src/` (the comparison will warn) |

Re-running the same command resumes; finished seeds are skipped.

## What a stored run contains

```
results/runs/<name>/
  manifest.toml                arm config + hash, per-spec budget and file hash, hash of src/,
                               git state, host, jobs — everything a comparison must check
  sessions.log                 every invocation, including resumes
  runs/<spec>.s<k>.csv         one row per seed: status, time to solve, generations, Z3 calls by
                               kind, tests, witnesses, program, size, validation accuracy, …
  generations/<spec>.s<k>.csv  one row per generation per seed: the trajectories
  artifacts/<spec>.s<k>.jsonl  per seed: the program found and the tests it generated
  logs/<spec>.s<k>.log         worker output
  report.md, figures/          written by `diagnose.py <name>`
```

Comparisons land in `results/comparisons/<baseline>__vs__<candidates>/`
(`report.md`, `stats.csv`, `figures/`), and every comparison is appended to
`results/comparisons/ledger.csv`.

## What the diagnosis computes

Everything is **paired by seed**: seed *s* of the baseline against seed *s* of the
candidate. A seed that crashed or errored in either run is dropped from both.

| question | test | effect size |
|---|---|---|
| does it solve more? (primary) | McNemar exact on verified solves within budget | odds ratio, exact 95% CI |
| …across all specs? | McNemar on the summed discordant pairs (the Mantel–Haenszel test stratified by pair) | pooled odds ratio |
| …the same on every spec? | chi-square across specs' discordant splits | — |
| does it solve faster? | log-rank on censored time-to-solve | Peto hazard ratio, 95% CI |
| accuracy, AUC over time, stall fraction, Z3 calls, generations, size | Wilcoxon signed-rank | matched-pairs rank-biserial *r*, median difference |
| testing several things at once | Holm correction across every primary test | — |

The verdict per spec is one of: *candidate better / worse* (significant after
Holm), *no significant difference*, *nominal only* (p < α before Holm but not
after), **underpowered** (too few discordant seeds for any outcome to reach α —
with *d* of them the best possible two-sided p is 2·0.5^d — so add seeds), or
**cannot discriminate** (both runs at 0% or 100%: change the budget; time-to-solve
is reported if it still separates them).

`--alternative greater` tests "the candidate is better" one-sided. Decide the
direction before you look: choosing it afterwards halves the p-value dishonestly.

**Several ideas against one baseline is several draws.** At α = 0.05, one in
twenty ideas that do nothing will look significant. The ledger counts comparisons
per baseline and the report states the Bonferroni threshold across them.

## Semantics worth knowing before reading the numbers

- **`solved` = verified by an out-of-process Z3 query *and* within the budget.**
  The deadline is checked between rounds, so a round can overrun; a solve in the
  overrun is `verified` but not `solved`. Without this rule a solve 16 ms after the
  deadline counted (it did, in a pre-harness analysis of max5, and moved its
  log-rank z from 4.05 to 4.22).
- **Statuses:** `solved`, `censored`, `unverified` (claimed but rejected by the
  independent check — a soundness bug, never a near miss), `error`, `crashed`.
- **Memory guard and re-verification failures.** A worker waits (before the clock starts)
  while free memory is under 1,500 MB, and records `sys_free_mb` / `mem_wait_s` per seed. A
  claimed solution whose re-verification cannot run (z3 fails to start) is retried 3 times,
  then recorded as `error` — never `unverified`, which is reserved for a real soundness
  failure. The report's **Run health** section lists low-memory seeds and such failures.
  Close memory-heavy applications before a long run: four workers need ~4 GB.
- **Crashes cost one seed.** A Z3 in-process abort kills the worker uncatchably
  (max5 / hybrid-ratio / seed 58 reproduces one); the supervisor records that seed
  as `crashed` and relaunches.
- **Warm-up:** each worker compiles on an untimed, discarded run first; otherwise the
  first seed pays ~5 s of JIT inside its budget.
- **Z3 counts** cover every call by kind, counted at the solver call sites.
  `z3_reverify` (the harness's own check) is kept out of the search's spend.
- **Runs stop at the solve.** `run_cdgp` ends at the generation in which the verified
  program appears rather than finishing its 10-generation round, so run totals (Z3
  calls, generations, elapsed time) are costs *to solve*, not costs to the end of
  the round.
- **Every figure comes in two versions**, `*_time` and `*_gen`; the overview shows
  them side by side. The generation-axis solve-rate curve is a proper Kaplan–Meier
  estimate (unsolved runs are censored at different generations), and the report
  adds a log-rank test on generations next to the wall-clock one.
- **Tests are complete or incomplete.** When the spec accepts several outputs at a
  counterexample's input (tier M, `spec_files/multi_answer/`), the counterexample
  becomes an *incomplete* test: input only, passed when the candidate satisfies the
  constraints there. `tests` / `tests_final` count both kinds, `incomplete_tests` /
  `incomplete_final` the incomplete ones; `single_answer`, `unique_checks` and
  `tests_unchecked` say how each run decided, and the report's **Test completion**
  table shows it per spec. On single-answer specs every column but `single_answer`
  stays 0 and runs replay the stored ones bit-for-bit. `baseline-lex-legacy` is the
  ablation that demands Z3's arbitrary output instead.
- **Counterexample harvest** (`cex_*` columns, report table "Counterexample harvest"):
  per run, the verifications that found a candidate wrong (*events*), the violation
  witnesses they returned, the tests added, duplicates, completion failures, cap hits and
  multi-test events. With `cex_mode = :per_constraint` (arms `lex-percon`,
  `lex-percon-1`) an event can add one test per violated constraint; the table shows
  whether that actually happens. `cex_fallback = 1` marks a spec where the mode was
  unavailable and `:single` ran instead.
- **Validation accuracy** is scored on a fixed 256-input battery shared by every run
  and seed: the share of inputs where every constraint holds. It is invariant to
  specification style, and it is what the trajectory plots use — training fitness is
  measured against a growing evidence set and is not comparable across runs.
- **Known gap:** for predicate specs the battery is not balanced by output, so a
  constant `false` can score well on `issorted`.

## Files

| file | role |
|---|---|
| `common.jl` | `SPECS` (tier, calibrated budget), `SUITES`, `ARMS`, run layout, CSV schema, provenance |
| `run.jl` | stores one arm as a named run: manifest, scheduling, crash recovery, resume guards |
| `worker.jl` | one spec shard: warm-up, trace, re-verification, validation, artifacts |
| `diagnose.py` | single-run report, or paired comparison with every test above |
| `figures.py` | the trajectory figures (library used by `diagnose.py`) |

## Adding an arm (RQ2 / RQ3)

Add an entry to `ARMS` in `common.jl`. If the idea needs a new `run_cdgp` keyword,
add the keyword; everything else — tracing, Z3 accounting, figures, statistics —
applies unchanged.
