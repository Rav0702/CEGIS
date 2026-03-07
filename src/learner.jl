"""
    Learner Component
    =================

Responsible for the **Learning** phase of the CEGIS loop.

After the `Verifier` produces a `Counterexample`, the `Learner` translates it
into *structural knowledge* — grammar constraints — that prune the search space
for the next synthesis round.  This is the key ingredient that makes CEGIS
converge faster than blind enumeration.

Relationship to other components
---------------------------------

    [Verifier] ──▶ Counterexample
                          │
                          ▼
                     [Learner]
                    ┌─────────────────────────────────────────┐
                    │  learn_constraint                        │
                    │    └─▶ generalize_counterexample         │
                    │          (from counterexample.jl)        │
                    │  add_constraint_to_grammar!              │
                    │    └─▶ HerbGrammar.addconstraint!        │
                    └─────────────────────────────────────────┘
                          │
                          ▼  updated grammar (fewer candidates)
                   [Synthesizer]   ──uses──▶ ProgramIterator

Key Herb types involved
-----------------------
- `HerbConstraints.AbstractGrammarConstraint` — Added to the grammar to prune
  the search space.
- `HerbGrammar.addconstraint!`               — Attaches a constraint to a
  `ContextSensitiveGrammar`.
- `HerbGrammar.clearconstraints!`            — Resets all learned constraints
  (useful if a full restart is needed).
- `HerbConstraints.Forbidden`               — Example built-in constraint that
  forbids specific rule sequences.
- `HerbConstraints.Ordered`                 — Enforces ordering constraints.
"""

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

"""
    learn_constraint(cx, candidate, grammar) -> AbstractGrammarConstraint

**[NOT IMPLEMENTED]**

Entry point for constraint learning.  Given a counterexample and the program
that failed, produce a grammar constraint that eliminates *at least* the
failing candidate from future synthesis rounds, and ideally rules out all
programs with the same structural defect.

Implementation notes
--------------------
1. Call `generalize_counterexample(cx, candidate, grammar)` (from
   `counterexample.jl`) to lift the concrete witness to a structural pattern.
2. Return the resulting `AbstractGrammarConstraint`.

Strategy options (choose one or combine)
-----------------------------------------
- **Forbidden sub-tree** : Wrap the failing sub-tree of `candidate` in a
  `HerbConstraints.Forbidden` constraint.
- **Ordered constraint** : If the failure is due to evaluation order, emit a
  `HerbConstraints.Ordered` constraint.
- **Custom constraint** : Implement a new `AbstractGrammarConstraint` /
  `AbstractLocalConstraint` pair in `HerbConstraints` and register it here.
- **SMT-derived** : Use the oracle's UNSAT core (from `oracle_from_smt`) to
  derive a compact constraint.

Participants
------------
- Produces  : `HerbConstraints.AbstractGrammarConstraint`
- Consumes  : `Counterexample`, `HerbCore.RuleNode`, `HerbGrammar.AbstractGrammar`

Called by: `run_cegis` in `cegis.jl` after each failed verification.
"""
function learn_constraint(
    cx        :: Counterexample,
    candidate :: RuleNode,
    grammar   :: AbstractGrammar,
) :: AbstractGrammarConstraint
    error("learn_constraint is not yet implemented. " *
          "Call generalize_counterexample and return the resulting AbstractGrammarConstraint.")
end

"""
    add_constraint_to_grammar!(grammar, constraint) -> Nothing

**[NOT IMPLEMENTED]**

Attach a learned `AbstractGrammarConstraint` to the grammar so that the next
`ProgramIterator` construction will respect it.

Implementation notes
--------------------
- Call `HerbGrammar.addconstraint!(grammar, constraint)`.
- No return value needed (mutates `grammar` in place).

Participants
------------
- Mutates   : `HerbGrammar.ContextSensitiveGrammar`
- Consumes  : `HerbConstraints.AbstractGrammarConstraint`

Called by: `run_cegis` immediately after `learn_constraint`.
"""
function add_constraint_to_grammar!(
    grammar    :: AbstractGrammar,
    constraint :: AbstractGrammarConstraint,
) :: Nothing
    error("add_constraint_to_grammar! is not yet implemented. " *
          "Call HerbGrammar.addconstraint!(grammar, constraint).")
end

"""
    reset_learned_constraints!(grammar, original_constraints) -> Nothing

**[NOT IMPLEMENTED]**

Restore the grammar to its original set of constraints (i.e., remove all
constraints added by the learner during the CEGIS run).

Implementation notes
--------------------
- `HerbGrammar.clearconstraints!(grammar)` removes all constraints.
- Then re-add each constraint from `original_constraints` with
  `HerbGrammar.addconstraint!`.

When to call
------------
- When restarting a CEGIS run with a different strategy.
- When the accumulated constraints make synthesis too slow and a fresh start
  (with all counterexamples as IOExamples but no structural constraints) is
  preferred.

Participants
------------
- Mutates   : `HerbGrammar.ContextSensitiveGrammar`
- Consumes  : `Vector{AbstractGrammarConstraint}` (original constraints snapshot)
"""
function reset_learned_constraints!(
    grammar              :: AbstractGrammar,
    original_constraints :: Vector{<:AbstractGrammarConstraint},
) :: Nothing
    error("reset_learned_constraints! is not yet implemented. " *
          "Call clearconstraints! then re-add each constraint from original_constraints.")
end

"""
    constraints_from_counterexamples(counterexamples, grammar) -> Vector{AbstractGrammarConstraint}

**[NOT IMPLEMENTED]**

Batch-learn constraints from an entire history of counterexamples.  Useful
when resuming a CEGIS run or when constraints time out and the grammar must be
rebuilt from scratch.

Implementation notes
--------------------
- Call `learn_constraint` for each `(cx, candidate)` pair recorded in the
  CEGIS history.
- Deduplicate identical constraints before returning.

Participants
------------
- Produces  : `Vector{HerbConstraints.AbstractGrammarConstraint}`
- Consumes  : `Vector{Counterexample}`

Called by: `run_cegis` if a full restart is requested (not in the hot path).
"""
function constraints_from_counterexamples(
    counterexamples :: Vector{Counterexample},
    grammar         :: AbstractGrammar,
) :: Vector{AbstractGrammarConstraint}
    error("constraints_from_counterexamples is not yet implemented. " *
          "Map learn_constraint over counterexamples and deduplicate.")
end
