"""
Main test suite for CEGIS package.

Runs end-to-end synthesis tests on SyGuS specification files,
testing the full pipeline: parsing → grammar building → oracle synthesis.
"""

using HerbCore
using HerbGrammar
using HerbInterpret
using HerbSearch
using HerbSpecification
using Test

# Include CEGIS module from src
const CEGIS_ROOT = dirname(@__DIR__)
const CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

# Set random seed for reproducibility
using Random
Random.seed!(42)

# Include test helpers
include("test_helpers.jl")

# Set parser to handle Bool→Int coercion automatically
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

@testset "CEGIS.jl" verbose = true begin
    include("test_parsing_utilities.jl")
    include("test_constraint_satisfaction.jl")
    include("test_constraint_satisfaction_solver.jl")
    include("test_cex_solver.jl")
    include("test_constraint_pointwise.jl")
    include("test_e2e_synthesis.jl")
    include("test_cdgp.jl")
    include("test_cdgp_constraint.jl")
    include("test_hybrid_and_minimize.jl")
    include("test_normalize.jl")
    include("test_witness_battery.jl")
    include("test_trace.jl")
    include("test_incomplete_tests.jl")
    include("test_per_constraint_cex.jl")
    include("test_rulenode_smt_sygus.jl")
    include("test_patching.jl")
    include("test_recipe_iterator.jl")
    include("test_enriched_grammar.jl")
    include("test_region_guards.jl")
    include("test_oracle_soundness.jl")
    include("test_seed_tests.jl")
    include("test_seed_programs.jl")
end
