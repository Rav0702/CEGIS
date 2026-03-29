#!/usr/bin/env julia
"""
test_phase3_e2e_synthesis_simple.jl - Minimal end-to-end CEGIS synthesis test
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const BENCHMARK_DIR = joinpath(dirname(@__DIR__), "spec_files", "phase3_benchmarks")

const BENCHMARKS = Dict(
    "max2" => (
        path = joinpath(BENCHMARK_DIR, "max2_simple.sl"),
        expected = "ifelse(x > y, x, y)"
    ),
    "max3" => (
        path = joinpath(BENCHMARK_DIR, "max3_simple.sl"),
        expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))"
    ),
    "symmetric" => (
        path = joinpath(BENCHMARK_DIR, "symmetric_max.sl"),
        expected = "ifelse(x > y, x, y)"
    ),
    "guard" => (
        path = joinpath(BENCHMARK_DIR, "guard_simple.sl"),
        expected = "ifelse(x > 0, x + y, z)"
    ),
    "arith" => (
        path = joinpath(BENCHMARK_DIR, "arith_simple.sl"),
        expected = "2 * x + y"
    ),
)

# Use type-aware parser that handles Bool→Int coercion automatically
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

results = []
for (name, config) in BENCHMARKS
    try
        println(">>>> Testing $name")
        println("      Expected: $(config.expected)")
        
        problem = CEGIS.CEGISProblem(
            config.path;
            iterator_config = CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=5),
            desired_solution = config.expected
        )
        
        CEGIS.ensure_initialized!(problem)
        println("      [DEBUG] Oracle type: $(typeof(problem.oracle))")
        result = CEGIS.run_synthesis(problem)
        
        # Check if we found a solution
        if result.program !== nothing
            solution_expr = HerbGrammar.rulenode2expr(result.program, problem.grammar)
            solution_str = string(solution_expr)
            status_str = "$(result.status)"
            println("      Found:    $solution_str")
            push!(results, (name=name, status=status_str, iters=result.iterations, found=true))
        else
            println("      Found:    NONE")
            push!(results, (name=name, status="$(result.status)", iters=result.iterations, found=false))
        end
        println()
    catch e
        println("      ERROR: $e\n")
        push!(results, (name=name, status="ERROR", iters=0, found=false))
    end
end

println("\n" * "="^60)
println("SUMMARY:")
for r in results
    found_str = r.found ? "✓" : "✗"
    println("  $found_str $r")
end
success_count = sum(r.found for r in results)
println("\nSolutions found: $success_count / $(length(results))")
