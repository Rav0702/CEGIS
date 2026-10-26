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

"""
    candidate_verified(oracle) -> Bool

After `extract_counterexample` returned `nothing`: was the candidate actually proved correct? An oracle
that can fail to decide (a solver `unknown`, a conversion error) returns `nothing` in those cases too, so
the CEGIS loop must accept a candidate only when this is `true`. Default `true`: oracles that return
`nothing` only for a passing candidate need not override it.
"""
candidate_verified(::AbstractOracle) = true
