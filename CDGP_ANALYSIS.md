# CDGP Implementation — Status & Gap Analysis vs. the Paper

Analysis of the Counterexample-Driven Genetic Programming (CDGP) implementation
in `src/GeneticSearch/` against Błądek & Krawiec's CDGP work
(*Counterexample-Driven Genetic Programming*, GECCO 2017; extended in
*Counterexample-Driven Genetic Programming: Heuristic Program Synthesis from
Formal Specifications*, **Evolutionary Computation** 27(3), 2019).

Date: 2026-06-16 · Branch: `ga-z3-guided-synthesis-poc`

---

## Verdict

Same skeleton as the paper. Lexicase selection is now implemented (opt-in);
remaining gaps:

- **Complete tests only** — no "incomplete tests" and no output-uniqueness
  check, so underdetermined specs are handled poorly.
- **Weak on relational / multi-invocation specs** (e.g. commutativity).

Resolved: ~~no lexicase selection~~ — `Arborist.evaluate_cases(::RuleNodeGenome,
::CDGPEvaluator)` plus a `selection=` kwarg on `run_cdgp` (see below).

Crucially, **accepted answers are always sound** — the final acceptance is a
real Z3 `:unsat` verification (`cdgp_evaluator.jl:97`). The gaps affect search
*completeness / efficiency*, not the correctness of a returned program.

---

## What is faithful to the paper

The core CDGP loop matches:

- Test set starts empty and grows from SMT counterexamples.
- Fitness = number of failed tests on the accumulated set (cheap interpretation
  only); `cdgp_evaluator.jl:112-145`.
- SMT is consulted **only** for test-perfect candidates (those passing all
  current tests); `cdgp_evaluator.jl:127`.
- Verification trichotomy: `:unsat` ⇒ solved, `:sat` ⇒ new test,
  `:unknown` ⇒ fitness `Inf`; `cdgp_evaluator.jl:82-103,127-142`.
- Sound final acceptance via a full counterexample query (`generate_cex_query`
  → `verify_query`); `cdgp_evaluator.jl:90-97`.

---

## Lexicase selection (implemented — opt-in)

`CDGPEvaluator` now implements `Arborist.evaluate_cases(g, e)`
(`cdgp_evaluator.jl`), returning a **per-test loss vector** (`0.0` pass / `1.0`
fail / `Inf` on a per-case interpreter exception). This is the per-test view of
the same loop the scalar `evaluate_genome` aggregates into a count.

`run_cdgp` takes a `selection=` kwarg (`run_cdgp.jl`); it defaults to
`Arborist.TournamentSelection(tournament_size)` (unchanged behavior). Pass
`Arborist.LexicaseSelection()` to use lexicase — each accumulated counterexample
test becomes a separate selection case.

**Why it is safe:** the solve loop materializes the case matrix
(`_compute_case_fitnesses`, `solve.jl:564`) **separately** from the scalar
`evaluate_genome` pass (`solve.jl:597`) that drives Z3 verification, test-set
growth, and solved-detection. `evaluate_cases` is therefore **side-effect-free**
(no Z3, no test growth) so the test set is constant across one matrix build ⇒
the matrix stays rectangular (lexicase indexes assume uniform length,
`selection.jl:101`), and all CDGP machinery keeps running through the unchanged
scalar path. Tournament vs. lexicase can be compared with
`scripts/run_cdgp_benchmarks.jl`; results are in
[`CDGP_BENCHMARK_RESULTS.md`](CDGP_BENCHMARK_RESULTS.md) (lexicase converges in
far fewer generations but ~4× per-gen cost).

---

## Gaps vs. the paper (ordered by impact)

### 1. Complete tests only — no incomplete tests, no uniqueness check (biggest)

The paper distinguishes:

- **complete test** `(input, output)` — usable only when the spec **uniquely
  determines** the output at that input;
- **incomplete test** `(input, —)` — passes iff the program's output
  *satisfies the postcondition* (checked against the constraints), used when the
  output is not unique.

The implementation always builds a complete test: it reads one spec-valid value
from the model's `out_<f>` constant and asserts `program(input) == out`
(`cdgp_evaluator.jl:100-102`). For **underdetermined specs**, `out_<f>` is just
*an arbitrary* valid output, so a genuinely-correct program that returns a
*different but equally valid* output will "fail" that test → it never reaches
`failed == 0` → it is never sent to verification → **CDGP can fail to recognize
a correct solution.** The paper avoids this with incomplete tests + an
output-uniqueness query. Neither is present here.

Consequence: fine for pointwise specs that uniquely fix the output
(max, abs, …) — which is why max2–max4 solve — but degrades on
underdetermined specs.

### 2. Fresh-constant substitution collapses multiple invocations

`substitute_synth_calls` (`query.jl:40`) replaces *every* `(f …)` with the
*same* `out_f`. A relational constraint like `(= (max2 x y) (max2 y x))` becomes
`(= out_max2 out_max2)` — vacuous. The candidate-violation half of the query
still works (it uses the real `define-fun`), but the extracted *expected output*
is then unconstrained garbage. So commutativity-style / relational specs cannot
produce meaningful complete tests. (Inherited from the shared CEX query
generator; also affects `Z3Oracle`.)

### 3. Single synth-fun assumption

`spec.synth_funs[1]` is used throughout (`cdgp_evaluator.jl:55,65,71`). The
paper's framework is general; most SyGuS benchmarks are single-function, so this
is minor in practice.

### 4. Minor issues

- `expected = get(r.model, "out_$(f)", 0)` silently defaults to `0` if the model
  lacks the constant (`cdgp_evaluator.jl:101`).
- Initialization is `rand(RuleNode, max_depth)` rather than ramped
  half-and-half.

Both are low-impact.

---

## Recommended next steps

1. ~~Lexicase path~~ — **done** (`evaluate_cases` + `selection=` kwarg). Use
   `scripts/run_cdgp_benchmarks.jl` to compare tournament vs. lexicase.
2. **Incomplete tests for non-unique specs (more involved):** detect when the
   output is not uniquely determined, and either record an incomplete test
   (checked against the postcondition) or fix the per-invocation fresh-constant
   handling so relational specs extract meaningful tests.

---

## Reference: key files

| Concern | Location |
|---|---|
| Fitness / verification loop | `src/GeneticSearch/cdgp_evaluator.jl` |
| GA driver, selection, rounds | `src/GeneticSearch/run_cdgp.jl` |
| Full CEX query + `out_<f>` extraction | `src/CEXGeneration/query.jl` |
| Per-constraint (graded) query | `src/CEXGeneration/graded.jl` |
| Arborist selection strategies | `~/.julia/dev/Arborist/src/operators/selection.jl` |
| Arborist case-matrix materialization | `~/.julia/dev/Arborist/src/solve.jl:564` |
| Benchmark runner (max2–max5) | `scripts/run_cdgp_benchmarks.jl` |
