"""
    RuleNodeRemap.jl

Carrying a program from one problem's grammar into another's — the mechanism behind
cross-problem seed transfer, where a solved `max_N` (or `array_search_N`) is handed to
the `N+1` search as a building block.

The original `remap_rulenode` in `scripts/iterative_seeded_max.jl` did this by *shifting
rule indices*, which is only valid because the two `max_n_grammar(n)` grammars share the
layout "variables `1..n`, then `ifelse`, `>`, `<`". For any other pair of grammars that
shift silently produces a different program rather than an error. The remapping here
matches rules by their expression and type instead, so it works for any two grammars that
share the rules a program actually uses, and reports the rule it cannot place.
"""

"""
    remap_rulenode_by_expression(node, from, to) :: RuleNode

Rebuild `node` over grammar `to`, matching each rule by its expression and nonterminal
type in `from`. Throws if a rule used by `node` has no counterpart in `to` — which is the
honest outcome, since a seed that cannot be expressed in the target grammar is not a seed.
"""
function remap_rulenode_by_expression(node::RuleNode, from::AbstractGrammar, to::AbstractGrammar)::RuleNode
    idx = _matching_rule(node.ind, from, to)
    isempty(node.children) && return RuleNode(idx)
    return RuleNode(idx, RuleNode[remap_rulenode_by_expression(c, from, to) for c in node.children])
end

"""
    try_remap_rulenode(node, from, to) :: Union{RuleNode,Nothing}

`remap_rulenode_by_expression`, returning `nothing` instead of throwing. Use when
remapping a bank of candidate seeds, most of which are worth skipping rather than fatal.
"""
function try_remap_rulenode(node::RuleNode, from::AbstractGrammar, to::AbstractGrammar)
    try
        return remap_rulenode_by_expression(node, from, to)
    catch
        return nothing
    end
end

function _matching_rule(ind::Int, from::AbstractGrammar, to::AbstractGrammar)::Int
    1 <= ind <= length(from.rules) || error("rule index $ind is out of range for the source grammar")
    rule, typ = from.rules[ind], from.types[ind]
    # Prefer an exact (rule, type) match; fall back to rule-only, which covers a target
    # grammar that renamed its nonterminals (e.g. Expr2 vs Expr).
    for (i, r) in enumerate(to.rules)
        r == rule && to.types[i] === typ && return i
    end
    for (i, r) in enumerate(to.rules)
        r == rule && return i
    end
    error("target grammar has no rule matching `$rule` (type $typ) used by the seed")
end
