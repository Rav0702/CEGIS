# Per-Constraint Satisfaction Checking

How CEGIS determines, for a candidate program and a SyGuS spec, **which constraints
the candidate satisfies for all inputs** — and how that check is executed (subprocess
by default, in-process persistent `Z3.Solver` behind a flag).

---

## The question, and why the cex query can't answer it

There are two distinct Z3 queries:

| Query | File | Question | Verifier | Result |
|---|---|---|---|---|
| `generate_cex_query` / `generate_query` | `query.jl` | "Is the candidate correct? If not, give one counterexample." | `verify_query` | `Z3Result{status, model, unsat_core}` |
| `generate_satisfaction_query` | `constraint_satisfaction.jl` | "For **each** constraint, does the candidate satisfy it for **all** inputs?" | `check_constraint_satisfaction` | `ConstraintSatResult` |

The cex query bundles all constraints into one `(not (and C1 … Cn))` check. On `:sat`
it returns a **single counterexample input** — which constraints are false there is a
property of *that one input*, not of the candidate. The same wrong candidate can
appear to break different constraint sets on different runs. Example — `max4 = x0`:

| Z3's counterexample | constraints false there |
|---|---|
| `(0,5,0,0)` | `{2}` |
| `(-2,0,-1,-1)` | `{2,3,4}` |

To get the **stable, input-independent** answer ("does the candidate violate
constraint *i* for *any* input?") each constraint must be checked on its own. That is
what per-constraint satisfaction checking does.

---

## Method 2 — assumption literals over one solver session

A constraint `Cᵢ` is satisfied for all inputs iff `(not Cᵢ)` is **unsat** once the
candidate is inlined as a `define-fun`. The naive way is one z3 process per
constraint. *Method 2* (`constraint_satisfaction.jl`) does it in a single session:

1. build the candidate-independent context (declarations + candidate `define-fun`)
   once,
2. introduce one Boolean **assumption literal** `pᵢ` per constraint with
   `(assert (=> pᵢ (not Cᵢ)))`,
3. run `(check-sat-assuming (pᵢ))` once per constraint.

Assuming `pᵢ` forces `(not Cᵢ)`; the other `pⱼ` stay free, so Z3 sets them false and
their implications go vacuous — **only `Cᵢ` is active**. Each check is independent and
sound:

* `unsat` ⟹ no input violates `Cᵢ` ⟹ satisfied (`bit = true`)
* `sat`   ⟹ some input violates `Cᵢ` ⟹ violated  (`bit = false`)

`(echo "csat_i")` markers delimit the results. The verdict is returned as:

```julia
struct ConstraintSatResult
    constraints :: Vector{String}   # spec order
    satisfied   :: Vector{Bool}     # satisfied[i] ⟺ Cᵢ holds for all inputs
    status      :: Vector{Symbol}   # :unsat (satisfied), :sat (violated), :unknown
end
```

Helpers: `n_satisfied`, `all_satisfied`, `satisfied_indices`, `violated_indices`.

```julia
check_constraint_satisfaction(spec, "max2", "(ite (< x0 x1) x1 x0)")  # all satisfied
check_constraint_satisfaction(spec, "max4", "x0")                     # violated_indices → [2,3,4]
```

By default this runs one `z3` **subprocess** per candidate (`_z3_exec` in
`z3_verify.jl`) — temp file + re-parse, but only one process (not N).

---

## In-process warm solver (`ConstraintSatSolver`)

`ConstraintSatSolver` (`constraint_satisfaction_solver.jl`) keeps the same Method 2
algorithm but on a **persistent in-process `Z3.Solver`** (Z3.jl high-level API), so the
constraint AST is built once and reused across candidates — no subprocess, no
re-parse.

### Mechanism
- Free-var consts (`x0…xn`), the synth-output const `out`, and every
  `(=> pᵢ (not Cᵢ))` are built as `Z3.Expr` and asserted **once** at construction
  (`(not Cᵢ)` maps the canonical application `(f x0…xn)` to `out`).
- `check_constraint_satisfaction(css, candidate_exprs)`: convert the candidate body to
  a `Z3.Expr` (`_csat_to_z3`, mirroring `rulenode_to_smt2`'s Bool↔Int coercion;
  parsed via `sexp.jl`), `push`, assert `out == candidate(inputs)`, then run one
  `check-sat-assuming (pᵢ)` per constraint, `pop`.
- Returns the same `ConstraintSatResult`. Because the result carries no witness, there
  is **no model extraction and no error-handler machinery** — `check-sat-assuming` is
  the only solver call.

Arithmetic/comparison builders (`+ - * >= > <= = distinct`) drop to `Z3.Libz3` (absent
from the high-level API); everything else uses `Z3.And/Or/Not/If/IntVal/IntVar`.

### Scope
Fast path assumes a single synth-fun whose only application in the constraints is the
canonical `(f x0…xn)` over the declared free vars (the common case; e.g. the max
family), with LIA-integer comparisons. Anything else (swapped/!= arg order,
multi-application or relational specs, multiple synth-funs) raises during
construction — callers fall back to the subprocess path (see the flag below).

---

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `CEGIS_CSAT_INPROCESS` | unset (`"0"`) | `=1` routes the stateless `check_constraint_satisfaction(spec, …)` through `ConstraintSatSolver` (in-process), with an automatic `try/catch` **fallback to the subprocess** for out-of-scope specs. Default is unchanged (subprocess) for backwards compatibility. |

For maximum throughput, construct a `ConstraintSatSolver(spec)` once and call
`check_constraint_satisfaction(css, …)` per candidate directly — that reuses the
constraint AST across candidates (the flag rebuilds it per stateless call).

---

## Files

| Concern | File | Key symbols |
|---|---|---|
| cex query (one counterexample) | `src/CEXGeneration/query.jl` | `generate_query`, `generate_cex_query` |
| cex verifier / subprocess primitives | `src/CEXGeneration/z3_verify.jl` | `verify_query`, `Z3Result`, `_z3_exec`, `_z3_run` |
| Method 2 (subprocess) | `src/CEXGeneration/constraint_satisfaction.jl` | `generate_satisfaction_query`, `check_constraint_satisfaction`, `ConstraintSatResult`, `n_satisfied`/`all_satisfied`/`satisfied_indices`/`violated_indices`; `CEGIS_CSAT_INPROCESS` dispatch |
| Method 2 (in-process warm solver) | `src/CEXGeneration/constraint_satisfaction_solver.jl` | `ConstraintSatSolver`, `check_constraint_satisfaction(css, …)`, `_csat_to_z3` |
| candidate → SMT-LIB2 | `src/CEXGeneration/rulenode_to_smt.jl` | `rulenode_to_smt2` |
| s-expression reader | `src/CEXGeneration/sexp.jl` | `read_sexprs`, `sexp_to_str` |

## Tests & benchmark

- `test/test_constraint_satisfaction.jl` — subprocess Method 2 (45 checks).
- `test/test_constraint_satisfaction_solver.jl` — `ConstraintSatSolver` known values,
  **parity with the subprocess path**, param-name renaming, the flag routing, and the
  out-of-scope fallback (42 checks).
- `scripts/benchmark_constraint_satisfaction.jl` — subprocess vs in-process, parity +
  timing (inline max specs, random candidate bodies).

```bash
julia --project=. test/runtests.jl                          # default (subprocess)
CEGIS_CSAT_INPROCESS=1 julia --project=. test/runtests.jl   # flag on (parity)
julia --project=. scripts/benchmark_constraint_satisfaction.jl
```

Both flag states: **181/181** passing.
