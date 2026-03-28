"""
    semantic_smt_oracle_declared_fun.jl

Extended SMT-based oracle for CEGIS synthesis that supports declare-fun (uninterpreted functions).

This module extends semantic_smt_oracle.jl to handle function declarations by treating
uninterpreted functions as symbolic terms that get passed to Z3.
"""

using HerbCore
using HerbGrammar
using SymbolicSMT
using SymbolicUtils
using SymbolicUtils: BasicSymbolic, operation, arguments, istree, @syms
using Symbolics: Num, unwrap
using Z3

# Include the base oracle (which has CEGIS imports)
include("semantic_smt_oracle.jl")
include("rulenode_to_symbolics.jl")

"""
    SemanticSMTOracleDeclaredFun <: AbstractOracle

Extended oracle that supports both defined functions (define-fun) and declared functions (declare-fun).
"""
struct SemanticSMTOracleDeclaredFun <: CEGIS.AbstractOracle
    spec::Any  # SMTSpec type
    sym_vars::Dict
    grammar::AbstractGrammar
    mod::Module
end

function SemanticSMTOracleDeclaredFun(
    spec,
    sym_vars::Dict,
    grammar::AbstractGrammar;
    mod::Module = Main
)
    return SemanticSMTOracleDeclaredFun(spec, sym_vars, grammar, mod)
end

# Build counterexample query with declared function support
function build_cex_query_with_expected_declared(oracle::SemanticSMTOracleDeclaredFun, candidate_symbolic)
    candidate_symbolic = _to_su(candidate_symbolic)
    @syms y_expected::Int

    println("\n=== DEBUG: Build CEX Query (with declared-fun support) ===")
    println("Number of constraints: $(length(oracle.spec.constraints))")

    # Get declared functions from spec - convert to Dict{String, Any} for compatibility
    declared_funs = Dict{String, Any}()
    try
        for (k, v) in oracle.spec.declared_functions
            declared_funs[k] = v
        end
    catch
        # No declared functions
    end
    println("Number of declared functions: $(length(declared_funs))")

    disjuncts = Any[]
    for (idx, c) in enumerate(oracle.spec.constraints)
        println("\nConstraint $idx:")
        println("  Raw constraint: $c")
        
        # Parse guard and RHS with declared function support - pass declared_funs
        guard_i, rhs_i = _constraint_guard_rhs(c, oracle.sym_vars, declared_funs)
        println("  Guard: $guard_i")
        println("  RHS: $rhs_i")
        guard_i = _to_su(guard_i)
        rhs_i   = _to_su(rhs_i)
        disjunct = guard_i & (y_expected == rhs_i) & (candidate_symbolic != y_expected)
        println("  Disjunct: $disjunct")
        push!(disjuncts, disjunct)
    end

    isempty(disjuncts) && return false, y_expected
    q = disjuncts[1]
    for i in 2:length(disjuncts)
        q = q | disjuncts[i]
    end
    println("\nFinal query: $q")
    return q, y_expected
end

# Override extract_counterexample to use the extended oracle
function extract_counterexample_declared(oracle::SemanticSMTOracleDeclaredFun, problem, candidate)
    try
        candidate_symbolic = convert_candidate_to_symbolic(candidate, problem.grammar)
        query, y_expected = build_cex_query_with_expected_declared(oracle, candidate_symbolic)

        if query == false
            println("All constraints are satisfiable (no counterexample)")
            return nothing
        end

        cs = Z3.Constraints()
        issatisfiable(query, cs) || return nothing

        println("Counterexample found!")
        vals = Z3.model(cs.ctx, cs.solver) |> (m -> Z3.get_const_interp(m))
        model_vals = Z3.model(cs.ctx, cs.solver)

        input_vals = Dict{Symbol, Any}()
        for (var_sym, var_z3) in oracle.sym_vars
            try
                val = evaluate_in_z3_model(var_z3, cs, cs.ctx, model_vals)
                input_vals[var_sym] = val
            catch
                input_vals[var_sym] = 0
            end
        end

        try
            expected_val = evaluate_in_z3_model(y_expected, cs, cs.ctx, model_vals)
        catch
            expected_val = 0
        end

        try
            actual_val = problem.evaluate(candidate, input_vals)
        catch
            actual_val = expected_val
        end

        return Counterexample(input_vals, expected_val, actual_val)
    catch e
        println("Error in extract_counterexample: $(typeof(e)): $e")
        return nothing
    end
end

# Register the method for the new oracle type
function CEGIS.extract_counterexample(oracle::SemanticSMTOracleDeclaredFun, problem, candidate::RuleNode)
    cs = Constraints([])
    pushed = false
    try
        candidate_symbolic = _to_su(rulenode_to_symbolic(candidate, oracle.grammar, oracle.sym_vars))
        cex_query, y_expected = build_cex_query_with_expected_declared(oracle, candidate_symbolic)

        # Skip the symbolic check, go directly to Z3
        Z3.push(cs.solver); pushed = true
        cex_query_z3 = SymbolicSMT.to_z3(_to_su(cex_query), cs.context)
        _solver_assert_local!(cs, cex_query_z3)

        chk = Z3.check(cs.solver)
        
        # CheckResult is a custom type, compare by string representation
        is_sat = (string(chk) == "sat")
        
        if !is_sat
            return nothing
        end

        # Model and extraction
        model_ptr = Z3.Libz3.Z3_solver_get_model(cs.context.ctx, cs.solver.solver)
        Z3.Libz3.Z3_model_inc_ref(cs.context.ctx, model_ptr)
        
        input_vals = Dict{Symbol, Any}()
        for (var_sym, var_expr) in oracle.sym_vars
            try
                val = evaluate_in_z3_model(var_expr, cs, cs.context, model_ptr)
                input_vals[var_sym] = val
            catch e
                input_vals[var_sym] = 0
            end
        end
        
        expected_val = try
            evaluate_in_z3_model(y_expected, cs, cs.context, model_ptr)
        catch e
            0
        end
        
        actual_val = try
            problem.evaluate(candidate, input_vals)
        catch e
            expected_val
        end
        
        return Counterexample(input_vals, expected_val, actual_val)
    catch e
        println("Extract_counterexample error (declared fun): $e")
        println("  type: $(typeof(e))")
        return nothing
    finally
        if pushed
            Z3.pop(cs.solver)
        end
    end
end
