"""
semantic_smt_cegis.jl

CEGIS synthesis with semantic SMT-based verification using SyGuS specifications.

Run from CEGIS/ directory:
    julia semantic_smt_cegis.jl [spec_file.sl]

This script:
1. Parses a SyGuS specification from a .sl file
2. Creates a SemanticSMTOracle for formal verification
3. Runs CEGIS synthesis with the oracle
4. Reports the synthesized program

Unlike IOExampleOracle (which requires examples), the SemanticSMTOracle uses
formal SMT solving to find counterexamples.
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification", "CEGIS",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbInterpret
using HerbSearch
using HerbSpecification

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "src", "CEGIS.jl"))
end
using .CEGIS

# Include the semantic SMT oracle and supporting modules
include("parse_sygus.jl")
include("rulenode_to_symbolics.jl")
include("semantic_smt_oracle.jl")
include("oracle_synth.jl")

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
    println("\nUsage: julia semantic_smt_cegis.jl [spec_file.sl]")
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
# Create symbolic variables from the specification
# ──────────────────────────────────────────────────────────────────────────────
function create_symbolic_variables(var_names::Vector{Symbol})
    vars_dict = Dict{Symbol, Any}()
    
    # Create the @syms expression with all variables
    var_syms = [Expr(:(::), v, :Real) for v in var_names]
    macro_expr = Expr(:macrocall, Symbol("@syms"))
    push!(macro_expr.args, nothing)
    append!(macro_expr.args, var_syms)
    
    # Evaluate to create the variables
    eval(macro_expr)
    
    # Retrieve the variables from Main module
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
# Define the synthesis grammar
# ──────────────────────────────────────────────────────────────────────────────
"""
Build a grammar with:
- Constants: 0, 1
- Variables: all from the spec
- Operators: +, -, *, <, =, >, &, |
"""

function build_grammar_from_spec(vars::Vector{Symbol})
    # Build grammar string dynamically
    grammar_str = "@csgrammar begin\n"
    grammar_str *= "    Expr = 0\n"
    grammar_str *= "    Expr = 1\n"
    grammar_str *= "    Expr = 2\n"
    grammar_str *= "    Expr = 3\n"
    grammar_str *= "    Expr = 4\n"
    grammar_str *= "    Expr = 5\n"
    
    # Add each variable from the spec
    for var in vars
        grammar_str *= "    Expr = $var\n"
    end
    
    # Add operators
    grammar_str *= "    Expr = Expr + Expr\n"
    grammar_str *= "    Expr = Expr < Expr\n"
    grammar_str *= "    Expr = Expr > Expr\n"
    grammar_str *= "    Expr = Expr >= Expr\n"
    grammar_str *= "    Expr = Expr <= Expr\n"
    grammar_str *= "end\n"
    
    # Parse and evaluate to create the grammar
    grammar_expr = Meta.parse(grammar_str)
    return eval(grammar_expr)
end

grammar = build_grammar_from_spec(spec.vars)
println("Created synthesis grammar with $(length(grammar.rules)) rules")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Create the SemanticSMTOracle
# ──────────────────────────────────────────────────────────────────────────────
oracle = SemanticSMTOracle(spec, sym_vars, grammar)
println("Created SemanticSMTOracle for formal verification")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Run synthesis with the oracle
# ──────────────────────────────────────────────────────────────────────────────
println(repeat("=", 80))
println("Starting CEGIS synthesis with SemanticSMTOracle")
println(repeat("=", 80))
println()

start_symbol = :Expr
max_depth = 8
max_enumerations = 500_000

synth_out = synth_with_oracle(
    grammar,
    start_symbol,
    oracle;
    max_depth = max_depth,
    max_enumerations = max_enumerations,
)

result = synth_out.result
satisfied_examples = synth_out.satisfied_examples

# ──────────────────────────────────────────────────────────────────────────────
# Report results
# ──────────────────────────────────────────────────────────────────────────────
println()
println(repeat("=", 80))
println("Synthesis Results")
println(repeat("=", 80))
println("Status: $(result.status)")
println("Iterations: $(result.iterations)")
println("Counterexamples used: $(length(result.counterexamples))")
println("Best satisfied examples: $satisfied_examples")
println()

if result.program !== nothing
    println("✓ Synthesized Program:")
    program_expr = rulenode2expr(result.program, grammar)
    println("  $program_expr")
    println()
else
    println("✗ No program found within the resource limits")
    if !isempty(result.counterexamples)
        println("Best program found (from counterexamples):")
        best_expr = rulenode2expr(result.program, grammar)
        println("  $best_expr")
        println()
    end
end

println("Final Specification (IO Examples collected):")
for (i, example) in enumerate(result.counterexamples)
    println("  Example $i: input=$(example.input) => expected=$(example.expected_output)")
end

println()
println(repeat("=", 80))
