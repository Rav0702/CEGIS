# Plan — scalable benchmark suite, per-problem grammars, repo cleanup

Date: 2026-10-10
Branch: `partial_specification_satisfaction_and_iterator_constraints` (= `master` + 2 commits)
Scope: generator for 3 scalable families → per-problem grammar support → measure the
current high-water mark per family → clean up the repo. **Nothing is pushed.**

---

## 0. State of the code, as found

### 0.1 `main` is a stub; `master` is the trunk

`git ls-tree main` = **one file** (`.gitignore`), single commit `ddb2611 "Initial commit"`,
and `git merge-base main master` fails — *unrelated histories*. All real work (PRs #5, #7)
merged into `master`. Our branch is `master` + 2 commits, 0 behind.

So "the code in main" does not exist. The GitHub default branch points at an empty
orphan branch. **Decision required** (see §4.3): either repoint the default to `master`,
or merge `master` into `main` once with `--allow-unrelated-histories` and retire `master`.
Until that is settled, PR bases are wrong by default.

Branch count: 19 local, 20 remote, most already merged or superseded.

### 0.2 Per-problem grammars are *not* supported by the parser

`src/CEXGeneration/parser.jl` handles `synth-fun` by reading only `expr[2..4]`
(name, params, return sort). **The grammar body — the nonterminal declarations and
production rules, `expr[5:]` — is silently dropped.** A SyGuS file with a grammar
section parses without error and then gets a grammar that ignores it.

Grammars today come from one of two places:
1. `GrammarBuilding/GrammarConfig.jl` — operation-set config (`BASE_OPERATIONS`,
   `LIA_OPERATIONS`, …) + `synth-fun` params as variables + constants scraped from the
   constraint text. Generic per *logic*, not per *problem*.
2. A hardcoded Julia function in the driver: `max_n_grammar(n)` in
   `scripts/iterative_seeded_max.jl:327`, passed through `solve_spec(...; grammar=...)`.

So the *plumbing* for a per-problem grammar exists (`solve_spec` accepts one); what is
missing is any way to **declare** it in the benchmark file. For a suite of three families
with different operator needs, keeping grammars in driver-script Julia does not scale and
makes the benchmarks non-portable and non-reproducible.

### 0.3 What the SMT backend supports (bounds what grammars may contain)

`src/CEXGeneration/rulenode_to_smt.jl`: `ifelse`/`ite`, `+ - *`, `< <= > >= == !=`,
`and or not`, integer literals (incl. negatives), variables. Two nonterminal
pass-through wrappers are recognised **by literal name**: `Expr` and `BoolExpr`
(`rulenode_to_smt.jl:99-106`).

Good news for this plan: all three families need only `ite`, comparisons, variables and
integer constants. **No new SMT operators are required.** Part 1 is parsing plus
generalising wrapper handling — not backend work.

Also name-coupled: `PartialSat.SeededCostBUIterator(grammar, :Expr; …)` hardcodes `:Expr`
as the start symbol.

### 0.4 Seed transfer is index-layout-coupled

`remap_rulenode` (`iterative_seeded_max.jl:349`) remaps a program between
`max_n_grammar(n)` and `max_n_grammar(n+1)` by *shifting rule indices*, valid only because
those two grammars share the layout "vars `1..n`, then `ifelse`, `>`, `<`". Any grammar
whose rule order differs — i.e. every new family — breaks it silently (wrong program, not
an error). Needs replacing with expression-matched remapping.

### 0.5 Current high-water mark (from `results/max_n_climbs/README.md`)

**max10**, under `EQUIV=constraint`, chained seed transfer, 300 s/problem. max11–max16
unsolved. Two caveats recorded there that this plan must honour:

- **Non-determinism is wall-clock-induced**: rounds that end by hitting the time cap
  differ run-to-run; rounds that end by finding a solution are byte-identical. ⇒ bound
  rounds by `ROUND_ENUM`, not seconds, for anything reported.
- **Budget-transfer confound**: in the 600 s run, max8 *solving* caused max10 to *fail*
  (max8 exited early, so max9 inherited a thinner bank). ⇒ chained numbers are not
  per-problem numbers; report chained and independent separately.

### 0.6 Clutter inventory

| What | Where | Size |
|---|---|---|
| 6 stale status/report MDs | root: `ALIGNMENT_REPORT_20260413.md`, `FIXES_APPLIED_20260413.md`, `SEARCH_SUMMARY.md`, `Z3_QUERY_ANALYSIS.md`, `Z3_QUERY_QUICK_REFERENCE.txt`, `CONSTRAINT_SATISFACTION.md` | ~40 KB |
| regenerable test/bench dumps | root: `test_output.txt`, `test_output_full.txt`, `benchmark_analysis.txt` | 194 KB |
| untracked presentation artifacts | root: `PRESENTATION.md`, `cegis_loop.html` | 11 KB |
| scratch SMT queries | `scripts/`: `q.smt2`, `q1.smt2`, `query.smt2`, `query2.smt2`, `query3.smt2`, `query_test.smt2`, `old_Z3_query.smt2`, `new_Z3_query.smt2`, `findidx_query.smt2` | — |
| scratch spec files | `spec_files/`: `findidx_2_problem copy.sl`, `successful_call`, `failed_call`, `findidx_2_declare_fun.sl`, `findidx_2_simple.sl` | — |
| one-off benchmark dirs | `benchmarks/`: `max_two`, `max_three`, `max_four`, `find_max_three`, `abs_value`, `clamp_value`, `conditional_sum`, `sign_function` | 8 dirs |
| root one-off scripts | `benchmark_no_cegis.jl`, `calc_enum.jl` | — |

---

## 1. Part 1 — per-problem grammar support (blocking; do first)

Benchmarks must carry their own grammar, because the three families need different
terminal sets and because grammar size is itself an experimental axis.

1. **Capture the grammar body.** Add `grammar_sexp::Vector{Any}` (raw s-expression, or
   empty) to `SynthFun` in `src/CEXGeneration/types.jl`; in `parser.jl`, store `expr[5:]`
   instead of discarding it. Purely additive — existing specs get an empty body.
2. **Translate SyGuS grammar → Herb grammar.** New `src/GrammarBuilding/SyGuSGrammar.jl`:
   `sygus_grammar_to_csgrammar(synth_fun)`. Handles nonterminal declarations
   `((Start Int) (BoolExpr Bool))`, productions over variables / integer literals /
   `ite` / comparisons, and the `(Constant Int)` and `(Variable Int)` special forms
   (expanded to the literal set / the parameter list).
   **Nonterminal naming**: map the Int-sorted start nonterminal to `Expr` and the
   Bool-sorted one to `BoolExpr`, so the `:Expr` start symbol and the SMT wrappers keep
   working. Additional nonterminals get fresh names.
3. **Decouple the SMT wrappers from those two names.** In `rulenode_to_smt.jl`, treat any
   rule whose RHS is a bare nonterminal symbol as a pass-through and pick `:int`/`:bool`
   from `grammar.types`, rather than string-matching `Expr`/`BoolExpr`. Removes the
   latent trap in step 2.
4. **Wire it in**, keeping the fallback: `build_grammar_from_spec` uses the parsed grammar
   when the spec has one, else the current `GrammarConfig` path. Every existing benchmark
   keeps its current behaviour.
5. **Expression-matched seed remapping.** Replace `remap_rulenode`'s index shift with a
   remapper that matches rules by `grammar.rules[i]` expression (and type) between source
   and target grammar, erroring on an unmappable rule instead of producing a wrong
   program. Keep the index-shift version as a tested fast path for the max_N family.
6. **Tests** (`test/test_sygus_grammar.jl`): for one spec per family, assert rule
   count/types; assert the family's reference solution (a) parses into a `RuleNode` over
   the generated grammar, (b) converts to SMT, (c) verifies `unsat` through
   `CEX.verify_query`. That last check is what makes a generated spec trustworthy.

## 2. Part 2 — the generator

`benchmarks/generate_suite.jl`, one function per family, each emitting a self-contained
`.sl` **with a grammar section**, plus a reference solution used for validation.

### 2.1 `array_search_N` — N = 2…15 → `benchmarks/array_search_n/array_searchN.sl`
Keeps the exact constraint shape of the existing `spec_files/findidx_5_problem.sl`
(sortedness guard + strict bounds on `k`), so the files match the SyGuS-COMP family.
N+1 constraints, guards mutually exclusive and *asymmetric* — unlike max_N, whose N
inequality constraints are interchangeable under input permutation, which flattens the
subset lattice. Reference solution: nested `ite` chain on `k < x_i`.
Grammar: `0…N`, the vars, `k`, `ite`, four comparisons.

### 2.2 `piecewise_N` — N = 2…12 → `benchmarks/piecewise_n/piecewiseN.sl`
Single input `x`, N constraints `a_i <= x < a_{i+1} ⇒ f(x) = c_i` (open at both ends).
Constraints fully independent → partial score is exactly "brackets correct". Scales depth
while arity stays 1, separating "banking helps" from "the grammar grew".
Grammar: thresholds `a_i` and outputs `c_i` as constants, `x`, `ite`, comparisons.

### 2.3 max_N granularity ablation — N = 3…16 × 3 encodings
→ `benchmarks/max_n/granularity/{split,conj,pairwise}/maxN.sl`
- `split` — current N+1 constraints (copy of today's files, so results stay comparable).
- `conj` — all of it as **one** conjunctive constraint. Partial score degenerates to 0/1.
- `pairwise` — adds the C(N,2) redundant `(or (>= y x_i) (>= y x_j))`-style constraints
  for a finer lattice.
Same problem, same grammar, three granularities: isolates whether the win comes from
*spec decomposability* or from the bank/seeding machinery. This is the cheapest high-value
experiment available and the one a reviewer will ask for.

### 2.4 Grammar tiers
`--tier d0|d1|d2`: d0 = minimal (what the family needs), d1 = + arithmetic `+ -`,
d2 = + `*` and a wider constant set. Emitted into sibling dirs, giving a grammar-size
axis per family — replaces the current `MINIMAL_GRAMMAR=0/1` env switch.

### 2.5 Validation gate (run inside the generator)
For every emitted file: parses → grammar builds → reference solution verifies `unsat`.
A family whose reference solution does not verify is a **spec bug**, and without this gate
it would show up as a solver failure in the results table.

## 3. Part 3 — establish the high-water mark

### 3.1 Protocol (identical across families)
- `ROUND_ENUM`-bounded rounds (per §0.5), with a wall-clock cap only as a safety net.
- `EQUIV=constraint` and `EQUIV=observational`.
- **chained** (seed transfer on) and **independent** (transfer off) — per §0.5.
- `USE_EGRAPH=1`, plus one `USE_EGRAPH=0` control per family: the e-graph-derived
  constraints were only ever exercised on the max_N grammar, and with constants in the
  grammar they could over-prune. Must be checked, not assumed.
- Climb N upward, stop after 2 consecutive failures.
- Logs → `results/<family>/`, gzipped, plus a per-round CSV.

### 3.2 Parallelism
One sonnet agent per (family × regime) cell. Each `julia --project` run is
single-threaded and holds an in-process Z3; on an M3/24 GB, **cap at 4 concurrent Julia
processes** — memory, not CPU, is the limit (bank saturation at high N is what killed
max11–16). Each agent gets exact env/commands, writes its own log paths, and returns a
compact table. Agents run while Part 4 proceeds.

### 3.3 Deliverable
`results/SUITE_2026-10-10.md`: highest solved N per family per configuration, with
times, enumeration counts and the verification status of each solution.

## 4. Part 4 — cleanup (separate commits, no push)

### 4.1 Files
- `docs/archive/` ← the 6 stale root reports (history, not current docs).
- **delete** `test_output.txt`, `test_output_full.txt`, `benchmark_analysis.txt` — regenerable.
- `docs/presentation/` ← `PRESENTATION.md`, `cegis_loop.html` (currently untracked).
- `scratch/` (gitignored) ← the 9 `.smt2` files in `scripts/`, the `spec_files/` scratch
  (`findidx_2_problem copy.sl`, `successful_call`, `failed_call`).
- `benchmarks/micro/` ← the 8 one-off single-problem dirs.
- `spec_files/findidx_{2,5}*.sl` → superseded by generated `array_search_n/`; keep one as
  a parser regression fixture, archive the rest.
- `benchmark_no_cegis.jl`, `calc_enum.jl` → `scripts/`.
- `.gitignore`: `scratch/`, `*.log`, `results/**/*.log`.

### 4.2 Driver refactor
Split `scripts/iterative_seeded_max.jl` (460 lines, half of it max_N-specific) into
`src/Suite/` (family-agnostic `solve_spec`, scoring, seeding) + `scripts/run_suite.jl`
(family descriptors + CLI). Needed anyway for Part 3 to run three families.

### 4.3 Branches — needs your call
`main` is an empty orphan (§0.1). Options: (a) repoint GitHub default to `master`;
(b) one-off `merge --allow-unrelated-histories` of `master` into `main`, then retire
`master`. (b) is tidier long-term but rewrites what collaborators track. Also: list the
merged local branches for deletion, leave remotes alone.

---

## Order of work

1. Part 1 (grammar) — blocking.
2. Part 2 (generator) + validation gate.
3. Launch Part 3 agents (background) → **while they run**, do Part 4.1/4.2.
4. Collect results table; settle §4.3.

## Risks

| Risk | Mitigation |
|---|---|
| e-graph pruning unsound on grammars with constants | `USE_EGRAPH=0` control run per family (§3.1) |
| generated spec subtly wrong ⇒ looks like solver failure | reference-solution verification gate (§2.5) |
| index-based seed remap silently wrong on new grammars | expression-matched remap + error on unmappable rule (§1.5) |
| bank saturation / memory at high N | 4-process cap; `ROUND_ENUM` bound; per-problem memory logged |
| cleanup breaks paths the runs use | cleanup lands after the runs are launched, benchmark paths untouched |
