"""
    EGraphPruning

E-graph–derived constraint generation: identifies structural equivalences in the
grammar's term space via equality saturation (Metatheory.jl) and compiles them
into `HerbConstraints` (`Forbidden` / `Ordered`) so that any constraint-aware
solver prunes redundant candidates *during* enumeration.

## Pipeline

1. **Pattern enumeration** — enumerate small grammar patterns (`RuleNode` trees
   with typed `VarNode` holes, canonically named so patterns are unique up to
   hole renaming) up to a configurable depth.
2. **Symmetry probes** — for every pair of binary rules of matching type, emit
   probe terms `r1(q1,q2)` / `r2(q2,q1)` to detect commutativity (`r1 == r2`)
   and mirrored rules (`r1 != r2`, e.g. `a < b ≡ b > a`).
3. **Equality saturation** — all terms are sent to an isolated Metatheory.jl
   subprocess (`tools/egraph_gen/saturate.jl`) which returns an e-class id per
   term. Equal ids = proven equivalent under the theory.
4. **Constraint compilation** — each e-class with >1 member yields constraints:
   the syntactically minimal member is kept as *canonical*; every other member
   becomes a `Forbidden` pattern. Commutative rules become `Ordered`; mirrored
   rules are eliminated wholesale (`Forbidden(rule(a, b))`).

## Soundness

A constraint is only emitted if pruning it preserves completeness modulo
equivalence: every pruned program has a semantically equivalent program that
remains enumerable.

- Hole-generalization is sound because equational logic is closed under
  substitution: an equivalence proven over free symbols holds for all subterms.
- A `Forbidden(m)` is accepted only if the canonical representative `c` of its
  e-class is strictly smaller than `m`, or is not itself matched by the pattern
  `m` (this rejects e.g. `Forbidden(a < a)` when the only remaining
  representatives of `false` are `0 < 0`-shaped and would be pruned too).
- Saturation is bounded; incomplete saturation only *misses* equivalences,
  never reports false ones, so derived constraints stay sound.

## Usage

```julia
grammar = CEGIS.build_grammar_from_spec("max2.sl")
derived = EGraphPruning.add_derived_constraints!(grammar; max_depth=2)
foreach(d -> println(d.description), derived)
iterator = BFSIterator(grammar, :Expr, max_depth=5)   # pruning is automatic
```
"""
module EGraphPruning

using HerbCore
using HerbGrammar
using HerbConstraints

export derive_constraints, add_derived_constraints!, DerivedConstraint

const GEN_PROJECT = normpath(joinpath(@__DIR__, "..", "..", "tools", "egraph_gen"))
const GEN_SCRIPT = joinpath(GEN_PROJECT, "saturate.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Patterns: RuleNode trees with VarNode holes
# ─────────────────────────────────────────────────────────────────────────────

"""
A grammar pattern paired with its nonterminal type and its conversion to a
plain Julia expression (the representation sent to the e-graph).
"""
struct Pattern
    node::AbstractRuleNode
    typ::Symbol
    expr::Any
end

"Hole-name pool per nonterminal type. Names must not collide with grammar symbols."
function hole_pool(typ::Symbol)
    typ === :Expr && return [:a, :b, :c, :d]
    typ === :BoolExpr && return [:p, :q, :r]
    return [Symbol("h_", typ, "_", i) for i in 1:4]
end

const PROBE_SYMBOLS = (:q1, :q2)

"Symbols reserved for holes and probes; grammar variables must not use them."
function check_symbol_collisions(grammar::AbstractGrammar)
    reserved = Set{Symbol}([:a, :b, :c, :d, :p, :q, :r, PROBE_SYMBOLS...])
    for ri in eachindex(grammar.rules)
        rule = grammar.rules[ri]
        if grammar.isterminal[ri] && rule isa Symbol && rule in reserved
            error("Grammar variable `$rule` collides with reserved hole/probe symbols $(collect(reserved)).")
        end
    end
end

# Hole state: number of holes already introduced, per type (restricted-growth naming).
const HoleState = Dict{Symbol,Int}

"Leaf options for a slot of type `typ`: constant terminals, reused holes, or one fresh hole."
function leaf_choices(grammar::AbstractGrammar, typ::Symbol, holes::HoleState)
    out = Tuple{AbstractRuleNode,HoleState}[]
    for ri in eachindex(grammar.rules)
        grammar.types[ri] === typ || continue
        grammar.isterminal[ri] || continue
        # Constants only: holes subsume grammar variables (a hole stands for *any* subtree).
        grammar.rules[ri] isa Number || continue
        push!(out, (RuleNode(ri), copy(holes)))
    end
    pool = hole_pool(typ)
    n = get(holes, typ, 0)
    for k in 1:min(n + 1, length(pool))
        h = copy(holes)
        h[typ] = max(n, k)
        push!(out, (VarNode(pool[k]), h))
    end
    return out
end

"All trees of type `typ` with the given remaining depth budget, threading hole state."
function enum_trees(grammar::AbstractGrammar, typ::Symbol, depth::Int, holes::HoleState)
    out = leaf_choices(grammar, typ, holes)
    if depth > 1
        for ri in eachindex(grammar.rules)
            grammar.types[ri] === typ || continue
            grammar.isterminal[ri] && continue
            for (children, h) in enum_children(grammar, grammar.childtypes[ri], depth - 1, holes)
                push!(out, (RuleNode(ri, children), h))
            end
        end
    end
    return out
end

function enum_children(grammar::AbstractGrammar, types::Vector{Symbol}, depth::Int, holes::HoleState)
    isempty(types) && return [(AbstractRuleNode[], copy(holes))]
    out = Tuple{Vector{AbstractRuleNode},HoleState}[]
    for (child, h1) in enum_trees(grammar, types[1], depth, holes)
        for (rest, h2) in enum_children(grammar, types[2:end], depth, h1)
            push!(out, (AbstractRuleNode[child; rest], h2))
        end
    end
    return out
end

"""
    enumerate_patterns(grammar; max_depth=2) :: Vector{Pattern}

Enumerate grammar patterns rooted at each nonterminal rule, with holes named
canonically (first occurrence order), plus seed members (bare holes and bare
constants) that serve as canonical-representative candidates for their e-classes.
"""
function enumerate_patterns(grammar::AbstractGrammar; max_depth::Int=2)
    patterns = Pattern[]
    for ri in eachindex(grammar.rules)
        grammar.isterminal[ri] && continue
        typ = grammar.types[ri]
        for (children, _) in enum_children(grammar, grammar.childtypes[ri], max_depth - 1, HoleState())
            node = RuleNode(ri, children)
            ex = pattern2expr(node, grammar)
            # A pattern that converts to a bare symbol (pure coercion wrapper) is vacuous.
            ex isa Symbol && continue
            push!(patterns, Pattern(node, typ, ex))
        end
    end
    for typ in unique(t for t in grammar.types if t !== nothing)
        h = first(hole_pool(typ))
        push!(patterns, Pattern(VarNode(h), typ, h))
    end
    for ri in eachindex(grammar.rules)
        (grammar.isterminal[ri] && grammar.rules[ri] isa Number) || continue
        push!(patterns, Pattern(RuleNode(ri), grammar.types[ri], grammar.rules[ri]))
    end
    return patterns
end

# ─────────────────────────────────────────────────────────────────────────────
# Pattern → Julia expression (e-graph term representation)
# ─────────────────────────────────────────────────────────────────────────────

pattern2expr(n::VarNode, ::AbstractGrammar) = n.name

function pattern2expr(n::RuleNode, grammar::AbstractGrammar)
    rule = grammar.rules[n.ind]
    isempty(n.children) && return rule
    kids = Any[pattern2expr(c, grammar) for c in n.children]
    nts = Set{Symbol}(t for t in grammar.types if t !== nothing)
    i = Ref(0)
    subst(ex) =
        ex isa Symbol && ex in nts ? kids[i[] += 1] :
        ex isa Expr ? Expr(ex.head, map(subst, ex.args)...) :
        ex
    return subst(rule)
end

# ─────────────────────────────────────────────────────────────────────────────
# Equality-saturation backend (subprocess in isolated environment)
# ─────────────────────────────────────────────────────────────────────────────

"""
    egraph_classes(exprs; theory="lia") :: Vector{Int}

Send terms to the Metatheory.jl saturation backend; returns one e-class id per
term (same id ⟺ proven equivalent). Runs as a subprocess because Metatheory.jl
and HerbSearch have incompatible dependency bounds (DataStructures 0.18 vs 0.19).
"""
function egraph_classes(exprs::Vector; theory::AbstractString="lia")
    isfile(GEN_SCRIPT) || error("Saturation backend not found at $GEN_SCRIPT")
    mktempdir() do dir
        terms_file = joinpath(dir, "terms.txt")
        open(terms_file, "w") do io
            foreach(e -> println(io, e), exprs)
        end
        julia = joinpath(Sys.BINDIR, "julia")
        out = read(`$julia --project=$GEN_PROJECT --startup-file=no $GEN_SCRIPT $terms_file $theory`, String)
        ids = parse.(Int, split(strip(out), '\n'))
        length(ids) == length(exprs) || error("Backend returned $(length(ids)) ids for $(length(exprs)) terms")
        return ids
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Symmetry probes (commutativity & mirrored rules)
# ─────────────────────────────────────────────────────────────────────────────

struct Probe
    r1::Int
    r2::Int
    e1::Any
    e2::Any
    swapped::Bool
end

"""
Probe terms for every pair of binary rules with matching types:
`r1(q1,q2)` vs `r2(q2,q1)` detects commutativity (r1 == r2) or mirrored rules
(r1 != r2, e.g. `<` vs `>`); `r1(q1,q2)` vs `r2(q1,q2)` detects duplicate rules.
"""
function symmetry_probes(grammar::AbstractGrammar)
    probes = Probe[]
    binary = [ri for ri in eachindex(grammar.rules)
              if !grammar.isterminal[ri] && length(grammar.childtypes[ri]) == 2]
    binexpr(ri, s1, s2) = pattern2expr(RuleNode(ri, [VarNode(s1), VarNode(s2)]), grammar)
    for i in eachindex(binary), j in i:lastindex(binary)
        r1, r2 = binary[i], binary[j]
        grammar.types[r1] === grammar.types[r2] || continue
        grammar.childtypes[r1] == grammar.childtypes[r2] || continue
        push!(probes, Probe(r1, r2, binexpr(r1, :q1, :q2), binexpr(r2, :q2, :q1), true))
        r1 != r2 && push!(probes, Probe(r1, r2, binexpr(r1, :q1, :q2), binexpr(r2, :q1, :q2), false))
    end
    return probes
end

# ─────────────────────────────────────────────────────────────────────────────
# Pattern utilities (size, matching, rule usage)
# ─────────────────────────────────────────────────────────────────────────────

pat_size(::VarNode) = 1
pat_size(n::RuleNode) = 1 + sum(pat_size, n.children; init=0)

hole_names!(s::Set{Symbol}, n::VarNode) = push!(s, n.name)
hole_names!(s::Set{Symbol}, n::RuleNode) = (foreach(c -> hole_names!(s, c), n.children); s)
hole_count(n::AbstractRuleNode) = length(hole_names!(Set{Symbol}(), n))

tree_eq(x::VarNode, y::VarNode) = x.name == y.name
tree_eq(x::RuleNode, y::RuleNode) =
    x.ind == y.ind && length(x.children) == length(y.children) &&
    all(tree_eq(a, b) for (a, b) in zip(x.children, y.children))
tree_eq(::AbstractRuleNode, ::AbstractRuleNode) = false

uses_rule(::VarNode, ::Set{Int}) = false
uses_rule(n::RuleNode, banned::Set{Int}) =
    n.ind in banned || any(uses_rule(c, banned) for c in n.children)

"""
    pattern_matches(p, t; conservative) :: Bool

Does pattern `p` (VarNodes bind consistently) match target `t`? When `p` has
structure where `t` has a hole, the answer depends on `t`'s instantiation:
`conservative=true` answers "possibly yes" (used for soundness checks, where a
possible match must reject the constraint); `conservative=false` answers "no"
(used for subsumption, where we must not over-claim coverage).
"""
function pattern_matches(p::AbstractRuleNode, t::AbstractRuleNode; conservative::Bool)
    bind = Dict{Symbol,AbstractRuleNode}()
    function go(p, t)
        if p isa VarNode
            haskey(bind, p.name) ? tree_eq(bind[p.name], t) : (bind[p.name] = t; true)
        elseif t isa VarNode
            conservative
        else
            p.ind == t.ind && length(p.children) == length(t.children) &&
                all(go(pc, tc) for (pc, tc) in zip(p.children, t.children))
        end
    end
    return go(p, t)
end

# ─────────────────────────────────────────────────────────────────────────────
# Constraint compilation
# ─────────────────────────────────────────────────────────────────────────────

"""
A derived grammar constraint with provenance.

- `kind` — `:ordered` (commutative rule), `:rule_eliminated` (mirrored or
  duplicate rule removed wholesale), or `:forbidden` (redundant pattern).
- `description` — human-readable provenance: the pruned shape and the canonical
  equivalent that remains enumerable.
"""
struct DerivedConstraint
    constraint::AbstractConstraint
    kind::Symbol
    description::String
end

"""
    derive_constraints(grammar; max_depth=2, theory="lia", verbose=false) :: Vector{DerivedConstraint}

Run the full pipeline (enumerate patterns → saturate → compile constraints)
without mutating the grammar. See module docstring for the soundness argument.
"""
function derive_constraints(grammar::AbstractGrammar;
                            max_depth::Int=2,
                            theory::AbstractString="lia",
                            verbose::Bool=false)
    check_symbol_collisions(grammar)

    patterns = enumerate_patterns(grammar; max_depth)
    probes = symmetry_probes(grammar)

    terms = Any[p.expr for p in patterns]
    probe_offset = length(terms)
    for pr in probes
        push!(terms, pr.e1)
        push!(terms, pr.e2)
    end
    verbose && @info "EGraphPruning: saturating $(length(terms)) terms ($(length(patterns)) patterns, $(length(probes)) probes)"

    classes = egraph_classes(terms; theory)
    derived = DerivedConstraint[]

    # Stage 1: rule-level symmetries.
    eliminated = Set{Int}()
    k = probe_offset
    for pr in probes
        c1, c2 = classes[k+1], classes[k+2]
        k += 2
        c1 == c2 || continue
        if pr.r1 == pr.r2
            tmpl = RuleNode(pr.r1, [VarNode(:a), VarNode(:b)])
            push!(derived, DerivedConstraint(
                Ordered(tmpl, [:a, :b]), :ordered,
                "Ordered($(pattern2expr(tmpl, grammar))): rule $(pr.r1) is commutative"))
        elseif !(pr.r1 in eliminated) && !(pr.r2 in eliminated)
            keep, doomed = min(pr.r1, pr.r2), max(pr.r1, pr.r2)
            tmpl = RuleNode(doomed, [VarNode(:a), VarNode(:b)])
            push!(eliminated, doomed)
            relation = pr.swapped ? "mirror" : "duplicate"
            push!(derived, DerivedConstraint(
                Forbidden(tmpl), :rule_eliminated,
                "Forbidden($(pattern2expr(tmpl, grammar))): rule $doomed is a $relation of rule $keep ($(grammar.rules[keep]))"))
        end
    end

    # Stage 2: pattern-level redundancies. Group patterns by e-class; within each
    # class and type, the minimal member is canonical and the rest are forbidden.
    groups = Dict{Int,Vector{Pattern}}()
    for (p, c) in zip(patterns, classes[1:length(patterns)])
        uses_rule(p.node, eliminated) && continue
        push!(get!(groups, c, Pattern[]), p)
    end

    candidates = Tuple{Pattern,Pattern}[]  # (member, canonical)
    for members in values(groups)
        length(members) > 1 || continue
        for typ in unique(m.typ for m in members)
            mt = [m for m in members if m.typ === typ]
            length(mt) > 1 || continue
            sort!(mt; by=m -> (pat_size(m.node), hole_count(m.node), string(m.expr)))
            canon = mt[1]
            for m in mt[2:end]
                tree_eq(m.node, canon.node) || push!(candidates, (m, canon))
            end
        end
    end

    # Process most general patterns first so they subsume specific ones.
    sort!(candidates; by=((m, _),) -> (pat_size(m.node), -hole_count(m.node), string(m.expr)))
    accepted = AbstractRuleNode[]
    for (m, canon) in candidates
        # Soundness: the canonical representative must survive the new constraint.
        if pat_size(canon.node) >= pat_size(m.node) &&
           pattern_matches(m.node, canon.node; conservative=true)
            verbose && @info "EGraphPruning: rejected Forbidden($(m.expr)) — would prune its own canonical $(canon.expr)"
            continue
        end
        # Subsumption: skip patterns already covered by an accepted constraint.
        any(pattern_matches(q, m.node; conservative=false) for q in accepted) && continue
        push!(accepted, m.node)
        push!(derived, DerivedConstraint(
            Forbidden(m.node), :forbidden,
            "Forbidden($(m.expr)): equivalent to canonical $(canon.expr)"))
    end

    return derived
end

"""
    add_derived_constraints!(grammar; max_depth=2, theory="lia", verbose=false) :: Vector{DerivedConstraint}

Derive equivalence-based constraints and add them to `grammar` in place.
Returns the derived constraints (with provenance descriptions) for reporting.
"""
function add_derived_constraints!(grammar::AbstractGrammar; kwargs...)
    derived = derive_constraints(grammar; kwargs...)
    for d in derived
        addconstraint!(grammar, d.constraint)
    end
    return derived
end

end # module EGraphPruning
