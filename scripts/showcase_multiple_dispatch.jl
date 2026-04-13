#!/usr/bin/env julia
"""
Showcase: Multiple Dispatch in run_synthesis()

This script demonstrates the unified run_synthesis() API that works with:
1. Standard HerbSpecification.Problem (IO examples)
2. CEGIS oracle-driven CEGISProblem

Both use the SAME run_synthesis() function, but it dispatches to different
implementations based on problem type.
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret, HerbConstraints, Herb
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

println("="^70)
println("MULTIPLE DISPATCH SHOWCASE: run_synthesis()")
println("="^70)

println("\n1️ STANDARD HERBSPECIFICATION.PROBLEM (IO Examples)")
println("-"^70)

io_examples = [IOExample(Dict(:x => x), 2x+1) for x ∈ 1:5]

io_problem = Problem(io_examples)
println("Problem: Find program that returns 2x + 1")
println("Examples:")
for ex in io_examples
    println("  $(ex.in) => $(ex.out)")
end

io_grammar = @csgrammar begin
    Number = |(1:2)
    Number = x
    Number = Number + Number
    Number = Number * Number
end

# Create iterator
io_iterator = BFSIterator(
    solver = GenericSolver(io_grammar, :Number; max_depth=3);
    max_depth = 3
)

try
    result = HerbSearch.synth(
        io_problem, io_iterator;
        max_enumerations = 100_000
    )
    
    if result !== nothing
        program, status = result
        solution_expr = rulenode2expr(program, io_grammar)
        println("Found: $(solution_expr)")
        println("  Status: $status")
    else
        println("No solution found (synthesis did not converge)")
    end
catch e
    println(" Error during synthesis: $e")
    println("  (This is expected for complex grammars - focus on CEGIS path below)")
end

println("\n2️ CEGIS CEGISPROBLEM (Oracle-Driven Verification)")
println("-"^70)

# Spec file for CEGIS
spec_path = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks", "max2_simple.sl")
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())
if isfile(spec_path)
    # Create lightweight CEGISProblem (minimal constructor)
    cegis_problem = CEGIS.CEGISProblem(
        spec_path;
        desired_solution = "ifelse(x > y, x, y)"
    )
    println("Problem: CEGISProblem from $spec_path")
    println("Desired solution (for debugging): ifelse(x > y, x, y)")
    
    # Build grammar externally (new API)
    cegis_grammar = CEGIS.build_grammar_from_spec(spec_path)
    
    # Create iterator
    cegis_iterator = BFSIterator(
    solver = GenericSolver(cegis_grammar, :Expr; max_depth=5);
    max_depth = 5
    )
    
    println("\nRunning run_synthesis(cegis_problem, cegis_iterator)...")
    try
        # Call run_synthesis with CEGIS problem
        result = CEGIS.run_synthesis(
            cegis_problem, cegis_iterator;
            max_enumerations = 1_000_000
        )
        
        if result.program !== nothing
            solution_expr = rulenode2expr(result.program, cegis_grammar)
            println(" Found: $(solution_expr)")
            println("  Status: $(result.status)")
            println("  Iterations: $(result.iterations)")
            println("  Counterexamples found: $(length(result.counterexamples))")
        else
            println("✗ No solution found")
        end
    catch e
        println("✗ Error: $e")
    end
else
    println("⚠ Spec file not found: $spec_path")
    println("  (Skipping CEGIS example)")
end
