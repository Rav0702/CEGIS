"""
    Counterexample Component
    ========================

Responsible for **managing and refining counterexamples** between CEGIS rounds.

A raw `Counterexample` comes from the `Verifier`.  Before it is given back to
the `Synthesizer`, it may be:
  1. Minimized   — remove superfluous parts of the input that are irrelevant to
                   the failure (delta-debugging / MUC-like reduction).
  2. Generalized — lift the concrete counterexample to a constraint that rules
                   out entire *families* of wrong programs rather than just the
                   one instance.
  3. Deduplicated — check whether the oracle has seen this counterexample
                   before (avoid infinite loops).

Relationship to other components
---------------------------------

    [Verifier] ──▶ raw Counterexample
                          │
                          ▼
               [CounterexampleManager]
                ├── minimize_counterexample
                ├── generalize_counterexample  ──▶ AbstractGrammarConstraint
                └── is_duplicate_counterexample
                          │
              ┌───────────┴─────────────────┐
              ▼                             ▼
       [Synthesizer]               [Learner]
    (new IOExample added)    (new grammar constraint added)

Key Herb types involved
-----------------------
- `HerbSpecification.IOExample`          — Converted from `Counterexample`.
- `HerbConstraints.AbstractGrammarConstraint` — Produced by generalization.
- `HerbCore.RuleNode`                    — Used during minimization to re-run
  the program on a smaller input.
- `HerbInterpret.execute_on_input`       — Checks whether a smaller input still
  witnesses the failure.
"""

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

"""
    counterexample_to_ioexample(cx) -> IOExample

**[NOT IMPLEMENTED]**

Convert a `Counterexample` (from `types.jl`) to a `HerbSpecification.IOExample`
so it can be appended to `Problem.spec`.

Implementation notes
--------------------
    IOExample(cx.input, cx.expected_output)

Participants
------------
- Produces  : `HerbSpecification.IOExample`
- Consumes  : `Counterexample`

Called by: `update_problem_with_counterexample!` in `synthesizer.jl`.
"""
function counterexample_to_ioexample(cx :: Counterexample) :: IOExample
    error("counterexample_to_ioexample is not yet implemented. " *
          "Return IOExample(cx.input, cx.expected_output).")
end

"""
    minimize_counterexample(cx, candidate, grammar) -> Counterexample

**[NOT IMPLEMENTED]**

Apply delta-debugging or a MUC-inspired reduction (see `ConflictAnalysis.jl`)
to shrink the counterexample input while preserving the failure.

Algorithm sketch
----------------
1. For each key `k` in `cx.input`, try removing it and re-run
   `HerbInterpret.execute_on_input(tab, expr, reduced_input)`.
2. If the program still fails with the reduced input → keep the reduction.
3. Repeat until no more keys can be removed.

Implementation notes
--------------------
- Use `HerbGrammar.rulenode2expr` + `HerbGrammar.grammar2symboltable` to get
  the executable expression.
- Call `HerbInterpret.execute_on_input` on the reduced inputs.
- Preserve the invariant that `reduced.expected_output` is unchanged.

Participants
------------
- Produces  : smaller `Counterexample`
- Consumes  : `Counterexample`, `HerbCore.RuleNode`, `HerbGrammar.AbstractGrammar`

Called by: `run_cegis` loop between verification and synthesis steps.
"""
function minimize_counterexample(
    cx        :: Counterexample,
    candidate :: RuleNode,
    grammar   :: AbstractGrammar,
) :: Counterexample
    error("minimize_counterexample is not yet implemented. " *
          "Apply delta-debugging: remove input keys that are not needed to reproduce the failure.")
end

"""
    generalize_counterexample(cx, candidate, grammar) -> AbstractGrammarConstraint

**[NOT IMPLEMENTED]**

Lift a concrete `Counterexample` to a `HerbConstraints.AbstractGrammarConstraint`
that rules out *all* programs exhibiting the same structural fault.

Algorithm sketch
----------------
- Inspect the sub-tree of `candidate` responsible for the wrong output (e.g.,
  via symbolic execution or pattern matching).
- Build a `HerbConstraints.Forbidden` or custom `AbstractGrammarConstraint` that
  excludes programs with that sub-tree shape.
- Alternatively, encode the constraint as an `SMTSpecification` and feed it to
  an SMT-based learner (see `learner.jl`).

Participants
------------
- Produces  : `HerbConstraints.AbstractGrammarConstraint`
- Consumes  : `Counterexample`, `HerbCore.RuleNode`, `HerbGrammar.AbstractGrammar`

Called by: `Learner.learn_constraint` in `learner.jl`.
"""
function generalize_counterexample(
    cx        :: Counterexample,
    candidate :: RuleNode,
    grammar   :: AbstractGrammar,
) :: AbstractGrammarConstraint
    error("generalize_counterexample is not yet implemented. " *
          "Extract a grammar constraint that blocks the structural root cause of cx.")
end

"""
    is_duplicate_counterexample(cx, seen) -> Bool

**[NOT IMPLEMENTED]**

Check whether `cx` is semantically equivalent to any counterexample in `seen`.

Implementation notes
--------------------
- Compare `cx.input` with each element of `seen` (dict equality).
- If the inputs are identical → return `true`.
- Optionally hash inputs for faster lookup.

Guards against: infinite loops where the verifier repeatedly returns the same
counterexample and the synthesizer keeps producing the same wrong program.

Participants
------------
- Produces  : `Bool`
- Consumes  : `Counterexample`, `Vector{Counterexample}`

Called by: `run_cegis` before incorporating a new counterexample.
"""
function is_duplicate_counterexample(
    cx   :: Counterexample,
    seen :: Vector{Counterexample},
) :: Bool
    error("is_duplicate_counterexample is not yet implemented. " *
          "Return true if cx.input matches any element of seen.")
end
