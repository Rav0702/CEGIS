"""
    rulenode_genome.jl

`RuleNodeGenome` — an Arborist genome backed by a HerbCore `RuleNode`.

Choosing the CEGIS-native `RuleNode` representation (rather than Arborist's
`ExprGenome`) lets the GA reuse the project's own type-correct
`CEXGeneration.rulenode_to_smt2` converter for Z3, and gives precise subtree
addressing for counterexample-targeted mutation.

The genome carries shared references to its `grammar` and `start_symbol` so that
the Arborist interface methods (`serialize`, `complexity`, …) work from the
genome alone.
"""

"""
    RuleNodeGenome(tree, grammar, start_symbol)

Wraps a `RuleNode` program tree plus the grammar it was derived from.
"""
struct RuleNodeGenome <: Arborist.AbstractGenome
    tree::RuleNode
    grammar::AbstractGrammar
    start_symbol::Symbol
end

# --- Arborist.AbstractGenome interface ---

"""Total node count — feeds Arborist's bloat penalty (parsimony pressure)."""
Arborist.complexity(g::RuleNodeGenome)::Float64 = Float64(length(g.tree))

"""Longest root-to-leaf path; used by depth-capped operators."""
Arborist.tree_depth(g::RuleNodeGenome)::Int = depth(g.tree)

"""Human-readable Julia source — also used as the blackboard/cache key."""
Arborist.serialize(g::RuleNodeGenome)::String = string(rulenode2expr(g.tree, g.grammar))

"""
Cheap structural distance (only consulted when speciation is enabled, which it is
not in the POC). Node-count delta plus a one-bit identity term.
"""
function Arborist.distance(g1::RuleNodeGenome, g2::RuleNodeGenome)::Float64
    Float64(abs(length(g1.tree) - length(g2.tree))) + (g1.tree == g2.tree ? 0.0 : 1.0)
end

Base.show(io::IO, g::RuleNodeGenome) =
    print(io, "RuleNodeGenome(", string(rulenode2expr(g.tree, g.grammar)), ")")
