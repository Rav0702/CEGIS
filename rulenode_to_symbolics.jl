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

export rulenode_to_symbolic, build_symbolic_context

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

# Examples
```julia
using HerbGrammar, HerbCore, Symbolics
include("rulenode_to_symbolics.jl")

@csgrammar begin
    Int = x | (1:3)
    Int = Int + Int | Int * Int
end

@variables x::Real
var_map = Dict(:x => x)

# Create a simple RuleNode (e.g., x + 1)
program = RuleNode(3, [RuleNode(2), RuleNode(1)])  # Depends on grammar rules

expr = rulenode_to_symbolic(program, grammar, var_map)
println(expr)  # Should print something like: x + 1
```
"""
function rulenode_to_symbolic(program::RuleNode, grammar::AbstractGrammar, var_map::Dict)
    return _rulenode_to_symbolic_recursive(program, grammar, var_map)
end

"""
    _rulenode_to_symbolic_recursive(node::RuleNode, grammar, var_map)

Recursively convert a RuleNode to a symbolic expression.

This is the core recursive function that handles:
- Leaf nodes (terminal symbols like constants or variables)
- Composite nodes (operations with children)
"""
function _rulenode_to_symbolic_recursive(node::RuleNode, grammar::AbstractGrammar, var_map::Dict)
    rule_index = node.ind
    
    # Get the rule from the grammar
    rule = grammar.rules[rule_index]
    
    # Handle different rule types
    if rule isa AbstractRuleNode
        error("Rule should not be an AbstractRuleNode")
    end
    
    # Check if it's a terminal (no children needed)
    if isempty(node.children)
        return _evaluate_terminal_rule(rule, var_map, grammar)
    else
        # Composite rule - recursively process children and apply the operation
        return _evaluate_composite_rule(rule, node.children, grammar, var_map)
    end
end

"""
    _evaluate_terminal_rule(rule, var_map, grammar)

Evaluate a terminal rule (constant, variable, or leaf symbol).

Types of terminal rules:
1. Numeric constants: `1`, `2`, `-5`, etc.
2. Variable references: `x`, `y`, `z`, etc.
3. Other symbolic constants
"""
function _evaluate_terminal_rule(rule, var_map::Dict, grammar::AbstractGrammar)
    # Rule value is typically the terminal value itself
    
    # Check if it's a variable name (Symbol)
    if rule isa Symbol
        var_name = rule
        if haskey(var_map, var_name)
            return var_map[var_name]
        else
            error("Variable $var_name not found in var_map. Available: $(keys(var_map))")
        end
    end
    
    # Check if it's a numeric constant
    if rule isa Number
        return Symbolics.wrap(rule)
    end
    
    # Check if rule is a string representation of a variable
    if rule isa String
        var_name = Symbol(rule)
        if haskey(var_map, var_name)
            return var_map[var_name]
        else
            error("Variable $var_name not found in var_map")
        end
    end
    
    # Fallback: try to convert to number
    try
        value = parse(Float64, string(rule))
        return Symbolics.wrap(value)
    catch
        error("Cannot evaluate terminal rule: $rule (type: $(typeof(rule)))")
    end
end

"""
    _evaluate_composite_rule(rule, children::Vector{RuleNode}, grammar, var_map)

Evaluate a composite rule (operation with child nodes).

Handles arithmetic and logical operations based on the rule definition.
"""
function _evaluate_composite_rule(rule, children::Vector{RuleNode}, grammar::AbstractGrammar, var_map::Dict)
    # Recursively evaluate all children
    child_values = [_rulenode_to_symbolic_recursive(child, grammar, var_map) for child in children]
    
    # Determine the operation based on the rule
    op_name = string(rule)
    
    # Common binary operations
    if op_name == "+" && length(child_values) == 2
        return child_values[1] + child_values[2]
    elseif op_name == "-" && length(child_values) == 2
        return child_values[1] - child_values[2]
    elseif op_name == "*" && length(child_values) == 2
        return child_values[1] * child_values[2]
    elseif op_name == "/" && length(child_values) == 2
        return child_values[1] / child_values[2]
    elseif op_name == "^" && length(child_values) == 2
        return child_values[1] ^ child_values[2]
    end
    
    # Unary operations
    if op_name == "-" && length(child_values) == 1
        return -child_values[1]
    elseif op_name == "abs" && length(child_values) == 1
        return abs(child_values[1])
    end
    
    # Comparison operations (return boolean)
    if op_name == ">" && length(child_values) == 2
        return child_values[1] > child_values[2]
    elseif op_name == "<" && length(child_values) == 2
        return child_values[1] < child_values[2]
    elseif op_name == ">=" && length(child_values) == 2
        return child_values[1] >= child_values[2]
    elseif op_name == "<=" && length(child_values) == 2
        return child_values[1] <= child_values[2]
    elseif op_name == "=" && length(child_values) == 2
        # = in SyGuS becomes == in Julia
        return child_values[1] == child_values[2]
    elseif op_name == "==" && length(child_values) == 2
        return child_values[1] == child_values[2]
    elseif op_name == "!=" && length(child_values) == 2
        return child_values[1] != child_values[2]
    end
    
    # Logical operations
    if op_name == "&" && length(child_values) == 2
        return child_values[1] & child_values[2]
    elseif op_name == "|" && length(child_values) == 2
        return child_values[1] | child_values[2]
    elseif op_name == "!" && length(child_values) == 1
        return !child_values[1]
    end
    
    # Special functions
    if op_name == "ifelse" && length(child_values) == 3
        # ifelse(cond, true_val, false_val)
        # For SMT, we need to encode this. Symbolics might not support it directly,
        # so we return a conditional expression
        return _symbolic_ifelse(child_values[1], child_values[2], child_values[3])
    end
    
    # If operation not recognized, raise error
    error("Unknown operation: $op_name with $(length(child_values)) arguments")
end

"""
    _symbolic_ifelse(cond, true_val, false_val)

Represent ifelse in symbolic form.

SMT solvers can handle this via:
  (cond => true_val) & (!cond => false_val)
which is logically equivalent to ifelse.
"""
function _symbolic_ifelse(cond, true_val, false_val)
    # Create the logical representation: (cond AND true_val) OR (NOT cond AND false_val)
    # This works for both integer and boolean value types
    return (cond & true_val) | (!cond & false_val)
end

"""
    build_symbolic_context(var_names::Vector{Symbol})

Create a symbolic context with variables for use in rulenode_to_symbolic.

# Arguments
- `var_names::Vector{Symbol}` — Names of variables to create (e.g., [:x, :y, :z])

# Returns
- `Dict{Symbol, Num}` — Mapping of variable names to Symbolics variables

# Example
```julia
using Symbolics
include("rulenode_to_symbolics.jl")

var_map = build_symbolic_context([:x, :y])
# Returns: Dict(:x => x::Num, :y => y::Num)
# where x, y are Symbolics variables
```
"""
function build_symbolic_context(var_names::Vector{Symbol})
    # Use Symbolics @variables macro to create variables
    var_dict = Dict{Symbol, Any}()
    
    for var_name in var_names
        # Create a real-valued symbolic variable
        var_sym = Symbolics.Sym{Symbolics.Real}(var_name)
        var_num = Symbolics.wrap(var_sym)
        var_dict[var_name] = var_num
    end
    
    return var_dict
end

"""
    rulenode_to_expr(program::RuleNode, grammar::AbstractGrammar)

Convert a RuleNode to a Julia Expr for interpretation.

This is different from rulenode_to_symbolic - it produces a Julia expression
that can be evaluated with execute_on_input, rather than a symbolic expression.

This is the standard way to convert RuleNodes for HerbInterpret.
"""
function rulenode_to_expr(program::RuleNode, grammar::AbstractGrammar)
    return HerbGrammar.rulenode2expr(program, grammar)
end
