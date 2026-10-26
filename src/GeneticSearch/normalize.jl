"""
    normalize.jl

Semantic normalization of `RuleNode` candidates — a directed-rewrite
reimplementation of the reduction half of the `egraphs-implementation` branch's
`EGraphPruning`.

## Why directed rewrites rather than an e-graph

That branch runs equality saturation (Metatheory.jl) in a **subprocess**,
because Metatheory pins DataStructures 0.18 while HerbSearch requires 0.19 —
the two cannot share an environment. A subprocess round-trip is fine for its
purpose (deriving grammar constraints once, ~15 s) but impossible per genome,
and the GA breeds tens of thousands of genomes per run.

The rules that actually delete meaningless structure (`a+0 → a`, `a*0 → 0`,
`ifelse(p,a,a) → a`, `a>=a → true`) are *directed and confluent*, so a plain
bottom-up rewrite to fixpoint computes the same normal form an e-graph would
extract — in microseconds, in-process, with no dependency conflict. What is
given up is only the non-orientable part (choosing canonically among genuinely
alternative forms), and for the commutative cases that matters here we recover
it by sorting operands (see `_canonical_commutative`).

The rule set below is lifted from that branch's `LIA_THEORY`
(`tools/egraph_gen/saturate.jl`), restricted to the rules that strictly
decrease term size or canonicalize shape.

## What it does

Bottom-up to fixpoint:

- **identity / absorbing**: `a+0`, `0+a`, `a-0`, `a*1`, `1*a` → `a`;
  `a*0`, `0*a` → `0`; `a-a` → `0`
- **constant folding**: literal ∘ literal → literal, when the result is
  representable in the grammar (`LIA` supplies `0,1,2,-1`)
- **reflexive comparisons**: `a<a`, `a>a` → canonical false; `a<=a`, `a>=a`,
  `a==a` → canonical true. Canonical Booleans are `0<0` / `0<=0`, since the
  generated grammar has no Bool literals (`BoolExpr` is comparisons only).
- **conditionals**: `ifelse(p,a,a)` → `a`; `ifelse(true,a,b)` → `a`;
  `ifelse(false,a,b)` → `b`
- **mirror comparisons**: `a>b` → `b<a`, `a>=b` → `b<=a`, collapsing each
  mirrored pair onto one form
- **commutative ordering**: operands of `+`, `*`, `==` sorted by a total
  structural order, so `x1+x0` and `x0+x1` share one representative

Every rewrite is semantics-preserving on `LIA` (no division, no side effects),
so a normalized genome computes exactly what the original did.

## Effect on the GA

Two distinct benefits, worth separating when reading benchmark results:

1. **Fewer meaningless candidates.** Dead structure (`0*x3`,
   `ifelse(x4>=x4, …)`, `x2-x4*1`) is deleted at birth rather than merely
   selected against later.
2. **Cache collapse.** Semantically identical genomes normalize to one tree, so
   the evaluators' `serialize`-keyed caches stop paying for the same Z3 check
   in a dozen syntactic disguises.

The known risk is that normalization removes *introns* — neutral subtrees that
buffer destructive crossover in GP. It is therefore behind `normalize=` and
benchmarked as an A/B rather than assumed to be an improvement.
"""

# ─────────────────────────────────────────────────────────────────────────────
# Structural equality / total order on RuleNodes
# ─────────────────────────────────────────────────────────────────────────────

_rn_eq(a::RuleNode, b::RuleNode)::Bool =
    a.ind == b.ind && length(a.children) == length(b.children) &&
    all(_rn_eq(x, y) for (x, y) in zip(a.children, b.children))
_rn_eq(::AbstractRuleNode, ::AbstractRuleNode) = false

"""Total order used to canonicalize commutative operands. Deterministic."""
function _rn_less(a::RuleNode, b::RuleNode)::Bool
    a.ind != b.ind && return a.ind < b.ind
    na, nb = length(a.children), length(b.children)
    na != nb && return na < nb
    for (x, y) in zip(a.children, b.children)
        _rn_eq(x, y) && continue
        return _rn_less(x, y)
    end
    return false
end

# ─────────────────────────────────────────────────────────────────────────────
# Grammar introspection
# ─────────────────────────────────────────────────────────────────────────────

"""
Per-rule operator table for a generated grammar, plus the literal and canonical
Boolean nodes the rewrites need. Built once per grammar and reused.
"""
struct GrammarOps
    op::Vector{Union{Symbol,Nothing}}   # operator symbol per rule (nothing = leaf/coercion)
    arity::Vector{Int}
    litval::Vector{Union{Int,Nothing}}  # integer value per terminal literal rule
    lit_rule::Dict{Int,Int}             # literal value → rule index
    rule_of_op::Dict{Tuple{Symbol,Int},Int}   # (operator, arity) → rule index
    false_node::Union{RuleNode,Nothing} # canonical always-false BoolExpr (`0 < 0`)
    true_node::Union{RuleNode,Nothing}  # canonical always-true  BoolExpr (`0 <= 0`)
end

function GrammarOps(grammar::AbstractGrammar)
    n = length(grammar.rules)
    op = Vector{Union{Symbol,Nothing}}(nothing, n)
    arity = zeros(Int, n)
    litval = Vector{Union{Int,Nothing}}(nothing, n)
    lit_rule = Dict{Int,Int}()
    rule_of_op = Dict{Tuple{Symbol,Int},Int}()

    for i in 1:n
        r = grammar.rules[i]
        if grammar.isterminal[i]
            if r isa Integer
                litval[i] = Int(r)
                get!(lit_rule, Int(r), i)
            end
        elseif r isa Expr
            if r.head === :call && !isempty(r.args) && r.args[1] isa Symbol
                op[i] = r.args[1]
                arity[i] = length(r.args) - 1
            elseif r.head in (:&&, :||)
                op[i] = r.head
                arity[i] = length(r.args)
            end
            op[i] === nothing || get!(rule_of_op, (op[i], arity[i]), i)
        end
        # `r isa Symbol` on a non-terminal is the `Expr = BoolExpr` coercion:
        # left as nothing — it has no algebraic identity of its own.
    end

    zero_rule = get(lit_rule, 0, nothing)
    lt = get(rule_of_op, (:<, 2), nothing)
    le = get(rule_of_op, (:<=, 2), nothing)
    mk(rule) = (rule === nothing || zero_rule === nothing) ? nothing :
               RuleNode(rule, [RuleNode(zero_rule), RuleNode(zero_rule)])

    return GrammarOps(op, arity, litval, lit_rule, rule_of_op, mk(lt), mk(le))
end

_lit(ops::GrammarOps, node::RuleNode)::Union{Int,Nothing} =
    isempty(node.children) ? ops.litval[node.ind] : nothing

_lit_node(ops::GrammarOps, v::Int)::Union{RuleNode,Nothing} =
    haskey(ops.lit_rule, v) ? RuleNode(ops.lit_rule[v]) : nothing

# ─────────────────────────────────────────────────────────────────────────────
# Rewriting
# ─────────────────────────────────────────────────────────────────────────────

"""Sort operands of a commutative operator into canonical order."""
function _canonical_commutative(node::RuleNode)::RuleNode
    length(node.children) == 2 || return node
    a, b = node.children[1], node.children[2]
    (a isa RuleNode && b isa RuleNode) || return node
    return _rn_less(b, a) ? RuleNode(node.ind, [b, a]) : node
end

"""
One rewrite pass at `node` (children already normalized). Returns the rewritten
node, or `node` itself when no rule fires.
"""
function _rewrite_here(node::RuleNode, ops::GrammarOps)::RuleNode
    o = ops.op[node.ind]
    o === nothing && return node
    cs = node.children
    all(c -> c isa RuleNode, cs) || return node

    # ---- binary arithmetic -------------------------------------------------
    if length(cs) == 2 && o in (:+, :-, :*)
        a, b = cs[1]::RuleNode, cs[2]::RuleNode
        la, lb = _lit(ops, a), _lit(ops, b)

        # constant folding, when the result exists in the grammar
        if la !== nothing && lb !== nothing
            v = o === :+ ? la + lb : o === :- ? la - lb : la * lb
            folded = _lit_node(ops, v)
            folded === nothing || return folded
        end

        if o === :+
            lb == 0 && return a
            la == 0 && return b
        elseif o === :-
            lb == 0 && return a
            if _rn_eq(a, b)
                z = _lit_node(ops, 0)
                z === nothing || return z
            end
        elseif o === :*
            if la == 0 || lb == 0
                z = _lit_node(ops, 0)
                z === nothing || return z
            end
            lb == 1 && return a
            la == 1 && return b
        end
        return o === :- ? node : _canonical_commutative(node)
    end

    # ---- unary minus -------------------------------------------------------
    if length(cs) == 1 && o === :-
        a = cs[1]::RuleNode
        la = _lit(ops, a)
        if la !== nothing
            folded = _lit_node(ops, -la)
            folded === nothing || return folded
        end
        # -(-x) → x
        ops.op[a.ind] === :- && length(a.children) == 1 &&
            a.children[1] isa RuleNode && return a.children[1]::RuleNode
        return node
    end

    # ---- comparisons -------------------------------------------------------
    if length(cs) == 2 && o in (:<, :>, :<=, :>=, :(==))
        a, b = cs[1]::RuleNode, cs[2]::RuleNode

        # reflexive: decided regardless of the operand's value
        if _rn_eq(a, b)
            t = o in (:<, :>) ? ops.false_node : ops.true_node
            t === nothing || return t
        end

        # constant comparison
        la, lb = _lit(ops, a), _lit(ops, b)
        if la !== nothing && lb !== nothing
            holds = o === :<  ? la <  lb : o === :>  ? la >  lb :
                    o === :<= ? la <= lb : o === :>= ? la >= lb : la == lb
            t = holds ? ops.true_node : ops.false_node
            t === nothing || return t
        end

        # mirror elimination: a>b → b<a, a>=b → b<=a
        if o === :>
            r = get(ops.rule_of_op, (:<, 2), nothing)
            r === nothing || return RuleNode(r, [b, a])
        elseif o === :>=
            r = get(ops.rule_of_op, (:<=, 2), nothing)
            r === nothing || return RuleNode(r, [b, a])
        end

        return o === :(==) ? _canonical_commutative(node) : node
    end

    # ---- ifelse ------------------------------------------------------------
    if length(cs) == 3 && o === :ifelse
        cond, thenb, elseb = cs[1]::RuleNode, cs[2]::RuleNode, cs[3]::RuleNode
        _rn_eq(thenb, elseb) && return thenb
        ops.true_node  !== nothing && _rn_eq(cond, ops.true_node)  && return thenb
        ops.false_node !== nothing && _rn_eq(cond, ops.false_node) && return elseb
        return node
    end

    return node
end

"""
    normalize_program(node, grammar[, ops]; max_steps=64) -> RuleNode

Rewrite `node` to its normal form under the rules documented at the top of this
file. Semantics-preserving: the returned tree evaluates identically to `node`
on every input. Never increases size or depth.

`ops` may be supplied to reuse a `GrammarOps` table across many calls (the GA
does this — building it per genome would dominate the cost).
"""
function normalize_program(node::RuleNode, grammar::AbstractGrammar,
                           ops::GrammarOps = GrammarOps(grammar);
                           max_steps::Int = 64)::RuleNode
    normalized = isempty(node.children) ? node :
        RuleNode(node.ind, AbstractRuleNode[
            c isa RuleNode ? normalize_program(c, grammar, ops; max_steps=max_steps) : c
            for c in node.children])

    # Rewriting at this node can expose a further redex here (e.g. `(x-x)*1`
    # becomes `0*1` becomes `0`), so iterate to fixpoint under a step guard.
    for _ in 1:max_steps
        next = _rewrite_here(normalized, ops)
        _rn_eq(next, normalized) && return normalized
        # A rewrite can rebuild children (mirror swap), so re-normalize them.
        normalized = isempty(next.children) ? next :
            RuleNode(next.ind, AbstractRuleNode[
                c isa RuleNode ? normalize_program(c, grammar, ops; max_steps=max_steps) : c
                for c in next.children])
    end
    return normalized
end

"""Convenience wrapper preserving genome identity fields."""
normalize_genome(g::RuleNodeGenome, ops::GrammarOps)::RuleNodeGenome =
    RuleNodeGenome(normalize_program(g.tree, g.grammar, ops), g.grammar, g.start_symbol)
