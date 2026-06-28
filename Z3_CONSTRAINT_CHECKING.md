# Z3 Constraint Checking & In-Process Backend

How CEGIS turns a candidate program + a SyGuS spec into Z3 queries, what each query
answers, and how those queries are executed. Three capabilities are documented here,
in the order they build on each other:

1. **Per-constraint failure attribution (SAT side)** — which constraints a wrong
   candidate violates *at a counterexample*.
2. **Universal per-constraint check (one query)** — which constraints a candidate
   violates *over all inputs*, in a single Z3 call.
3. **In-process Z3 backend** — run the constructed query strings via
   `Z3_eval_smtlib2_string` instead of spawning the `z3` binary (~10× faster),
   with a subprocess fallback.

All three preserve the existing public API (`verify_query`, `verify_graded_query`,
`Z3Result`, `ConstraintResult`) and parsers.

---

## 0. Background: the two query families

| Query builder | File | Question it answers | Verifier | Result |
|---|---|---|---|---|
| `generate_query` / `generate_cex_query` | `src/CEXGeneration/query.jl`, `CEXGeneration.jl` | "Is the candidate correct? If not, give one counterexample." | `verify_query` | `Z3Result` |
| `generate_graded_query` | `src/CEXGeneration/graded.jl` | "For each constraint, does the candidate satisfy it for **all** inputs?" | `verify_graded_query` | `Vector{ConstraintResult}` |

The cex query bundles all constraints into one `(not (and c1 … cn))` check (one
sat/unsat verdict + one counterexample). The graded family checks each constraint
independently and is the basis of the graded GA fitness (`Z3GradedEvaluator`).

A legacy one-constraint-per-call helper, `generate_constraint_check_query`
(`graded.jl`), still exists for the standalone dump script (`max4_query_dump.jl`)
but is no longer used by the evaluator (superseded by §2).

---

## 1. Per-constraint failure attribution (SAT side)

### Problem
On `:sat`, `verify_query` historically returned only the counterexample input — not
which constraints the candidate actually broke. The unsat-core machinery
(`:named` assertions + `get-unsat-core`) only produces a core on `:unsat`, and even
then it degenerates to the single bundled `candidate_check` label, so it never
attributes failures for a wrong candidate.

### Mechanism
Cores don't exist for SAT, but a SAT result has a *model*. `generate_query`
(`query.jl`) therefore defines one Bool indicator per constraint over the candidate
and reads them back:

```smt
(define-fun cand_c_1 () Bool <constraint 1 with (f …) → candidate>)
...
(get-value (cand_c_1 cand_c_2 … cand_c_n))
```

`false` ⇒ the candidate violates that constraint at the counterexample.

- `Z3Result` (`z3_verify.jl`) gained `violated_constraints::Vector{Int}` (1-based
  indices into `spec.constraints`); a 3-arg back-compat constructor defaults it to
  `Int[]`.
- `_extract_violated_constraints!` (`z3_verify.jl`) pops the `cand_c_*` entries out
  of the parsed model (keeping `model` clean) and returns the violated indices.
- `verify_query` populates it on `:sat`; `format_result` and `z3_oracle.jl` print it.

### ⚠️ Per-point, not universal
The returned set is a property of the **(candidate, counterexample)** pair, not the
candidate. Z3 may return any falsifying input, so the same wrong candidate can report
different sets on different runs. Example — `max4 = x0`:

| Z3's counterexample | reported `violated_constraints` |
|---|---|
| `(0,5,0,0)` | `[2]` |
| `(-2,0,-1,-1)` | `[2,3,4]` |

Use this for "explain *this* failure". For the stable, input-independent answer, use §2.

---

## 2. Universal per-constraint check (one query)

### Problem
The universal question — "does the candidate violate constraint *i* for **some**
input?" — is an independent ∃-query per constraint, so N constraints need N
satisfiability checks. The old evaluator paid N **separate `z3` process spawns** per
candidate (re-parsing the preamble each time).

### Mechanism
`generate_graded_query` (`graded.jl`) emits the preamble + candidate `define-fun`
**once**, then probes each constraint in its own scope:

```smt
(push 1) (assert (not c_i)) (check-sat) (get-value (<free vars>)) (pop 1)
```

One Z3 call, N independent verdicts. `verify_graded_query` parses the per-constraint
`(check-sat)` results in order into `Vector{ConstraintResult}`:

```julia
struct ConstraintResult
    status::Symbol               # :unsat ⇒ satisfied ∀ inputs; :sat ⇒ violated; :unknown
    witness::Dict{String,Any}    # free-var counterexample when :sat, else empty
end
```

`status == :unsat` for every constraint ⇒ candidate is formally correct.

### Used by
`Z3GradedEvaluator.evaluate_genome` (`src/GeneticSearch/z3_evaluator.jl`) — one
`generate_graded_query` + `verify_graded_query` per candidate (was N subprocess
calls). Fitness = number of `:sat` constraints; `0` ⇒ verified. The first violated
constraint's witness steers counterexample-targeted mutation.

### Stable results (`max4`)
| candidate | universal violated |
|---|---|
| `x0` | `[2,3,4]` (every run) |
| `(+ (+ x0 x1) (+ x2 x3))` | `[1,2,3,4,5]` |
| `(ite (>= (ite (>= x0 x1) x0 x1) (ite (>= x2 x3) x2 x3)) …)` (correct) | `[]` |

---

## 3. In-process Z3 backend

### Problem
Every verification shelled out to the `z3` binary via `_z3_run` (`z3_verify.jl`):
temp-file write → subprocess spawn → stdout read → SMT re-parse. In the GA loop
(thousands of candidates) this overhead dominates.

### Mechanism
Z3's C API exposes `Z3_eval_smtlib2_string(ctx, str)`, which runs the **same query
string** in-process and returns the **same output text**. `_z3_eval` (`z3_verify.jl`)
wraps it; `_z3_solve` dispatches:

```julia
_z3_solve(query) = get(ENV, "CEGIS_Z3_SUBPROCESS", "0") == "1" ?
                   _z3_run(query) : _z3_eval(query)
```

`verify_query` and `verify_graded_query` call `_z3_solve`. Output format is identical,
so all parsers (`_parse_get_value_output`, `_parse_unsat_core`,
`_extract_violated_constraints!`, the `verify_graded_query` line-parser) are reused
unchanged — they already skip interleaved `(error …)` lines.

### Three gotchas (the reason `_z3_eval` looks the way it does)

1. **No-op error handler is required.** With the default context, *any* SMT error
   mid-script — notably `get-value` after an `unsat` `check-sat` — aborts the whole
   process. A no-op handler makes Z3 continue and **return** the output instead,
   leaving a harmless `(error "model is not available")` line that the parsers skip.
   This is how "on unsat, ignore the model error and report a correct candidate"
   works.
2. **Z3.jl's `Z3_set_error_handler` wrapper is mistyped** (`Z3_error_handler = Cvoid`),
   so the handler pointer is installed via a raw `ccall(..., Ptr{Cvoid}, ...)`. The
   handler is a top-level `@cfunction` const (`_Z3_ERR_HANDLER`) for a stable pointer.
3. **Fresh context per call.** Reusing a context accumulates assertions and re-runs
   `set-logic` → errors and wrong results. Each query gets its own `Z3_mk_context`
   (freed in a `finally`; the result is `unsafe_string`-copied before the context is
   deleted). Single-threaded use only — CEGIS runs serial.

### Performance (max4 graded check, wrong candidate)
| backend | per call |
|---|---|
| in-process | **8.44 ms** |
| subprocess | 85.24 ms |

≈ **10×**, on every Z3 path (cex oracle, CDGP verification, graded GA).

### Known limitation
With the no-op handler an **ill-typed** SMT candidate is silently dropped and can
surface as `:sat` rather than `:unknown`. CEGIS builds candidates from a typed
grammar with type-aware converters, so this should not arise in practice; set
`CEGIS_Z3_SUBPROCESS=1` to fall back if it ever matters.

---

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `CEGIS_Z3_SUBPROCESS` | unset (`"0"`) | `=1` routes all Z3 calls through the `z3` subprocess (`_z3_run`) instead of in-process. |

---

## Files

| Concern | File | Key symbols |
|---|---|---|
| Cex query + SAT attribution | `src/CEXGeneration/query.jl` | `generate_query` (`cand_c_*` indicators + `get-value`) |
| Universal one-query graded | `src/CEXGeneration/graded.jl` | `generate_graded_query`, `verify_graded_query`, `ConstraintResult`; legacy `generate_constraint_check_query` |
| Result type + backends + parsing | `src/CEXGeneration/z3_verify.jl` | `Z3Result.violated_constraints`, `_extract_violated_constraints!`, `_z3_run`, `_z3_eval`, `_z3_solve`, `_Z3_ERR_HANDLER`, `verify_query`, `format_result` |
| Exports | `src/CEXGeneration/CEXGeneration.jl` | `generate_graded_query`, `verify_graded_query`, `ConstraintResult` |
| Graded GA fitness | `src/GeneticSearch/z3_evaluator.jl` | `Z3GradedEvaluator.evaluate_genome` |
| Oracle logging | `src/Oracles/z3_oracle.jl` | prints `violated_constraints` on SAT |

## Tests & demo

- `test/test_constraint_failure_attribution.jl` — SAT attribution (`violated_constraints`)
  and the universal one-query graded check; wired into `test/runtests.jl`.
- `test/test_inprocess_z3.jl` — direct `_z3_eval`, in-process `verify_query` /
  `verify_graded_query`, and an in-process-vs-subprocess parity check.
- `scripts/demo_inprocess_z3.jl` — end-to-end demo + backend timing comparison.

Run:
```bash
julia --project=. test/runtests.jl                       # in-process (default)
CEGIS_Z3_SUBPROCESS=1 julia --project=. test/runtests.jl # subprocess fallback (parity)
julia --project=. scripts/demo_inprocess_z3.jl           # demo + timing
```
Both backends: **153/153** passing.
