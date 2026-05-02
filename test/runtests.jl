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
    include("test_e2e_synthesis.jl")
end
