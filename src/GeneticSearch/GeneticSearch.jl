"""
    module GeneticSearch

Genetic synthesis over CEGIS-native `RuleNode` programs, using Arborist as the
GA engine. Two fitness modes:

1. **Graded constraint fitness** (`Z3GradedEvaluator`, [`run_ga_cegis`](@ref)) —
   fitness = number of spec constraints a candidate violates universally (each
   checked independently with Z3). `0` ⇒ formally verified, so the GA's fitness
   function *is* the verifier — no outer CEGIS counterexample-accumulation loop.
   Plus **counterexample-targeted mutation**: the SAT witness input steers
   mutation to the subtree active at the failure.
2. **CDGP test-case fitness** (`CDGPEvaluator`, [`run_cdgp`](@ref)) — classic
   counterexample-driven GP: fitness = number of failed tests on an accumulated
   counterexample-derived test set (cheap interpretation); Z3 only verifies
   test-perfect candidates, and each failed verification adds a test.
"""
module GeneticSearch

using HerbCore
using HerbGrammar
using HerbSearch
using HerbInterpret
using HerbSpecification: IOExample
using Random
import Arborist

# Sibling submodule and parent-module helpers.
using ..CEXGeneration
import ..build_grammar_from_spec
import ..Counterexample

include("rulenode_genome.jl")
include("z3_evaluator.jl")
include("cdgp_evaluator.jl")
include("state_and_init.jl")
include("operators.jl")
include("run.jl")
include("run_cdgp.jl")

export run_ga_cegis, GAResult,
       run_cdgp, CDGPResult, CDGPEvaluator,
       RuleNodeGenome, Z3GradedEvaluator, GenomeDiagnostics,
       GrammarSubtreeMutation, CounterexampleTargetedMutation, GrammarSubtreeCrossover

end # module GeneticSearch
