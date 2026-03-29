#!/usr/bin/env julia
"""
test_phase3_e2e_synthesis.jl - End-to-end CEGIS synthesis test
Numbers and variables are extracted automatically from specs
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const BENCHMARK_DIR = joinpath(dirname(@__DIR__), "spec_files", "phase3_benchmarks")
const SPEC_DIR = joinpath(dirname(@__DIR__), "spec_files")

const BENCHMARKS = Dict(
    "max2" => (path = joinpath(BENCHMARK_DIR, "max2_simple.sl"), expected = "ifelse(x > y, x, y)"),
    "max3" => (path = joinpath(BENCHMARK_DIR, "max3_simple.sl"), expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))"),
    "symmetric" => (path = joinpath(BENCHMARK_DIR, "symmetric_max.sl"), expected = "ifelse(x > y, x, y)"),
    "guard" => (path = joinpath(BENCHMARK_DIR, "guard_simple.sl"), expected = "ifelse(x > 0, x + y, z)"),
    "arith" => (path = joinpath(BENCHMARK_DIR, "arith_simple.sl"), expected = "2 * x + y"),
    "findidx" => (path = joinpath(SPEC_DIR, "findidx_2_simple.sl"), expected = "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))"),
    "fnd_sum" => (path = joinpath(BENCHMARK_DIR, "fnd_sum_simple.sl"), expected = "ifelse((x1 + x2) > 5, (x1 + x2), ifelse((x2 + x3) > 5, (x2 + x3), 0))"),
    "simple_define_sum" => (path = joinpath(BENCHMARK_DIR, "simple_define_sum.sl"), expected = "x + y"),
    "jmbl_fg" => (path = joinpath(SPEC_DIR, "jmbl_fg_VC22_a.sl"), expected = nothing),
)

# Use type-aware parser that handles Bool→Int coercion automatically
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

results = []
for (name, config) in BENCHMARKS
    try
        println(">>>> Testing $name")
        if config.expected !== nothing
            println("      Expected: $(config.expected)")
        else
            println("      Expected: TBD (will check with Z3)")
        end
        
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
