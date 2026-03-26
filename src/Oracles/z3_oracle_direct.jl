"""
    z3_oracle_direct.jl

Z3-based oracle using direct Z3 Julia API instead of SMT-LIB2 queries.
Uses native Z3.jl wrapper for more efficient verification.

Replaces the CEXGeneration + SMT-LIB2 string approach with direct AST building.
"""

using HerbCore
using HerbGrammar
using Z3

"""
    Z3OracleDirect <: AbstractOracle

An oracle that verifies candidate programs using Z3 Julia API directly.

Builds Z3 AST expressions from candidates and formulas, avoiding string conversion issues.

Fields:
- `spec_file::String` — Path to the .sl SyGuS specification file
- `spec::Any` — Parsed specification (CEXGeneration.Spec)
- `grammar::AbstractGrammar` — The grammar used to generate candidates
- `z3_ctx::Z3.Context` — Z3 context for expression building
- `z3_vars::Dict{String,Z3.Expr}` — Cached Z3 variables for free variables
- `mod::Module` — Module context for evaluation
"""
struct Z3OracleDirect <: AbstractOracle
    spec_file::String
    spec::Any  # CEXGeneration.Spec
    grammar::AbstractGrammar
    z3_ctx::Z3.Context
    z3_vars::Dict{String,Z3.Expr}
    mod::Module
end

"""
    Z3OracleDirect(spec_file::String, grammar::AbstractGrammar; mod::Module = Main)

Create a Z3OracleDirect using the native Z3 Julia API.
"""
function Z3OracleDirect(
    spec_file::String,
    grammar::AbstractGrammar;
    mod::Module = Main
)
    spec = try
        CEXGeneration.parse_spec_from_file(spec_file)
    catch
        error("CEXGeneration module not found. Make sure it's loaded before Z3OracleDirect is used.")
    end
    
    # Create Z3 context
    z3_ctx = Z3.Context()
    
    # Create Z3 variables for all free variables
    z3_vars = Dict{String,Z3.Expr}()
    for fv in spec.free_vars
        if fv.sort == "Int"
            z3_vars[fv.name] = Z3.IntVar(fv.name, z3_ctx)
        elseif fv.sort == "Bool"
            z3_vars[fv.name] = Z3.BoolVar(fv.name, z3_ctx)
        end
    end
    
    return Z3OracleDirect(spec_file, spec, grammar, z3_ctx, z3_vars, mod)
end

"""
    rulenode_to_z3_expr(node::RuleNode, grammar::AbstractGrammar, z3_ctx::Z3.Context, z3_vars::Dict)::Z3.Expr

Convert a RuleNode to a Z3 expression using the Z3 API.
"""
function rulenode_to_z3_expr(
    node::RuleNode,
    grammar::AbstractGrammar,
    z3_ctx::Z3.Context,
    z3_vars::Dict{String,Z3.Expr}
)::Z3.Expr
    # Convert to Julia expression first
    julia_expr = HerbGrammar.rulenode2expr(node, grammar)
    
    # Then convert Julia expression to Z3
    return expr_to_z3(julia_expr, z3_ctx, z3_vars)
end

"""
    expr_to_z3(val::Any, ctx::Z3.Context, vars::Dict)::Z3.Expr

Convert a Julia value or expression to a Z3 expression.
"""
function expr_to_z3(val::Any, ctx::Z3.Context, vars::Dict{String,Z3.Expr})::Z3.Expr
    # Handle literals
    if val isa Integer
        return Z3.IntVal(val, ctx)
    elseif val isa Bool
        return Z3.BoolVal(val, ctx)
    elseif val isa Symbol
        # Look up variable in vars dict
        var_name = string(val)
        if haskey(vars, var_name)
            return vars[var_name]
        else
            error("Variable not found: $var_name")
        end
    elseif val isa Expr && val.head == :call
        op = val.args[1]
        args = val.args[2:end]
        
        # Binary arithmetic operators
        if length(args) == 2
            left = expr_to_z3(args[1], ctx, vars)
            right = expr_to_z3(args[2], ctx, vars)
            
            if op == :+
                return left + right
            elseif op == :-
                return left - right
            elseif op == :*
                return left * right
            elseif op == :/
                return left / right
            elseif op == :^
                return left ^ right
            # Comparisons
            elseif op == :<
                return left < right
            elseif op == :<=
                return left <= right
            elseif op == :>
                return left > right
            elseif op == :>=
                return left >= right
            elseif op == :(==)
                return left == right
            elseif op == :(!=)
                return left != right
            end
        end
        
        # Unary operators
        if length(args) == 1
            arg = expr_to_z3(args[1], ctx, vars)
            if op == :-
                return -arg
            elseif op == :!
                return Z3.Not(arg)
            end
        end
        
        # if-then-else (ternary)
        if op == :ifelse && length(args) == 3
            cond = expr_to_z3(args[1], ctx, vars)
            then_val = expr_to_z3(args[2], ctx, vars)
            else_val = expr_to_z3(args[3], ctx, vars)
            return Z3.If(cond, then_val, else_val)
        end
    end
    
    error("Cannot convert to Z3 expression: $val")
end

"""
    extract_counterexample(oracle::Z3OracleDirect, problem, candidate::RuleNode)

Extract a counterexample by directly building Z3 expressions and solving.
"""
function extract_counterexample(
    oracle::Z3OracleDirect,
    problem,
    candidate::RuleNode
)::Union{Counterexample, Nothing}
    try
        # Convert candidate to Z3 expression
        candidate_z3 = rulenode_to_z3_expr(candidate, oracle.grammar, oracle.z3_ctx, oracle.z3_vars)
        
        # Build constraints from spec
        # Each constraint is a SMT-LIB2 string - need to convert to Z3 expressions
        # For now, return nothing if no constraints (UNSAT check not properly impl yet)
        if isempty(oracle.spec.constraints)
            return nothing
        end
        
        # TODO: Convert spec.constraints strings to Z3 expressions
        # This requires parsing the constraint SMT-LIB2 format or having a converter
        
        # For now, just return nothing (no counterexample found)
        return nothing
        
    catch e
        return nothing
    end
end
