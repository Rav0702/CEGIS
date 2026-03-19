"""
rulenode_to_symbolics.jl

Translator from HerbCore RuleNode to Symbolics.jl symbolic expressions.

This module provides utilities to convert synthesized programs (represented as RuleNodes)
into symbolic expressions that can be checked with SymbolicSMT for formal verification.

Usage:
    using HerbGrammar, HerbCore
    using Symbolics
    include("rulenode_to_symbolics.jl")

    @csgrammar begin
        Int = x | y | (1:5)
        Int = Int + Int | Int * Int
    end

    # Create a RuleNode program
    program = RuleNode(...)

    # Convert to symbolic expression
    @variables x::Real y::Real
    expr = rulenode_to_symbolic(program, grammar, Dict(:x => x, :y => y))

    # Use with SymbolicSMT
    using SymbolicSMT
    constraints = Constraints([x >= 0, y >= 0])
    issatisfiable(expr > 0, constraints)
"""

using HerbCore
using HerbGrammar
using HerbInterpret
using Symbolics

export rulenode_to_symbolic

"""
    rulenode_to_symbolic(program::RuleNode, grammar::AbstractGrammar, var_map::Dict)

Convert a RuleNode program to a Symbolics.jl symbolic expression.

# Arguments
- `program::RuleNode` — The synthesized program to convert
- `grammar::AbstractGrammar` — The grammar used for synthesis
- `var_map::Dict{Symbol, Num}` — Mapping of variable names to Symbolics variables
  (e.g., `Dict(:x => x, :y => y)` where `x, y` are created with `@variables`)

# Returns
- `Num` — A Symbolics.jl expression representing the program

# Implementation
Converts RuleNode → Julia Expr → Symbolics by:
1. Using HerbGrammar.rulenode2expr to get a Julia expression
2. Recursively substituting symbolic variables using var_map
3. Evaluating the result to a Symbolics expression
"""
function rulenode_to_symbolic(program::RuleNode, grammar::AbstractGrammar, var_map::Dict)
    # First, convert RuleNode to a Julia expression
    expr = rulenode2expr(program, grammar)
    
    # Then convert that expression to symbolic form
    return _expr_to_symbolic(expr, var_map)
end

"""
    _expr_to_symbolic(expr::Any, var_map::Dict)

Convert a Julia expression (potentially containing variables) to Symbolics form.

Recursively processes expressions, replacing variable names with their corresponding
Symbolics values from var_map.
"""
function _expr_to_symbolic(expr::Any, var_map::Dict)
    # If it's a number, wrap it
    if expr isa Number
        return Symbolics.wrap(expr)
    end
    
    # If it's a symbol, look it up in var_map
    if expr isa Symbol
        if haskey(var_map, expr)
            return var_map[expr]
        else
            error("Variable $expr not found in var_map. Available: $(keys(var_map))")
        end
    end
    
    # If it's an Expr (function call, operator, etc.)
    if expr isa Expr
        # Handle special forms
        if expr.head == :call
            # It's a function call like :(+(x, y))
            func_sym = expr.args[1]
            args = expr.args[2:end]
            
            # Recursively convert arguments
            sym_args = [_expr_to_symbolic(arg, var_map) for arg in args]
            
            # Apply the function
            if func_sym isa Symbol
                # Try to get the function from Main module
                try
                    func = eval(func_sym)
                    return func(sym_args...)
                catch
                    # If it fails, it might be an operator like +, -, *, etc.
                    # These should be handled by the recursive calls above
                    error("Cannot evaluate function: $func_sym")
                end
            end
        end
    end
    
    # If we get here, return the expression as-is (might already be symbolic)
    expr
end
