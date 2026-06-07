"""
    module GeneticSearch

Z3-guided genetic synthesis POC. Uses Arborist as the GA engine over CEGIS-native
`RuleNode` programs, with two novel Z3-derived signals:

1. **Graded constraint fitness** — fitness = number of spec constraints a candidate
   violates universally (each checked independently with Z3). `0` ⇒ formally
   verified, so the GA's fitness function *is* the verifier — no outer CEGIS
   counterexample-accumulation loop.
2. **Counterexample-targeted mutation** — the SAT witness input steers mutation to
   the subtree active at the failure.

Entry point: [`run_ga_cegis`](@ref).
"""
module GeneticSearch

using HerbCore
using HerbGrammar
using HerbSearch
using HerbInterpret
using Random
import Arborist

# Sibling submodule and parent-module helper.
using ..CEXGeneration
import ..build_grammar_from_spec

include("rulenode_genome.jl")
include("z3_evaluator.jl")
include("state_and_init.jl")
include("operators.jl")
include("run.jl")

export run_ga_cegis, GAResult,
       RuleNodeGenome, Z3GradedEvaluator, GenomeDiagnostics,
       GrammarSubtreeMutation, CounterexampleTargetedMutation, GrammarSubtreeCrossover

end # module GeneticSearch
