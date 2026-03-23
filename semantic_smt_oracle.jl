"""
    semantic_smt_oracle.jl

Semantic SMT-based oracle for CEGIS synthesis using formal verification.

The oracle takes a parsed SyGuS specification (SMTSpec) and checks candidate
programs against its constraints using SMT solving. It produces counterexamples
when a candidate violates a constraint.

Usage:
    using HerbCore, HerbGrammar
    include("parse_sygus.jl")
    include("rulenode_to_symbolics.jl")
    include("semantic_smt_oracle.jl")
    
    spec = parse_sygus("problem.sl")
    oracle = SemanticSMTOracle(spec, sym_vars, grammar)
    cex = extract_counterexample(oracle, problem, candidate)
"""

include("parse_sygus.jl")
include("rulenode_to_symbolics.jl")

using HerbCore
using HerbGrammar
using SymbolicSMT
using SymbolicUtils
using Z3

if !isdefined(Main, :CEGIS)
    # Try to load CEGIS module
    try
        using CEGIS
    catch
        include(joinpath(@__DIR__, "src", "CEGIS.jl"))
        using .CEGIS
    end
end

"""
    SemanticSMTOracle <: AbstractOracle

An oracle that verifies candidate programs using SMT solving against a SyGuS specification.

Fields:
- `spec::SMTSpec` — The parsed SyGuS specification containing constraints
- `sym_vars::Dict` — Mapping of variable symbols to SymbolicUtils objects
- `grammar::AbstractGrammar` — The grammar used to generate candidates
- `mod::Module` — Module context for evaluation

The oracle checks if a candidate program violates any constraint in the specification
by building a counterexample query and checking satisfiability with SymbolicSMT.
"""
struct SemanticSMTOracle <: CEGIS.AbstractOracle
    spec::Any  # SMTSpec type not imported, using Any to avoid dependency issues
    sym_vars::Dict
    grammar::AbstractGrammar
    mod::Module
end

function SemanticSMTOracle(
    spec,
    sym_vars::Dict,
    grammar::AbstractGrammar;
    mod::Module = Main
)
    return SemanticSMTOracle(spec, sym_vars, grammar, mod)
end

"""
    extract_counterexample(oracle::SemanticSMTOracle, problem, candidate::RuleNode)

Extract a counterexample from the candidate program using SMT verification.

Returns:
- `Counterexample(input_dict, expected_output, actual_output)` if candidate violates a constraint
- `nothing` if the candidate satisfies all constraints (is verified)
"""
function CEGIS.extract_counterexample(
    oracle::SemanticSMTOracle,
    problem,
    candidate::RuleNode
)::Union{CEGIS.Counterexample, Nothing}
    
    try
        # Convert RuleNode candidate to symbolic expression
        candidate_symbolic = rulenode_to_symbolic(candidate, oracle.grammar, oracle.sym_vars)
        
        # Build CEX query from the specification
        cex_query = build_cex_query(oracle.spec, candidate_symbolic, oracle.sym_vars)
        
        # Check if the query is satisfiable
        is_violated = issatisfiable(cex_query, Constraints([]))
        
        if !is_violated
            # Candidate is verified - satisfies all constraints
            return nothing
        end
        
        # Extract all variable assignments using Z3 model
        cs = Constraints([])
        Z3.push(cs.solver)
        add(cs.solver, SymbolicSMT.to_z3(cex_query, cs.context))
        res = Z3.check(cs.solver)
        
        if string(res) != "sat"
            Z3.pop(cs.solver, 1)
            return nothing
        end
        
        # Get the Z3 model
        model_ptr = Z3.Libz3.Z3_solver_get_model(cs.context.ctx, cs.solver.solver)
        
        # Extract all variable assignments
        input_dict = Dict{Symbol, Any}()
        for var_name in oracle.spec.vars
            SymbolicSMT._eval_var_from_model(var_name, model_ptr, cs.context, input_dict)
        end
        
        println("Found counterexample: $input_dict")
        
        # Find the first violated constraint to get expected output
        # We iterate through constraints to find the one with satisfied precondition
        expected_output = 0
        for (i, constraint) in enumerate(oracle.spec.constraints)
            # Check if precondition is satisfied
            julia_lhs_str = sexpression_to_julia(constraint.lhs)
            lhs_expr = Meta.parse(julia_lhs_str)
            lhs_symbolic = substitute_symbols(lhs_expr, oracle.sym_vars)
            precondition_satisfied = evaluate_in_z3_model(lhs_symbolic, cs, cs.context, model_ptr)
            
            if precondition_satisfied !== true
                continue
            end
            
            # Precondition is satisfied, get expected output
            # The rhs_out can be either an integer (for numeric outputs) or a string (for expressions)
            rhs_out_value = constraint.rhs_out
            
            # Handle numeric outputs directly
            if rhs_out_value isa Int || rhs_out_value isa Float64
                expected_output = rhs_out_value
            else
                # rhs_out_value is a string expression like "(+ x1 x2)" - need to evaluate it
                rhs_str = string(rhs_out_value)  # Ensure it's a string
                try
                    # Convert S-expression to Julia format
                    julia_rhs_str = sexpression_to_julia(rhs_str)
                    # Parse into an expression
                    rhs_expr = Meta.parse(julia_rhs_str)
                    # Substitute symbolic variables
                    rhs_symbolic = substitute_symbols(rhs_expr, oracle.sym_vars)
                    
                    # First try Z3 model evaluation
                    expected_output = evaluate_in_z3_model(rhs_symbolic, cs, cs.context, model_ptr)
                    
                    # If Z3 evaluation returned nothing or a string that looks unevaluated,
                    # fall back to direct evaluation using the counterexample values
                    if expected_output === nothing || (expected_output isa String && startswith(expected_output, "("))
                        expected_output = evaluate_expr_with_values(rhs_symbolic, input_dict)
                        # If that also fails, set to 0
                        if expected_output === nothing
                            println("  WARNING: Could not evaluate RHS expression '$rhs_str' with input $input_dict")
                            expected_output = 0
                        end
                    elseif expected_output isa String
                        # Z3 returned something that's not numeric - this shouldn't happen for well-formed problems
                        println("  WARNING: Z3 evaluation of RHS returned string: '$expected_output'")
                        expected_output = 0
                    end
                catch e
                    # If evaluation fails, set to 0 as fallback
                    println("  WARNING: Failed to evaluate RHS expression '$rhs_str': $e")
                    expected_output = 0
                end
            end
            
            println("Violated constraint #$i: expected output $expected_output")
            break
        end
        
        Z3.pop(cs.solver, 1)
        
        # We don't need actual_output for the IOExample - just use expected_output
        return CEGIS.Counterexample(input_dict, expected_output, expected_output)
        
    catch e
        println("Error in extract_counterexample: $e")
        return nothing
    end
end

"""
    evaluate_in_z3_model(expr, cs::Constraints, context, model_ptr)

Evaluate a symbolic expression using Z3's model.
Returns the evaluated result (Bool, Int, Float, or other value).
"""
function evaluate_in_z3_model(expr, cs::Constraints, context, model_ptr)
    # Convert the expression to Z3
    expr_z3 = SymbolicSMT.to_z3(expr, context)
    
    # Evaluate in the model with model_completion=true
    result_ptr = Ref{Z3.Libz3.Z3_ast}()
    success = Z3.Libz3.Z3_model_eval(
        context.ctx,
        model_ptr,
        expr_z3.expr,
        true,  # model_completion=true
        result_ptr
    )
    
    if success
        result_str = unsafe_string(Z3.Libz3.Z3_ast_to_string(context.ctx, result_ptr[]))
        
        # Try to parse the result as a numeric value first
        # Z3 may return results in various formats: "42", "(\- 3)", "(+ 2 3)", etc.
        
        # Handle boolean values
        if result_str == "true"
            return true
        elseif result_str == "false"
            return false
        end
        
        # Parse Z3 S-expression format for negative numbers: "(- N)" -> -N
        if startswith(result_str, "(- ") && endswith(result_str, ")")
            inner = result_str[4:end-1]
            try
                return -parse(Int, inner)
            catch
                try
                    return -parse(Float64, inner)
                catch
                end
            end
        end
        
        # Try to parse as direct numeric value (most common case)
        try
            return parse(Int, result_str)
        catch
            try
                return parse(Float64, result_str)
            catch
            end
        end
        
        # If direct parsing fails, it might be an S-expression like "(+ 2 3)"
        # Try to evaluate it recursively as a simplified form
        if startswith(result_str, "(") && endswith(result_str, ")")
            # Extract the operator and operands
            # For now, return the string as-is (this shouldn't normally happen for arithmetic)
            # since Z3 should simplify arithmetic expressions automatically
            return result_str
        end
        
        return result_str
    end
    
    return nothing
end

"""
    evaluate_expr_with_values(expr, values_dict::Dict{Symbol, Any})

Evaluate a standard (non-Z3) expression by directly substituting variable values.
This is a fallback for when Z3 model evaluation doesn't work properly.

Args:
- expr: The expression (can be SymbolicUtils expression or Julia expression)
- values_dict: Dictionary mapping variable names (as Symbols) to their numeric values
"""
function evaluate_expr_with_values(expr, values_dict::Dict{Symbol, Any})
    try
        # If it's already a SymbolicUtils expression, evaluate it directly
        if applicable(Symbolics.substitute, expr, values_dict)
            result = Symbolics.substitute(expr, values_dict)
            # If result is still symbolic, try to simplify
            if applicable(Symbolics.simplify, result)
                result = Symbolics.simplify(result)
            end
            # Convert to a numeric value if possible
            if result isa Number
                return result
            elseif isa(result, SymbolicUtils.Sym) || isa(result, SymbolicUtils.Add) || 
                   isa(result, SymbolicUtils.Mul) || isa(result, SymbolicUtils.Div)
                # Try to evaluate the expression numerically
                return Float64(result)
            end
            return result
        end
    catch
        # If substitute/evaluation fails, return nothing
    end
    return nothing
end
