"""
    minimize.jl

Verified post-hoc program shrinking. GP output is bloated by construction
(neutral code like `(t - t) * 0`, `x * 1`, dead `ifelse` guards survive
selection), and lexicase in particular applies no parsimony pressure. This
pass makes the *delivered* program small without touching the search:

`minimize_program` greedily tries, at every position, to replace the subtree
with (a) any same-type terminal (variable/constant) or (b) any smaller
same-type descendant subtree (hoisting), keeping a replacement only when the
whole program still **formally verifies**. Each accepted step strictly shrinks
the tree, so the loop terminates; the result is 1-minimal w.r.t. these two
moves. With the warm in-process verifier each attempt is ~a millisecond.
"""

"""Collect all positions (paths of child indices, BFS order — shallow first)."""
function _mp_paths(n::RuleNode)::Vector{Vector{Int}}
    out = Vector{Vector{Int}}([Int[]])
    queue = Tuple{RuleNode,Vector{Int}}[(n, Int[])]
    while !isempty(queue)
        (node, p) = popfirst!(queue)
        for (i, c) in enumerate(node.children)
            c isa RuleNode || continue
            cp = vcat(p, i)
            push!(out, cp)
            push!(queue, (c, cp))
        end
    end
    return out
end

_mp_subtree(n::RuleNode, path)::RuleNode =
    isempty(path) ? n : _mp_subtree(n.children[path[1]]::RuleNode, path[2:end])

"""Rebuild the tree with the subtree at `path` replaced by `rep`."""
function _mp_with(n::RuleNode, path, rep::RuleNode)::RuleNode
    isempty(path) && return rep
    kids = AbstractRuleNode[c for c in n.children]
    kids[path[1]] = _mp_with(kids[path[1]]::RuleNode, path[2:end], rep)
    return RuleNode(n.ind, kids)
end

"""Same-type descendants of `sub` (candidates for hoisting), smallest first."""
function _mp_descendants(sub::RuleNode, grammar, t::Symbol)::Vector{RuleNode}
    out = RuleNode[]
    stack = RuleNode[c for c in sub.children if c isa RuleNode]
    while !isempty(stack)
        node = pop!(stack)
        grammar.types[node.ind] == t && push!(out, node)
        append!(stack, RuleNode[c for c in node.children if c isa RuleNode])
    end
    sort!(out, by=length)
    return out
end

"""
    minimize_program(node::RuleNode, grammar, verify) -> RuleNode

Shrink a **formally verified** program while preserving verification.
`verify(candidate::RuleNode)::Bool` must be sound (`true` ⇒ correct for all
inputs); conservative `false` (e.g. Z3 `:unknown`) merely keeps a bigger tree.
Returns `node` unchanged if it does not verify to begin with.
"""
function minimize_program(node::RuleNode, grammar::AbstractGrammar, verify)::RuleNode
    verify(node) || return node

    terminals = Dict{Symbol,Vector{RuleNode}}()
    for i in eachindex(grammar.rules)
        isempty(grammar.childtypes[i]) || continue
        push!(get!(terminals, grammar.types[i], RuleNode[]), RuleNode(i))
    end

    best = node
    improved = true
    while improved
        improved = false
        for path in _mp_paths(best)
            sub = _mp_subtree(best, path)
            isempty(sub.children) && continue
            t = grammar.types[sub.ind]

            # Smallest replacements first: terminals, then hoisted descendants.
            candidates = RuleNode[]
            append!(candidates, get(terminals, t, RuleNode[]))
            append!(candidates, _mp_descendants(sub, grammar, t))

            tried = Set{RuleNode}()
            for rep in candidates
                length(rep) < length(sub) || continue
                rep in tried && continue
                push!(tried, rep)
                cand = _mp_with(best, path, rep)
                if verify(cand)
                    best = cand
                    improved = true
                    break
                end
            end
            improved && break   # tree changed — restart the position scan
        end
    end
    return best
end

# ── Verifier closures over the evaluators' warm solvers ──────────────────────

"""`node -> Bool` formal verifier reusing the evaluator's in-process solver."""
function _minimize_verifier(e::CDGPEvaluator)
    return function (node::RuleNode)
        smt = try
            CEXGeneration.rulenode_to_smt2(node, e.grammar)
        catch
            return false
        end
        if e.cex_solver !== nothing
            return CEXGeneration.find_counterexample(
                e.cex_solver, Dict(e.func_name => smt)).status == :unsat
        end
        q = CEXGeneration.generate_cex_query(e.spec, Dict(e.func_name => smt))
        r = try
            CEXGeneration.verify_query(q)
        catch
            return false
        end
        return r.status == :unsat
    end
end

function _minimize_verifier(e::Union{CDGPConstraintEvaluator,HybridCDGPEvaluator})
    return function (node::RuleNode)
        smt = try
            CEXGeneration.rulenode_to_smt2(node, e.grammar)
        catch
            return false
        end
        r = CEXGeneration.check_constraint_satisfaction(e.css, e.func_name, smt)
        return !isempty(r.status) && all(==(:unsat), r.status)
    end
end
