"""
test_program_verification.jl

Test a candidate program directly against the parsed SyGuS specification
using Z3 verification, without running full synthesis.

This helps validate that a program is correct and that the formal verification
pipeline works as expected.

Run from CEGIS/ directory:
    julia test_program_verification.jl [spec_file.sl] [program]

Example:
    julia test_program_verification.jl formal_benchmarks/array_sum_2_5.sl "(x1 + x2) * (x1 + x2 > 5)"
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
using HerbInterpret
using HerbSpecification
using SymbolicSMT
using SymbolicUtils
using Symbolics
using Z3

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "src", "CEGIS.jl"))
end
using .CEGIS

# Include helper modules
include("parse_sygus.jl")
include("rulenode_to_symbolics.jl")
include("semantic_smt_oracle.jl")

# ──────────────────────────────────────────────────────────────────────────────
# Parse command line arguments
# ──────────────────────────────────────────────────────────────────────────────
if length(ARGS) < 2
    println("Usage: julia test_program_verification.jl <spec_file.sl> <program_expr>")
    println()
    println("Example:")
    println("  julia test_program_verification.jl formal_benchmarks/array_sum_2_5.sl '(x1 + x2) * (x1 + x2 > 5)'")
    exit(1)
end

spec_file = ARGS[1]
program_str = ARGS[2]

if !isfile(spec_file)
    println("Error: Spec file not found: $spec_file")
    exit(1)
end

println(repeat("=", 80))
println("Program Verification Test")
println(repeat("=", 80))
println()
println("Specification file: $spec_file")
println("Program to test: $program_str")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Parse the specification
# ──────────────────────────────────────────────────────────────────────────────
println("Parsing specification...")
spec = parse_sygus(spec_file)

println("\nParsed SyGuS Specification:")
println("Variables: $(spec.vars)")
println("Constraints ($(length(spec.constraints))):")
for (i, constraint) in enumerate(spec.constraints)
    println("  [$i] $(constraint.lhs) => $(constraint.rhs_out)")
end
println()

# ──────────────────────────────────────────────────────────────────────────────
# Create symbolic variables
# ──────────────────────────────────────────────────────────────────────────────
println("Creating symbolic variables...")
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
# Parse the candidate program
# ──────────────────────────────────────────────────────────────────────────────
println("Parsing candidate program...")

program_symbolic = nothing

program_expr = Meta.parse(program_str)
println("Parsed expression: $program_expr")

# Convert to symbolic form
program_symbolic = if program_expr isa Symbol
    get(sym_vars, program_expr, program_expr)
else
    # Substitute symbols in the expression
    substitute_symbols(program_expr, sym_vars)
end

println("Symbolic form: $program_symbolic")
println()

# Debug: check the type
println("DEBUG: program_symbolic = $program_symbolic (type: $(typeof(program_symbolic)))")

# Verify program_symbolic is not nothing
if program_symbolic === nothing
    println("ERROR: program_symbolic is nothing after parsing!")
    exit(1)
end
println()

# ──────────────────────────────────────────────────────────────────────────────
# Build and check the verification query
# ──────────────────────────────────────────────────────────────────────────────
println("Building verification query...")

# First, let's print what the candidate expression and expected outputs are
println("\nDebug info:")
println("  Candidate: $program_symbolic (type: $(typeof(program_symbolic)))")
for (i, c) in enumerate(spec.constraints)
    println("  Constraint $i:")
    println("    LHS: $(c.lhs)")
    println("    RHS (expected output): $(c.rhs_out) (type: $(typeof(c.rhs_out)))")
end
println()

# Build the query: check if there exists an assignment where some constraint is violated
cex_query = build_cex_query(spec, program_symbolic, sym_vars)

println("Verification Query (looking for counterexample):")
println("$cex_query")
println("Query type: $(typeof(cex_query))")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Check satisfiability with Z3
# ──────────────────────────────────────────────────────────────────────────────
println(repeat("=", 80))
println("Z3 Verification")
println(repeat("=", 80))
println()

is_violated = issatisfiable(cex_query, Constraints([]))

println("Counterexample query is satisfiable: $is_violated")
println()

if is_violated
    println("❌ RESULT: COUNTEREXAMPLE FOUND (program is INCORRECT)")
    println()
    println("The program does NOT satisfy all constraints.")
    println("Z3 found an assignment that violates at least one constraint.")
    println()
    
    # Try to extract the counterexample details
    try
        cs = Constraints([])
        Z3.push(cs.solver)
        add(cs.solver, SymbolicSMT.to_z3(cex_query, cs.context))
        res = Z3.check(cs.solver)
        
        if string(res) == "sat"
            model_ptr = Z3.Libz3.Z3_solver_get_model(cs.context.ctx, cs.solver.solver)
            
            input_dict = Dict{Symbol, Any}()
            for var_name in spec.vars
                SymbolicSMT._eval_var_from_model(var_name, model_ptr, cs.context, input_dict)
            end
            
            println("Counterexample values: $input_dict")
            
            # Evaluate program at these values
            # Try using Symbolics.substitute and evaluate
            try
                substituted = Symbolics.substitute(program_symbolic, input_dict)
                result_simplified = try
                    Symbolics.simplify(substituted)
                catch
                    substituted
                end
                
                # Try to get numeric value
                result_numeric = try
                    if result_simplified isa Number
                        result_simplified
                    else
                        Float64(result_simplified)
                    end
                catch
                    result_simplified
                end
                
                println("Program output at counterexample: $result_numeric")
                println()
                
                # Check what the expected output should be for each constraint
                println("Constraint verification:")
                violations_found = false
                for (i, c) in enumerate(spec.constraints)
                    julia_lhs_str = sexpression_to_julia(c.lhs)
                    lhs_expr = Meta.parse(julia_lhs_str)
                    lhs_symbolic = substitute_symbols(lhs_expr, sym_vars)
                    
                    # Check if precondition is satisfied
                    precondition_result = Symbolics.substitute(lhs_symbolic, input_dict)
                    
                    # Debug: print pre-simplification
                    println("    [DEBUG pre-simplification] $(precondition_result)")
                    
                    precondition_satisfied = try
                        simplified = Symbolics.simplify(precondition_result)
                        println("    [DEBUG post-simplification] $simplified")
                        simplified
                    catch e
                        println("    [DEBUG simplify failed] $e")
                        precondition_result
                    end
                    
                    println("  ────────────────────────────────────────")
                    println("  Constraint #$i:")
                    
                    if precondition_satisfied === true || precondition_satisfied == true
                        println("    Precondition: SATISFIED")
                        
                        # Get expected output
                        rhs_out_value = c.rhs_out
                        if rhs_out_value isa String
                            julia_rhs_str = sexpression_to_julia(rhs_out_value)
                            rhs_expr = Meta.parse(julia_rhs_str)
                            rhs_symbolic = substitute_symbols(rhs_expr, sym_vars)
                            expected_value = try
                                rhs_substituted = Symbolics.substitute(rhs_symbolic, input_dict)
                                simplified = Symbolics.simplify(rhs_substituted)
                                if simplified isa Number
                                    simplified
                                else
                                    Float64(simplified)
                                end
                            catch
                                c.rhs_out
                            end
                        else
                            expected_value = rhs_out_value
                        end
                        
                        is_match = result_numeric == expected_value
                        println("    Expected output: $expected_value")
                        println("    Actual output:   $result_numeric")
                        println("    Match: $(is_match ? "✓ YES" : "✗ NO")")
                        
                        if !is_match
                            violations_found = true
                        end
                    else
                        println("    Precondition: NOT SATISFIED")
                        println("    Precondition value: $precondition_satisfied (type: $(typeof(precondition_satisfied)))")
                    end
                end
                
                println("  ────────────────────────────────────────")
                println()
                if violations_found
                    println("Result: Program violates at least one constraint")
                else
                    println("Result: Program satisfies all applicable constraints at this input")
                end
            catch e
                println("Program evaluation failed: $e")
            end
        end
        
        Z3.pop(cs.solver, 1)
    catch e
        println("(Could not extract detailed counterexample: $e)")
    end
else
    println("✓ RESULT: NO COUNTEREXAMPLE (program is CORRECT)")
    println()
    println("The program satisfies all constraints!")
    println("Z3 confirmed that for all possible input assignments,")
    println("the program produces the expected outputs.")
end

println()
println(repeat("=", 80))
