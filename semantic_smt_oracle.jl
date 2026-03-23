"""
    semantic_smt_oracle.jl

Semantic SMT-based oracle for CEGIS synthesis using formal verification.

The oracle takes a parsed SyGuS specification (SMTSpec) and checks candidate
programs against its constraints using SMT solving. It produces counterexamples
when a candidate violates a constraint.

Requires: parse_sygus.jl, rulenode_to_symbolics.jl, and CEGIS module to be loaded first.
"""

using HerbCore
using HerbGrammar
using SymbolicSMT
using SymbolicUtils
using Z3

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
            rhs_out_value = constraint.rhs_out
            if rhs_out_value isa String
                julia_rhs_str = sexpression_to_julia(rhs_out_value)
                rhs_expr = Meta.parse(julia_rhs_str)
                rhs_symbolic = substitute_symbols(rhs_expr, oracle.sym_vars)
                expected_output = evaluate_in_z3_model(rhs_symbolic, cs, cs.context, model_ptr)
            else
                expected_output = rhs_out_value
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
        
        # Try to parse as numeric value
        try
            return parse(Int, result_str)
        catch
            try
                return parse(Float64, result_str)
            catch
                return result_str
            end
        end
    end
    
    return nothing
end
