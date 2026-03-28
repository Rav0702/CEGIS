#!/usr/bin/env julia
"""
test_max2_only.jl - Test max2 synthesis
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const BENCHMARK_DIR = joinpath(dirname(@__DIR__), "spec_files", "phase3_benchmarks")

println("Testing max2")

spec_path = joinpath(BENCHMARK_DIR, "max2_simple.sl")
println("Spec path: $spec_path")

problem = CEGIS.CEGISProblem(
    spec_path;
    iterator_config = CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=5)
)

CEGIS.ensure_initialized!(problem)

println("Grammar built successfully")
println("Starting synthesis...")

result = CEGIS.run_synthesis(problem)

println("Synthesis completed with status: $(result.status)")
if result.program !== nothing
    solution_expr = HerbCore.rulenode2expr(result.program, problem.grammar)
    solution_str = string(solution_expr)
    println("Solution: $solution_str")
else
    println("No solution found after $(result.iterations) iterations")
end
