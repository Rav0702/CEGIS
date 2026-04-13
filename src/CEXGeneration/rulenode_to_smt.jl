"""
    rulenode_to_smt.jl

Direct RuleNode → SMT-LIB2 conversion (simplified approach).

Skips intermediate representations (Julia Expr, infix string) by:
1. Traversing RuleNode tree directly
2. Tracking type context (Bool vs Int) at each node
3. Building SMT-LIB2 strings directly

This is simpler, faster, and preserves type information throughout.
"""

using HerbCore
using HerbGrammar

"""
    rulenode_to_smt2(node::RuleNode, grammar::AbstractGrammar; context_type::Symbol=:int)::String

Convert a RuleNode directly to SMT-LIB2 format with type tracking.

# Arguments
- `node::RuleNode` — The candidate program tree
- `grammar::AbstractGrammar` — Grammar from which the RuleNode was derived
- `context_type::Symbol` — Expected type context (`:int` or `:bool`)

# Returns
- SMT-LIB2 formatted string

# Type Coercion Rules
- **Bool → Int**: `(ite condition 1 0)` when Bool appears in arithmetic context
- **Int → Bool**: Error (cannot coerce Int to Bool in comparisons)

# Supported Operators
- **Arithmetic**: `+`, `-`, `*`
- **Comparison**: `>`, `<`, `>=`, `<=`, `=`, `!=`
- **Boolean**: `and`, `or`, `not`
- **Control**: `if-then-else` (ite/ifelse)

# Example
```julia
oracle = Z3Oracle("problem.sl", grammar)
candidate = rulenode_to_smt2(some_rulenode, oracle.grammar)
# Returns: "(ite (> x y) x y)" or similar
```
"""
function rulenode_to_smt2(
    node::RuleNode,
    grammar::AbstractGrammar;
    context_type::Symbol = :int
)::String
    _rulenode_to_smt_impl(node, grammar, context_type)
end

# ═════════════════════════════════════════════════════════════════════════════
# INTERNAL IMPLEMENTATION
# ═════════════════════════════════════════════════════════════════════════════

"""
Internal implementation with type tracking.
Returns smt_string with proper type tracking.
"""
function _rulenode_to_smt_impl(
    node::RuleNode,
    grammar::AbstractGrammar,
    expected_type::Symbol = :int
)::String
    
    # Terminal node (leaf)
    if isempty(node.children)
        rule_idx = node.ind
        rule_expr = grammar.rules[rule_idx]  # Direct expression from grammar
        
        smt, typ = _terminal_to_smt(rule_expr, grammar, rule_idx)
        
        # Coerce type if needed
        if typ != expected_type
            smt = _coerce_type(smt, typ, expected_type)
        end
        
        return smt
    end
    
    # Internal node (operator with children)
    rule_idx = node.ind
    rule_expr = grammar.rules[rule_idx]
    op_name = isa(rule_expr, Symbol) ? rule_expr : rule_expr  # Handle both Symbol and Expr
    
    if isa(rule_expr, Symbol)
        op_name = rule_expr
    elseif isa(rule_expr, Expr) && rule_expr.head == :call
        op_name = rule_expr.args[1]
    else
        op_name = rule_expr
    end
    
    # Dispatch to specific operator handlers
    if op_name == :ifelse || op_name == :ite || op_name == Symbol("ite")
        return _handle_ite(node, grammar, expected_type)
    elseif op_name ∈ (:+, :-, :*)
        return _handle_arithmetic(node, grammar, op_name, expected_type)
    elseif op_name ∈ (:(>), :(<), :(>=), :(<=), :(==), :(!=))
        return _handle_comparison(node, grammar, op_name, expected_type)
    elseif op_name ∈ (:and, :or)
        return _handle_boolean(node, grammar, op_name, expected_type)
    elseif op_name == :not
        return _handle_not(node, grammar, expected_type)
    else
        # Unknown operator: try as-is
        error("Unknown operator in RuleNode: $op_name")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# TERMINAL HANDLING
# ─────────────────────────────────────────────────────────────────────────────

"""Handle terminal nodes (literals and variables)"""
function _terminal_to_smt(rule_expr::Any, grammar::AbstractGrammar, rule_idx::Int)::Tuple{String, Symbol}
    # Convert rule expression to symbol if needed
    sym = isa(rule_expr, Symbol) ? rule_expr : Symbol(string(rule_expr))
    name_str = string(sym)
    
    # Boolean literals
    if sym == :true
        return ("true", :bool)
    elseif sym == :false
        return ("false", :bool)
    end
    
    # Integer literals
    if occursin(r"^-?\d+$", name_str)
        num = parse(Int, name_str)
        if num < 0
            return ("(- $(abs(num)))", :int)
        else
            return (name_str, :int)
        end
    end
    
    # Variables (assume Int by default unless context suggests Bool)
    # Variables like x, y, k, x0, x1 etc.
    return (name_str, :int)
end

# ─────────────────────────────────────────────────────────────────────────────
# OPERATOR HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

"""Handle if-then-else (ite) expressions"""
function _handle_ite(
    node::RuleNode,
    grammar::AbstractGrammar,
    expected_type::Symbol
)::String
    
    length(node.children) >= 3 || error("ite requires 3 children")
    
    # Condition must be Bool
    cond = _rulenode_to_smt_impl(node.children[1], grammar, :bool)
    
    # Then/else branch: should match expected type
    then_br = _rulenode_to_smt_impl(node.children[2], grammar, expected_type)
    else_br = _rulenode_to_smt_impl(node.children[3], grammar, expected_type)
    
    return "(ite $cond $then_br $else_br)"
end

"""Handle arithmetic operators (+, -, *)"""
function _handle_arithmetic(
    node::RuleNode,
    grammar::AbstractGrammar,
    op::Symbol,
    expected_type::Symbol
)::String
    
    length(node.children) == 2 || error("Binary operator $op requires 2 children, got $(length(node.children))")
    
    # Arithmetic always works on Int
    lhs = _rulenode_to_smt_impl(node.children[1], grammar, :int)
    rhs = _rulenode_to_smt_impl(node.children[2], grammar, :int)
    
    smt_op = string(op)  # "+", "-", "*"
    result = "($smt_op $lhs $rhs)"
    
    # If context expects Bool, wrap result
    if expected_type == :bool
        result = "(> $result 0)"  # Treat non-zero as true
    end
    
    return result
end

"""Handle comparison operators (>, <, >=, <=, =, !=)"""
function _handle_comparison(
    node::RuleNode,
    grammar::AbstractGrammar,
    op::Symbol,
    expected_type::Symbol
)::String
    
    length(node.children) == 2 || error("Comparison $op requires 2 children")
    
    # Comparisons always work on Int
    lhs = _rulenode_to_smt_impl(node.children[1], grammar, :int)
    rhs = _rulenode_to_smt_impl(node.children[2], grammar, :int)
    
    # Map operators to SMT names
    op_map = Dict(
        :(>) => ">",
        :(<) => "<",
        :(>=) => ">=",
        :(<=) => "<=",
        :(==) => "=",
        :(!=) => "distinct"
    )
    
    smt_op = get(op_map, op, string(op))
    result = "($smt_op $lhs $rhs)"
    
    # Comparison returns Bool; coerce if context needs Int
    if expected_type == :int
        result = "(ite $result 1 0)"
    end
    
    return result
end

"""Handle boolean operators (and, or)"""
function _handle_boolean(
    node::RuleNode,
    grammar::AbstractGrammar,
    op::Symbol,
    expected_type::Symbol
)::String
    
    length(node.children) == 2 || error("Boolean op $op requires 2 children")
    
    # Boolean operators work on Bool
    lhs = _rulenode_to_smt_impl(node.children[1], grammar, :bool)
    rhs = _rulenode_to_smt_impl(node.children[2], grammar, :bool)
    
    smt_op = string(op)  # "and", "or"
    result = "($smt_op $lhs $rhs)"
    
    # If context expects Int, coerce Bool result
    if expected_type == :int
        result = "(ite $result 1 0)"
    end
    
    return result
end

"""Handle negation (not)"""
function _handle_not(
    node::RuleNode,
    grammar::AbstractGrammar,
    expected_type::Symbol
)::String
    
    length(node.children) == 1 || error("not requires 1 child")
    
    # not works on Bool
    arg = _rulenode_to_smt_impl(node.children[1], grammar, :bool)
    
    result = "(not $arg)"
    
    # If context expects Int, coerce Bool result
    if expected_type == :int
        result = "(ite $result 1 0)"
    end
    
    return result
end

# ─────────────────────────────────────────────────────────────────────────────
# TYPE COERCION
# ─────────────────────────────────────────────────────────────────────────────

"""
Coerce an SMT-LIB2 expression from source type to target type.

Rules:
- Bool → Int: Wrap in (ite expr 1 0)
- Int → Bool: Wrap in (> expr 0)
- Same type: Return as-is
"""
function _coerce_type(smt::String, from_type::Symbol, to_type::Symbol)::String
    from_type == to_type && return smt
    
    if from_type == :bool && to_type == :int
        return "(ite $smt 1 0)"
    elseif from_type == :int && to_type == :bool
        return "(> $smt 0)"
    else
        error("Unsupported type coercion: $from_type → $to_type")
    end
end
