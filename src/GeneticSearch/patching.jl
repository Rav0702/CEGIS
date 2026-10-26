"""
    patching.jl

The **guarded patch** (RQ1_RQ2_PLAN.md §7.3): at a node `n` that SMT localization
found repairable, write the input-conditional change its angelic values ask for,

    n  :=  ite(g, e, n)

where `g` is true exactly on the inputs whose value must change and false on those
whose value must stay, and `e` produces the required (angelic) value on the former.
At a Bool node the same shape is `(g && e) || (!g && n)`.

- `PatchKit(grammar)` — the grammar's building blocks (comparison, `ite`, `+`/`-`,
  `and`/`not` rules; variable and 0/1 leaves). Missing rules make the corresponding
  candidates unavailable, never an error.
- `separating_guards(kit, change, keep)` — guards over the inputs, smallest first: atoms
  `a ⋈ b` (`⋈ ∈ {<=, >=, ==}`, `a, b` variables or constants), their negations, then
  conjunctions of two.
- `matching_terms(kit, change, targets)` — smallest Int terms (bottom-up over leaves,
  `+`, `-`, depth ≤ 3) or Bool atoms equal to the target values on the change inputs.
- `site_patches(kit, tree, path, fail, pass)` — partial guarded repairs `(g, e, covered)`:
  `e` fixes some failing inputs, `g` covers them and avoids every passing input `e` would
  break (stage 2 construction as amended; see the docstring).
- `guarded_patch(tree, path, kit, g, e)` / `plain_patch(tree, path, e)`.

Candidates are evaluated concretely on the given inputs (program inputs, `Dict{Symbol}`),
so everything here is interpreter-side — no solver.
"""

struct PatchKit
    grammar::AbstractGrammar
    le::Int
    ge::Int
    eq::Int
    notr::Int
    andr::Int
    orr::Int
    ite::Int
    plus::Int
    minus::Int
    leaves::Vector{Int}          # Expr-typed variable and constant leaves
    leafval::Vector{Any}         # Symbol (variable) or Int (constant)
end

function PatchKit(g::AbstractGrammar)
    find(e) = something(findfirst(==(e), g.rules), 0)
    leaves = Int[]; vals = Any[]
    for (i, r) in enumerate(g.rules)
        g.types[i] === :BoolExpr && continue
        if r isa Symbol && isempty(g.childtypes[i])
            push!(leaves, i); push!(vals, r)
        elseif r isa Integer && !(r isa Bool)
            push!(leaves, i); push!(vals, Int(r))
        end
    end
    PatchKit(g, find(:(Expr <= Expr)), find(:(Expr >= Expr)), find(:(Expr == Expr)),
             find(:(!BoolExpr)), find(:(BoolExpr && BoolExpr)), find(:(BoolExpr || BoolExpr)),
             find(:(ifelse(BoolExpr, Expr, Expr))), find(:(Expr + Expr)), find(:(Expr - Expr)),
             leaves, vals)
end

_leafv(v, x::Dict{Symbol,Any}) = v isa Symbol ? x[v] : v
_cmp(op::Symbol, x, y) = op === :<= ? x <= y : op === :>= ? x >= y : x == y

"""A candidate: its tree, its size, and its values on the inputs."""
struct Cand
    tree::RuleNode
    size::Int
    vals::Vector{Any}
end

"""Atoms `a ⋈ b` over distinct leaf pairs, with their values on `inputs`."""
function _atoms(kit::PatchKit, inputs)
    out = Cand[]
    for (op, r) in ((:<=, kit.le), (:>=, kit.ge), (:(==), kit.eq))
        r == 0 && continue
        for (i, a) in enumerate(kit.leaves), (j, b) in enumerate(kit.leaves)
            i == j && continue
            (op === :(==) && j < i) && continue                  # symmetric
            va, vb = kit.leafval[i], kit.leafval[j]
            (va isa Int && vb isa Int) && continue                # constant comparison
            vals = Any[_cmp(op, _leafv(va, inp), _leafv(vb, inp)) for inp in inputs]
            push!(out, Cand(RuleNode(r, [RuleNode(a), RuleNode(b)]), 3, vals))
        end
    end
    return out
end

_neg(kit, c::Cand) = kit.notr == 0 ? nothing :
    Cand(RuleNode(kit.notr, [c.tree]), c.size + 1, Any[!v for v in c.vals])

"""
    separating_guards(kit, change, keep; max=50) -> Vector{RuleNode}

Guards true on every `change` input and false on every `keep` input, smallest first.
"""
function separating_guards(kit::PatchKit, change::Vector{Dict{Symbol,Any}},
                           keep::Vector{Dict{Symbol,Any}}; max::Int = 50)::Vector{RuleNode}
    inputs = vcat(change, keep)
    nc = length(change)
    atoms = _atoms(kit, inputs)
    lits = copy(atoms)
    for a in atoms
        n = _neg(kit, a); n === nothing || push!(lits, n)
    end
    sep(c) = all(c.vals[1:nc]) && !any(c.vals[nc+1:end])
    found = [c for c in lits if sep(c)]
    if isempty(found) && kit.andr != 0
        pos = [c for c in lits if all(c.vals[1:nc])]              # each conjunct holds on all change
        for i in eachindex(pos), j in (i+1):length(pos)
            a, b = pos[i], pos[j]
            if !any(k -> a.vals[k] && b.vals[k], (nc+1):length(inputs))
                push!(found, Cand(RuleNode(kit.andr, [a.tree, b.tree]), a.size + b.size + 1, Any[]))
            end
            length(found) >= 4 * max && break
        end
    end
    sort!(found; by = c -> c.size)
    return [c.tree for c in first(found, max)]
end

"""
    matching_terms(kit, change, targets; bool=false, max=50) -> Vector{RuleNode}

Smallest terms whose value on each `change` input equals the corresponding target:
Int terms as bounded chains (`_enum_terms`); Bool targets from atoms and
their negations.
"""
function matching_terms(kit::PatchKit, change::Vector{Dict{Symbol,Any}}, targets::Vector;
                        bool::Bool = false, max::Int = 50)::Vector{RuleNode}
    if bool
        want = Any[t isa Bool ? t : t == 1 for t in targets]
        lits = _atoms(kit, change)
        for a in copy(lits)
            n = _neg(kit, a); n === nothing || push!(lits, n)
        end
        hits = sort([c for c in lits if c.vals == want]; by = c -> c.size)
        return [c.tree for c in first(hits, max)]
    end
    want = Any[Int(t) for t in targets]
    return _enum_terms(kit, change, vals -> vals == want; max = max)
end

"""
Bottom-up Int terms over the leaves, grown as chains `t ⊕ leaf` / `leaf ⊕ t`
(`⊕ ∈ {+, -}`) up to `extra` operators, deduplicated by their values on the inputs
(observational equivalence). Returns the smallest accepted terms. Chains keep the space
linear in the depth (a full `t ⊕ t` product explodes past depth 2) and still reach the
constants and offsets these grammars need (`1 + 1 + 1`, `x + 1`, `x - y`).
"""
function _enum_terms(kit::PatchKit, inputs, accept; extra::Int = 3, max::Int = 50)
    leaves = [Cand(RuleNode(r), 1, Any[_leafv(v, x) for x in inputs]) for (r, v) in zip(kit.leaves, kit.leafval)]
    seen = Dict{Vector{Any},Cand}()
    for c in leaves; haskey(seen, c.vals) || (seen[c.vals] = c); end
    hits = [c for c in values(seen) if accept(c.vals)]
    frontier = collect(values(seen))
    for _ in 1:extra
        isempty(hits) || break
        new = Cand[]
        for a in frontier, b in leaves, (r, f) in ((kit.plus, +), (kit.minus, -))
            r == 0 && continue
            for (x, y) in ((a, b), (b, a))
                vals = Any[f(x.vals[k], y.vals[k]) for k in eachindex(inputs)]
                haskey(seen, vals) && continue
                cnd = Cand(RuleNode(r, [x.tree, y.tree]), x.size + y.size + 1, vals)
                seen[vals] = cnd
                push!(new, cnd)
                accept(vals) && push!(hits, cnd)
            end
        end
        frontier = new
    end
    sort!(hits; by = c -> c.size)
    return [c.tree for c in first(hits, max)]
end

"""
    repair_terms(kit, tree, path, inputs, ok; max=50) -> Vector{RuleNode}

Smallest terms `e` such that the program with the node at `path` replaced by `e` is
correct on every one of `inputs`, judged by `ok(i, output)::Bool`. Int nodes: bounded
chains over leaves, `+`, `-` (`_enum_terms`); Bool nodes: atoms and their negations.

Why not match the SMT model's angelic values: a relaxed intermediate node usually
admits many values per input (only the program output is constrained), and the model
is one arbitrary choice among them — exact matching almost never succeeds (measured:
0–2% of sites). Checking the *output* accepts every term that actually repairs.
"""
function repair_terms(kit::PatchKit, tree::RuleNode, path::NodePath,
                      inputs::Vector{Dict{Symbol,Any}}, ok; max::Int = 50)::Vector{RuleNode}
    isempty(inputs) && return RuleNode[]
    ty = _node_ty(kit.grammar, node_at(tree, path))
    good(vals) = all(i -> begin
        out = try
            _symeval(tree, Int[], path, vals[i], ty, kit.grammar, inputs[i], nothing)[1]
        catch
            nothing
        end
        out !== nothing && ok(i, out isa Bool ? Int(out) : out)
    end, eachindex(inputs))
    if ty === :bool
        lits = _atoms(kit, inputs)
        for a in copy(lits)
            n = _neg(kit, a); n === nothing || push!(lits, n)
        end
        hits = sort([c for c in lits if good(c.vals)]; by = c -> c.size)
        return [c.tree for c in first(hits, max)]
    end
    return _enum_terms(kit, inputs, good; max = max)
end

"""Atoms and their negations over `inputs` (the Bool candidates for guards and Bool terms)."""
function _literals(kit::PatchKit, inputs)
    lits = _atoms(kit, inputs)
    for a in copy(lits)
        n = _neg(kit, a); n === nothing || push!(lits, n)
    end
    return lits
end

"""All Int terms of `_enum_terms`' space (no acceptance test), capped at `cap` distinct value vectors."""
function _term_pool(kit::PatchKit, inputs; extra::Int = 3, cap::Int = 20_000)
    leaves = [Cand(RuleNode(r), 1, Any[_leafv(v, x) for x in inputs]) for (r, v) in zip(kit.leaves, kit.leafval)]
    seen = Dict{Vector{Any},Cand}()
    for c in leaves; haskey(seen, c.vals) || (seen[c.vals] = c); end
    frontier = collect(values(seen))
    for _ in 1:extra
        new = Cand[]
        for a in frontier, b in leaves, (r, f) in ((kit.plus, +), (kit.minus, -))
            r == 0 && continue
            for (x, y) in ((a, b), (b, a))
                vals = Any[f(x.vals[k], y.vals[k]) for k in eachindex(inputs)]
                haskey(seen, vals) && continue
                cnd = Cand(RuleNode(r, [x.tree, y.tree]), x.size + y.size + 1, vals)
                seen[vals] = cnd
                push!(new, cnd)
            end
            length(seen) >= cap && break
        end
        frontier = new
        length(seen) >= cap && break
    end
    return collect(values(seen))
end

"""
    site_patches(kit, tree, path, fail, pass; extra=3, max=50, per_term=5, conj_terms=50)
        -> Vector{Tuple{RuleNode,RuleNode,Int}}

Guarded patches `(g, e, covered)` for the node at `path`, best first. `fail` / `pass` are
the failing / passing evidence as `(input, ok)` pairs with `ok(output)::Bool`.

A term `e` *repairs* the failing inputs `R_e` (the program with node := e is correct there)
and *breaks* the passing inputs `B_e`. A guard `g` is valid for `e` when it is false on all
of `B_e` and true on some input of `R_e`: `ite(g, e, n)` then fixes `R_e ∩ g` and every
passing input stays passing. Ranked by `|R_e ∩ g|` (descending), then size. Partial repairs
are the point: a case split rarely admits one term for all of its failing inputs.

One term per `(R_e, B_e)` signature (the smallest); guards are literals, and conjunctions of
two literals for the `conj_terms` best-repairing terms when no literal covers all of `R_e`.
Program outputs are computed by `_symeval` with the node's value substituted, memoized per
(input, value) — no solver.
"""
function site_patches(kit::PatchKit, tree::RuleNode, path::NodePath, fail::Vector, pass::Vector;
                      extra::Int = 3, max::Int = 50, per_term::Int = 5, conj_terms::Int = 50,
                      pool_cap::Int = 20_000)::Vector{Tuple{RuleNode,RuleNode,Int}}
    isempty(fail) && return Tuple{RuleNode,RuleNode,Int}[]
    items = vcat(fail, pass)
    nf, np = length(fail), length(pass)
    inputs = Dict{Symbol,Any}[it[1] for it in items]
    ty = _node_ty(kit.grammar, node_at(tree, path))
    memo = [Dict{Any,Bool}() for _ in items]
    okv(i, v) = get!(memo[i], v) do
        out = try
            _symeval(tree, Int[], path, v, ty, kit.grammar, inputs[i], nothing)[1]
        catch
            nothing
        end
        out !== nothing && items[i][2](out isa Bool ? Int(out) : out)
    end
    lits = _literals(kit, inputs)
    pool = ty === :bool ? lits : _term_pool(kit, inputs; extra = extra, cap = pool_cap)
    sigs = Dict{Tuple{BitVector,BitVector},Cand}()
    for c in pool
        R = BitVector([okv(i, c.vals[i]) for i in 1:nf])
        any(R) || continue
        B = BitVector([!okv(nf + j, c.vals[nf + j]) for j in 1:np])
        k = (R, B)
        (haskey(sigs, k) && sigs[k].size <= c.size) || (sigs[k] = c)
    end
    litF = [BitVector(Bool[v for v in l.vals[1:nf]]) for l in lits]
    litP = [BitVector(Bool[v for v in l.vals[nf+1:end]]) for l in lits]
    out = Tuple{RuleNode,RuleNode,Int,Int}[]
    ranked = sort(collect(sigs); by = kv -> (-count(kv[1][1]), kv[2].size))
    for (n, ((R, B), e)) in enumerate(ranked)
        best = Tuple{RuleNode,Int,Int}[]
        for (l, gF, gP) in zip(lits, litF, litP)
            any(gP .& B) && continue
            cov = count(gF .& R)
            cov > 0 && push!(best, (l.tree, cov, l.size))
        end
        full = !isempty(best) && maximum(b -> b[2], best) == count(R)
        if !full && n <= conj_terms && kit.andr != 0
            idx = [i for i in eachindex(lits) if any(litF[i] .& R)]
            for a in eachindex(idx), b in (a+1):length(idx)
                i, j = idx[a], idx[b]
                any(litP[i] .& litP[j] .& B) && continue
                cov = count(litF[i] .& litF[j] .& R)
                cov > 0 && push!(best, (RuleNode(kit.andr, [lits[i].tree, lits[j].tree]), cov,
                                        lits[i].size + lits[j].size + 1))
            end
        end
        sort!(best; by = b -> (-b[2], b[3]))
        for (g, cov, sz) in first(best, per_term)
            push!(out, (g, e.tree, cov, sz + e.size))
        end
    end
    sort!(out; by = t -> (-t[3], t[4]))
    return [(t[1], t[2], t[3]) for t in first(out, max)]
end

"""
    guarded_patch(tree, path, kit, g, e) -> Union{RuleNode,Nothing}

A copy of `tree` with the node at `path` replaced by `ite(g, e, node)` (Int node) or
`(g && e) || (!g && node)` (Bool node). `nothing` if the grammar lacks the rules.
"""
function guarded_patch(tree::RuleNode, path::NodePath, kit::PatchKit, g::RuleNode, e::RuleNode)
    t = deepcopy(tree)
    node = node_at(t, path)
    old = deepcopy(node)
    new = if _node_ty(kit.grammar, node) === :int
        kit.ite == 0 && return nothing
        RuleNode(kit.ite, [deepcopy(g), deepcopy(e), old])
    else
        (kit.andr == 0 || kit.orr == 0 || kit.notr == 0) && return nothing
        RuleNode(kit.orr, [RuleNode(kit.andr, [deepcopy(g), deepcopy(e)]),
                           RuleNode(kit.andr, [RuleNode(kit.notr, [deepcopy(g)]), old])])
    end
    insert!(t, nodeloc_at(t, path), new)
    return t
end

"""A copy of `tree` with the node at `path` replaced by `e` (unconditional patch)."""
function plain_patch(tree::RuleNode, path::NodePath, e::RuleNode)::RuleNode
    t = deepcopy(tree)
    insert!(t, nodeloc_at(t, path), deepcopy(e))
    return t
end
