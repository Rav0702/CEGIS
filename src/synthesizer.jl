"""
    Synthesizer Component
    =====================

Responsible for the **Synthesis** phase of the CEGIS loop.

Given:
  • A (context-sensitive) grammar           — `HerbGrammar.ContextSensitiveGrammar`
  • A start symbol                          — `Symbol`
  • A current set of examples / constraints — `HerbSpecification.Problem`
  • (optionally) grammar constraints learned from previous counterexamples

The synthesizer must return a program (as a `HerbCore.RuleNode`) that satisfies
*all* currently known examples, or signal that no such program exists in the
grammar.

Relationship to other components
---------------------------------

    [Learner]           adds grammar constraints
         │
         ▼
    [Synthesizer]  ──uses──▶  ProgramIterator (HerbSearch)
                   ──uses──▶  synth            (HerbSearch)
                   ──uses──▶  evaluate         (HerbSearch / HerbInterpret)
         │
         ▼ RuleNode (candidate program)
    [Verifier]

The key Herb types involved:
  - `HerbSearch.ProgramIterator` (e.g., `BFSIterator`, `DFSIterator`)
  - `HerbSearch.synth`           — drives the iterator until a satisfying
                                   program is found or the budget is spent.
  - `HerbSpecification.Problem`  — wraps the current IO examples.
  - `HerbGrammar.ContextSensitiveGrammar` — may have extra constraints added
                                   by the Learner before each synth call.
"""

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

"""
    build_iterator(grammar, start_symbol; max_depth, max_size) -> ProgramIterator

**[NOT IMPLEMENTED]**

Construct a `HerbSearch.ProgramIterator` anchored at `start_symbol` inside
`grammar`.

Implementation notes
--------------------
- Choose a concrete iterator type (e.g. `BFSIterator`, `TopDownIterator`, or a
  stochastic variant) based on the problem characteristics.
- `max_depth` and `max_size` bound the search space; tune them or expose them
  as parameters of `CEGISProblem`.
- The iterator wraps a solver (`HerbConstraints.GenericSolver` or
  `HerbConstraints.UniformSolver`) that enforces grammar constraints during
  enumeration.

Participants
------------
- Produces  : `HerbSearch.ProgramIterator`
- Consumes  : `HerbGrammar.ContextSensitiveGrammar`, `Symbol`

```julia
# Example sketch (not final):
function build_iterator(grammar, start_symbol; max_depth=5, max_size=50)
    solver = HerbConstraints.GenericSolver(grammar, start_symbol)
    return HerbSearch.BFSIterator(solver; max_depth=max_depth)
end
```
"""
function build_iterator(
    grammar      :: AbstractGrammar,
    start_symbol :: Symbol;
    max_depth    :: Int = 5,
    max_size     :: Int = 50,
) :: ProgramIterator
    error("build_iterator is not yet implemented. " *
          "Create a HerbSearch.ProgramIterator (e.g. BFSIterator) from the grammar and start_symbol.")
end

"""
    synthesize(problem, grammar, start_symbol; max_enumerations, max_time) -> Union{RuleNode, Nothing}

**[NOT IMPLEMENTED]**

Run the synthesis engine and return the first `HerbCore.RuleNode` program that
satisfies every `IOExample` in `problem.spec`, or `nothing` if the search is
exhausted.

Implementation notes
--------------------
1. Call `build_iterator` to get a `ProgramIterator`.
2. Delegate to `HerbSearch.synth(problem, iterator; ...)`.
3. Map `HerbSearch.SynthResult` to a nullable `RuleNode`:
   - `optimal_program`   → return the node.
   - `suboptimal_program` → return `nothing` (no program satisfies all examples).
   - `nothing` result from `synth` → return `nothing`.

Participants
------------
- Produces  : `HerbCore.RuleNode` or `nothing`
- Consumes  : `HerbSpecification.Problem`, `HerbGrammar.AbstractGrammar`,
              `HerbSearch.ProgramIterator` (internal)

Called by: CEGIS main loop in `cegis.jl`.

```julia
# Example sketch (not final):
function synthesize(problem, grammar, start_symbol; max_enumerations=10_000, max_time=30.0)
    iterator = build_iterator(grammar, start_symbol)
    result   = HerbSearch.synth(problem, iterator;
                   max_enumerations = max_enumerations,
                   max_time         = max_time)
    result === nothing && return nothing
    (program, status) = result
    return status == HerbSearch.optimal_program ? program : nothing
end
```
"""
function synthesize(
    problem          :: Problem,
    grammar          :: AbstractGrammar,
    start_symbol     :: Symbol;
    max_enumerations :: Int     = 10_000,
    max_time         :: Float64 = 30.0,
) :: Union{RuleNode, Nothing}
    error("synthesize is not yet implemented. " *
          "Use HerbSearch.synth with a ProgramIterator built from the grammar.")
end

"""
    update_problem_with_counterexample!(problem, counterexample) -> Problem

**[NOT IMPLEMENTED]**

Incorporate a new `Counterexample` into the `HerbSpecification.Problem` so
the next synthesizer call cannot reproduce the same mistake.

Implementation notes
--------------------
- Convert `counterexample` to an `IOExample`:
      IOExample(counterexample.input, counterexample.expected_output)
- Append it to `problem.spec` (the vector of examples).
- Return the mutated problem (or a fresh `Problem` if the spec is immutable).

Participants
------------
- Mutates   : `HerbSpecification.Problem`
- Consumes  : `Counterexample` (from `types.jl`)
- Produces  : updated `HerbSpecification.Problem`

Called by: CEGIS main loop after each failed verification round.
"""
function update_problem_with_counterexample!(
    problem        :: Problem,
    counterexample :: Counterexample,
) :: Problem
    error("update_problem_with_counterexample! is not yet implemented. " *
          "Append IOExample(counterexample.input, counterexample.expected_output) to problem.spec.")
end
