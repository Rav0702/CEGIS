# rulenode_smt_cex_demo.jl
# RuleNode-based CEX generation demo using SyGuS specifications
# Run from CEGIS/ directory:
#     julia rulenode_smt_cex_demo.jl [spec_file.sl]
#
# Demonstrates verifying RuleNode candidates against SyGuS constraints

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
include("rulenode_to_symbolics.jl")

using SymbolicSMT
using SymbolicUtils
using HerbCore
using HerbGrammar

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
    println("\nUsage: julia rulenode_smt_cex_demo.jl [spec_file.sl]")
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
# Define a grammar for synthesizing candidates
# The grammar produces expressions using only the basic operators and variables
# ──────────────────────────────────────────────────────────────────────────────

# Create grammar dynamically based on specification variables
function create_grammar_from_spec(vars::Vector{Symbol})
    """
    Create a grammar that includes:
    - Constants: 0, 1
    - Variables: all variables from the spec
    - Operators: <, =, >, |, &, +, -, *
    """
    
    # Build grammar string dynamically
    grammar_str = "@csgrammar begin\n"
    grammar_str *= "    Expr = 0\n"
    grammar_str *= "    Expr = 1\n"
    
    # Add each variable
    for var in vars
        grammar_str *= "    Expr = $var\n"
    end
    
    # Add operators
    grammar_str *= "    Expr = Expr + Expr\n"
    grammar_str *= "    Expr = Expr - Expr\n"
    grammar_str *= "    Expr = Expr * Expr\n"
    grammar_str *= "    Expr = Expr < Expr\n"
    grammar_str *= "    Expr = Expr = Expr\n"
    grammar_str *= "    Expr = Expr > Expr\n"
    grammar_str *= "    Expr = Expr & Expr\n"
    grammar_str *= "    Expr = Expr | Expr\n"
    grammar_str *= "end\n"
    
    # Parse and evaluate to create the grammar
    grammar_expr = Meta.parse(grammar_str)
    return eval(grammar_expr)
end

const candidate_grammar = create_grammar_from_spec(spec.vars)
println("Created candidate grammar with $(length(candidate_grammar.rules)) rules")
println("Variables: $(spec.vars)")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Helper function: Convert RuleNode candidate to symbolic expression
# ──────────────────────────────────────────────────────────────────────────────
function rulenode_to_symbolic_expr(rulenode::RuleNode, grammar::AbstractGrammar, sym_vars::Dict)
    """
    Convert a RuleNode candidate to a symbolic expression using the given grammar.
    """
    try
        return rulenode_to_symbolic(rulenode, grammar, sym_vars)
    catch e
        println("Error converting RuleNode to symbolic: $e")
        return nothing
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# Test candidates using the CEX query from parse_sygus
# ──────────────────────────────────────────────────────────────────────────────
function verify(name, candidate_rulenode::RuleNode, grammar::AbstractGrammar)
    println("=== $name ===")
    
    # Convert RuleNode to symbolic expression
    candidate_symbolic = rulenode_to_symbolic_expr(candidate_rulenode, grammar, sym_vars)
    
    if candidate_symbolic === nothing
        println("✗ Error: Could not convert RuleNode to symbolic expression")
        return nothing
    end
    
    println("  RuleNode interpreted as: $(string(candidate_symbolic))")
    
    # Build CEX query: all constraints disjunctively ORed with candidate violation
    cex_query = build_cex_query(spec, candidate_symbolic, sym_vars)
    
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
# Create test RuleNode candidates
# ──────────────────────────────────────────────────────────────────────────────
function create_test_candidates(grammar::AbstractGrammar)
    """
    Create several test RuleNode candidates manually.
    Each candidate is constructed using specific rule indices from the grammar.
    """
    candidates = []
    
    # Helper function: find rule index by rule value
    function find_rule_index(grammar, rule_value)
        for (idx, r) in enumerate(grammar.rules)
            if r == rule_value
                return idx
            end
        end
        return nothing
    end
    
    # Find indices for constants and variables in the grammar
    const_0_idx = find_rule_index(grammar, 0)
    const_1_idx = find_rule_index(grammar, 1)
    var_x0_idx = find_rule_index(grammar, :x0)
    var_k_idx = find_rule_index(grammar, :k)
    
    # Candidate 1: Constant 0
    if const_0_idx !== nothing
        println("Found constant 0 at rule index $const_0_idx")
        push!(candidates, ("Candidate 1: constant 0", RuleNode(const_0_idx)))
    else
        println("Warning: Could not find constant 0 in grammar")
    end
    
    # Candidate 2: Constant 1
    if const_1_idx !== nothing
        println("Found constant 1 at rule index $const_1_idx")
        push!(candidates, ("Candidate 2: constant 1", RuleNode(const_1_idx)))
    else
        println("Warning: Could not find constant 1 in grammar")
    end
    
    # Candidate 3: First variable (x0)
    if var_x0_idx !== nothing
        println("Found variable x0 at rule index $var_x0_idx")
        push!(candidates, ("Candidate 3: variable x0", RuleNode(var_x0_idx)))
    else
        println("Warning: Could not find variable x0 in grammar")
    end
    
    # Candidate 4: The last variable (k)
    if var_k_idx !== nothing
        println("Found variable k at rule index $var_k_idx")
        push!(candidates, ("Candidate 4: variable k", RuleNode(var_k_idx)))
    else
        println("Warning: Could not find variable k in grammar")
    end
    
    # Candidate 5: Simple arithmetic (if we can find + operator)
    plus_idx = find_rule_index(grammar, :(+))
    if plus_idx !== nothing && var_x0_idx !== nothing && const_1_idx !== nothing
        println("Found + operator at rule index $plus_idx")
        # Build: x0 + 1
        plus_node = RuleNode(plus_idx, Any[], [RuleNode(var_x0_idx), RuleNode(const_1_idx)])
        push!(candidates, ("Candidate 5: x0 + 1", plus_node))
    end
    
    # Candidate 6: Simple comparison (if we can find < operator)
    lt_idx = find_rule_index(grammar, :(<))
    if lt_idx !== nothing && var_k_idx !== nothing && var_x0_idx !== nothing
        println("Found < operator at rule index $lt_idx")
        # Build: k < x0
        lt_node = RuleNode(lt_idx, Any[], [RuleNode(var_k_idx), RuleNode(var_x0_idx)])
        push!(candidates, ("Candidate 6: k < x0", lt_node))
    end
    
    # Print grammar rules for debugging
    println("\nGrammar rules (first 30):")
    for (idx, r) in enumerate(grammar.rules[1:min(30, length(grammar.rules))])
        println("  [$idx] $r")
    end
    if length(grammar.rules) > 30
        println("  ... and $(length(grammar.rules) - 30) more rules")
    end
    
    return candidates
end

# ──────────────────────────────────────────────────────────────────────────────
# Test with RuleNode candidates
# ──────────────────────────────────────────────────────────────────────────────
function run_tests()
    println(repeat("=", 80))
    println("Testing RuleNode Candidates via SMT")
    println(repeat("=", 80))
    println()
    
    candidates = create_test_candidates(candidate_grammar)
    
    if isempty(candidates)
        println("Warning: No test candidates created. Grammar structure:")
        println("  First 10 rules: $(candidate_grammar.rules[1:min(10, length(candidate_grammar.rules))])")
        println()
    end
    
    for (name, rulenode) in candidates
        verify(name, rulenode, candidate_grammar)
        println()
    end
    
    println(repeat("=", 80))
    println("RuleNode demo complete")
    println(repeat("=", 80))
end

# Run the tests
run_tests()
