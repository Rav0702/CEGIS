# CDGP Benchmark Results — Tournament vs. Lexicase

Counterexample-Driven Genetic Programming (`run_cdgp`) on the max-family SyGuS
benchmarks, comparing `TournamentSelection` (default) against
`LexicaseSelection`. Each solved program is independently re-verified against its
spec with Z3 (`:unsat` ⇒ correct for all inputs).

- Reproduce: `julia --project=. scripts/run_cdgp_benchmarks.jl`
- Date: 2026-06-16 · Branch: `ga-z3-guided-synthesis-poc` · **Single seed (`seed=1`)**

## Results

| spec | selection | solved | verify | gens | rounds | tests | z3 | time |
|------|-----------|--------|--------|------|--------|-------|----|------|
| max2 | tournament | ✓ | unsat | 10 | 1 | 7 | 8 | 32.6s\* |
| max2 | lexicase | ✓ | unsat | 10 | 1 | 5 | 6 | 2.2s |
| max3 | tournament | ✓ | unsat | 100 | 10 | 13 | 14 | 6.0s |
| max3 | lexicase | ✓ | unsat | **10** | **1** | 13 | 14 | 3.0s |
| max4 | tournament | ✓ | unsat | 920 | 92 | 35 | 36 | 105.0s |
| max4 | lexicase | ✓ | unsat | **140** | **14** | 48 | 49 | 58.7s |
| max5 | tournament | ✓ | unsat | 2540 | 254 | 52 | 53 | 272.8s |
| max5 | lexicase | ✗ | not_solved | 770 | 77 | 40 | 40 | 363.6s |

**Confirmed solutions: 7 / 8** (4 specs × 2 selections).

\* max2 tournament's 32.6s is one-time JIT warmup (first run of the process).

## Per-spec configuration

Defined in `scripts/run_cdgp_benchmarks.jl`; harder specs get larger population,
deeper trees, and a longer wall-clock budget:

| spec | pop_size | generations | max_depth | depth_cap | max_time |
|------|----------|-------------|-----------|-----------|----------|
| max2 | 100 | 200 | 4 | 6 | 60s |
| max3 | 200 | 500 | 5 | 8 | 120s |
| max4 | 300 | 2000 | 6 | 10 | 240s |
| max5 | 400 | 3000 | 6 | 12 | 360s |

## Analysis

**Lexicase converges in far fewer generations.** max3: 10 vs 100; max4:
**140 vs 920**. This matches the CDGP paper's claim — per-case selection
preserves specialists that pass *some* counterexample tests even when their
aggregate score is poor, which is exactly the modal fitness landscape CDGP
produces.

**But each lexicase generation is ~4× more expensive.** On max5 it reached only
**770 generations** before hitting the 360s wall, while tournament fit **2540
generations** into 272s. The overhead is structural: lexicase makes the solve
loop materialize a per-case matrix (`_compute_case_fitnesses` runs
`evaluate_cases` on every genome every generation) *on top of* the scalar
`evaluate_genome` pass, plus per-parent case-filtering. With `pop_size=400` and
~40–50 tests, that dominated, and tournament's raw throughput won the hardest
problem within the budget.

**Net:** lexicase is the better searcher *per generation* but the worse one
*per wall-clock second* under this setup. Its max5 failure was a **time-budget
loss, not a search-quality loss** — it ran out of time (generation cap was 3000,
it reached 770), so raising max5's `max_time` would likely let lexicase finish.

## Caveats

- **n = 1.** Single seed (`seed=1`); directional, not statistical. The paper's
  claims are over many runs. For a real comparison, run multiple seeds.
- **No parallelism.** `run_cdgp` forces `parallel=false` because the evaluator
  mutates shared state (test set, cache, counters), so lexicase's extra
  per-genome work cannot be threaded away.

## Solutions found (Z3-verified `:unsat`)

- **max2 / tournament:** `ifelse(x1 < x0, x0, x1)`
- **max2 / lexicase:** `ifelse(1x0 == x0, ifelse(x1 >= x0, x1, x0), 1)`
- **max3 / lexicase:** `ifelse(x > ifelse(z > y, z, y), x, ifelse(z > y, z, y))`
- **max4 / tournament:** `ifelse(x2 >= ifelse(x1 <= x0, x0, x1), ifelse(x3 <= x2, ifelse(x1 <= x0, x2, ifelse(x2 > x1, ifelse(x2 > x1, ifelse(x2 > x1, x2, x1), x3), x1)), x3), ifelse(x3 <= ifelse(x1 <= x0, x0, x1), ifelse(x1 <= x0, x0, x1), x3))`

(Other solved programs are larger; see the script output. All re-verified
`:unsat`, i.e. correct for all inputs, even when syntactically bloated.)
