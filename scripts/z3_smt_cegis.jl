#!/usr/bin/env julia
"""
z3_smt_cegis.jl

CEGIS synthesis with Z3 SMT-based verification using SyGuS specifications.
Uses native Z3 SMT-LIB2 parser via CEXGeneration module.

Differences from semantic_smt_cegis.jl:
- Uses Z3Oracle instead of SemanticSMTOracle
- Uses CEXGeneration.parse_spec_from_file for spec parsing
- Generates SMT-LIB2 queries via CEXGeneration
- Verifies with native Z3 (no subprocess, native API)

Usage:
    julia z3_smt_cegis.jl [spec_file.sl] [max_depth] [max_enumerations]

Example:
    julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl 8 5000000
"""

# ─────────────────────────────────────────────────────────────────────────────
# Environment setup
# ─────────────────────────────────────────────────────────────────────────────
import Pkg
const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env_z3")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = ["HerbCore", "HerbGrammar", "HerbConstraints",
                   "HerbInterpret", "HerbSearch", "HerbSpecification", "CEGIS"]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))
end
using .CEGIS

# Include supporting modules (order matters)
# All oracle implementations are available through CEGIS module now

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

"""
    build_grammar_from_spec_file(spec_file::String)::AbstractGrammar

Build a synthesis grammar from a SyGuS specification file.
Uses CEXGeneration to parse the spec and extract variable information.

The grammar separates IntExpr (returns Int) from BoolExpr (returns Bool) to ensure
the synthesis function returns the correct type.
"""
function build_grammar_from_spec_file(spec_file::String)::AbstractGrammar
    spec = CEXGeneration.parse_spec_from_file(spec_file)
    
    # Extract free variable names from the spec
    var_names = [fv.name for fv in spec.free_vars]
    
    println("Free variables in spec: $var_names")
    
    # Build grammar with separate Int and Bool expressions
    # The synthesis target (Expr) returns Int
    grammar_str = "@csgrammar begin\n"
    
    # Expr: Integer expressions (can be returned by synthesis function)
    for i in 0:5
        grammar_str *= "    Expr = $i\n"
    end
    
    # Add variables to IntExpr
    for var in var_names
        grammar_str *= "    Expr = $var\n"
    end
    
    # Arithmetic operations return Int
    grammar_str *= "    Expr = Expr + Expr\n"
    grammar_str *= "    Expr = Expr - Expr\n"
    grammar_str *= "    Expr = Expr * Expr\n"
    
    # # If-then-else for integer expressions
    # grammar_str *= "    Expr = ifelse(BoolExpr, Expr, Expr)\n"
    
    # # BoolExpr: Boolean expressions (for conditions only)
    # # Integer constants for Bool literals
    # grammar_str *= "    BoolExpr = true\n"
    # grammar_str *= "    BoolExpr = false\n"
    
    # Comparisons
    grammar_str *= "    BoolExpr = Expr < Expr\n"
    grammar_str *= "    BoolExpr = Expr > Expr\n"
    grammar_str *= "    BoolExpr = Expr >= Expr\n"
    grammar_str *= "    BoolExpr = Expr <= Expr\n"
    # grammar_str *= "    BoolExpr = Expr == Expr\n"
    # grammar_str *= "    BoolExpr = Expr != Expr\n"
    
    grammar_str *= "end\n"
    
    return eval(Meta.parse(grammar_str))
end

"""
    run_z3_cegis(spec_file::String; max_depth::Int=6, max_enumerations::Int=50_000)

Main Z3 CEGIS loop:
1. Parse the SyGuS specification
2. Build a synthesis grammar
3. Create a Z3Oracle for formal verification
4. Run the oracle-driven CEGIS synthesis
5. Report results
"""
function run_z3_cegis(
    spec_file::String;
    max_depth::Int = 6,
    max_enumerations::Int = 50_000
)
    # ─────────────────────────────────────────────────────────────────────────
    # Step 1: Load and parse specification
    # ─────────────────────────────────────────────────────────────────────────
    if !isfile(spec_file)
        println("Error: Spec file not found: $spec_file")
        return nothing
    end
    
    println("Loading specification: $spec_file")
    spec = CEXGeneration.parse_spec_from_file(spec_file)
    
    println("\nParsed SyGuS Specification:")
    println("  Synthesis function: $(isempty(spec.synth_funs) ? "NONE" : spec.synth_funs[1].name)")
    println("  Free variables: $(length(spec.free_vars)) - $(join([fv.name for fv in spec.free_vars], ", "))")
    if !isempty(spec.constraints)
        println("  Constraints: $(length(spec.constraints))")
    end
    println()
    
    # ─────────────────────────────────────────────────────────────────────────
    # Step 2: Build synthesis grammar
    # ─────────────────────────────────────────────────────────────────────────
    println("Building synthesis grammar...")
    grammar = build_grammar_from_spec_file(spec_file)
    println("Grammar created with $(length(grammar.rules)) rules\n")
    
    # ─────────────────────────────────────────────────────────────────────────
    # Step 3: Create Z3Oracle for SMT-based verification
    # ─────────────────────────────────────────────────────────────────────────
    println("Creating Z3Oracle for formal verification...")
    oracle = Z3Oracle(spec_file, grammar)
    println("Z3Oracle created and ready for synthesis\n")
    
    # ─────────────────────────────────────────────────────────────────────────
    # Step 4: Run oracle-driven CEGIS synthesis
    # ─────────────────────────────────────────────────────────────────────────
    println(repeat("=", 80))
    println("Starting Z3-based CEGIS Synthesis")
    println(repeat("=", 80))
    println()
    
    synth_out = synth_with_oracle(
        grammar,
        :Expr,
        oracle;
        max_depth = max_depth,
        max_enumerations = max_enumerations
    )
    
    result = synth_out.result
    satisfied_examples = synth_out.satisfied_examples
    
    # ─────────────────────────────────────────────────────────────────────────
    # Step 5: Report results
    # ─────────────────────────────────────────────────────────────────────────
    println()
    println(repeat("=", 80))
    println("Z3 CEGIS Synthesis Results")
    println(repeat("=", 80))
    println()
    
    status_str = if result.status == CEGIS.cegis_success
        "✓ SUCCESS"
    elseif result.status == CEGIS.cegis_failure
        "✗ FAILURE"
    elseif result.status == CEGIS.cegis_timeout
        "⏱ TIMEOUT"
    else
        "? UNKNOWN"
    end
    
    println("Status:              $status_str")
    println("Iterations:          $(result.iterations)")
    println("Counterexamples:     $(length(result.counterexamples))")
    println("Satisfied examples:  $satisfied_examples")
    println()
    
    if result.program !== nothing
        candidate_expr = rulenode2expr(result.program, grammar)
        println("Synthesized Program: $candidate_expr")
        println()
    else
        println("No solution found within resource limits")
        println()
    end
    
    if !isempty(result.counterexamples)
        println("Counterexamples collected during synthesis:")
        for (i, cx) in enumerate(result.counterexamples)
            println("  [$i] Input: $(cx.input)")
            println("      Expected: $(cx.expected_output)")
            if cx.actual_output !== nothing
                println("      Got:      $(cx.actual_output)")
            end
        end
        println()
    end
    
    println(repeat("=", 80))
    println()
    
    return result
end

# ─────────────────────────────────────────────────────────────────────────────
# Main execution
# ─────────────────────────────────────────────────────────────────────────────

# Parse command-line arguments
spec_file = isempty(ARGS) ? "../spec_files/findidx_problem.sl" : ARGS[1]
max_depth = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 6
max_enumerations = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 50_000

println("Z3 CEGIS Synthesis Script")
println(repeat("=", 80))
println("Spec file:        $spec_file")
println("Max depth:        $max_depth")
println("Max enumerations: $max_enumerations")
println(repeat("=", 80))
println()

try
    result = run_z3_cegis(spec_file; max_depth = max_depth, max_enumerations = max_enumerations)
    
    if result !== nothing && result.status == CEGIS.cegis_success
        exit(0)  # Success
    else
        exit(1)  # Failure or no solution
    end
catch e
    println("\n" * repeat("=", 80))
    println("ERROR during synthesis:")
    println(repeat("=", 80))
    println(e)
    println()
    println("Stacktrace:")
    Base.showerror(stderr, e)
    println()
    exit(2)  # Error
end
