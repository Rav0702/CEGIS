"""
    abstract_oracle.jl

Abstract base type and interface for CEGIS oracles.

All concrete oracle implementations (IOExampleOracle, Z3Oracle, etc.) should
subtype `AbstractOracle` and implement the `extract_counterexample` method.
"""

"""
    abstract type AbstractOracle end

Parent type for all verifier oracles used by CEGIS.

Concrete oracles should subtype `AbstractOracle` and implement
[`extract_counterexample`](@ref).
"""
abstract type AbstractOracle end

"""
    extract_counterexample(oracle, problem, candidate) -> Union{Counterexample, Nothing}

Oracle interface method.

Given a synthesis `problem` and a `candidate` program, return:
- `Counterexample` when the candidate is invalid.
- `nothing` when no counterexample is found.

Concrete `AbstractOracle` subtypes must implement this method.
"""
function extract_counterexample(
    oracle    :: AbstractOracle,
    problem,
    candidate,
) :: Union{Counterexample, Nothing}
    error("extract_counterexample is not implemented for $(typeof(oracle)).")
end
