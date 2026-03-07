"""
    CEGIS Types
    ===========

This file defines the core types used throughout the CEGIS loop. All components
of the pipeline — synthesizer, verifier, counterexample generator, and learner —
communicate through these shared types.

Dependency graph:
    CEGISProblem ──▶ Synthesizer ──▶ SynthesisResult
                         ▲
    Counterexample ──────┘
    (from verifier feedback)

    Verifier ──▶ VerificationResult ─── if ¬verified ──▶ Counterexample
"""

# ─────────────────────────────────────────────────────────────────────────────
# Result enumerations
# ─────────────────────────────────────────────────────────────────────────────

"""
    @enum CEGISStatus

Possible terminal outcomes of a full CEGIS run.

| Value            | Meaning                                                  |
|------------------|----------------------------------------------------------|
| `cegis_success`  | A program satisfying all constraints was found.          |
| `cegis_failure`  | The search space was exhausted without success.          |
| `cegis_timeout`  | The loop hit the user-supplied time / iteration limit.   |
"""
@enum CEGISStatus begin
    cegis_success = 1
    cegis_failure = 2
    cegis_timeout = 3
end

"""
    @enum VerificationStatus

Result returned by the oracle / verifier after checking a candidate program.

| Value                  | Meaning                                       |
|------------------------|-----------------------------------------------|
| `verified`             | Program is correct on all inputs.             |
| `counterexample_found` | Oracle found an input that falsifies program. |
| `verification_error`   | The verifier raised an internal exception.    |
"""
@enum VerificationStatus begin
    verified            = 1
    counterexample_found = 2
    verification_error  = 3
end

# ─────────────────────────────────────────────────────────────────────────────
# Counterexample
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct Counterexample

An input/output witness that shows why a candidate program is wrong.

Fields
------
- `input  :: Dict{Symbol, Any}` — Variable bindings fed to the program.
- `expected_output :: Any`      — The output the oracle deems correct.
- `actual_output   :: Any`      — The (wrong) output the candidate produced.

Relationship to Herb types
--------------------------
A `Counterexample` is converted to a `HerbSpecification.IOExample` before it is
added to the growing example set that drives the synthesizer in the next round:

    IOExample(cx.input, cx.expected_output)

See also: `HerbSpecification.IOExample`, `HerbSpecification.Problem`.
"""
struct Counterexample
    input           :: Dict{Symbol, Any}
    expected_output :: Any
    actual_output   :: Any
end

# ─────────────────────────────────────────────────────────────────────────────
# Verification result
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct VerificationResult

Encapsulates the answer returned by the oracle after checking a candidate.

Fields
------
- `status          :: VerificationStatus` — Outcome of verification.
- `counterexample  :: Union{Counterexample, Nothing}` — Populated only when
  `status == counterexample_found`.

Produced by: [`verify`](@ref) in `verifier.jl`.
Consumed by: the main CEGIS loop in `pipeline.jl` and by
             [`generate_counterexample`](@ref) in `counterexample.jl`.
"""
struct VerificationResult
    status         :: VerificationStatus
    counterexample :: Union{Counterexample, Nothing}
end

# ─────────────────────────────────────────────────────────────────────────────
# CEGIS problem specification
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct CEGISProblem

A self-contained description of a CEGIS synthesis task.

Fields
------
- `grammar      :: AbstractGrammar`      — The context-sensitive grammar that
  defines the program space.  Created with `HerbGrammar.@csgrammar`.
- `start_symbol :: Symbol`               — Non-terminal to start synthesis from
  (e.g. `:Program`, `:Expr`).
- `spec         :: AbstractSpecification`— Initial specification.  In the IO
  setting this is `Vector{IOExample}`.  Grows each round with new
  `Counterexample`s converted to `IOExample`s.
- `oracle       :: Function`             — A callable `(program::RuleNode,
  grammar::AbstractGrammar) -> VerificationResult` that acts as the verifier.
  Can wrap an SMT solver, a type-checker, or an exhaustive tester.
- `max_iterations :: Int`                — Hard cap on the number of
  synthesize → verify rounds (default 100).
- `max_time      :: Float64`             — Wall-clock time budget in seconds
  (default `Inf`).

How it flows through the pipeline
----------------------------------
    CEGISProblem
        │
        ├─▶ synthesize(problem, ...)  ──▶ RuleNode candidate
        │
        └─▶ verify(candidate, problem.oracle, ...)
                │  if counterexample_found
                └─▶ add_counterexample!(problem, cx)  ──▶ updated spec
"""
mutable struct CEGISProblem
    grammar         :: AbstractGrammar
    start_symbol    :: Symbol
    spec            :: AbstractSpecification
    oracle          :: Function
    max_iterations  :: Int
    max_time        :: Float64
end

"""
    CEGISProblem(grammar, start_symbol, spec, oracle)

Convenience constructor with default limits (100 iterations, no time limit).
"""
function CEGISProblem(
    grammar      :: AbstractGrammar,
    start_symbol :: Symbol,
    spec         :: AbstractSpecification,
    oracle       :: Function,
)
    return CEGISProblem(grammar, start_symbol, spec, oracle, 100, Inf)
end

# ─────────────────────────────────────────────────────────────────────────────
# Final output of the CEGIS run
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct CEGISResult

The value returned by [`cegis`](@ref) after the loop terminates.

Fields
------
- `status         :: CEGISStatus`                    — High-level outcome.
- `program        :: Union{RuleNode, Nothing}`        — The synthesized program
  (or `nothing` on failure / timeout with nothing found).
- `iterations     :: Int`                            — Number of rounds run.
- `counterexamples :: Vector{Counterexample}`        — All counterexamples
  accumulated during the run (useful for debugging and analysis).

Consumed by: the caller of `cegis(...)` — typically a higher-level driver or
the `pipeline.jl` script.
"""
struct CEGISResult
    status          :: CEGISStatus
    program         :: Union{RuleNode, Nothing}
    iterations      :: Int
    counterexamples :: Vector{Counterexample}
end
