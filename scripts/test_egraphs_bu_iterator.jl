#!/usr/bin/env julia
CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const SPEC_DIR = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks")

const BENCHMARKS = Dict(
    "max2" => (path = joinpath(SPEC_DIR, "max2_simple.sl"), expected = "ifelse(x0 > x1, x0, x1)"),
    # "max3" => (path = joinpath(SPEC_DIR, "max3_simple.sl"), expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))"),
)

# Use type-aware parser that handles Bool→Int coercion automatically
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

# Conversion mode toggle:
# true  => direct RuleNode -> SMT-LIB2 (`rulenode_to_smt2`)
# false => multi-stage RuleNode -> Expr -> string -> SMT-LIB2
const USE_DIRECT_RULENODE_TO_SMT2 = true

# Iterator selection:
# true  => bottom-up iterator (BOTTOM_UP_VARIANT below)
# false => standard BFS iterator
const USE_BOTTOM_UP_ITERATOR = true

# Bottom-up iterator settings:
const BOTTOM_UP_VARIANT = :cost # :cost, :size, or :depth
const MAX_DEPTH = 5
const MAX_SIZE = 20
const MAX_COST = Inf

results = []
for (name, config) in BENCHMARKS
    try
        println(">>>> Testing $name ($(USE_BOTTOM_UP_ITERATOR ? "BU iterator :$BOTTOM_UP_VARIANT" : "BFS iterator"))")
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
        
        # Build the iterator via the IteratorConfig integration.
        # Any constraints already on the grammar (incl. EGraphPruning-derived
        # Forbidden/Ordered) are enforced inside the bottom-up loop.
        iter_config = USE_BOTTOM_UP_ITERATOR ?
            CEGIS.IteratorConfig.BottomUpIteratorConfig(
                variant=BOTTOM_UP_VARIANT,
                max_depth=MAX_DEPTH,
                max_size=MAX_SIZE,
                max_cost=MAX_COST,
            ) :
            CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=MAX_DEPTH)
        iterator = CEGIS.IteratorConfig.create_iterator(iter_config, grammar, :Expr)

        result = CEGIS.run_synthesis(
            problem, iterator;
            max_enumerations = 1_000_0000,
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
println("SUMMARY ($(USE_BOTTOM_UP_ITERATOR ? "BU iterator :$BOTTOM_UP_VARIANT" : "BFS iterator")):")
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
