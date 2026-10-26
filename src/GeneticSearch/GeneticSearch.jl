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
   test-perfect candidates (warm in-process `CexSolver` when the spec allows
   it), and each failed verification adds a test.
3. **Constraint-graded CDGP fitness** (`CDGPConstraintEvaluator`,
   `run_cdgp(...; fitness=:constraints)`) — fitness = number of spec
   constraints violated universally, each checked on the warm in-process
   `ConstraintSatSolver` (Z3.jl, constraint ASTs built once); `0` ⇒ formally
   verified. `evaluate_cases` exposes per-constraint verdicts, so pairing with
   `Arborist.LexicaseSelection` gives constraint-based lexicase.
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
include("incomplete_tests.jl")
include("cdgp_evaluator.jl")
include("constraint_evaluator.jl")
include("hybrid_evaluator.jl")
include("minimize.jl")
include("normalize.jl")
include("state_and_init.jl")
include("operators.jl")
include("localization.jl")
include("patching.jl")
include("constraint_patches.jl")
include("seed_tests.jl")
include("seed_programs.jl")
include("guided_patch.jl")
include("run.jl")
include("trace.jl")
include("run_cdgp.jl")

export run_ga_cegis, GAResult,
       run_cdgp, CDGPResult, CDGPEvaluator, CDGPConstraintEvaluator,
       HybridCDGPEvaluator, hybrid_evict_witnesses!, hybrid_witness_log,
       minimize_program, TestCompletion, completion_stats, CexHarvest, harvest_stats,
       node_paths, node_at, nodeloc_at, active_paths, ochiai_scores, LocEvidence,
       repairable_paths, angelic_class,
       PatchKit, separating_guards, matching_terms, repair_terms, site_patches, guarded_patch, plain_patch,
       GuidedPatchMutation, guided_stats, AnswerRecipe, spec_answer_recipes, recipe_fires, answer_patch,
       RegionGuard, spec_region_guards, region_fires, spec_region_points, spec_region_inner_points, random_points,
       seed_items, inert_guard, spec_seed_programs, seed_guards_kept,
       CDGPTrace, ValidationBattery, validation_scores, trace_validation,
       normalize_program, normalize_genome, GrammarOps,
       RuleNodeGenome, Z3GradedEvaluator, GenomeDiagnostics,
       GrammarSubtreeMutation, CounterexampleTargetedMutation, GrammarSubtreeCrossover

end # module GeneticSearch
