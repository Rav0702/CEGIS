#!/usr/bin/env julia
CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const BENCHMARK_DIR = joinpath(dirname(@__DIR__), "spec_files", "phase3_benchmarks")
const SPEC_DIR = joinpath(dirname(@__DIR__), "spec_files")

const BENCHMARKS = Dict(
     "max2" => (path = joinpath(BENCHMARK_DIR, "max2_simple.sl"), expected = "ifelse(x > y, x, y)"),
    # "max3" => (path = joinpath(BENCHMARK_DIR, "max3_simple.sl"), expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))"),
    #  "symmetric" => (path = joinpath(BENCHMARK_DIR, "symmetric_max.sl"), expected = "ifelse(x > y, x, y)"),
    #   "guard" => (path = joinpath(BENCHMARK_DIR, "guard_simple.sl"), expected = "ifelse(x > 0, x + y, z)"),
    #  "arith" => (path = joinpath(BENCHMARK_DIR, "arith_simple.sl"), expected = "2 * x + y"),
    #  "findidx" => (path = joinpath(SPEC_DIR, "findidx_2_simple.sl"), expected = "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))"),
    #  "fnd_sum" => (path = joinpath(BENCHMARK_DIR, "fnd_sum_simple.sl"), expected = "ifelse((x1 + x2) > 5, (x1 + x2), ifelse((x2 + x3) > 5, (x2 + x3), 0))"),
    #  "simple_define_sum" => (path = joinpath(BENCHMARK_DIR, "simple_define_sum.sl"), expected = "x + y"),
    # "jmbl_fg" => (path = joinpath(SPEC_DIR, "jmbl_fg_VC22_a.sl"), expected = nothing),
 )

#   ============================================================ 2 native queries 1M enums
# SUMMARY:
#   ✓ (name = "max3", status = "cegis_failure", iters = 8, found = true)
#   ✓ (name = "guard", status = "cegis_success", iters = 8, found = true)
#   ✓ (name = "symmetric", status = "cegis_success", iters = 4, found = true)
#   ✓ (name = "arith", status = "cegis_success", iters = 3, found = true)
#   ✓ (name = "max2", status = "cegis_success", iters = 3, found = true)
#   ✓ (name = "findidx", status = "cegis_success", iters = 7, found = true)
#   ✓ (name = "fnd_sum", status = "cegis_failure", iters = 4, found = true)
#   ✓ (name = "simple_define_sum", status = "cegis_success", iters = 2, found = true)
#   ✓ (name = "jmbl_fg", status = "cegis_success", iters = 0, found = true)


  

# Use type-aware parser that handles Bool→Int coercion automatically
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

# Conversion mode toggle:
# true  => direct RuleNode -> SMT-LIB2 (`rulenode_to_smt2`)
# false => multi-stage RuleNode -> Expr -> string -> SMT-LIB2
const USE_DIRECT_RULENODE_TO_SMT2 = true

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
            desired_solution = config.expected,
        )
        grammar = CEGIS.build_grammar_from_spec(config.path)
        iterator = CEGIS.IteratorConfig.create_iterator(
            CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=5),
            grammar,
            :Expr
        )
        
        result = CEGIS.run_synthesis(
            problem, iterator;
            max_enumerations = 1_000_000,
            use_direct_conversion = USE_DIRECT_RULENODE_TO_SMT2,
        )
        
        status_str = "$(result.status)"
        verified = status_str == "cegis_success"

        # Print best candidate if available, but only mark `found=true` for verified success
        if result.program !== nothing
            solution_expr = HerbGrammar.rulenode2expr(result.program, grammar)
            solution_str = string(solution_expr)
            println("      Candidate: $solution_str")
            push!(results, (name=name, status=status_str, iters=result.iterations, found=verified, solution=solution_str, expected=config.expected))
        else
            println("      Candidate: NONE")
            push!(results, (name=name, status=status_str, iters=result.iterations, found=false, solution=nothing, expected=config.expected))
        end
        println()
    catch e
        println("      ERROR: $e\n")
        push!(results, (name=name, status="ERROR", iters=0, found=false, solution=nothing, expected=config.expected))
    end
end

println("\n" * "="^60)
println("SUMMARY:")
for r in results
    found_str = r.found ? "✓" : "✗"
    expected_str = r.expected !== nothing ? r.expected : "TBD"
    match_str = ""
    if r.found && r.expected !== nothing
        match_str = r.solution == r.expected ? "MATCH" : "MISMATCH"
    end
    println("  $found_str (name = \"$(r.name)\", status = \"$(r.status)\", iters = $(r.iters), found = $(r.found))")
    if r.solution !== nothing
        label = r.found ? "Found" : "Best"
        println("      $label:     $(r.solution)")
    end
    if r.found
        println("      Expected: $expected_str $match_str")
    elseif r.expected !== nothing
        println("      Expected: $expected_str")
    end
end
success_count = sum(r.found for r in results)
println("\nSolutions found: $success_count / $(length(results))")
