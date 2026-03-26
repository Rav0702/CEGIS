"""
    ioexample_oracle.jl

Test-based oracle backed by I/O examples.

IOExampleOracle evaluates candidates against a fixed set of input/output examples
and returns the first failing example as a counterexample.
"""

using HerbCore
using HerbGrammar
using HerbInterpret
using HerbSpecification

"""
    struct IOExampleOracle <: AbstractOracle

Oracle backed by a fixed list of input/output examples.

The constructor takes `examples::AbstractVector{<:IOExample}`. During
counterexample extraction, the oracle evaluates the candidate on each example
in order and returns the first failing one.
"""
struct IOExampleOracle{T <: AbstractVector{<:IOExample}} <: AbstractOracle
    examples :: T
    mod      :: Module
end

function IOExampleOracle(
    examples :: AbstractVector{<:IOExample};
    mod      :: Module = Main,
)
    return IOExampleOracle(examples, mod)
end

"""
    extract_counterexample(oracle::IOExampleOracle, problem::CEGISProblem, candidate::RuleNode)

Return the first `Counterexample` induced by `oracle.examples`, or `nothing` if
the candidate matches all examples.
"""
function extract_counterexample(
    oracle    :: IOExampleOracle,
    problem,
    candidate :: RuleNode,
) :: Union{Counterexample, Nothing}
    symboltable = grammar2symboltable(problem.grammar, oracle.mod)
    expr = rulenode2expr(candidate, problem.grammar)

    for ex in oracle.examples
        actual_output = execute_on_input(symboltable, expr, ex.in)
        if actual_output != ex.out
            return Counterexample(ex.in, ex.out, actual_output)
        end
    end
    return nothing
end
