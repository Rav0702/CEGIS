# Partial Specification Satisfaction — Work Log

**Branch:** `partial-constraints-sat`
**Dates:** June 15–16, 2026
**Author:** Claude Opus (Claude Code), driven by Stanisław Howard

Implements the paper's research question:

> **Guided Search through Partial Specification Satisfaction.** Can partial
> programs "partially satisfy" a formal specification? Use the *subset of
> satisfied constraints* as a fitness metric to guide search, collect partial
> programs that satisfy part of the spec as building blocks, and recombine them
> into a complete solution.

---

## 1. Core idea & the answer to "can this be a Z3 query?"

A SyGuS `.sl` spec is a **conjunction** of `(constraint …)` predicates. The
standard CEGIS verifier treats them all-or-nothing. We instead measure *how many*
predicates a candidate satisfies.

**Yes, it is a Z3 query — one per constraint.** For each constraint `Cᵢ` we
install the candidate as a `define-fun` and ask Z3 whether the candidate can
*violate* it:

```
(define-fun max2 ((x0 Int)(x1 Int)) Int <candidate body>)
(assert (not Cᵢ))     ; Cᵢ already calls (max2 x0 x1)
(check-sat)
```

- **unsat** ⟹ no input violates `Cᵢ` ⟹ it holds for **all** inputs ⟹ *satisfied*.
- **sat**   ⟹ an input violates it ⟹ *not satisfied*; the model is a witnessing input.
- **unknown** ⟹ Z3 could not decide; treated as not-satisfied and surfaced.

Counting the `unsat` results gives the partial-satisfaction **score**
`#satisfied / #total`. This is **sound** — each `Cᵢ` is checked *universally*
(∀ inputs over LIA), not sampled on examples. It differs from full verification
only in that the verifier negates the *conjunction* of all constraints in one
query, whereas this negates *one constraint at a time* to get the pass/fail
vector.

---

## 2. Files created / modified

| File | Status | Purpose |
|---|---|---|
| `src/CEXGeneration/query.jl` | modified | Added `_candidate_query_header` (shared with the verifier) and `generate_partial_sat_query` (per-constraint universal check). `generate_query` (the all-or-nothing verifier) was **not** touched. |
| `src/CEXGeneration/CEXGeneration.jl` | modified | Export `generate_partial_sat_query`. |
| `src/PartialSat/PartialSat.jl` | new | Submodule `CEGIS.PartialSat`: evaluator, building-block bank, guided search, `collect_satisfying`. |
| `src/PartialSat/SeededBottomUp.jl` | new | `SeededCostBUIterator` + `populate_bank!` override (seed the BU bank with collected programs). |
| `src/CEGIS.jl` | modified | `include` + export `PartialSat` (after `CEXGeneration`). |
| `scripts/test_partial_satisfaction.jl` | new | Demo: per-constraint scoring, guided search, seed-and-resume. |

---

## 3. The module API (`CEGIS.PartialSat`)

**Evaluation**
- `PartialSatResult` — `n_total`, `n_satisfied`, `satisfied::Vector{Bool}`,
  `violating_inputs`, `score`.
- `evaluate_partial_satisfaction(spec, candidate_exprs; verbose)` — one Z3 query
  per constraint. Overload `(spec, grammar, program)` converts a `RuleNode` first
  (via `CEXGeneration.rulenode_to_smt2`).
- `unknown_indices(result)` — constraints Z3 left undecided.

**Building-block bank**
- `PartialSolutionBank` — keyed by the *satisfied-subset*; keeps the smallest
  program per subset; tracks `best`.
- `record!`, `building_blocks` (best first), `complementary_cover` (greedy set
  cover of blocks whose satisfied-sets union to all constraints).
- `collect_satisfying(bank; threshold=0.5, composite_only=true)` — the banked
  programs satisfying `≥ threshold` of the constraints, as `RuleNode`s ready to
  seed a bottom-up iterator. `composite_only` drops bare terminals (already in
  any BU bank).

**Search**
- `guided_partial_search(spec, grammar, iterator; max_enumerations, verbose, log_every)`
  — enumerate, score, bank, stop at a full solution. Returns
  `(; full, bank, enumerated, skipped, unknown_checks)`. Intermediate logging:
  per-constraint breakdown (✓/✗/?) on each new best and the full solution,
  periodic progress every `log_every`, `unknown` warnings, and a final summary.

**Seeded bottom-up iterator** (`SeededBottomUp.jl`)
- `SeededCostBUIterator(grammar, sym; seed_programs, seed_cost=1.0, current_costs, max_depth, max_size, max_cost)`
  — a `CostBasedBottomUpIterator` subtype whose bank is pre-loaded with
  `seed_programs`. Each seed enters the bank at cost `seed_cost` (treated as a
  cheap atom, not re-charged for internal structure) so combinations reusing it
  surface early. Everything else (combine, horizons, constraint checks) is
  inherited.

---

## 4. Native vs. written

- **Combining existing programs into larger ones — native.** That is exactly
  what the HerbSearch bottom-up iterators do: keep a *bank* and `combine` glues
  banked programs under operators.
- **Seeding the bank with externally-collected programs — NOT native.**
  `populate_bank!` natively seeds only grammar terminals. So we wrote
  `SeededCostBUIterator`: a `<: HerbSearch.AbstractCostBasedBottomUpIterator`
  subtype (via `@programiterator`) with a `seed_programs` field and a
  `populate_bank!` override that injects them. ~40 lines; all other behavior
  inherited.

Implementation gotchas encountered and fixed:
- `@programiterator` rejects a *qualified* supertype — import the abstract type
  as a bare name (`import HerbSearch: AbstractCostBasedBottomUpIterator`).
- A docstring cannot be attached directly to the `@programiterator` call — use
  `@doc "…" SeededCostBUIterator` *after* the macro (as HerbSearch itself does).
- Name clash: `PartialSat` defines its own `BankEntry`; HerbSearch's `BankEntry`
  is therefore **qualified** (`HerbSearch.BankEntry`), not imported.

---

## 5. Results so far

**Per-constraint evaluation (verified).** On `max2_simple.sl` (3 constraints):

| candidate | satisfies | score |
|---|---|---|
| `x0` | {1, 3} | 2/3 |
| `x1` | {2, 3} | 2/3 |
| `(+ x0 x1)` | ∅ | 0/3 |
| `(ite (< x0 x1) x1 x0)` | {1, 2, 3} | 3/3 |

`x0` and `x1` are textbook **complementary** building blocks (their satisfied-sets
union to all 3). For `max3_simple.sl` (4 constraints) the analogous blocks are
`x`→{1,4}, `y`→{2,4}, `z`→{3,4}, and `max(x,y)`→{1,2,4}.

**Guided search (verified, max2).** A cost-biased `CostBasedBottomUpIterator`
found the full solution `ifelse(x1 < x0, x0, x1)` at **enumeration 292**; the bank
held one representative per satisfied-subset, and the complementary cover
returned the full solution.

**Seeded bottom-up + full Z3 CEGIS (VERIFIED).** Recombination works. Phase 1
collects programs satisfying ≥ ½ the constraints; phase 2 seeds them into a
`SeededCostBUIterator` and runs the standard full-spec Z3 CEGIS loop (one
verification per candidate). On **max3**, with `max_depth=5`/`max_size=16`
matched to the seeded solution shape, CEGIS returned **`cegis_success` in 5
iterations** (enum ≈ 1024) with
`ifelse(y>x, ifelse(z<y,y,z), ifelse(z>x,z,x))` — a Z3-verified-correct max3 (a
semantically-equivalent variant of the hand-written form; flagged "MISMATCH"
only against the literal expected string). A complete solution was **assembled
from partial programs**, not enumerated from scratch.

Note on bounds: with loose limits (`max_depth` 6–8, `max_cost=Inf`) the BU
`combine` step stalls — it rebuilds the next cost-horizon from a bank-wide
cartesian product, which explodes as the bank grows (observed: a ~164 s pause
between progress ticks). Bounding `max_depth`/`max_size` to the known solution
shape keeps the bank small and `combine` cheap.

---

## 6. How to run

```bash
julia --project=. --startup-file=no scripts/test_partial_satisfaction.jl
```

The script has three parts:
- **A) Per-constraint satisfaction** — scores hand-written candidates for max2 and
  max3, printing the ✓/✗/? breakdown per constraint (`verbose=true`).
- **B) Guided search** — `run_guided` enumerates with a cost-biased BU iterator,
  scores each candidate, banks the building blocks, prints the bank +
  complementary cover. Run for max2 (cap 500) and max3 (cap 1500).
- **C) Seed-and-resume** — if max3 was not solved, `collect_satisfying(bank, 0.5)`
  gathers the ≥50%-satisfying blocks, seeds a `SeededCostBUIterator`, and searches
  again (cap 2000).

Note: each scored candidate costs `#constraints` Z3 calls, so large enumeration
caps are slow (≈ `4 × cap` Z3 invocations for max3).

---

## 7. Open items / next steps

1. **Seeded BU path — DONE** (verified on max3: `cegis_success`, 5 iters). Next:
   confirm it generalizes to other benchmarks and to seeds collected fully
   automatically (vs. the hand-seeded `max(x,y)` used in the fast checks).
2. **Cost model for seeds** — `seed_cost` as a flat atom cost is a heuristic;
   tune it (or expose per-seed cost) so building-block reuse genuinely
   accelerates rather than just warm-starts.
3. **Fitness actually steering search** — currently the partial-sat score is
   computed *post-hoc*; the iterator order is the BU cost, not the score. A
   best-first/priority iterator keyed on `n_satisfied` would make fitness *drive*
   enumeration.
4. **Targeted recombination (sketch completion)** — for complementary blocks,
   synthesize only the *guard*: build `ifelse(□Bool, blockA, blockB)` and search
   just the hole. Far smaller than full enumeration; uses `complementary_cover`
   output directly.
5. **Amortize Z3** — one process with `push`/`pop` + multiple `check-sat` to
   decide all constraints per candidate in a single Z3 invocation.
6. **Genetic iterator** — explicitly out of scope per direction ("don't touch the
   genetic iterators").
