"""
    operators.jl

Grammar-aware genetic operators over `RuleNodeGenome`, plus the
counterexample-targeted mutation that is the centerpiece of this POC.

Subtree handling reuses HerbGrammar's `NodeLoc` machinery (the same primitives
HerbSearch's own genetic operators use): `get(root, loc)` reads, and
`insert!(root, loc, sub)` replaces, the subtree a `NodeLoc` points at. Typed
replacement (`return_type` + `rand(RuleNode, grammar, type, depth)`) keeps every
offspring grammar-valid.
"""

# ─────────────────────────────────────────────────────────────────────────────
# NodeLoc helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Resolve the `RuleNode` a `NodeLoc` points at without needing the root."""
_loc_node(loc::NodeLoc)::RuleNode = loc.i == 0 ? loc.parent : loc.parent.children[loc.i]

"""Collect a `NodeLoc` for every node in `root` (root first)."""
function _all_nodelocs(root::RuleNode)::Vector{NodeLoc}
    locs = NodeLoc[HerbGrammar.root_node_loc(root)]
    _collect_locs!(locs, root)
    return locs
end
function _collect_locs!(locs::Vector{NodeLoc}, node::RuleNode)
    for (i, c) in enumerate(node.children)
        push!(locs, NodeLoc(node, i))
        c isa RuleNode && _collect_locs!(locs, c)
    end
end

"""True if `node`'s grammar rule is `ifelse(BoolExpr, Expr, Expr)`."""
function _is_ifelse(grammar::AbstractGrammar, node::RuleNode)::Bool
    r = grammar.rules[node.ind]
    return r isa Expr && r.head == :call && r.args[1] == :ifelse && length(node.children) == 3
end

"""
    _active_nodelocs(root, grammar, symboltable, input) -> Vector{NodeLoc}

Collect the nodes that are *active* when the program runs on `input`: at an
`ifelse` node only the condition and the taken branch are active (and recursed
into); everywhere else all children are active. This is how a Z3 counterexample
witness is turned into a set of mutation targets. Generic over any grammar.
"""
function _active_nodelocs(root::RuleNode, grammar::AbstractGrammar,
                          symboltable, input::Dict{Symbol,Any})::Vector{NodeLoc}
    locs = NodeLoc[]
    _active!(locs, root, HerbGrammar.root_node_loc(root), grammar, symboltable, input)
    return locs
end

function _active!(locs::Vector{NodeLoc}, node::RuleNode, loc::NodeLoc,
                  grammar::AbstractGrammar, symboltable, input::Dict{Symbol,Any})
    push!(locs, loc)
    isempty(node.children) && return

    if _is_ifelse(grammar, node)
        cond, thenb, elseb = node.children[1], node.children[2], node.children[3]
        _active!(locs, cond, NodeLoc(node, 1), grammar, symboltable, input)
        taken = true
        try
            taken = Bool(execute_on_input(symboltable, rulenode2expr(cond, grammar), input))
        catch
            taken = true
        end
        branch, idx = taken ? (thenb, 2) : (elseb, 3)
        branch isa RuleNode && _active!(locs, branch, NodeLoc(node, idx), grammar, symboltable, input)
    else
        for (i, c) in enumerate(node.children)
            c isa RuleNode && _active!(locs, c, NodeLoc(node, i), grammar, symboltable, input)
        end
    end
end

"""
Weighted pick over candidate locations, biased toward Bool-typed (condition)
nodes — conditions are the most common culprits in conditional programs.
"""
function _pick_targeted(locs::Vector{NodeLoc}, grammar::AbstractGrammar, rng::AbstractRNG)::NodeLoc
    weights = Float64[return_type(grammar, _loc_node(l)) == :BoolExpr ? 3.0 : 1.0 for l in locs]
    total = sum(weights)
    r = rand(rng) * total
    acc = 0.0
    for (k, w) in enumerate(weights)
        acc += w
        r <= acc && return locs[k]
    end
    return locs[end]
end

"""Replace the subtree at `loc` with a fresh type-matched random subtree, in place."""
function _replace_at!(tree::RuleNode, loc::NodeLoc, grammar::AbstractGrammar, depth::Int)
    sym = return_type(grammar, _loc_node(loc))
    insert!(tree, loc, rand(RuleNode, grammar, sym, depth))
    return tree
end

# ─────────────────────────────────────────────────────────────────────────────
# Operators
# ─────────────────────────────────────────────────────────────────────────────

"""
    GrammarSubtreeMutation(grammar, subtree_depth, depth_cap)

Baseline / fallback mutation: replace a uniformly-random subtree with a fresh
type-matched grammar subtree. Offspring exceeding `depth_cap` are rejected
(parent returned unchanged) to keep Z3 queries small.
"""
struct GrammarSubtreeMutation <: Arborist.AbstractMutationOperator
    grammar::AbstractGrammar
    subtree_depth::Int
    depth_cap::Int
end

function Arborist.mutate(op::GrammarSubtreeMutation, g::RuleNodeGenome, rng::AbstractRNG)
    t = deepcopy(g.tree)
    locs = _all_nodelocs(t)
    _replace_at!(t, rand(rng, locs), op.grammar, op.subtree_depth)
    depth(t) > op.depth_cap && return g
    return RuleNodeGenome(t, g.grammar, g.start_symbol)
end

"""
    CounterexampleTargetedMutation(grammar, subtree_depth, depth_cap, blackboard, symboltable)

Z3-guided mutation. Looks up the genome's diagnostics on the shared `blackboard`;
if a counterexample witness exists, it mutates a subtree that is *active* at that
witness (biased toward the condition). Falls back to uniform subtree mutation
when no witness is available. `targeted_hits` / `fallback_hits` count which path
was taken (for the POC's reporting).
"""
mutable struct CounterexampleTargetedMutation <: Arborist.AbstractMutationOperator
    grammar::AbstractGrammar
    subtree_depth::Int
    depth_cap::Int
    blackboard::Dict{String,GenomeDiagnostics}
    symboltable::Any
    targeted_hits::Base.RefValue{Int}
    fallback_hits::Base.RefValue{Int}
end

function CounterexampleTargetedMutation(grammar, subtree_depth, depth_cap, blackboard, symboltable)
    CounterexampleTargetedMutation(grammar, subtree_depth, depth_cap, blackboard, symboltable,
                                   Ref(0), Ref(0))
end

Arborist.operator_name(::CounterexampleTargetedMutation) = :CounterexampleTargetedMutation

function Arborist.mutate(op::CounterexampleTargetedMutation, g::RuleNodeGenome, rng::AbstractRNG)
    diag = get(op.blackboard, Arborist.serialize(g), nothing)
    t = deepcopy(g.tree)

    if diag !== nothing && !isempty(diag.witness)
        locs = _active_nodelocs(t, op.grammar, op.symboltable, diag.witness)
        if !isempty(locs)
            op.targeted_hits[] += 1
            _replace_at!(t, _pick_targeted(locs, op.grammar, rng), op.grammar, op.subtree_depth)
            depth(t) > op.depth_cap && return g
            return RuleNodeGenome(t, g.grammar, g.start_symbol)
        end
    end

    # Fallback: uniform subtree mutation.
    op.fallback_hits[] += 1
    locs = _all_nodelocs(t)
    _replace_at!(t, rand(rng, locs), op.grammar, op.subtree_depth)
    depth(t) > op.depth_cap && return g
    return RuleNodeGenome(t, g.grammar, g.start_symbol)
end

"""
    GrammarSubtreeCrossover(grammar, depth_cap)

Typed subtree crossover: pick a node in parent 1, a type-matching node in
parent 2, and swap. Offspring exceeding `depth_cap` are discarded (parents
returned).
"""
struct GrammarSubtreeCrossover <: Arborist.AbstractCrossoverOperator
    grammar::AbstractGrammar
    depth_cap::Int
end

function Arborist.crossover(op::GrammarSubtreeCrossover, g1::RuleNodeGenome,
                            g2::RuleNodeGenome, rng::AbstractRNG)
    t1 = deepcopy(g1.tree)
    t2 = deepcopy(g2.tree)

    loc1 = rand(rng, _all_nodelocs(t1))
    sym = return_type(op.grammar, _loc_node(loc1))
    compatible = filter(l -> return_type(op.grammar, _loc_node(l)) == sym, _all_nodelocs(t2))
    isempty(compatible) && return (g1, g2)
    loc2 = rand(rng, compatible)

    sub1 = deepcopy(_loc_node(loc1))
    sub2 = deepcopy(_loc_node(loc2))
    insert!(t1, loc1, sub2)
    insert!(t2, loc2, sub1)

    (depth(t1) > op.depth_cap || depth(t2) > op.depth_cap) && return (g1, g2)
    return (RuleNodeGenome(t1, g1.grammar, g1.start_symbol),
            RuleNodeGenome(t2, g2.grammar, g2.start_symbol))
end
