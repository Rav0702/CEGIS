# max_N seeded-climb experiments

Runs of `scripts/iterative_seeded_max.jl` and `scripts/compare_equivalence.jl` on
the `max_N` family (`benchmarks/max_n/max3.sl` … `max16.sl`).

All runs used the spec-specialised minimal grammar (input variables, `ifelse`,
`>`, `<` — no arithmetic, no constants, no Bool→Int coercion), e-graph-derived
`HerbConstraints` added before the search, and the in-process Z3
`ConstraintSatSolver` for per-constraint scoring. Every reported solution was
re-verified independently through the all-or-nothing counterexample query
(`independent full-spec verification: PASS` in the logs).

Hardware: Apple M3, 24 GB, macOS, single-threaded. Julia 1.12.6, HerbSearch 1.0.2,
HerbConstraints 1.2.1, HerbCore 1.1.0, HerbGrammar 1.1.3, Z3.jl 1.0.4 (Z3 4.16.0),
Metatheory.jl 2.0.2 in the isolated `tools/egraph_gen` environment.

Logs are gzipped; `zless <file>` to read.

## Runs

| file | command | outcome |
|---|---|---|
| `climb10_observational_run1.log.gz` | `PROBLEM_TIME=300 ROUND_TIME=120 … 3 4 5 6 7 8 9 10` | 6/8 solved; max8 ✗, max9 ✓, max10 ✗ |
| `climb10_observational_run2.log.gz` | identical repeat of run 1 | 6/8 solved; **max8 ✓, max9 ✗**, max10 ✗ |
| `climb10_constraint.log.gz` | `EQUIV=constraint PROBLEM_TIME=300 …` | 7/8 solved; max8 ✗, max9 ✓, **max10 ✓** |
| `climb12_constraint.log.gz` | `EQUIV=constraint PROBLEM_TIME=300 … 3..12` | 7/10; max11, max12 ✗ (bank saturation) |
| `climb16_constraint_600s.log.gz` | `EQUIV=constraint PROBLEM_TIME=600 … 3..16` | 7/14; **max8 ✓ (r4)**, max9 ✓, max10–16 ✗ |
| `equiv_independent_TRUNCATED.log.gz` | `compare_equivalence.jl 3 10` | see caveat below |

`solutions/max{3,4,5,6,7,9}.txt` hold the exact verified programs from
`climb10_constraint.log` (max3 86 chars → max9 5315 chars).

`per_problem_first_runs/max{3,4,5}.log` are the earliest runs, before seed
transfer existed — each problem solved from scratch. They are the unaided
baseline: max3 solved in 3.0 s, max4 in 19.2 s (two rounds), max5 not solved at
all within the budget. Compare against the chained table below, where max4 solves
in 1.4 s and max5 in 35.1 s from an inherited seed.

`equivalence_smoketest_max3-4.csv` is the per-round CSV format emitted by
`compare_equivalence.jl`, from a short max3–max4 verification run.

## Result 1 — seed transfer extends reach, then plateaus

Carrying a solved `max_N` program forward as a cost-1 seed into `max_{N+1}`
(`carry_over_seeds`, with rule-index remapping between the per-N grammars).

| N | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|
| observational, 300 s (run 1) | ✓ 3.1 s | ✓ 1.4 s | ✓ 35.1 s | ✓ 93.9 s | ✓ 129.6 s | ✗ | ✓ 172.6 s | ✗ |
| observational, 300 s (run 2) | ✓ 2.5 s | ✓ 1.5 s | ✓ 36.4 s | ✓ 88.8 s | ✓ 128.1 s | ✓ 223.6 s | ✗ | ✗ |
| constraint, 300 s | ✓ 2.6 s | ✓ 1.7 s | ✓ 43.0 s | ✓ 102.4 s | ✓ 129.2 s | ✗ | ✓ 238.6 s | ✓ 231.8 s |
| constraint, 600 s | ✓ 2.5 s | ✓ 1.5 s | ✓ 43.7 s | ✓ 103.9 s | ✓ 129.1 s | ✓ 410.0 s (r4) | ✓ 324.6 s | ✗ |

max3–max7 reproduce across every configuration. **max3–max6 solve by literally
wrapping the inherited seed** — `ifelse(x_new > prev, x_new, prev)`, with the
previous solution appearing verbatim twice. From max7 on the search instead
assembles idiosyncratic programs from smaller banked blocks.

Solution size roughly doubles per step (21 → 46 → 96 → 196 → 226 → 1266 → 3186
nodes), because each solution embeds the previous one twice.

## Result 2 — outcomes at N ≥ 8 are not reproducible under a wall-clock budget

Runs 1 and 2 are the *same command*. They disagree on max8 and max9 in opposite
directions (6/8 solved either way). Cause, isolated from the logs: every round
that ends by *finding a solution* has byte-identical enumeration counts across
runs (45, 120, 1320, 20080, 27920, 1402); every round that ends by hitting the
**120 s cap** differs (e.g. max7 r1: 21369 vs 22576). The search is deterministic
— enumeration order is fixed, the observational sample uses `MersenneTwister(1234)`,
Z3 is deterministic — so the only nondeterminism is *where the timer cuts the
round*, which changes what is banked, which changes the next round's seeds.

**Implication:** bound rounds by enumeration count (`ROUND_ENUM`), not seconds,
for any reported number. `compare_equivalence.jl` does this.

## Result 3 — a budget-transfer confound couples adjacent problems

In the 600 s run, max8 solving *caused* max10 to fail. max8 previously failed and
spent its full budget filling its bank, which max9 then inherited; with 600 s max8
solves at round 4 and exits early, max9 solves at round 3 with a 1726-node
(not 1266-node) solution, and max10–max16 inherit that heavier skeleton and never
improve on it. A problem's difficulty therefore depends on how long its
predecessor ran — so the climb **cannot be reported as a scaling curve**.

## Result 4 — constraint equivalence saturates

`EQUIV=constraint` keys the bank by the subset of constraints a program satisfies
universally (predicate abstraction over the spec). At most 2^(N+1) classes exist.

Per-round `kept` (programs admitted to the bank), 600 s run:

| problem | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| max11 | 234 | 32 | 5 | 2 | **0** |
| max12 | 234 | 19 | **0** | 1 | **0** |
| max13 | 251 | 26 | 2 | **0** | **0** |
| max16 | 371 | 19 | 1 | **0** | **0** |

Eight rounds reached `kept = 0`: every candidate rejected, nothing admissible,
the search structurally dead rather than out of time. `kept` stays flat at
254–449 across max8–max16 while the signature space grows to 131072 — at max16
only **0.3 %** of available signatures are used, so the limit is not the label
space but the search's inability to produce candidates with *new* coverage.

Across max3–max16: 189197 candidates reached the gate, 185651 dropped (**98.1 %**),
3546 kept, at a cost of ~3.9 h of Z3 signature proving (≈70 % of each problem's
budget from max10 on).

## Result 5 — observational vs. constraint equivalence, same candidates

`compare_equivalence.jl`, independent problems (no seeds), 15000 candidates/round,
3 rounds, no time cap. `offered` was verified identical between the two arms for
every problem, so differences are attributable to the relation alone.

| problem | offered | obs kept | obs % | con kept | con % | bank ratio |
|---|---|---|---|---|---|---|
| max3 | 219 | 93 | 42.5 % | 28 | 12.8 % | 3.3× |
| max4 | 1147 | 792 | 69.0 % | 77 | 6.7 % | 10.3× |
| max5 | 18342 | 10867 | 59.2 % | 254 | 1.4 % | 42.8× |
| max6 | 19908 | 14200 | 71.3 % | 471 | 2.4 % | 30.1× |
| max7 | 21849 | 15860 | 72.6 % | 699 | 3.2 % | 22.7× |
| max8 | 34906 | 27166 | 77.8 % | 911 | 2.6 % | 29.8× |
| **total** | **96371** | **68978** | **71.6 %** | **2440** | **2.5 %** | **28.3×** |

Signature/evaluation cost: observational 47.9 s, constraint 112.2 s (≈2.3×).

> **Caveat — this table's source log was lost.** The numbers were extracted from
> the complete run log, but a polling agent then re-ran the command, whose
> `rm -f` deleted that log before it was archived. `equiv_independent_TRUNCATED.log.gz`
> is only the first 32 KB of the *restarted* run (max3–max5) and does **not**
> back the table above. The run is deterministic, so
> `ROUND_ENUM=15000 ROUNDS=3 julia --project scripts/compare_equivalence.jl 3 8`
> should reproduce these counts exactly — do that before citing them.

## Reproducing

```bash
# seeded climb (chained, wall-clock budget)
EQUIV=constraint PROBLEM_TIME=300 ROUND_TIME=120 LOG_EVERY=2000 \
  julia --project scripts/iterative_seeded_max.jl 3 4 5 6 7 8 9 10

# equivalence comparison (deterministic, enumeration-bounded)
ROUND_ENUM=15000 ROUNDS=3 OUT=/tmp/equiv.csv \
  julia --project scripts/compare_equivalence.jl 3 8
```

Knobs: `EQUIV` (`observational` | `constraint` | `both`), `MINIMAL_GRAMMAR`,
`USE_EGRAPH`, `EGRAPH_DEPTH`, `ROUNDS`, `ROUND_ENUM`, `ROUND_TIME`,
`PROBLEM_TIME`, `MAX_DEPTH`, `MAX_SIZE`, `MAX_COST`, `LOG_EVERY`, `CHAIN`.

## Known limitations

- Round and problem time caps are checked only *between* yielded candidates, so a
  single long `combine` call can overrun them (observed: 445 s against a 120 s cap
  in an early max5 run). Not an issue at `MAX_COST=6`.
- Only start-type programs carry constraint signatures; boolean guards keep
  behavioural ones, otherwise the bank would retain a single guard.
- The `both` mode (constraint subset refined by behaviour) is implemented but has
  not been run over the suite.
- `max9.sl`–`max16.sl` were generated for these experiments and are not from the
  SyGuS competition set.
