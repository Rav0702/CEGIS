"""
    Verifier Component
    ==================

Responsible for the **Verification** phase of the CEGIS loop.

Given a candidate `HerbCore.RuleNode` program that satisfies all currently
known examples, the verifier checks whether the program is *universally*
correct — i.e., correct on *all* possible inputs, not just the training set.

When the program is wrong, the verifier produces a `Counterexample` (an input
on which the program fails) that is fed back to the Synthesizer to rule out
this class of programs.

Relationship to other components
---------------------------------

    [Synthesizer]  ──▶ RuleNode candidate
                              │
                              ▼
                        [Verifier]  ──uses──▶  oracle (from Oracles module)
                              │                HerbInterpret.execute_on_input
                              │                HerbGrammar.rulenode2expr
                              │
             ┌────────────────┴──────────────────┐
             ▼                                   ▼
        verified = true                  counterexample_found
             │                                   │
      return CEGISResult                  Counterexample ──▶ [Learner] + [Synthesizer]

Key Herb types involved
-----------------------
- `HerbCore.RuleNode`            — The candidate program tree.
- `HerbGrammar.rulenode2expr`    — Converts a `RuleNode` to a Julia `Expr`.
- `HerbGrammar.grammar2symboltable` — Builds the symbol table for interpretation.
- `HerbInterpret.execute_on_input`  — Executes the expression on one input.
- `HerbSpecification.IOExample`  — Used when the oracle is test-based.

Oracle implementations are defined in the Oracles module (Oracles/Oracles.jl).
"""

# ─────────────────────────────────────────────────────────────────────────────
# Note: AbstractOracle and IOExampleOracle are defined in Oracles/Oracles.jl
# and imported through CEGIS module initialization.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Verification functions
# ─────────────────────────────────────────────────────────────────────────────

"""
    verify(candidate, grammar, oracle) -> VerificationResult

**[NOT IMPLEMENTED]**

Check whether `candidate` is universally correct by calling `oracle`.

The `oracle` is a user-supplied `Function` with signature:

    oracle(candidate::RuleNode, grammar::AbstractGrammar) -> VerificationResult

Possible oracle implementations
--------------------------------
1. **SMT-based**  : Encode the program semantics in an SMT theory and use a
   solver (e.g., Z3 via `Satisfiability.jl`) to search for a falsifying input.
2. **Test-based** : Evaluate the program on a held-out or randomly generated
   test set using `HerbInterpret.execute_on_input`.
3. **Type-based** : Use a dependent-type checker (e.g., Agda — see
   `HerbSpecification.AgdaSpecification`) to prove correctness.

Implementation notes
--------------------
- Convert `candidate` to a Julia expression first:
      expr = HerbGrammar.rulenode2expr(candidate, grammar)
- Pass `expr` together with the grammar's symbol table to the oracle.
- Wrap the oracle output in `VerificationResult`.
- Catch exceptions from the oracle and return a `VerificationResult` with
  `status = verification_error`.

Participants
------------
- Produces  : `VerificationResult` (see `types.jl`)
- Consumes  : `HerbCore.RuleNode`, `HerbGrammar.AbstractGrammar`, oracle `Function`

Called by: CEGIS main loop in `cegis.jl`.
"""
function verify(
    candidate :: RuleNode,
    grammar   :: AbstractGrammar,
    oracle    :: Function,
) :: VerificationResult
    error("verify is not yet implemented. " *
          "Convert candidate via rulenode2expr then delegate to the oracle.")
end

"""
    oracle_from_examples(held_out_examples) -> Function

**[NOT IMPLEMENTED]**

Build a simple test-based oracle from a collection of `IOExample`s that were
*not* shown to the synthesizer (i.e., a held-out test set).

This is a convenience factory that returns a closure usable as the `oracle`
field of a `CEGISProblem`.

Implementation notes
--------------------
- For each example `(input, expected)` in `held_out_examples`:
    1. `expr = HerbGrammar.rulenode2expr(candidate, grammar)`
    2. `tab  = HerbGrammar.grammar2symboltable(grammar)`
    3. `out  = HerbInterpret.execute_on_input(tab, expr, input)`
    4. If `out ≠ expected` → return `VerificationResult(counterexample_found,
       Counterexample(input, expected, out))`.
- If all examples pass → return `VerificationResult(verified, nothing)`.

Participants
------------
- Produces  : `Function` (oracle closure)
- Consumes  : `Vector{IOExample}` from `HerbSpecification`

Used by: `CEGISProblem` constructor in user code / pipeline.
"""
function oracle_from_examples(
    held_out_examples :: AbstractVector
) :: Function
    error("oracle_from_examples is not yet implemented. " *
          "Return a closure over held_out_examples that runs execute_on_input " *
          "and wraps the result in VerificationResult.")
end

"""
    oracle_from_smt(formula) -> Function

**[NOT IMPLEMENTED]**

Build a formal oracle backed by an SMT solver.  The `formula` can be a
`HerbSpecification.SMTSpecification` or a raw Z3 / CVC5 formula.

Implementation notes
--------------------
- Encode the candidate program's semantics as SMT constraints.
- Assert the negation of the specification formula.
- If `SAT` → extract a model and construct a `Counterexample`.
- If `UNSAT` → return `VerificationResult(verified, nothing)`.
- Reuse the incremental solver infrastructure from `ConflictAnalysis.jl`
  (`Satisfiability.InteractiveSolver`) to avoid restarting the solver each
  iteration.

Participants
------------
- Produces  : `Function` (oracle closure)
- Consumes  : `SMTSpecification` or Z3/CVC5 formula object

Used by: `CEGISProblem` constructor in user code / pipeline.
"""
function oracle_from_smt(formula) :: Function
    error("oracle_from_smt is not yet implemented. " *
          "Encode program semantics as SMT and check satisfiability of ¬spec.")
end
