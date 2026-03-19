# smt_cex_generation_demo.jl
# Using parse_sygus to generate CEX queries from .sl files
# Run from CEGIS/ directory:
#     julia smt_cex_generation_demo.jl [spec_file.sl]
#
# If no spec file is provided, defaults to "findidx_5_problem.sl"

import Pkg
const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)
const _HERB_PKGS = ["SymbolicSMT"]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

include("parse_sygus.jl")
using SymbolicSMT
using SymbolicUtils

# ──────────────────────────────────────────────────────────────────────────────
# Get spec file from command line arguments
# ──────────────────────────────────────────────────────────────────────────────
spec_file = if !isempty(ARGS)
    ARGS[1]
else
    "findidx_5_problem.sl"
end

if !isfile(spec_file)
    println("Error: Spec file not found: $spec_file")
    println("\nUsage: julia smt_cex_generation_demo.jl [spec_file.sl]")
    exit(1)
end

# ──────────────────────────────────────────────────────────────────────────────
# Parse the SyGuS specification
# ──────────────────────────────────────────────────────────────────────────────
println("Loading specification: $spec_file")
spec = parse_sygus(spec_file)

println("\nParsed SyGuS Specification:")
println(spec)
println()

# ──────────────────────────────────────────────────────────────────────────────
# Create symbolic variables matching the spec dynamically
# ──────────────────────────────────────────────────────────────────────────────
# Build a function to create the variables at runtime
function create_symbolic_variables(var_names::Vector{Symbol})
    vars_dict = Dict{Symbol, Any}()
    
    # Create the @syms expression with all variables
    var_syms = [Expr(:(::), v, :Real) for v in var_names]
    macro_expr = Expr(:macrocall, Symbol("@syms"))
    push!(macro_expr.args, nothing)  # The implicit first argument
    append!(macro_expr.args, var_syms)
    
    # Evaluate to create the variables
    eval(macro_expr)
    
    # Retrieve the variables from Main module (where they're created)
    for v in var_names
        try
            vars_dict[v] = eval(v)
        catch e
            println("Warning: Could not retrieve variable $v: $e")
        end
    end
    
    return vars_dict
end

sym_vars = create_symbolic_variables(spec.vars)
println("Created symbolic variables: $(collect(keys(sym_vars)))")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Test candidates using the CEX query from parse_sygus
# ──────────────────────────────────────────────────────────────────────────────
function verify(name, candidate)
    println("=== $name ===")
    
    # Build CEX query: all constraints disjunctively ORed with candidate violation
    cex_query = build_cex_query(spec, candidate, sym_vars)
    
    # Check if the query is satisfiable (i.e., if candidate fails a constraint)
    is_violated = issatisfiable(cex_query, Constraints([]))
    
    if !is_violated
        println("✓ Candidate PASSES all constraints!")
        return nothing
    end
    
    println("✗ Counterexample found!")
    
    # Extract the specific counterexample with the variables from the spec
    assignment = get_model_assignment(
        cex_query,
        Constraints([]),
        spec.vars
    )
    
    if assignment !== nothing
        println("Counterexample assignment:")
        for (var, val) in assignment
            println("  $var = $val")
        end
    else
        println("  (Could not extract assignment)")
    end
    
    return assignment
end

# ──────────────────────────────────────────────────────────────────────────────
# Test with different candidate functions
# ──────────────────────────────────────────────────────────────────────────────
function run_tests()
    println(repeat("=", 80))
    println("Testing Candidates")
    println(repeat("=", 80))
    println()

    # Candidate 1: Always returns 0
    candidate_1 = 0 * first(values(sym_vars))
    verify("Candidate 1: always 0", candidate_1)
    println()

    # Candidate 2: Always returns constant
    candidate_2 = 2 + 0 * first(values(sym_vars))
    verify("Candidate 2: always 2", candidate_2)
    println()

    # Candidate 3: Returns first variable
    candidate_3 = first(values(sym_vars))
    verify("Candidate 3: returns first var", candidate_3)
    println()

    # Candidate 4: CORRECT SOLUTION - counts how many thresholds k exceeds
    # For a sorted array of thresholds, the index where k falls 
    # is the number of thresholds <= k
    # Get the 'k' variable (should be the last one in spec.vars)
    k_var = sym_vars[spec.vars[end]]  # Last variable is typically 'k'
    threshold_vars = [sym_vars[v] for v in spec.vars[1:end-1]]  # All but the last
    
    # Build: (k >= x0) + (k >= x1) + ... + (k >= x_n)
    candidate_correct = sum((k_var >= xvar) for xvar in threshold_vars)
    verify("Candidate 4: CORRECT - sum((k >= x_i))", candidate_correct)
    println()

    println(repeat("=", 80))
    println("Demo complete")
    println(repeat("=", 80))
end

# Run the tests
run_tests()

